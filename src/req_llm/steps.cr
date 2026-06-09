require "./error"
require "./http/request"
require "./http/response"

module ReqLLM
  # Shared, provider-agnostic pipeline steps. These are the named *response*
  # steps every provider wires into the fixed contract order
  # `[:error, :decode_response, :usage]` (see the Pipeline contract). They are
  # the Crystal analogues of `ReqLLM.Step.Error` (step/error.ex) and
  # `ReqLLM.Step.Usage` (step/usage.ex).
  #
  # Each step is exposed two ways:
  #   * `Steps.error` / `Steps.usage` return a `{Symbol, HTTP::ResponseStepProc}`
  #     named-step tuple (handy for direct invocation and testing);
  #   * `Steps.attach_error` / `Steps.attach_usage` append the step onto a
  #     request's response-step list (how providers will wire them).
  module Steps
    extend self

    # `Steps.error` — runs before decode. When the transport response is an
    # error (status >= 400) it raises `Error::API::Request` carrying the status
    # and raw body, so a 4xx/5xx body is never handed to the decode step.
    # Otherwise the response passes through unchanged.
    def error : {Symbol, HTTP::ResponseStepProc}
      {:error, HTTP::ResponseStepProc.new { |req, resp| run_error(req, resp) }}
    end

    # `Steps.usage` — runs after decode. The decode step has populated
    # `resp.decoded` with a semantic `Response` whose `usage` carries the token
    # counts the provider reported. This step is the point at which per-token
    # cost would be merged onto that usage. Cost computation is DEFERRED until
    # `LLMDB::Model` pricing is wired (Tasks 17/18); until then the step keeps
    # the token usage decode produced and passes the response through.
    def usage : {Symbol, HTTP::ResponseStepProc}
      {:usage, HTTP::ResponseStepProc.new { |req, resp| run_usage(req, resp) }}
    end

    # Append `Steps.error` onto a request's response steps under `:error`.
    def attach_error(req : HTTP::Request) : HTTP::Request
      _name, step = error
      req.append_response_step(:error) { |r, resp| step.call(r, resp) }
      req
    end

    # Append `Steps.usage` onto a request's response steps under `:usage`.
    def attach_usage(req : HTTP::Request) : HTTP::Request
      _name, step = usage
      req.append_response_step(:usage) { |r, resp| step.call(r, resp) }
      req
    end

    private def run_error(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      if resp.status >= 400
        raise Error::API::Request.new(resp.body, status: resp.status, body: resp.body)
      end
      {req, resp}
    end

    private def run_usage(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      # Read the usage decode attached (resp.decoded.try(&.usage)). It already
      # lives on the decoded response, so there is nothing to copy; cost merging
      # waits on model pricing (see the method docs above). Pass through.
      {req, resp}
    end
  end
end
