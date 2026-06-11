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
  # The Google (Gemini) provider. Targets the Generative Language API; the
  # non-streaming chat operation is `POST {base}/models/{id}:generateContent`.
  # Request encoding and response decoding mirror
  # `req_llm/lib/req_llm/providers/google.ex`.
  #
  # Subclasses `BaseProvider`, which wires `attach` in the fixed Pipeline-contract
  # step order; this class supplies identity, `prepare_request`, the auth-header
  # override (Gemini uses the `x-goog-api-key` header, NOT `Authorization: Bearer`
  # and NOT the `?key=` query param — keeping the key out of the URL), and the
  # `encode_body`/`decode_response` steps. Body encoding, response decoding, and
  # streaming are filled by later units (GU2-GU5).
  class Google < ReqLLM::BaseProvider
    # NOTE: NO DEFAULT_MAX_TOKENS constant. Unlike Anthropic, Gemini does NOT
    # require maxOutputTokens; GU2 OMITS it when unset.

    def id : String
      "google"
    end

    def default_base_url : String
      "https://generativelanguage.googleapis.com/v1beta"
    end

    def default_env_key : String
      "GOOGLE_API_KEY"
    end

    # Build a fresh chat request: a POST to `<base_url>/models/<id>:generateContent`
    # carrying the typed pipeline state (model, context, operation, options). The
    # operation is encoded in the URL path (Gemini has no body `stream` flag);
    # `attach_stream` (GU5) rewrites this path to `:streamGenerateContent`.
    # Encoding/auth/decoding are wired later by `attach`.
    def prepare_request(operation : Symbol, model : LLMDB::Model, data, opts) : HTTP::Request
      ensure_provider!(model)

      context = data.as(ReqLLM::Context)
      url = URI.parse("#{default_base_url}/models/#{model.id}:generateContent")
      req = HTTP::Request.new("POST", url)
      req.operation = operation
      req.model = model
      req.context = context
      req.options = opts.as(ReqLLM::Options::Validated)
      req
    end

    # Google auth: the `x-goog-api-key` header (NOT `Authorization: Bearer`, NOT
    # the `?key=` query param — keeps the key out of the URL and therefore out of
    # any logged/fixtured URL). Overrides `BaseProvider#apply_common_headers`;
    # preserves AUTH-SKIP-ON-REPLAY (`Fixture.will_replay?`) so offline fixture
    # replays need no key. Shared by `attach` + `attach_stream`, so overriding
    # here covers both paths. `Content-Type` is always set; `x-goog-api-key` is
    # resolved only when we are NOT replaying.
    protected def apply_common_headers(req : HTTP::Request) : Nil
      req.headers["Content-Type"] = "application/json"
      unless ReqLLM::Fixture.will_replay?(req, id)
        api_key = ReqLLM::Keys.resolve(default_env_key, explicit_api_key(req))
        req.headers["x-goog-api-key"] = api_key
      end
    end

    # Configure a STREAMING request. Unlike OpenAI/Anthropic (which flip a body
    # `stream` flag), Gemini streaming is ENDPOINT-based: the same
    # `generateContent` body is POSTed to the `:streamGenerateContent` operation
    # with `?alt=sse` framing. So this REWRITES the URL path + query and leaves
    # the body byte-identical to the non-streaming `encode_chat_body` (NO stream
    # flag). Header/auth setup is shared with the non-streaming `attach` via the
    # overridden `apply_common_headers` (sets `x-goog-api-key` + `Content-Type`,
    # honouring AUTH-SKIP-ON-REPLAY so a fixture replay needs no key); we then add
    # the SSE `Accept` header. The producer fiber + `StreamAdapter` drive
    # transport and decoding (`StreamAdapter.live` posts to `uri.request_target`,
    # so `?alt=sse` MUST live in the URL, not just a header). No
    # Steps.error/decode/usage are wired (the adapter handles non-2xx; the
    # accumulator folds chunks).
    def attach_stream(req : HTTP::Request) : HTTP::Request
      model = req.model.as(LLMDB::Model)
      context = req.context.as(ReqLLM::Context)
      opts = req.options.as(ReqLLM::Options::Validated)

      # Rewrite :generateContent -> :streamGenerateContent and request SSE
      # framing. `sub` replaces the first occurrence only — safe, since the model
      # id cannot contain ":generateContent". Dup + reassign so we never mutate a
      # shared URI in place.
      uri = req.url.dup
      uri.path = uri.path.sub(":generateContent", ":streamGenerateContent")
      uri.query = "alt=sse"
      req.url = uri

      apply_common_headers(req) # x-goog-api-key + Content-Type (AUTH-SKIP-ON-REPLAY)
      req.headers["Accept"] = "text/event-stream"
      # Body is identical to non-streaming; Gemini has NO body stream flag.
      req.body = encode_chat_body(model, context, opts)
      req
    end

    # Request step: serialize the typed state into the Gemini request body.
    # For the `:object` operation (set by `generate_object`) it dispatches to
    # `encode_object_body`, which sets `generationConfig.responseMimeType` +
    # `responseSchema`/`responseJsonSchema` so the model returns the structured
    # object as the candidate text (decode is unchanged; the shared
    # `unwrap_object` parses it). Gemini object output is non-streaming
    # `generateContent`, so the URL built by `prepare_request(:object)` is the
    # normal one — no path rewrite.
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

    # Build the Gemini `generateContent` request body for the `:object`
    # operation: the normal chat body PLUS, in `generationConfig`,
    # `responseMimeType: "application/json"` and the response schema. The schema
    # form depends on the model: gemini-2.5+/gemini-3 accept a plain JSON Schema
    # (`responseJsonSchema`, passed AS-IS); earlier models need the Gemini schema
    # dialect (`responseSchema`, via `convert_to_google_schema` — uppercase types,
    # no `additionalProperties`, with `propertyOrdering`). Ports upstream
    # `encode_object_body` + `put_schema_for_model` (google.ex:1211-1290). The
    # rest of the body (systemInstruction hoist, contents, the other
    # generationConfig keys) is byte-identical to the chat body. Public so a test
    # can drive it directly with an explicit schema + name.
    # `name` is part of the uniform `encode_object_body` signature shared across
    # providers (so the `encode_body` dispatch is identical), but Google does not
    # use it: Gemini keys the schema by `responseSchema`/`responseJsonSchema`, not
    # by a caller-supplied name (that name is meaningful only on the OpenAI
    # `response_format` path).
    def encode_object_body(model : LLMDB::Model, context : ReqLLM::Context,
                           opts : ReqLLM::Options::Validated,
                           schema : Hash(String, JSON::Any), name : String) : String
      body = chat_body_hash(model, context, opts)

      # Start from any existing generationConfig (temperature/maxOutputTokens/...)
      # so the non-object config keys are preserved; object mode ALWAYS emits a
      # generationConfig (it carries at least responseMimeType + the schema).
      #
      # Deliberate deviations from upstream (both inert): upstream also seeds
      # `candidateCount: 1`, but 1 is the Gemini default, so we omit it to keep
      # the body minimal. The 2.5/3 gate is by model id alone (upstream also
      # checks the schema's top-level type is a known scalar/object/array); for
      # well-formed object schemas the two agree.
      gc = body["generationConfig"]?.try(&.as_h?).try(&.dup) || {} of String => JSON::Any
      gc["responseMimeType"] = JSON::Any.new("application/json")
      if json_schema_supported?(model.id)
        gc["responseJsonSchema"] = JSON::Any.new(schema)
      else
        gc["responseSchema"] = JSON::Any.new(convert_to_google_schema(schema))
      end
      body["generationConfig"] = JSON::Any.new(gc)

      body.to_json
    end

    # Build the Gemini `generateContent` request body as a JSON string. Public so
    # the canonical golden test can exercise it without a full pipeline run. Ports
    # `Google.encode_chat_body` + `split_messages_for_gemini` +
    # `convert_messages_to_gemini`, but encodes DIRECTLY from our `Context` (no
    # OpenAI-format intermediary). Note: NO `stream` kwarg — Gemini streaming is
    # endpoint-based (`:streamGenerateContent`), so the body is byte-identical for
    # streaming and non-streaming.
    #
    #   * `systemInstruction` — hoisted from `Role::System` messages, their text
    #                           joined with "\n\n" into `{parts:[{text}]}`; omitted
    #                           entirely when none / blank.
    #   * `contents`          — non-system messages as `{role, parts}` (User→"user",
    #                           Assistant→"model", Tool→"user"), with consecutive
    #                           same-role entries folded into one.
    #   * `tools`             — present only when non-empty:
    #                           `[{functionDeclarations:[{name, description,
    #                           parameters}]}]` (parameters deep-stripped of
    #                           `$schema`/`additionalProperties`).
    #   * `generationConfig`  — value-based `temperature`/`maxOutputTokens`/`topP`/
    #                           `stopSequences`; omitted entirely when empty.
    #                           CRITICAL: `maxOutputTokens` is OMITTED when
    #                           `max_tokens` is unset (Gemini does NOT require it —
    #                           the key difference from Anthropic).
    #
    # Key order (deterministic; pinned in the goldens): `systemInstruction?`,
    # `contents`, `tools?`, `generationConfig?`.
    def encode_chat_body(model : LLMDB::Model, context : ReqLLM::Context,
                         opts : ReqLLM::Options::Validated) : String
      chat_body_hash(model, context, opts).to_json
    end

    # Assemble the Gemini `generateContent` body as a Hash (shared by
    # `encode_chat_body` and `encode_object_body`, which adds the object-mode
    # `generationConfig` keys). Key order is deterministic and pinned by the
    # chat goldens: `systemInstruction?`, `contents`, `tools?`,
    # `generationConfig?`.
    private def chat_body_hash(model : LLMDB::Model, context : ReqLLM::Context,
                               opts : ReqLLM::Options::Validated) : Hash(String, JSON::Any)
      body = {} of String => JSON::Any

      system, non_system = partition_system(context.messages)
      if si = encode_system_instruction(system)
        body["systemInstruction"] = si
      end

      contents = merge_consecutive_roles(non_system.map { |m| encode_message(m) })
      body["contents"] = JSON::Any.new(contents.map { |c| JSON::Any.new(c) })

      tools = opts.fetch_tools
      unless tools.empty?
        decls = tools.map { |t| JSON::Any.new(encode_tool(t)) }
        body["tools"] = JSON::Any.new([JSON::Any.new(
          {"functionDeclarations" => JSON::Any.new(decls)} of String => JSON::Any)])
      end

      if gc = encode_generation_config(opts)
        body["generationConfig"] = gc
      end

      body
    end

    # True when the model accepts a plain JSON Schema in `responseJsonSchema`
    # (gemini-2.5+/gemini-3). Earlier models need the Gemini schema dialect via
    # `responseSchema`. Ports upstream `json_schema_supported?`
    # (google.ex:1274-1279).
    private def json_schema_supported?(id : String) : Bool
      id.starts_with?("gemini-2.5") || id.starts_with?("gemini-3")
    end

    # Convert a plain JSON Schema into the Gemini schema dialect for
    # `responseSchema` (ports `convert_to_google_schema` + `to_google_type` +
    # `convert_properties_to_google` + `maybe_add_property_ordering`,
    # google.ex:1298-1343): drop `additionalProperties`/`$schema`; UPPERCASE the
    # `"type"` VALUE (object→OBJECT, array→ARRAY, string→STRING, integer→INTEGER,
    # number→NUMBER, boolean→BOOLEAN, null→NULL; an unknown value passes through);
    # recurse `properties` values and an object `items`; and, when an object has
    # non-empty `properties`, add `propertyOrdering` = the property key order
    # (unless already present). PURE: returns a new Hash; never mutates the input.
    private def convert_to_google_schema(schema : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      schema.each do |key, value|
        next if key == "additionalProperties" || key == "$schema"

        case key
        when "type"
          if s = value.as_s?
            result["type"] = JSON::Any.new(to_google_type(s))
          else
            result["type"] = value
          end
        when "properties"
          result["properties"] = convert_properties_to_google(value)
        when "items"
          if h = value.as_h?
            result["items"] = JSON::Any.new(convert_to_google_schema(h))
          elsif value.as_a?
            # A list-valued `items` is JSON Schema tuple validation, which the
            # Gemini schema does not support — reject rather than emit an invalid
            # schema (ports upstream `raise_unsupported_schema`, google.ex:1306).
            raise ReqLLM::Error::Invalid::Schema.new(
              "tuple arrays (list-valued \"items\") are not supported by the Gemini schema")
          else
            result["items"] = value
          end
        else
          result[key] = value
        end
      end

      maybe_add_property_ordering(result)
    end

    # Map a JSON Schema `type` value to the Gemini UPPERCASE form; an unknown
    # value passes through unchanged (ports `to_google_type`).
    private def to_google_type(type : String) : String
      case type
      when "object"  then "OBJECT"
      when "array"   then "ARRAY"
      when "string"  then "STRING"
      when "integer" then "INTEGER"
      when "number"  then "NUMBER"
      when "boolean" then "BOOLEAN"
      when "null"    then "NULL"
      else                type
      end
    end

    # Recurse each property value through `convert_to_google_schema` (object
    # values), preserving key order; non-object values pass through.
    private def convert_properties_to_google(properties : JSON::Any) : JSON::Any
      h = properties.as_h?
      return properties unless h

      converted = {} of String => JSON::Any
      h.each do |k, v|
        converted[k] = if vh = v.as_h?
                         JSON::Any.new(convert_to_google_schema(vh))
                       else
                         v
                       end
      end
      JSON::Any.new(converted)
    end

    # When an object schema has non-empty `properties`, add `propertyOrdering` =
    # the property key order (unless already present). Mutates + returns the
    # passed Hash (it is the freshly built result from `convert_to_google_schema`).
    private def maybe_add_property_ordering(schema : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      props = schema["properties"]?.try(&.as_h?)
      if props && !props.empty? && !schema.has_key?("propertyOrdering")
        schema["propertyOrdering"] = JSON::Any.new(props.keys.map { |k| JSON::Any.new(k) })
      end
      schema
    end

    # Split messages into `{system, non_system}` by `role.system?`. System
    # messages are hoisted into the top-level `systemInstruction`.
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

    # Hoist the system messages into the `systemInstruction` object: join each
    # message's text (text parts joined) with "\n\n", dropping blank messages.
    # Returns nil when the combined text is empty/blank (omitting the key), else
    # `{parts:[{text: combined}]}` wrapped as `JSON::Any` (mirrors the Anthropic
    # `encode_system` sibling).
    private def encode_system_instruction(messages : Array(ReqLLM::Message)) : JSON::Any?
      texts = messages.map { |m| message_text(m) }.reject(&.strip.empty?)
      return nil if texts.empty?
      combined = texts.join("\n\n")
      return nil if combined.strip.empty?

      JSON::Any.new({
        "parts" => JSON::Any.new([JSON::Any.new(
          {"text" => JSON::Any.new(combined)} of String => JSON::Any)]),
      } of String => JSON::Any)
    end

    # Encode one non-system message to its Gemini `{role, parts}` shape:
    #   * `Role::Tool` → a single `{functionResponse:{name, response:{content}}}`
    #     part (RAISES when `tool_call_id` is nil).
    #   * assistant with `tool_calls` → non-empty text part(s) ++ one
    #     `{functionCall:{name, args}}` per call (args is the DECODED object).
    #   * otherwise → text `{text}` parts (non-text parts skipped — multimodal
    #     deferred); a message with no encodable parts → `[{text:""}]` (matches
    #     upstream `convert_single_message_to_gemini`).
    private def encode_message(message : ReqLLM::Message) : Hash(String, JSON::Any)
      parts =
        case message.role
        when .tool?
          encode_tool_result_parts(message)
        when .assistant?
          if (tool_calls = message.tool_calls) && !tool_calls.empty?
            encode_assistant_with_tool_calls(message, tool_calls)
          else
            encode_text_parts(message)
          end
        else
          encode_text_parts(message)
        end

      {
        "role"  => JSON::Any.new(role_to_wire(message.role)),
        "parts" => JSON::Any.new(parts),
      } of String => JSON::Any
    end

    # Map a normal message's text parts to `{text}` parts (non-text skipped). A
    # message with no encodable parts (or a bare empty-string message) collapses
    # to `[{text:""}]`, matching upstream's handling of empty content.
    private def encode_text_parts(message : ReqLLM::Message) : Array(JSON::Any)
      parts = [] of JSON::Any
      message.content.each do |part|
        next unless part.type.text?
        text = part.text || ""
        parts << JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)
      end
      return parts unless parts.empty?
      [JSON::Any.new({"text" => JSON::Any.new("")} of String => JSON::Any)]
    end

    # Assistant message with tool calls → any NON-EMPTY text part(s) followed by
    # one `{functionCall:{name, args}}` per tool call, where `args` is the DECODED
    # arguments object (`ToolCall#args_map`), not the raw JSON string.
    private def encode_assistant_with_tool_calls(message : ReqLLM::Message,
                                                 tool_calls : Array(ReqLLM::ToolCall)) : Array(JSON::Any)
      parts = [] of JSON::Any
      message.content.each do |part|
        next unless part.type.text?
        text = part.text || ""
        next if text.empty?
        parts << JSON::Any.new({"text" => JSON::Any.new(text)} of String => JSON::Any)
      end

      tool_calls.each do |tc|
        parts << JSON::Any.new({
          "functionCall" => JSON::Any.new({
            "name" => JSON::Any.new(tc.name),
            "args" => JSON::Any.new(tc.args_map),
          } of String => JSON::Any),
        } of String => JSON::Any)
      end

      parts
    end

    # `Role::Tool` → a single `{functionResponse:{name, response:{content}}}` part
    # (upstream `build_tool_result_part`). `name` = the message's `name` getter
    # when set, else `"unknown"` (`tool_result_name/1`); `response.content` = the
    # message's joined text. RAISES when `tool_call_id` is nil (same posture as
    # the Anthropic sibling).
    private def encode_tool_result_parts(message : ReqLLM::Message) : Array(JSON::Any)
      if message.tool_call_id.nil?
        raise ReqLLM::Error::Invalid::Parameter.new("tool message missing tool_call_id")
      end

      name = message.name || "unknown"
      content = message_text(message)
      [JSON::Any.new({
        "functionResponse" => JSON::Any.new({
          "name"     => JSON::Any.new(name),
          "response" => JSON::Any.new(
            {"content" => JSON::Any.new(content)} of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any)]
    end

    # Fold consecutive entries sharing the SAME `role` into one, concatenating
    # their `parts` arrays (upstream `merge_consecutive_roles`, google.ex:2248).
    # Critical for parallel tool results: N `Role::Tool` messages all map to role
    # "user" and must become ONE `{role:"user"}` entry with N functionResponse
    # parts.
    private def merge_consecutive_roles(entries : Array(Hash(String, JSON::Any))) : Array(Hash(String, JSON::Any))
      result = [] of Hash(String, JSON::Any)
      entries.each do |entry|
        prev = result.last?
        if prev && prev["role"]?.try(&.as_s?) == entry["role"]?.try(&.as_s?)
          # Hash is a reference type, so mutating `prev` updates the entry in
          # `result` in place.
          prev["parts"] = JSON::Any.new(prev["parts"].as_a + entry["parts"].as_a)
        else
          result << entry
        end
      end
      result
    end

    # Build `generationConfig` value-based: `temperature`, `maxOutputTokens` (from
    # `max_tokens`), `topP` (from `top_p`), `stopSequences` (from `stop`: string →
    # 1-element array; array as-is). Returns nil when empty (omitting the key).
    # CRITICAL: `maxOutputTokens` is OMITTED when `max_tokens` is unset — Gemini
    # does NOT require it (the key difference from Anthropic; do NOT default it).
    private def encode_generation_config(opts : ReqLLM::Options::Validated) : JSON::Any?
      config = {} of String => JSON::Any

      if temperature = opts.fetch_float?(:temperature)
        config["temperature"] = JSON::Any.new(temperature)
      end

      if max_tokens = opts.fetch_int?(:max_tokens)
        config["maxOutputTokens"] = JSON::Any.new(max_tokens.to_i64)
      end

      if top_p = opts.fetch_float?(:top_p)
        config["topP"] = JSON::Any.new(top_p)
      end

      case stop = opts.fetch_stop
      when String
        config["stopSequences"] = JSON::Any.new([JSON::Any.new(stop)])
      when Array(String)
        config["stopSequences"] = JSON::Any.new(stop.map { |s| JSON::Any.new(s) })
      end

      return nil if config.empty?
      JSON::Any.new(config)
    end

    # Render a Tool to the Gemini `functionDeclarations` entry shape (upstream
    # `to_google_format`): `{name, description, parameters}` where `parameters` is
    # the normalized JSON Schema DEEP-STRIPPED of `$schema` and
    # `additionalProperties` (forbidden by Gemini, schema.ex:707).
    private def encode_tool(tool : ReqLLM::Tool) : Hash(String, JSON::Any)
      {
        "name"        => JSON::Any.new(tool.name),
        "description" => JSON::Any.new(tool.description),
        "parameters"  => deep_strip(JSON::Any.new(tool.to_json_schema),
          ["$schema", "additionalProperties"]),
      } of String => JSON::Any
    end

    # Recursively delete `keys` from EVERY nested object in `value` (ports
    # `deep_delete_keys`). Arrays are mapped element-wise; scalars pass through.
    private def deep_strip(value : JSON::Any, keys : Array(String)) : JSON::Any
      if h = value.as_h?
        cleaned = {} of String => JSON::Any
        h.each do |k, v|
          next if keys.includes?(k)
          cleaned[k] = deep_strip(v, keys)
        end
        JSON::Any.new(cleaned)
      elsif a = value.as_a?
        JSON::Any.new(a.map { |e| deep_strip(e, keys) })
      else
        value
      end
    end

    # Map our `Role` to the Gemini wire role: User→"user", Assistant→"model",
    # Tool→"user" (tool results are delivered as a user turn). System never
    # reaches here (hoisted into `systemInstruction` pre-partition).
    private def role_to_wire(role : ReqLLM::Role) : String
      case role
      when .assistant? then "model"
      when .tool?      then "user"
      else                  "user"
      end
    end

    # Join a message's text parts into a single string (non-text parts skipped).
    private def message_text(message : ReqLLM::Message) : String
      String.build do |io|
        message.content.each do |part|
          next unless part.type.text?
          io << (part.text || "")
        end
      end
    end

    # Response step: decode a `generateContent` JSON response into a semantic
    # `Response`, populating the assistant message, finish reason, and usage so
    # the downstream usage/cost steps work end-to-end. Ports
    # `convert_google_to_openai_format` + `convert_google_parts_to_content` +
    # `extract_tool_calls` + the usage normalization, but builds our `Response`
    # DIRECTLY and mirrors the OpenAI/Anthropic context merge.
    def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      model = req.model.as(LLMDB::Model)
      data = JSON.parse(resp.body)

      # Gemini returns `modelVersion`, not `model`; fall back to the request id.
      model_name = data["modelVersion"]?.try(&.as_s?) || model.id

      # Take candidates[0] (nilable throughout — absent/empty candidates or
      # content still yield one empty text part for parity).
      candidate = data["candidates"]?.try(&.as_a?).try(&.first?)

      # PARITY with ChunkAccumulator#finish (accumulator.cr): build EXACTLY one
      # concatenated text part (even ""), then ONE concatenated thinking part
      # only when thinking is non-empty, then tool_calls. `decode_content`
      # returns the joined strings + tool calls (NOT a pre-built parts list), so
      # the shape is identical to a folded stream of the same logical content.
      text, thinking, tool_calls = decode_content(candidate)
      parts = [ReqLLM::ContentPart.text(text)]
      parts << ReqLLM::ContentPart.thinking(thinking) unless thinking.empty?

      message = ReqLLM::Message.new(
        ReqLLM::Role::Assistant,
        parts,
        tool_calls: tool_calls.empty? ? nil : tool_calls,
      )

      # finish_reason: map the wire token, then UPGRADE Stop -> ToolCalls when
      # the candidate carries `functionCall` parts. Gemini reports "STOP"
      # alongside function calls, where the meaningful finish is ToolCalls
      # (upstream google.ex:1764-1768 gates the override on "STOP" exactly). The
      # gate matters: a TRUNCATED tool call ("MAX_TOKENS" + functionCall) must
      # stay Length so the incomplete-args signal isn't lost. This is the SAME
      # rule the streaming `ChunkAccumulator#finish` applies, so a folded stream
      # yields the identical finish_reason as this decode (stream.join == decode).
      finish_reason = ReqLLM::FinishReason.from_wire(
        candidate.try(&.["finishReason"]?).try(&.as_s?))
      if finish_reason.stop? && !tool_calls.empty?
        finish_reason = ReqLLM::FinishReason::ToolCalls
      end

      usage = normalize_google_usage(data["usageMetadata"]?)

      # CONTEXT MERGE (upstream `Context.merge_response`): input messages PLUS
      # the appended assistant reply, tools preserved. Dup the input messages to
      # avoid mutating the caller's `req.context`.
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

    # Fold a candidate's `content.parts` into `{concatenated_text,
    # concatenated_thinking, tool_calls}` — mirroring how `ChunkAccumulator#finish`
    # folds a stream into ONE text part + ONE thinking part. `{text}` with
    # `thought != true` appends to the text builder; `{text, thought:true}`
    # appends to the thinking builder; `{functionCall:{name,args}}` becomes a
    # `ToolCall` (id = `functionCall["id"]` else generated; args object default
    # `{}`). Returning joined strings (each possibly "") rather than a parts list
    # guarantees `join == decode`. Absent candidate/content yields `{"", "", []}`.
    private def decode_content(candidate : JSON::Any?) : {String, String, Array(ReqLLM::ToolCall)}
      text = String::Builder.new
      thinking = String::Builder.new
      tool_calls = [] of ReqLLM::ToolCall

      parts = candidate.try(&.["content"]?).try(&.["parts"]?).try(&.as_a?)
      parts.try &.each do |part|
        h = part.as_h?
        next unless h

        if fc = h["functionCall"]?.try(&.as_h?)
          id = fc["id"]?.try(&.as_s?) || ReqLLM::ToolCall.generate_id
          name = fc["name"]?.try(&.as_s?) || ""
          args = fc["args"]? || JSON::Any.new({} of String => JSON::Any)
          tool_calls << ReqLLM::ToolCall.new(id, name, args.to_json)
        elsif (t = h["text"]?.try(&.as_s?))
          if h["thought"]?.try(&.as_bool?) == true
            thinking << t
          else
            text << t
          end
        end
      end

      {text.to_s, thinking.to_s, tool_calls}
    end

    # Normalize a Gemini `usageMetadata` object into `ReqLLM::Usage`. SHARED with
    # streaming (GU4). Ports `google_usage_from_metadata` + `google_output_tokens`
    # + `google_token_details_count` (google.ex:632-691):
    #   * `input`     = `promptTokenCount`, else sum of
    #                   `promptTokensDetails[].tokenCount`, else 0.
    #   * `reasoning` = `thoughtsTokenCount` || 0.
    #   * `cached`    = `cachedContentTokenCount` || 0.
    #   * `output`    = `candidatesTokenCount + reasoning` when candidates is an
    #                   int; elsif `totalTokenCount` int → `max(0, total - input)`;
    #                   elsif `reasoning > 0` → `reasoning`; else 0.
    # Absent `usageMetadata` → a zeroed `Usage` (parity with the OpenAI/Anthropic
    # `decode_usage`, so `join == decode`).
    private def normalize_google_usage(usage : JSON::Any?) : ReqLLM::Usage
      return ReqLLM::Usage.new unless usage
      h = usage.as_h?
      return ReqLLM::Usage.new unless h

      input = metadata_count(h, "promptTokenCount") ||
              prompt_details_count(h["promptTokensDetails"]?) || 0
      reasoning = metadata_count(h, "thoughtsTokenCount") || 0
      cached = metadata_count(h, "cachedContentTokenCount") || 0
      candidates = metadata_count(h, "candidatesTokenCount")
      total = metadata_count(h, "totalTokenCount")

      output =
        if candidates
          candidates + reasoning
        elsif total
          {0, total - input}.max
        elsif reasoning > 0
          reasoning
        else
          0
        end

      ReqLLM::Usage.new(
        input_tokens: input,
        output_tokens: output,
        reasoning_tokens: reasoning,
        cached_tokens: cached,
      )
    end

    # Read a non-negative integer metadata count, else nil (ports
    # `google_metadata_count`).
    private def metadata_count(h : Hash(String, JSON::Any), key : String) : Int32?
      count = h[key]?.try(&.as_i?)
      return nil unless count && count >= 0
      count
    end

    # Sum the non-negative `tokenCount` fields of a `promptTokensDetails` list,
    # nil when absent/empty (ports `google_token_details_count`).
    private def prompt_details_count(details : JSON::Any?) : Int32?
      arr = details.try(&.as_a?)
      return nil unless arr
      total = nil.as(Int32?)
      arr.each do |detail|
        count = detail.as_h?.try(&.["tokenCount"]?).try(&.as_i?)
        next unless count && count >= 0
        total = (total || 0) + count
      end
      total
    end

    # Decode ONE Gemini `streamGenerateContent?alt=sse` event into zero-or-more
    # `StreamChunk`s. PURE: no IO/concurrency. Each `data:` payload is a partial
    # `GenerateContentResponse` (NOT a typed event), so we switch on the JSON
    # SHAPE, not a `type` field. The chunks emit EXACTLY the metadata the
    # `ChunkAccumulator` reads, so folding a stream yields the same `Response` as
    # the non-streaming `decode_response`. Ports `decode_google_event` +
    # `extract_chunks_from_parts` (google.ex:2548+, 2626+).
    #
    #   * `candidates[0].content.parts` → text / thinking / tool_call chunks
    #     (`extract_chunks_from_parts`). functionCall parts arrive COMPLETE (full
    #     args object) in one frame; emitted via `StreamChunk.tool_call` with
    #     `{"index" => i, "id" => id}` metadata (i = position among functionCall
    #     parts in THIS event), the accumulator's pre-assembled-args path.
    #   * `candidates[0].finishReason` non-null → a trailing
    #     `meta{finish_reason: <RAW wire>}` (emit the raw "STOP"; the
    #     accumulator's Stop->ToolCalls upgrade handles the tool-call case — NO
    #     per-frame override, so co-located vs separated frames behave the same).
    #   * top-level `usageMetadata` → `meta{usage: <normalized canonical keys>}`.
    #   * blank / `{}` / unrelated frame → `[]`. There is no `[DONE]` sentinel;
    #     the stream just ends at EOF.
    def decode_stream_event(event : ReqLLM::SSE::Event) : Array(ReqLLM::StreamChunk)
      decode_stream_event(event.data)
    end

    # :ditto: convenience overload accepting the raw SSE `data` payload directly.
    def decode_stream_event(data : String) : Array(ReqLLM::StreamChunk)
      chunks = [] of ReqLLM::StreamChunk
      stripped = data.strip
      return chunks if stripped.empty?

      parsed = JSON.parse(stripped)
      candidate = parsed["candidates"]?.try(&.as_a?).try(&.first?)

      if candidate
        parts = candidate["content"]?.try(&.["parts"]?).try(&.as_a?)
        chunks.concat(extract_chunks_from_parts(parts)) if parts

        if reason = candidate["finishReason"]?.try(&.as_s?)
          chunks << ReqLLM::StreamChunk.meta(
            {"finish_reason" => JSON::Any.new(reason)})
        end
      end

      if usage = parsed["usageMetadata"]?
        chunks << ReqLLM::StreamChunk.meta(
          {"usage" => normalize_google_usage_json(usage)})
      end

      chunks
    end

    # Map a candidate's `content.parts` to stream chunks (`extract_chunks_from_
    # parts`): `{text}` non-empty & `thought != true` → Content; `{text,
    # thought:true}` non-empty → Thinking; `{functionCall:{name,args}}` → a
    # pre-assembled ToolCall chunk with `{"index" => i, "id" => id}` metadata,
    # where `i` is the functionCall's position among functionCall parts in THIS
    # event (so parallel calls co-located in one frame get distinct indices) and
    # `id` is `functionCall["id"]` when present else a generated id.
    #
    # KNOWN LIMITATION (deferred): `i` resets to 0 per event, and the
    # `ChunkAccumulator` groups tool calls solely by `metadata["index"]`. Gemini
    # delivers all `functionCall` parts of a response COMPLETE and CO-LOCATED in a
    # single content frame (upstream's primary decode arm assumes this), so this
    # is correct in practice. If Gemini ever split parallel function calls across
    # SEPARATE frames they would both land at index 0 and merge into one call.
    private def extract_chunks_from_parts(parts : Array(JSON::Any)) : Array(ReqLLM::StreamChunk)
      chunks = [] of ReqLLM::StreamChunk
      fc_index = 0

      parts.each do |part|
        h = part.as_h?
        next unless h

        if fc = h["functionCall"]?.try(&.as_h?)
          name = fc["name"]?.try(&.as_s?) || ""
          id = fc["id"]?.try(&.as_s?) || ReqLLM::ToolCall.generate_id
          args = fc["args"]?.try(&.as_h?) || {} of String => JSON::Any
          chunks << ReqLLM::StreamChunk.tool_call(name, args,
            {
              "index" => JSON::Any.new(fc_index.to_i64),
              "id"    => JSON::Any.new(id),
            } of String => JSON::Any)
          fc_index += 1
        elsif (text = h["text"]?.try(&.as_s?)) && !text.empty?
          if h["thought"]?.try(&.as_bool?) == true
            chunks << ReqLLM::StreamChunk.thinking(text)
          else
            chunks << ReqLLM::StreamChunk.text(text)
          end
        end
      end

      chunks
    end

    # Normalize a Gemini `usageMetadata` object into the accumulator's CANONICAL
    # streaming-usage keys (`input_tokens`/`output_tokens`/`reasoning_tokens`/
    # `cached_tokens`, Ints). REUSES the shared `normalize_google_usage` (so a
    # folded stream matches the non-streaming decode), then re-exposes it as the
    # JSON::Any object `ChunkAccumulator#parse_usage` reads — mirroring the
    # OpenAI/Anthropic `normalize_stream_usage` shape.
    private def normalize_google_usage_json(usage : JSON::Any) : JSON::Any
      u = normalize_google_usage(usage)
      JSON::Any.new({
        "input_tokens"     => JSON::Any.new(u.input_tokens.to_i64),
        "output_tokens"    => JSON::Any.new(u.output_tokens.to_i64),
        "reasoning_tokens" => JSON::Any.new(u.reasoning_tokens.to_i64),
        "cached_tokens"    => JSON::Any.new(u.cached_tokens.to_i64),
      } of String => JSON::Any)
    end

    # Guard: a request's model must belong to this provider.
    private def ensure_provider!(model : LLMDB::Model) : Nil
      return if model.provider == id
      raise ReqLLM::Error::Invalid::Parameter.new(
        "model provider #{model.provider.inspect} does not match provider #{id.inspect}")
    end
  end
end

ReqLLM::Registry.register(ReqLLM::Providers::Google.new)
