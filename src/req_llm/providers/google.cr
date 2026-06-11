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

    # Request step: serialize the typed state into the Gemini request body.
    # Implemented in GU2.
    def encode_body(req : HTTP::Request) : HTTP::Request
      raise "GU2"
    end

    # Response step: decode a `generateContent` JSON response into a semantic
    # `Response`. Implemented in GU3.
    def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      raise "GU3"
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
