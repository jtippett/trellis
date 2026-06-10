require "json"
require "uri"
require "../base_provider"
require "../registry"
require "../context"
require "../message"
require "../content_part"
require "../response"
require "../usage"
require "../options"

module ReqLLM::Providers
  # The OpenAI reference provider. Targets the Chat Completions API
  # (`POST /v1/chat/completions`). Request encoding and response decoding mirror
  # `req_llm/lib/req_llm/providers/openai.ex` plus the shared body/usage builders
  # in `req_llm/lib/req_llm/provider/defaults.ex`.
  #
  # Subclasses `BaseProvider`, which wires `attach` in the fixed Pipeline-contract
  # step order; this class supplies identity, `prepare_request`, `encode_body`,
  # and `decode_response`. Tool calling (encode + decode) is wired here;
  # streaming and the Responses API are out of scope for this unit.
  class OpenAI < ReqLLM::BaseProvider
    def id : String
      "openai"
    end

    def default_base_url : String
      "https://api.openai.com/v1"
    end

    def default_env_key : String
      "OPENAI_API_KEY"
    end

    # Build a fresh chat request: a POST to `<base_url>/chat/completions`
    # carrying the typed pipeline state (model, context, operation, options).
    # Encoding/auth/decoding are wired later by `attach`.
    def prepare_request(operation : Symbol, model : LLMDB::Model, data, opts) : HTTP::Request
      ensure_provider!(model)

      context = data.as(ReqLLM::Context)
      url = URI.parse("#{default_base_url}/chat/completions")
      req = HTTP::Request.new("POST", url)
      req.operation = operation
      req.model = model
      req.context = context
      req.options = opts.as(ReqLLM::Options::Validated)
      req
    end

    # Request step: serialize the typed state into the OpenAI chat wire body.
    def encode_body(req : HTTP::Request) : HTTP::Request
      model = req.model.as(LLMDB::Model)
      context = req.context.as(ReqLLM::Context)
      opts = req.options.as(ReqLLM::Options::Validated)
      req.body = encode_chat_body(model, context, opts)
      req
    end

    # Build the Chat Completions request body as a JSON string. Public so the
    # canonical golden test can exercise it without a full pipeline run.
    #
    # Mirrors `Defaults.encode_chat_body`/`add_basic_options`: value-based
    # conditionals (not key-presence), `maybe_put` semantics that drop only nil.
    #   * `temperature` — emitted only when set (default nil → genuinely absent).
    #   * `max_tokens`  — emitted only when set.
    #   * `stream`      — always emitted (the nimble default is `false`, and
    #                     `maybe_put` keeps a non-nil `false`).
    #   * `tools`       — omitted entirely when the list is empty (upstream guards
    #                     `tools != []`).
    def encode_chat_body(model : LLMDB::Model, context : ReqLLM::Context,
                         opts : ReqLLM::Options::Validated) : String
      body = {} of String => JSON::Any
      body["model"] = JSON::Any.new(model.id)
      body["messages"] = JSON::Any.new(encode_messages(context.messages))

      if temperature = opts.fetch_float?(:temperature)
        body["temperature"] = JSON::Any.new(temperature)
      end

      if max_tokens = opts.fetch_int?(:max_tokens)
        body["max_tokens"] = JSON::Any.new(max_tokens.to_i64)
      end

      # Sampling params (upstream `add_basic_options`): value-based, emitted only
      # when set. Wire keys match OpenAI exactly.
      if top_p = opts.fetch_float?(:top_p)
        body["top_p"] = JSON::Any.new(top_p)
      end

      if frequency_penalty = opts.fetch_float?(:frequency_penalty)
        body["frequency_penalty"] = JSON::Any.new(frequency_penalty)
      end

      if presence_penalty = opts.fetch_float?(:presence_penalty)
        body["presence_penalty"] = JSON::Any.new(presence_penalty)
      end

      if seed = opts.fetch_int?(:seed)
        body["seed"] = JSON::Any.new(seed.to_i64)
      end

      # `stop` accepts a single String or an Array(String); render each shape.
      case stop = opts.fetch_stop
      when String
        body["stop"] = JSON::Any.new(stop)
      when Array(String)
        body["stop"] = JSON::Any.new(stop.map { |s| JSON::Any.new(s) })
      end

      # stream is always present (value-based: the materialized default is false).
      body["stream"] = JSON::Any.new(opts.fetch_bool(:stream))

      # tools omitted entirely when empty (upstream guards `tools != []`); when
      # present, each Tool renders to the OpenAI function shape via to_json_schema.
      # `tool_choice` is emitted ONLY when the caller set it explicitly — upstream
      # `Defaults.encode_chat_body` puts no default, so we omit the key otherwise.
      tools = opts.fetch_tools
      unless tools.empty?
        body["tools"] = JSON::Any.new(tools.map { |t| JSON::Any.new(encode_tool(t)) })
      end

      body.to_json
    end

    # Response step: decode a Chat Completions JSON response into a semantic
    # `Response`, populating the assistant message, finish reason, and usage so
    # downstream usage/cost steps work end-to-end. Mirrors
    # `Defaults.decode_response_body_openai_format` (text + tool calls +
    # finish_reason + usage).
    def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      model = req.model.as(LLMDB::Model)
      data = JSON.parse(resp.body)

      model_name = data["model"]?.try(&.as_s?) || model.id
      choices = data["choices"]?.try(&.as_a?) || [] of JSON::Any
      first_choice = choices[0]?

      finish_wire = first_choice.try(&.["finish_reason"]?).try(&.as_s?)
      finish_reason = ReqLLM::FinishReason.from_wire(finish_wire)

      message_json = first_choice.try(&.["message"]?)

      text = message_json
        .try(&.["content"]?)
        .try(&.as_s?) || ""

      # Tool calls: decode `message.tool_calls` (OpenAI shape `[{id, type,
      # function: {name, arguments}}]`) via `ToolCall.from_wire`, preserving the
      # id/name/raw-arguments round-trip. Absent or non-array → no tool calls.
      tool_calls = decode_tool_calls(message_json)

      message = ReqLLM::Message.new(
        ReqLLM::Role::Assistant,
        text,
        tool_calls: tool_calls.empty? ? nil : tool_calls,
      )

      usage = decode_usage(data["usage"]?)

      # CONTEXT MERGE (upstream `Context.merge_response`): the returned context
      # is the input messages PLUS the appended assistant reply, so multi-turn
      # callers can feed `resp.context` straight back in without losing the turn.
      # Build a fresh Context (dup the input messages) to avoid mutating the
      # caller's `req.context`.
      input = req.context
      merged_messages = input ? input.messages.dup : [] of ReqLLM::Message
      merged_messages << message
      merged_tools = input.try(&.tools) || [] of ReqLLM::Tool
      merged_context = ReqLLM::Context.new(merged_messages, merged_tools)

      resp.decoded = ReqLLM::Response.new(
        model: model_name,
        context: merged_context,
        message: message,
        usage: usage,
        finish_reason: finish_reason,
      )

      {req, resp}
    end

    # Decode ONE OpenAI streaming SSE event into zero-or-more `StreamChunk`s.
    # PURE: no IO/concurrency. The chunks emit EXACTLY the metadata the
    # `ChunkAccumulator` reads, so folding a stream yields the same `Response` as
    # the non-streaming `decode_response`. Mirrors upstream
    # `Defaults.default_decode_stream_event` (the OpenAI chat-completions shape).
    #
    # A single wire event can produce MULTIPLE chunks (e.g. a content delta plus a
    # finish_reason meta, or N tool-call deltas, or a final usage-only frame), so
    # all are collected and returned in order.
    #
    #   * `data == "[DONE]"` → `[]` (terminal sentinel; SU1 leaves it as data).
    #   * blank/empty data → `[]` (SU1 emits field-only frames as `data == ""`;
    #     guarded so we never `JSON.parse("")`).
    #   * `choices[0].delta.content` (non-empty) → Content chunk.
    #   * `choices[0].delta.reasoning`/`reasoning_content` (non-empty) → Thinking.
    #   * `choices[0].delta.tool_calls[]` → one ToolCall delta chunk each.
    #   * `choices[0].finish_reason` (non-null) → Meta chunk (wire string).
    #   * top-level `usage` (the include_usage final frame) → Meta chunk with
    #     usage NORMALIZED to the accumulator's canonical keys.
    def decode_stream_event(event : ReqLLM::SSE::Event) : Array(ReqLLM::StreamChunk)
      decode_stream_event(event.data)
    end

    # :ditto: convenience overload accepting the raw SSE `data` payload directly.
    def decode_stream_event(data : String) : Array(ReqLLM::StreamChunk)
      chunks = [] of ReqLLM::StreamChunk
      return chunks if data == "[DONE]"
      stripped = data.strip
      return chunks if stripped.empty?

      parsed = JSON.parse(stripped)

      # In-stream error frame: a 200 OK stream can carry `{"error": {...}}`
      # mid-flight (content filter, server-side failure). The transport status
      # was 200 so `Steps.error` never fired, so surface it here — raising
      # propagates to the consumer via the producer fiber, matching the
      # non-streaming path where `Steps.error` raises on a bad response.
      if err = parsed["error"]?
        message = err["message"]?.try(&.as_s?) || err.as_s? || err.to_json
        raise ReqLLM::Error::API::Response.new("OpenAI stream error: #{message}")
      end

      # Choices: content/thinking/tool-call deltas + per-choice finish_reason.
      if choices = parsed["choices"]?.try(&.as_a?)
        choices.each do |choice|
          delta = choice["delta"]?

          if delta
            if content = delta["content"]?.try(&.as_s?)
              chunks << ReqLLM::StreamChunk.text(content) unless content.empty?
            end

            reasoning = delta["reasoning"]?.try(&.as_s?) ||
                        delta["reasoning_content"]?.try(&.as_s?)
            if reasoning && !reasoning.empty?
              chunks << ReqLLM::StreamChunk.thinking(reasoning)
            end

            if tool_calls = delta["tool_calls"]?.try(&.as_a?)
              tool_calls.each do |tc|
                chunks << decode_tool_call_delta(tc)
              end
            end
          end

          if finish_wire = choice["finish_reason"]?.try(&.as_s?)
            chunks << ReqLLM::StreamChunk.meta(
              {"finish_reason" => JSON::Any.new(finish_wire)})
          end
        end
      end

      # Top-level usage (include_usage final frame; choices may be empty).
      if usage = parsed["usage"]?
        if normalized = normalize_stream_usage(usage)
          chunks << ReqLLM::StreamChunk.meta({"usage" => normalized})
        end
      end

      chunks
    end

    # Build a ToolCall delta chunk from one OpenAI `delta.tool_calls[]` entry.
    # The first fragment for an index carries `id` + `function.name`; subsequent
    # fragments carry partial `function.arguments` pieces. An empty arguments
    # string (the opening fragment) is NOT emitted as a fragment.
    private def decode_tool_call_delta(tc : JSON::Any) : ReqLLM::StreamChunk
      index = tc["index"]?.try(&.as_i?) || 0
      id = tc["id"]?.try(&.as_s?)
      function = tc["function"]?
      name = function.try(&.["name"]?).try(&.as_s?)
      args = function.try(&.["arguments"]?).try(&.as_s?)
      fragment = (args && !args.empty?) ? args : nil

      ReqLLM::StreamChunk.tool_call_delta(
        index, id: id, name: name, arguments_fragment: fragment)
    end

    # Normalize a streaming `usage` object into the accumulator's canonical keys
    # (`input_tokens`/`output_tokens`/`reasoning_tokens`/`cached_tokens` as Ints).
    # Same key mapping as the non-streaming `decode_usage`. Returns nil when the
    # value is not an object.
    private def normalize_stream_usage(usage : JSON::Any) : JSON::Any?
      return nil unless h = usage.as_h?
      input = h["prompt_tokens"]?.try(&.as_i?) || 0
      output = h["completion_tokens"]?.try(&.as_i?) || 0
      reasoning = usage.dig?("completion_tokens_details", "reasoning_tokens").try(&.as_i?) || 0
      cached = usage.dig?("prompt_tokens_details", "cached_tokens").try(&.as_i?) || 0

      JSON::Any.new({
        "input_tokens"     => JSON::Any.new(input.to_i64),
        "output_tokens"    => JSON::Any.new(output.to_i64),
        "reasoning_tokens" => JSON::Any.new(reasoning.to_i64),
        "cached_tokens"    => JSON::Any.new(cached.to_i64),
      } of String => JSON::Any)
    end

    # Encode each message to the OpenAI `{role, content}` shape. A single bare
    # text part collapses to a string `content` (upstream
    # `normalize_encoded_content`); richer multi-part content becomes an array of
    # typed blocks.
    private def encode_messages(messages : Array(ReqLLM::Message)) : Array(JSON::Any)
      messages.map { |m| JSON::Any.new(encode_message(m)) }
    end

    private def encode_message(message : ReqLLM::Message) : Hash(String, JSON::Any)
      {
        "role"    => JSON::Any.new(role_to_wire(message.role)),
        "content" => encode_content(message.content),
      }
    end

    private def encode_content(parts : Array(ReqLLM::ContentPart)) : JSON::Any
      encoded = parts.compact_map { |p| encode_content_part(p) }

      # Collapse a single plain text block to a bare string; an empty list to ""
      # (strict OpenAI rejects `"content": []`).
      if encoded.empty?
        JSON::Any.new("")
      elsif encoded.size == 1 && (only = encoded.first) &&
            only.size == 2 && only["type"]?.try(&.as_s?) == "text"
        only["text"]
      else
        JSON::Any.new(encoded.map { |h| JSON::Any.new(h) })
      end
    end

    private def encode_content_part(part : ReqLLM::ContentPart) : Hash(String, JSON::Any)?
      case part.type
      when .text?
        {"type" => JSON::Any.new("text"), "text" => JSON::Any.new(part.text || "")}
      else
        # Non-text parts (images/files/etc.) are out of scope for this unit.
        nil
      end
    end

    # Render a Tool to the OpenAI function wire shape (mirrors upstream
    # `Schema.to_openai_format`): `{"type":"function","function":{name,
    # description, parameters}}`, where `parameters` is the normalized JSON Schema
    # object from `Tool#to_json_schema`.
    private def encode_tool(tool : ReqLLM::Tool) : Hash(String, JSON::Any)
      function = {
        "name"        => JSON::Any.new(tool.name),
        "description" => JSON::Any.new(tool.description),
        "parameters"  => JSON::Any.new(tool.to_json_schema),
      } of String => JSON::Any
      # Upstream `Schema.to_openai_format` only adds `"strict": true` when the
      # tool is strict, and omits the key otherwise (never emits `strict: false`).
      function["strict"] = JSON::Any.new(true) if tool.strict

      {
        "type"     => JSON::Any.new("function"),
        "function" => JSON::Any.new(function),
      } of String => JSON::Any
    end

    private def role_to_wire(role : ReqLLM::Role) : String
      case role
      when .user?      then "user"
      when .assistant? then "assistant"
      when .system?    then "system"
      when .tool?      then "tool"
      else                  role.to_s.downcase
      end
    end

    # Decode `message.tool_calls` into `ReqLLM::ToolCall`s. Each entry is the
    # OpenAI nested wire shape, which `ToolCall.from_wire` consumes directly
    # (preserving id, name, and the raw `arguments` JSON string for `args_map`).
    private def decode_tool_calls(message : JSON::Any?) : Array(ReqLLM::ToolCall)
      raw = message.try(&.["tool_calls"]?).try(&.as_a?)
      return [] of ReqLLM::ToolCall unless raw
      raw.map { |entry| ReqLLM::ToolCall.from_wire(entry) }
    end

    private def decode_usage(usage : JSON::Any?) : ReqLLM::Usage
      return ReqLLM::Usage.new unless usage
      h = usage.as_h?
      return ReqLLM::Usage.new unless h

      input = h["prompt_tokens"]?.try(&.as_i?) || 0
      output = h["completion_tokens"]?.try(&.as_i?) || 0
      reasoning = usage.dig?("completion_tokens_details", "reasoning_tokens").try(&.as_i?) || 0
      cached = usage.dig?("prompt_tokens_details", "cached_tokens").try(&.as_i?) || 0

      ReqLLM::Usage.new(
        input_tokens: input,
        output_tokens: output,
        reasoning_tokens: reasoning,
        cached_tokens: cached,
      )
    end

    # Guard: a request's model must belong to this provider.
    private def ensure_provider!(model : LLMDB::Model) : Nil
      return if model.provider == id
      raise ReqLLM::Error::Invalid::Parameter.new(
        "model provider #{model.provider.inspect} does not match provider #{id.inspect}")
    end
  end
end

ReqLLM::Registry.register(ReqLLM::Providers::OpenAI.new)
