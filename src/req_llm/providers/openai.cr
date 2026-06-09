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
