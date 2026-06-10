require "./provider"
require "./keys"
require "./steps"
require "./fixture"
require "./retry_policy"
require "./http/request"
require "./http/response"

module ReqLLM
  # Shared base for concrete providers. Mirrors `ReqLLM.Provider.Defaults`
  # (`req_llm/lib/req_llm/provider/defaults.ex`). Subclasses supply identity
  # (`id`, `default_base_url`, `default_env_key`), `prepare_request`, and the
  # `encode_body`/`decode_response` steps; `BaseProvider` implements the shared
  # `attach` that wires every step into the fixed Pipeline-contract order.
  abstract class BaseProvider
    include Provider

    # Wire provider configuration onto `req` in the FIXED contract order
    # (upstream `provider/defaults.ex:585-591`):
    #
    #   1. Content-Type + Authorization headers (model already on req.model).
    #   2. retry policy (read by the pipeline, never a step).
    #   3. append Steps.error          (response step).
    #   4. prepend encode_body         (request step — runs first).
    #   5. append decode_response      (response step).
    #   6. append Steps.usage          (response step).
    #   7. fixture LAST, with a nil-guard.
    #
    # This yields request steps `[:encode_body, (:fixture)]` and response steps
    # `[:error, :decode_response, :usage, (:fixture_capture)]`.
    def attach(req : HTTP::Request) : HTTP::Request
      # 1. Headers + auth. The model is set by `prepare_request`; attach never
      #    clobbers it. AUTH-SKIP-ON-REPLAY: when the request will be served from
      #    a recorded fixture no real request is made, so resolving a key would
      #    be pointless (and would force users to set one for offline runs). Only
      #    resolve + set the Authorization header when we are NOT replaying.
      apply_common_headers(req)

      # 2. Retry policy (pipeline reads `req.retry || RetryPolicy.default`).
      req.retry ||= RetryPolicy.default

      # 3. Steps.error — response step that raises on status >= 400 before decode.
      Steps.attach_error(req)

      # 4. encode_body — prepended so it runs first among request steps.
      req.prepend_request_step(:encode_body) { |r| encode_body(r) }

      # 5. decode_response — response step that populates resp.decoded.
      req.append_response_step(:decode_response) { |r, resp| decode_response(r, resp) }

      # 6. Steps.usage — response step after decode. Pass `self` so the step can
      #    source usage via `extract_usage` and compute cost from model pricing.
      Steps.attach_usage(req, self)

      # 7. Fixture LAST, nil-guard (CRITICAL): only wire when a fixture name is
      #    set. In record mode this appends :fixture_capture (response step); in
      #    replay mode it appends the :fixture replay request-step last. NEVER
      #    wire when nil, or record mode would capture every real request.
      if name = req.fixture
        Fixture.attach(req, id, name)
      end

      req
    end

    # Default usage extraction: the decode step already attaches usage to the
    # semantic response, so return it as-is. Providers may override.
    def extract_usage(req : HTTP::Request, resp : HTTP::Response) : ReqLLM::Usage?
      resp.decoded.try(&.usage)
    end

    # Streaming is Phase 2; concrete providers will override.
    def attach_stream(req : HTTP::Request) : HTTP::Request
      raise "streaming is not implemented (Phase 2)"
    end

    # Default: providers that support streaming override this. Mirrors the
    # `attach_stream` Phase-2 stub — keeps the abstract contract satisfied for
    # non-streaming providers.
    def decode_stream_event(event : ReqLLM::SSE::Event) : Array(ReqLLM::StreamChunk)
      raise "decode_stream_event is not implemented for #{id}"
    end

    # Content-Type + Authorization header setup, shared by `attach` (the
    # non-streaming pipeline) and `attach_stream`. AUTH-SKIP-ON-REPLAY: when the
    # request will be served from a recorded fixture no real request is made, so
    # resolving a key would be pointless (and would force users to set one for
    # offline runs). Only resolve + set Authorization when we are NOT replaying.
    protected def apply_common_headers(req : HTTP::Request) : Nil
      req.headers["Content-Type"] = "application/json"
      unless Fixture.will_replay?(req, id)
        api_key = Keys.resolve(default_env_key, explicit_api_key(req))
        req.headers["Authorization"] = "Bearer #{api_key}"
      end
    end

    # The explicit API key, if any, carried out-of-band on the request (set by
    # `generate_text` from the user's `api_key:` arg). It is NOT a generation
    # option — the options schema has no `:api_key` and would reject it — so it
    # lives on `req.api_key`, not `req.options`. Falls back to the environment
    # via `Keys.resolve`. Overridable by providers.
    protected def explicit_api_key(req : HTTP::Request) : String?
      req.api_key
    end
  end
end
