require "json"
require "../stream_chunk"
require "../response"
require "../message"
require "../content_part"
require "../tool_call"
require "../usage"
require "../context"

module ReqLLM
  # Folds an ordered sequence of `StreamChunk`s into a single
  # `ReqLLM::Response` — the same shape a non-streaming `decode_response`
  # produces, so `stream.join` yields a Response equivalent to the
  # non-streaming path.
  #
  # PURE: no IO, no concurrency. Feed chunks with `add`/`<<` (the hot path,
  # used incrementally by the streaming `join`), then call `finish` once to
  # materialise the Response. Mirrors the fold semantics of upstream
  # `ReqLLM.Provider.ChunkAccumulator` (chunk_accumulator.ex).
  #
  # ## StreamChunk contract (what SU4's decode_stream_event must emit)
  #
  # * `:content` — `text` carries the text delta. Concatenated in order.
  # * `:thinking` — `text` carries the reasoning delta. Concatenated in order
  #   into a single `ContentPart.thinking` part.
  # * `:tool_call` — tool calls stream as deltas grouped by index:
  #   * `metadata["index"]` (Int) — REQUIRED; groups fragments belonging to one
  #     call. Defaults to 0 when absent.
  #   * `name` (the struct field) — the function name; present on the first
  #     fragment for an index. The accumulator takes any non-nil name (last
  #     wins, but normally only the first fragment carries it).
  #   * `metadata["id"]` (String) — the provider tool-call id; present on the
  #     first fragment for an index. A `call_<uuid>` id is generated if never
  #     seen.
  #   * `metadata["arguments_fragment"]` (String) — a partial JSON string piece;
  #     concatenated in arrival order per index to form the final `arguments`
  #     JSON string.
  #   * `arguments` (the struct field, a Hash) — OPTIONAL fallback used only
  #     when NO `arguments_fragment` pieces were seen for that index (i.e. the
  #     provider delivered already-assembled arguments). JSON-encoded.
  # * `:meta` — trailing/terminal metadata:
  #   * `metadata["finish_reason"]` (String wire value) — converted via
  #     `FinishReason.from_wire`. Latest non-nil wins.
  #   * `metadata["usage"]` (object) — token counts with the CANONICAL keys
  #     `input_tokens`, `output_tokens`, `reasoning_tokens`, `cached_tokens`
  #     (Ints; missing → 0). SU4 normalises the provider's usage into this
  #     shape. Latest meta usage wins (terminal capture).
  class ChunkAccumulator
    # Per-index accumulation state for a streaming tool call.
    private class ToolCallBuilder
      property id : String?
      property name : String?
      property has_fragments = false
      property arguments : Hash(String, JSON::Any)?
      getter args : String::Builder

      def initialize
        @args = String::Builder.new
      end
    end

    def initialize
      @text = String::Builder.new
      @thinking = String::Builder.new
      @tool_order = [] of Int32
      @tool_builders = {} of Int32 => ToolCallBuilder
      @finish_reason_wire = nil.as(String?)
      @usage = nil.as(Usage?)
    end

    # Fold a single chunk into the accumulator. Pure — no IO.
    def add(chunk : StreamChunk) : self
      case chunk.type
      in ChunkType::Content
        if t = chunk.text
          @text << t
        end
      in ChunkType::Thinking
        if t = chunk.text
          @thinking << t
        end
      in ChunkType::ToolCall
        add_tool_call(chunk)
      in ChunkType::Meta
        add_meta(chunk)
      end
      self
    end

    # `<<` alias for `add`, enabling `acc << chunk`.
    def <<(chunk : StreamChunk) : self
      add(chunk)
    end

    # Materialise the accumulated chunks into a `Response`. Single-use: the
    # text/thinking buffers are consumed here. `model` is the model id string;
    # `context` is the input context whose messages the assistant reply is
    # appended to (mirroring the non-streaming context merge — the input is not
    # mutated).
    def finish(model : String, context : Context? = nil) : Response
      text = @text.to_s
      thinking = @thinking.to_s
      tool_calls = build_tool_calls

      # Match the non-streaming decode shape: always a single text part (even
      # empty), so `join == non-stream`. Thinking is appended as a separate
      # reasoning part when present.
      parts = [ContentPart.text(text)]
      parts << ContentPart.thinking(thinking) unless thinking.empty?

      message = Message.new(
        Role::Assistant,
        parts,
        tool_calls: tool_calls.empty? ? nil : tool_calls,
      )

      # Context merge (upstream Context.merge_response): input messages + the
      # appended assistant reply, tools preserved. Dup to avoid mutating input.
      merged_messages = context ? context.messages.dup : [] of Message
      merged_messages << message
      merged_tools = context.try(&.tools) || [] of Tool
      merged_context = Context.new(merged_messages, merged_tools)

      # Match non-streaming decode parity (so `join == non-stream`):
      # `FinishReason.from_wire(nil) == Other` (never nil), and absent usage is a
      # zeroed `Usage` (decode_usage never returns nil), not nil.
      finish_reason = FinishReason.from_wire(@finish_reason_wire)

      Response.new(
        model: model,
        context: merged_context,
        message: message,
        usage: @usage || Usage.new,
        finish_reason: finish_reason,
      )
    end

    private def add_tool_call(chunk : StreamChunk) : Nil
      index = chunk.metadata["index"]?.try(&.as_i?) || 0
      builder = @tool_builders[index]?
      unless builder
        builder = ToolCallBuilder.new
        @tool_builders[index] = builder
        @tool_order << index
      end

      if id = chunk.metadata["id"]?.try(&.as_s?)
        builder.id = id
      end
      if name = chunk.name
        builder.name = name
      end
      if frag = chunk.metadata["arguments_fragment"]?.try(&.as_s?)
        builder.args << frag
        builder.has_fragments = true
      end
      if args = chunk.arguments
        builder.arguments = args
      end
    end

    private def add_meta(chunk : StreamChunk) : Nil
      if reason = chunk.metadata["finish_reason"]?.try(&.as_s?)
        @finish_reason_wire = reason
      end
      if usage_any = chunk.metadata["usage"]?
        if parsed = parse_usage(usage_any)
          @usage = parsed
        end
      end
    end

    private def parse_usage(any : JSON::Any) : Usage?
      h = any.as_h?
      return nil unless h
      Usage.new(
        input_tokens: h["input_tokens"]?.try(&.as_i?) || 0,
        output_tokens: h["output_tokens"]?.try(&.as_i?) || 0,
        reasoning_tokens: h["reasoning_tokens"]?.try(&.as_i?) || 0,
        cached_tokens: h["cached_tokens"]?.try(&.as_i?) || 0,
      )
    end

    private def build_tool_calls : Array(ToolCall)
      @tool_order.map do |index|
        b = @tool_builders[index]
        arguments =
          if b.has_fragments
            b.args.to_s
          elsif args = b.arguments
            args.to_json
          else
            "{}"
          end
        ToolCall.new(b.id || ToolCall.generate_id, b.name || "", arguments)
      end
    end
  end
end
