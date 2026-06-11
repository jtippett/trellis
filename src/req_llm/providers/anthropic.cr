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

    # AU2 fills this: serialize the typed state into the Anthropic Messages body.
    def encode_body(req : HTTP::Request) : HTTP::Request
      raise "AU2"
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
