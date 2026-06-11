require "./context"
require "./message"
require "./content_part"
require "./response"
require "./schema"
require "./options"
require "./registry"
require "./http/request"
require "./http/pipeline"
require "./http/client_adapter"
require "./streaming/stream_response"
require "./streaming/stream_adapter"
require "../llmdb"

module ReqLLM
  # `ReqLLM.generate_text` — the end-to-end text generation entry point.
  # Mirrors `req_llm/lib/req_llm/generation.ex` + the `ReqLLM` facade.
  #
  # Flow:
  #   1. Resolve the model (`LLMDB.model`) and its provider (`Registry.fetch`,
  #      keyed on the String `model.provider`).
  #   2. Normalize the prompt into a `Context` (a bare String becomes a single
  #      user message; a `Context` passes through).
  #   3. Validate the generation options. `api_key:` and `fixture:` are NOT
  #      generation options (the schema rejects unknown keys), so they are
  #      dedicated keyword params, extracted BEFORE validation — only `**opts`
  #      reaches the schema.
  #   4. `prepare_request` builds the typed `HTTP::Request`.
  #   5. Out-of-band fields (`fixture`, `api_key`) are set on the request.
  #   6. `attach` wires the pipeline steps (encode/decode/usage/auth/fixture).
  #   7. `Pipeline.run` executes it, returning the semantic `Response`.
  #
  # When `fixture:` names a recorded file, the run is fully offline and needs no
  # API key (auth is skipped on replay).
  def self.generate_text(spec : String, prompt : String | Context, *,
                         fixture : String? = nil, api_key : String? = nil,
                         **opts) : Response
    model = LLMDB.model(spec)
    provider = Registry.fetch(model.provider)

    context = case prompt
              in String  then Context.new([Message.new(Role::User, prompt)])
              in Context then prompt
              end

    # Only the remaining `**opts` are generation options; api_key/fixture were
    # already split out as keyword params above.
    validated = Options.validate(opts)

    req = provider.prepare_request(:chat, model, context, validated)
    req.fixture = fixture if fixture
    req.api_key = api_key if api_key
    provider.attach(req)

    HTTP::Pipeline.run(req, HTTP::ClientAdapter.new)
  end

  # `ReqLLM.stream_text` — the streaming entry point. The front half mirrors
  # `generate_text` (resolve model + provider, normalize the prompt into a
  # Context, validate options, split out the out-of-band `fixture:`/`api_key:`),
  # but instead of running the response-folding pipeline it builds a streaming
  # request via `provider.attach_stream` and returns a `StreamResponse` whose
  # producer fiber drives `StreamAdapter` (live transport or offline fixture
  # replay), emitting decoded `StreamChunk`s as they arrive.
  #
  # The model's catalog pricing is threaded into the `StreamResponse` so a
  # subsequent `join` attaches cost the way `Steps.usage` does for the
  # non-streaming path (the streaming path skips that step). When `fixture:`
  # names a recorded file the run is fully offline and needs no API key (auth is
  # skipped on replay, same as `generate_text`).
  def self.stream_text(spec : String, prompt : String | Context, *,
                       fixture : String? = nil, api_key : String? = nil,
                       **opts) : StreamResponse
    model = LLMDB.model(spec)
    provider = Registry.fetch(model.provider)

    context = case prompt
              in String  then Context.new([Message.new(Role::User, prompt)])
              in Context then prompt
              end

    validated = Options.validate(opts)

    req = provider.prepare_request(:chat, model, context, validated)
    req.fixture = fixture if fixture
    req.api_key = api_key if api_key
    provider.attach_stream(req)

    StreamResponse.new(model.key, context, cost: model.cost) do |emit|
      StreamAdapter.drive(req, provider, emit)
    end
  end

  # `ReqLLM.generate_object` — the structured-output entry point. Mirrors
  # `generate_text` end-to-end (resolve model + provider, normalize the prompt
  # into a Context, validate options, split out the out-of-band
  # `fixture:`/`api_key:`), but runs the `:object` operation: the caller supplies
  # a JSON Schema (a `Hash(String, JSON::Any)`) the model must emit data matching.
  #
  # The schema/name are stashed on the request out-of-band (NOT generation
  # options — the schema would reject them), then each provider's `encode_body`
  # branches on `req.operation == :object` to encode its object-mode directive
  # (OpenAI `response_format` json_schema, Anthropic synthetic `structured_output`
  # tool, Google `responseSchema`). The pipeline then runs unchanged; afterwards
  # the SHARED `Response#unwrap_object` extracts the object (a tool call's args
  # or the assistant text parsed as JSON), `Schema.validate` checks it against
  # the schema (raising `Error::Validation` on mismatch), and it is set on
  # `response.object`.
  #
  # As with `generate_text`, a `fixture:` makes the run fully offline (no key).
  def self.generate_object(spec : String, prompt : String | Context,
                           schema : Hash(String, JSON::Any), *,
                           name : String = "output_schema",
                           fixture : String? = nil, api_key : String? = nil,
                           **opts) : Response
    model = LLMDB.model(spec)
    provider = Registry.fetch(model.provider)

    context = case prompt
              in String  then Context.new([Message.new(Role::User, prompt)])
              in Context then prompt
              end

    validated = Options.validate(opts)

    req = provider.prepare_request(:object, model, context, validated)
    req.object_schema = schema
    req.object_schema_name = name
    req.fixture = fixture if fixture
    req.api_key = api_key if api_key
    provider.attach(req)

    response = HTTP::Pipeline.run(req, HTTP::ClientAdapter.new)
    object = response.unwrap_object # raises Error::Validation if absent
    Schema.validate(object, schema) # raises Error::Validation on mismatch
    response.object = object
    response
  end

  # Returns just the structured object (a JSON::Any). Raises on error / missing
  # object (the same `Error::Validation` paths as `generate_object`).
  def self.generate_object!(spec : String, prompt : String | Context,
                            schema : Hash(String, JSON::Any), **opts) : JSON::Any
    generate_object(spec, prompt, schema, **opts).object.not_nil!
  end
end
