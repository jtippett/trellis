require "json"
require "uri"
require "../base_provider"
require "../registry"
require "../context"
require "../message"
require "../content_part"
require "../response"
require "../schema"
require "../usage"
require "../tool_call"
require "../tool"
require "../options"

module ReqLLM::Providers
  # The Anthropic provider. Targets the Messages API (`POST /v1/messages`).
  # Request encoding and response decoding mirror
  # `req_llm/lib/req_llm/providers/anthropic.ex`, `anthropic/context.ex`, and
  # `anthropic/response.ex`.
  #
  # Subclasses `BaseProvider`, which wires `attach` in the fixed Pipeline-contract
  # step order; this class supplies identity, `prepare_request`, the auth-header
  # override (Anthropic uses `x-api-key` + `anthropic-version`, NOT
  # `Authorization: Bearer`), and the `encode_body`/`decode_response` steps.
  # Body encoding, response decoding, and streaming are filled by later units.
  class Anthropic < ReqLLM::BaseProvider
    DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
    DEFAULT_MAX_TOKENS        = 1024

    def id : String
      "anthropic"
    end

    def default_base_url : String
      "https://api.anthropic.com"
    end

    def default_env_key : String
      "ANTHROPIC_API_KEY"
    end

    # Build a fresh chat request: a POST to `<base_url>/v1/messages` carrying the
    # typed pipeline state (model, context, operation, options). Encoding/auth/
    # decoding are wired later by `attach`.
    def prepare_request(operation : Symbol, model : LLMDB::Model, data, opts) : HTTP::Request
      ensure_provider!(model)

      context = data.as(ReqLLM::Context)
      url = URI.parse("#{default_base_url}/v1/messages")
      req = HTTP::Request.new("POST", url)
      req.operation = operation
      req.model = model
      req.context = context
      req.options = opts.as(ReqLLM::Options::Validated)
      req
    end

    # Anthropic auth: `x-api-key` + `anthropic-version` (NOT `Authorization:
    # Bearer`). Overrides `BaseProvider#apply_common_headers`; preserves
    # AUTH-SKIP-ON-REPLAY (`Fixture.will_replay?`) so offline fixture replays need
    # no key. Shared by `attach` + `attach_stream`, so overriding here covers both
    # paths. `Content-Type` + `anthropic-version` are always set; `x-api-key` is
    # resolved only when we are NOT replaying.
    protected def apply_common_headers(req : HTTP::Request) : Nil
      req.headers["Content-Type"] = "application/json"
      req.headers["anthropic-version"] = DEFAULT_ANTHROPIC_VERSION
      unless ReqLLM::Fixture.will_replay?(req, id)
        api_key = ReqLLM::Keys.resolve(default_env_key, explicit_api_key(req))
        req.headers["x-api-key"] = api_key
      end
    end

    # Request step: serialize the typed state into the Anthropic Messages body.
    # For the `:object` operation (set by `generate_object`) it dispatches to
    # `encode_object_body`, which injects the synthetic `structured_output` tool
    # and forces it via `tool_choice` so the model returns the structured object
    # as that tool call's `input` (decode is unchanged; the `tool_use` block
    # already decodes into a `structured_output` ToolCall whose raw arguments the
    # shared `unwrap_object` reads).
    def encode_body(req : HTTP::Request) : HTTP::Request
      model = req.model.as(LLMDB::Model)
      context = req.context.as(ReqLLM::Context)
      opts = req.options.as(ReqLLM::Options::Validated)
      if req.operation == :object && (schema = req.object_schema)
        req.body = encode_object_body(
          model, context, opts, schema, req.object_schema_name || "output_schema")
      else
        req.body = encode_chat_body(model, context, opts)
      end
      req
    end

    # Build the Messages request body for the `:object` operation: the normal
    # Messages body but with a single synthetic `structured_output` tool (object
    # mode ignores any user tools — the forced tool IS the output channel) and a
    # forced `tool_choice: {type:"tool", name:"structured_output"}`. Mirrors
    # upstream `prepare_strict_tool_request` (anthropic.ex): the schema is run
    # through `Schema.enforce_strict` (required = all keys + additional
    # Properties:false) and encoded via the existing `encode_tool`. This is the
    # MINIMAL `tool_choice` support OU2 adds (only the forced-tool shape; general
    # `tool_choice` stays deferred). Public so a test can drive it directly with
    # an explicit schema + name.
    def encode_object_body(model : LLMDB::Model, context : ReqLLM::Context,
                           opts : ReqLLM::Options::Validated,
                           schema : Hash(String, JSON::Any), name : String) : String
      body = chat_body_hash(model, context, opts)

      tool = ReqLLM::Tool.new(
        "structured_output",
        "Generate structured output matching the provided schema",
        ReqLLM::Schema.enforce_strict(schema),
        strict: true,
      )
      body["tools"] = JSON::Any.new([JSON::Any.new(encode_tool(tool))])
      body["tool_choice"] = JSON::Any.new({
        "type" => JSON::Any.new("tool"),
        "name" => JSON::Any.new("structured_output"),
      } of String => JSON::Any)

      body.to_json
    end

    # Configure a STREAMING Messages request. Shares header/auth setup with the
    # non-streaming `attach` (via the overridden `apply_common_headers`, which
    # sets `x-api-key` + `anthropic-version` and honours AUTH-SKIP-ON-REPLAY so a
    # fixture replay needs no key), then adds the SSE `Accept` header Anthropic
    # requires and encodes the body with `stream: true`. The request URL is
    # already `<base>/v1/messages` from `prepare_request`. The producer fiber +
    # `StreamAdapter` drive transport and decoding; no Steps.error/decode/usage
    # are wired (the adapter handles non-2xx; the accumulator folds chunks).
    # Mirrors the OpenAI sibling, which sets the same `stream: true` body flag;
    # Anthropic ADDITIONALLY sets `Accept: text/event-stream`.
    def attach_stream(req : HTTP::Request) : HTTP::Request
      model = req.model.as(LLMDB::Model)
      context = req.context.as(ReqLLM::Context)
      opts = req.options.as(ReqLLM::Options::Validated)

      apply_common_headers(req) # x-api-key + anthropic-version + Content-Type
      req.headers["Accept"] = "text/event-stream"
      req.body = encode_chat_body(model, context, opts, stream: true)
      req
    end

    # Build the Messages request body as a JSON string. Public so the canonical
    # golden test can exercise it without a full pipeline run. Ports
    # `Anthropic.Context.encode_request` + `build_request_body`: value-based
    # conditionals (not key-presence) with `filter_nil_values` semantics — absent
    # keys (`system`/`temperature`/`top_p`/`stop_sequences`/`tools`) never appear.
    #
    #   * `model`        — `model.id` (no `provider_model_id` exists).
    #   * `system`       — hoisted from `Role::System` messages: a lone plain-text
    #                      block collapses to a bare string; multiple → an array of
    #                      `{type:"text"}` blocks; blank/whitespace dropped; none →
    #                      omitted entirely.
    #   * `messages`     — non-system messages; `Role::Tool` becomes a `user`
    #                      message carrying a `tool_result` block, assistant tool
    #                      calls emit `tool_use` blocks, adjacent tool-result user
    #                      messages fold into one.
    #   * `max_tokens`   — ALWAYS present (Anthropic requires it); default 1024.
    #   * `temperature`/`top_p` — emitted only when set.
    #   * `stop_sequences` — from `:stop` (string → 1-element list; array as-is).
    #   * `stream`       — ALWAYS present; the `stream:` param overrides the option
    #                      (the streaming path forces `true`).
    #   * `tools`        — omitted when empty; each `{name, description,
    #                      input_schema}` (+ `strict:true` only when set).
    #
    # Key order (deterministic; pinned in the goldens): `model`, `system?`,
    # `messages`, `max_tokens`, `temperature?`, `top_p?`, `stop_sequences?`,
    # `stream`, `tools?`.
    def encode_chat_body(model : LLMDB::Model, context : ReqLLM::Context,
                         opts : ReqLLM::Options::Validated,
                         *, stream : Bool? = nil) : String
      chat_body_hash(model, context, opts, stream: stream).to_json
    end

    # Assemble the Messages body as a Hash (shared by `encode_chat_body` and
    # `encode_object_body`, which overrides `tools` with the synthetic tool and
    # adds `tool_choice`). Same value-based `filter_nil_values` semantics
    # described on `encode_chat_body`; the key insertion order is preserved so
    # the non-object path stays byte-identical.
    private def chat_body_hash(model : LLMDB::Model, context : ReqLLM::Context,
                               opts : ReqLLM::Options::Validated,
                               *, stream : Bool? = nil) : Hash(String, JSON::Any)
      body = {} of String => JSON::Any
      body["model"] = JSON::Any.new(model.id)

      system, non_system = partition_system(context.messages)
      if encoded_system = encode_system(system)
        body["system"] = encoded_system
      end

      encoded_msgs = merge_consecutive_tool_results(non_system.map { |m| encode_message(m) })
      body["messages"] = JSON::Any.new(encoded_msgs.map { |m| JSON::Any.new(m) })

      # max_tokens is REQUIRED by Anthropic; default 1024 when unset.
      body["max_tokens"] = JSON::Any.new((opts.fetch_int?(:max_tokens) || DEFAULT_MAX_TOKENS).to_i64)

      if temperature = opts.fetch_float?(:temperature)
        body["temperature"] = JSON::Any.new(temperature)
      end

      if top_p = opts.fetch_float?(:top_p)
        body["top_p"] = JSON::Any.new(top_p)
      end

      # `stop` accepts a single String or an Array(String); Anthropic wires it as
      # `stop_sequences` (string → 1-element list).
      case stop = opts.fetch_stop
      when String
        body["stop_sequences"] = JSON::Any.new([JSON::Any.new(stop)])
      when Array(String)
        body["stop_sequences"] = JSON::Any.new(stop.map { |s| JSON::Any.new(s) })
      end

      # stream is always present (materialized default false). The `stream:`
      # param overrides the option-derived flag — `attach_stream` passes
      # `stream: true`.
      stream_flag = stream.nil? ? opts.fetch_bool(:stream) : stream
      body["stream"] = JSON::Any.new(stream_flag)

      # tools omitted entirely when empty (upstream guards `tools != []`).
      tools = opts.fetch_tools
      unless tools.empty?
        body["tools"] = JSON::Any.new(tools.map { |t| JSON::Any.new(encode_tool(t)) })
      end

      body
    end

    # Split messages into `{system, non_system}` by `role.system?`. System
    # messages are hoisted into the top-level `system` parameter.
    private def partition_system(messages : Array(ReqLLM::Message)) : {Array(ReqLLM::Message), Array(ReqLLM::Message)}
      system = [] of ReqLLM::Message
      non_system = [] of ReqLLM::Message
      messages.each do |m|
        if m.role.system?
          system << m
        else
          non_system << m
        end
      end
      {system, non_system}
    end

    # Encode the hoisted system messages (upstream `encode_system_messages` +
    # `normalize_system_content`). Maps each text part to a `{type:"text"}` block,
    # dropping whitespace-only text. Returns nil when empty; a lone plain text
    # block collapses to a bare string; otherwise an array of blocks. Returns a
    # WRAPPED `JSON::Any` so `body["system"] = ...` type-checks against
    # `Hash(String, JSON::Any)` (mirrors the OpenAI `encode_content` sibling).
    private def encode_system(messages : Array(ReqLLM::Message)) : JSON::Any?
      blocks = [] of Hash(String, JSON::Any)
      messages.each do |m|
        m.content.each do |part|
          next unless part.type.text?
          text = part.text || ""
          next if text.strip.empty?
          blocks << {"type" => JSON::Any.new("text"), "text" => JSON::Any.new(text)}
        end
      end

      return nil if blocks.empty?
      # Collapse a lone bare `{type, text}` block (exactly 2 keys) to a string,
      # matching upstream `normalize_system_content`'s `map_size == 2` guard: a
      # single block carrying anything extra (e.g. a future `cache_control`
      # breakpoint) must stay an array so the extra key is preserved. Mirrors the
      # same guard in `encode_content`.
      if blocks.size == 1 && (only = blocks.first) &&
         only.size == 2 && only["type"]?.try(&.as_s?) == "text"
        only["text"]
      else
        JSON::Any.new(blocks.map { |b| JSON::Any.new(b) })
      end
    end

    # Encode one non-system message to its Anthropic `{role, content}` shape.
    # Ports `encode_message`: `Role::Tool` → a `user` message wrapping a
    # `tool_result` block; an assistant message with `tool_calls` → an array of
    # text block(s) ++ `tool_use` blocks; otherwise `{role, content}` with the
    # content collapsed to a bare string or an array of blocks.
    private def encode_message(message : ReqLLM::Message) : Hash(String, JSON::Any)
      case message.role
      when .tool?
        encode_tool_message(message)
      when .assistant?
        if (tool_calls = message.tool_calls) && !tool_calls.empty?
          encode_assistant_with_tool_calls(message, tool_calls)
        else
          {"role" => JSON::Any.new("assistant"), "content" => encode_content(message.content)}
        end
      else
        {"role" => JSON::Any.new(role_to_wire(message.role)), "content" => encode_content(message.content)}
      end
    end

    # `Role::Tool` → a `user` message carrying a single `tool_result` block
    # `{type:"tool_result", tool_use_id, content}` (upstream `encode_message/1`).
    # The block's `content` reuses `encode_content` so it collapses just like any
    # message. RAISES when `tool_call_id` is nil rather than emitting a nil id.
    # Propagates the error flag: adds `"is_error" => true` ONLY when
    # `metadata["is_error"]` is truthy (never emits `is_error: false`).
    private def encode_tool_message(message : ReqLLM::Message) : Hash(String, JSON::Any)
      id = message.tool_call_id
      if id.nil?
        raise ReqLLM::Error::Invalid::Parameter.new("tool message missing tool_call_id")
      end

      block = {
        "type"        => JSON::Any.new("tool_result"),
        "tool_use_id" => JSON::Any.new(id),
        "content"     => encode_content(message.content),
      } of String => JSON::Any
      block["is_error"] = JSON::Any.new(true) if truthy?(message.metadata["is_error"]?)

      {
        "role"    => JSON::Any.new("user"),
        "content" => JSON::Any.new([JSON::Any.new(block)]),
      } of String => JSON::Any
    end

    # Assistant message with tool calls → content is the ARRAY form: any text
    # block(s) (only when the message carries non-empty text) followed by one
    # `tool_use` block `{type, id, name, input}` per tool call. Mirrors
    # `combine_all_content_blocks` (text blocks ++ tool blocks).
    private def encode_assistant_with_tool_calls(message : ReqLLM::Message,
                                                 tool_calls : Array(ReqLLM::ToolCall)) : Hash(String, JSON::Any)
      blocks = [] of JSON::Any

      # Reuse encode_content, then splat it into blocks like combine_all_content_
      # blocks: "" → no text block; bare string → one text block; array → as-is.
      encoded = encode_content(message.content)
      case raw = encoded.raw
      when String
        blocks << JSON::Any.new({"type" => JSON::Any.new("text"), "text" => encoded}) unless raw.empty?
      when Array
        raw.each { |b| blocks << b }
      end

      tool_calls.each do |tc|
        blocks << JSON::Any.new({
          "type"  => JSON::Any.new("tool_use"),
          "id"    => JSON::Any.new(tc.id),
          "name"  => JSON::Any.new(tc.name),
          "input" => JSON::Any.new(tc.args_map),
        } of String => JSON::Any)
      end

      {"role" => JSON::Any.new("assistant"), "content" => JSON::Any.new(blocks)}
    end

    # Fold adjacent `user` messages whose content arrays are BOTH entirely
    # `tool_result` blocks into a single `user` message concatenating the blocks
    # (upstream `merge_consecutive_tool_results`). Without this, a multi-tool turn
    # emits consecutive user messages instead of one. All other messages are
    # untouched.
    private def merge_consecutive_tool_results(messages : Array(Hash(String, JSON::Any))) : Array(Hash(String, JSON::Any))
      result = [] of Hash(String, JSON::Any)
      messages.each do |msg|
        prev = result.last?
        if prev && mergeable_tool_results?(prev, msg)
          # Hash is a reference type, so mutating `prev` updates the entry in
          # `result` in place.
          prev["content"] = JSON::Any.new(prev["content"].as_a + msg["content"].as_a)
        else
          result << msg
        end
      end
      result
    end

    private def mergeable_tool_results?(prev : Hash(String, JSON::Any), curr : Hash(String, JSON::Any)) : Bool
      return false unless prev["role"]?.try(&.as_s?) == "user"
      return false unless curr["role"]?.try(&.as_s?) == "user"
      prev_content = prev["content"]?.try(&.as_a?)
      curr_content = curr["content"]?.try(&.as_a?)
      return false unless prev_content && curr_content
      all_tool_results?(prev_content) && all_tool_results?(curr_content)
    end

    private def all_tool_results?(blocks : Array(JSON::Any)) : Bool
      blocks.all? { |b| b.as_h?.try(&.["type"]?).try(&.as_s?) == "tool_result" }
    end

    # Encode a message's content parts. A single plain text part collapses to a
    # bare string; richer/multiple parts become an array of `{type:"text"}`
    # blocks; an empty list → bare `""`. Text parts only (multimodal deferred —
    # non-text parts are skipped, mirroring the OpenAI sibling). Returns
    # `JSON::Any`.
    private def encode_content(parts : Array(ReqLLM::ContentPart)) : JSON::Any
      encoded = parts.compact_map { |p| encode_content_part(p) }

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
        text = part.text || ""
        # Upstream drops empty text parts (`do_encode_content_part(text: "")`).
        return nil if text.empty?
        {"type" => JSON::Any.new("text"), "text" => JSON::Any.new(text)}
      else
        # Non-text parts (images/files/etc.) are out of scope for this unit.
        nil
      end
    end

    # Render a Tool to the Anthropic tool wire shape (upstream `encode_tool`):
    # `{name, description, input_schema}` where `input_schema` is the normalized
    # JSON Schema from `Tool#to_json_schema`. `strict: true` is added only when
    # the tool is strict (never emits `strict: false`).
    private def encode_tool(tool : ReqLLM::Tool) : Hash(String, JSON::Any)
      encoded = {
        "name"         => JSON::Any.new(tool.name),
        "description"  => JSON::Any.new(tool.description),
        "input_schema" => JSON::Any.new(tool.to_json_schema),
      } of String => JSON::Any
      encoded["strict"] = JSON::Any.new(true) if tool.strict
      encoded
    end

    private def role_to_wire(role : ReqLLM::Role) : String
      case role
      when .user?      then "user"
      when .assistant? then "assistant"
      else                  role.to_s.downcase
      end
    end

    # Truthy test for an optional metadata flag: present and neither JSON null
    # nor `false` (mirrors Elixir's `if metadata[:is_error]`).
    private def truthy?(value : JSON::Any?) : Bool
      return false if value.nil?
      raw = value.raw
      return false if raw.nil?
      return false if raw == false
      true
    end

    # Response step: decode a Messages JSON response into a semantic `Response`,
    # populating the assistant message, finish reason, and usage so the
    # downstream usage/cost steps work end-to-end. Ports
    # `Anthropic.Response.decode_response` (content blocks → parts/tool_calls,
    # `stop_reason` → finish reason, cache-aware usage) and mirrors the OpenAI
    # sibling's context merge.
    def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      model = req.model.as(LLMDB::Model)
      data = JSON.parse(resp.body)

      model_name = data["model"]?.try(&.as_s?) || model.id
      finish_reason = ReqLLM::FinishReason.from_wire(data["stop_reason"]?.try(&.as_s?))

      # PARITY with ChunkAccumulator#finish (accumulator.cr:100-136): build
      # EXACTLY one concatenated text part (even ""), then ONE concatenated
      # thinking part only when thinking is non-empty, then tool_calls.
      # `decode_content` returns the joined strings + tool calls (NOT a pre-built
      # parts list), so this shape is identical to a folded stream of the same
      # logical content — guaranteeing `stream.join == decode`.
      text, thinking, tool_calls = decode_content(data["content"]?)
      parts = [ReqLLM::ContentPart.text(text)]
      parts << ReqLLM::ContentPart.thinking(thinking) unless thinking.empty?

      message = ReqLLM::Message.new(
        ReqLLM::Role::Assistant,
        parts,
        tool_calls: tool_calls.empty? ? nil : tool_calls,
      )

      usage = decode_usage(data["usage"]?)

      # CONTEXT MERGE (upstream `Context.merge_response`): the returned context is
      # the input messages PLUS the appended assistant reply, so multi-turn
      # callers can feed `resp.context` straight back in. Dup the input messages
      # to avoid mutating the caller's `req.context`; tools are preserved.
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

    # Decode ONE Anthropic Messages SSE event into zero-or-more `StreamChunk`s.
    # PURE: no IO/concurrency. The chunks emit EXACTLY the metadata the
    # `ChunkAccumulator` reads, so folding a stream yields the same `Response` as
    # the non-streaming `decode_response`. Ports the stateless 2-arg
    # `Anthropic.Response.decode_stream_event/2` (the thinking-signature /
    # reasoning-details machinery, which needs cross-event state, is deferred —
    # `content_block_stop` therefore yields `[]`).
    #
    # Anthropic SPLITS usage across frames: `message_start` carries
    # `input_tokens` + `cache_read_input_tokens`, while `message_delta` carries
    # the cumulative `output_tokens`. Both are emitted as Meta usage chunks; the
    # accumulator's per-field merge reassembles the complete totals.
    #
    #   * `{"type":"error", ...}` → RAISE (200-OK in-stream error; see below).
    #   * `message_start` (`message.usage`) → one normalized Meta usage chunk.
    #   * `content_block_start` → text/thinking (non-empty) or a tool_use delta.
    #   * `content_block_delta` → text / thinking / input_json_delta fragment.
    #   * `message_delta` → finish_reason Meta + (top-level usage) usage Meta.
    #   * `message_stop`/`content_block_stop`/`ping`/unknown/blank/`[DONE]` → `[]`.
    def decode_stream_event(event : ReqLLM::SSE::Event) : Array(ReqLLM::StreamChunk)
      decode_stream_event(event.data)
    end

    # :ditto: convenience overload accepting the raw SSE `data` payload directly.
    def decode_stream_event(data : String) : Array(ReqLLM::StreamChunk)
      chunks = [] of ReqLLM::StreamChunk
      stripped = data.strip
      return chunks if stripped.empty? || stripped == "[DONE]"

      parsed = JSON.parse(stripped)

      # In-stream error frame: Anthropic streams `{"type":"error","error":{...}}`
      # on a 200 OK connection (overloaded, server-side failure). The transport
      # status was 200 so `Steps.error` never fired, so surface it here by
      # raising — same posture as the OpenAI sibling (openai.cr) so a live
      # failure isn't silently swallowed. Raising propagates to the consumer via
      # the producer fiber, matching the non-streaming path.
      if parsed["type"]?.try(&.as_s?) == "error"
        err = parsed["error"]?
        message = err.try(&.["message"]?).try(&.as_s?) ||
                  err.try(&.["type"]?).try(&.as_s?) || parsed.to_json
        raise ReqLLM::Error::API::Response.new("Anthropic stream error: #{message}")
      end

      case parsed["type"]?.try(&.as_s?)
      when "message_start"
        if usage = parsed.dig?("message", "usage")
          if normalized = normalize_stream_usage(usage)
            chunks << ReqLLM::StreamChunk.meta({"usage" => normalized})
          end
        end
      when "content_block_start"
        index = parsed["index"]?.try(&.as_i?) || 0
        chunks.concat(decode_block_start(parsed["content_block"]?, index))
      when "content_block_delta"
        index = parsed["index"]?.try(&.as_i?) || 0
        chunks.concat(decode_block_delta(parsed["delta"]?, index))
      when "message_delta"
        if reason = parsed.dig?("delta", "stop_reason").try(&.as_s?)
          chunks << ReqLLM::StreamChunk.meta(
            {"finish_reason" => JSON::Any.new(reason)})
        end
        if usage = parsed["usage"]?
          if normalized = normalize_stream_usage(usage)
            chunks << ReqLLM::StreamChunk.meta({"usage" => normalized})
          end
        end
      else
        # message_stop / content_block_stop / ping / unknown → []
      end

      chunks
    end

    # Decode a `content_block_start`'s `content_block` into zero-or-one chunk:
    # `text`/`thinking` → the corresponding chunk (only when non-empty);
    # `tool_use{id,name}` → an opening tool-call delta carrying id + name. Any
    # other block type → `[]`.
    private def decode_block_start(block : JSON::Any?, index : Int32) : Array(ReqLLM::StreamChunk)
      chunks = [] of ReqLLM::StreamChunk
      return chunks unless block

      case block["type"]?.try(&.as_s?)
      when "text"
        if text = block["text"]?.try(&.as_s?)
          chunks << ReqLLM::StreamChunk.text(text) unless text.empty?
        end
      when "thinking"
        if text = block["thinking"]?.try(&.as_s?)
          chunks << ReqLLM::StreamChunk.thinking(text) unless text.empty?
        end
      when "tool_use"
        id = block["id"]?.try(&.as_s?)
        name = block["name"]?.try(&.as_s?)
        chunks << ReqLLM::StreamChunk.tool_call_delta(index, id: id, name: name)
      else
        # Unknown block types are ignored.
      end

      chunks
    end

    # Decode a `content_block_delta`'s `delta` into zero-or-one chunk:
    # `text_delta{text}` → Content; `thinking_delta{thinking|text}` → Thinking;
    # `input_json_delta{partial_json}` → a tool-call arguments fragment. An empty
    # text/thinking fragment adds nothing once folded, so we skip it (consistent
    # with the OpenAI sibling). Other delta types → `[]`.
    private def decode_block_delta(delta : JSON::Any?, index : Int32) : Array(ReqLLM::StreamChunk)
      chunks = [] of ReqLLM::StreamChunk
      return chunks unless delta

      case delta["type"]?.try(&.as_s?)
      when "text_delta"
        if text = delta["text"]?.try(&.as_s?)
          chunks << ReqLLM::StreamChunk.text(text) unless text.empty?
        end
      when "thinking_delta"
        text = delta["thinking"]?.try(&.as_s?) || delta["text"]?.try(&.as_s?)
        if text && !text.empty?
          chunks << ReqLLM::StreamChunk.thinking(text)
        end
      when "input_json_delta"
        if partial = delta["partial_json"]?.try(&.as_s?)
          chunks << ReqLLM::StreamChunk.tool_call_delta(
            index, arguments_fragment: partial)
        end
      else
        # Unknown delta types are ignored.
      end

      chunks
    end

    # Normalize a streaming `usage` object into the accumulator's canonical keys
    # (`input_tokens`/`output_tokens`/`reasoning_tokens`/`cached_tokens` as Ints).
    # Same source-key mapping as the non-streaming `decode_usage` (so a folded
    # stream matches decode): `reasoning_output_tokens` → `reasoning_tokens`,
    # `cache_read_input_tokens` → `cached_tokens`, both defaulting to 0. Returns
    # nil when the value is not an object.
    private def normalize_stream_usage(usage : JSON::Any) : JSON::Any?
      return nil unless h = usage.as_h?
      input = h["input_tokens"]?.try(&.as_i?) || 0
      output = h["output_tokens"]?.try(&.as_i?) || 0
      reasoning = h["reasoning_output_tokens"]?.try(&.as_i?) || 0
      cached = h["cache_read_input_tokens"]?.try(&.as_i?) || 0

      JSON::Any.new({
        "input_tokens"     => JSON::Any.new(input.to_i64),
        "output_tokens"    => JSON::Any.new(output.to_i64),
        "reasoning_tokens" => JSON::Any.new(reasoning.to_i64),
        "cached_tokens"    => JSON::Any.new(cached.to_i64),
      } of String => JSON::Any)
    end

    # Fold the Anthropic `content` block array into `{concatenated_text,
    # concatenated_thinking, tool_calls}` — mirroring how `ChunkAccumulator#finish`
    # folds a stream into ONE text part + ONE thinking part. `text` blocks append
    # to the text builder; `thinking` blocks (key `thinking` OR `text`) append to
    # the thinking builder; `tool_use` blocks become `ToolCall`s. Returning the
    # joined strings (each possibly "") rather than a parts list guarantees
    # `join == decode` for the same logical content (no multiple text parts, no
    # thinking-only message lacking a text part). Absent/non-array content yields
    # `{"", "", []}`.
    private def decode_content(content : JSON::Any?) : {String, String, Array(ReqLLM::ToolCall)}
      text = String::Builder.new
      thinking = String::Builder.new
      tool_calls = [] of ReqLLM::ToolCall

      blocks = content.try(&.as_a?)
      blocks.try &.each do |block|
        h = block.as_h?
        next unless h
        case h["type"]?.try(&.as_s?)
        when "text"
          text << (h["text"]?.try(&.as_s?) || "")
        when "thinking"
          # Upstream accepts the reasoning text under `thinking` or `text`.
          thinking << (h["thinking"]?.try(&.as_s?) || h["text"]?.try(&.as_s?) || "")
        when "tool_use"
          id = h["id"]?.try(&.as_s?) || ReqLLM::ToolCall.generate_id
          name = h["name"]?.try(&.as_s?) || ""
          input = h["input"]? || JSON::Any.new({} of String => JSON::Any)
          tool_calls << ReqLLM::ToolCall.new(id, name, input.to_json)
        else
          # Unknown block types are ignored (multimodal/decode deferred).
        end
      end

      {text.to_s, thinking.to_s, tool_calls}
    end

    # Decode the Anthropic `usage` object into `ReqLLM::Usage`. Ports
    # `Anthropic.Response.parse_usage` (response.ex:363-368) for the fields our
    # `Usage` carries: `input_tokens`, `output_tokens`,
    # `cache_read_input_tokens` → `cached_tokens`,
    # `reasoning_output_tokens` → `reasoning_tokens` (the codex parity fix —
    # usage-decode parity, NOT reasoning-budget support). Absent usage → a zeroed
    # `Usage` (parity with the OpenAI `decode_usage`, so `join == decode`).
    private def decode_usage(usage : JSON::Any?) : ReqLLM::Usage
      return ReqLLM::Usage.new unless usage
      h = usage.as_h?
      return ReqLLM::Usage.new unless h

      input = h["input_tokens"]?.try(&.as_i?) || 0
      output = h["output_tokens"]?.try(&.as_i?) || 0
      cached = h["cache_read_input_tokens"]?.try(&.as_i?) || 0
      reasoning = h["reasoning_output_tokens"]?.try(&.as_i?) || 0
      # DEFERRED: `cache_creation_input_tokens` has no `Usage` field (cache-write
      # billing is out of scope, matching usage.cr) — dropped here.

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

ReqLLM::Registry.register(ReqLLM::Providers::Anthropic.new)
