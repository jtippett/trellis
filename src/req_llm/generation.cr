require "./context"
require "./message"
require "./content_part"
require "./response"
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
end
