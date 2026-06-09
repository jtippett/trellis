require "./error"
require "./usage"
require "./http/request"
require "./http/response"

module ReqLLM
  # The provider contract — the Crystal analogue of the `ReqLLM.Provider`
  # behaviour (`req_llm/lib/req_llm/provider.ex`). A provider is a thin plugin
  # that supplies its identity, auth/base-url defaults, and the encode/decode
  # steps that get wired into the shared named-step pipeline.
  #
  # Concrete providers (OpenAI/Anthropic/Google — Unit N) subclass
  # `BaseProvider`, which implements the shared `attach` in the fixed contract
  # order; the methods left abstract here are the per-provider pieces.
  #
  # NOTE: a provider `id` is a **String** (e.g. "openai"), consistent with the
  # String-provider refactor (`LLMDB::Model#provider` is also a String). The
  # `Registry` keys on this id.
  module Provider
    # Stable provider id, the Registry key and `LLMDB::Model#provider` value.
    abstract def id : String

    # Default API base URL (e.g. "https://api.openai.com/v1").
    abstract def default_base_url : String

    # Environment variable holding the API key (e.g. "OPENAI_API_KEY").
    abstract def default_env_key : String

    # Build and configure a fresh request for an operation. `data` is the
    # operation payload (a Context for :chat, etc.); `opts` the validated
    # options. Mirrors the upstream `prepare_request/4` callback.
    abstract def prepare_request(operation : Symbol, model : LLMDB::Model, data, opts) : HTTP::Request

    # Wire provider-specific configuration (auth headers, retry, encode/decode
    # steps, fixture) onto the request in the fixed contract order. Implemented
    # by `BaseProvider`.
    abstract def attach(req : HTTP::Request) : HTTP::Request

    # Request step: encode the typed request state into the provider's wire body.
    abstract def encode_body(req : HTTP::Request) : HTTP::Request

    # Response step: decode the raw transport body into a semantic `Response`,
    # storing it on `resp.decoded`.
    abstract def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}

    # Extract usage from a decoded response. Has a default in `BaseProvider`.
    abstract def extract_usage(req : HTTP::Request, resp : HTTP::Response) : ReqLLM::Usage?

    # Configure a streaming request. Has a default in `BaseProvider`
    # (streaming is Phase 2).
    abstract def attach_stream(req : HTTP::Request) : HTTP::Request
  end
end
