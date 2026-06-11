require "json"
require "uri"
require "../base_provider"
require "../registry"
require "../context"
require "../message"
require "../content_part"
require "../response"
require "../usage"
require "../tool_call"
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
    def encode_body(req : HTTP::Request) : HTTP::Request
      model = req.model.as(LLMDB::Model)
      context = req.context.as(ReqLLM::Context)
      opts = req.options.as(ReqLLM::Options::Validated)
      req.body = encode_chat_body(model, context, opts)
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

      body.to_json
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
      if blocks.size == 1 && (only = blocks.first) && only["type"]?.try(&.as_s?) == "text"
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

    # AU3 fills this: decode a Messages JSON response into a semantic `Response`.
    def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      raise "AU3"
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
