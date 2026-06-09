require "./error"
require "./provider"
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
    # counts the provider reported. This step makes the usage seam live (mirrors
    # `ReqLLM.Step.Usage.handle/1`): it sources the usage object via
    # `provider.extract_usage(req, resp)` (falling back to the decoded usage),
    # then computes per-token cost from `req.model` pricing
    # (`LLMDB::Model::Cost`) and stores it on the usage. When no provider is
    # given (direct/test invocation) it falls back to the decoded usage; when no
    # `req.model` is present it leaves cost nil.
    def usage(provider : Provider? = nil) : {Symbol, HTTP::ResponseStepProc}
      {:usage, HTTP::ResponseStepProc.new { |req, resp| run_usage(req, resp, provider) }}
    end

    # Append `Steps.error` onto a request's response steps under `:error`.
    def attach_error(req : HTTP::Request) : HTTP::Request
      _name, step = error
      req.append_response_step(:error) { |r, resp| step.call(r, resp) }
      req
    end

    # Append `Steps.usage` onto a request's response steps under `:usage`.
    # `provider` is the live provider (passed by `BaseProvider#attach` as
    # `self`) whose `extract_usage` sources the usage object; nil for direct
    # invocation, in which case the decoded usage is used as-is.
    def attach_usage(req : HTTP::Request, provider : Provider? = nil) : HTTP::Request
      _name, step = usage(provider)
      req.append_response_step(:usage) { |r, resp| step.call(r, resp) }
      req
    end

    private def run_error(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      if resp.status >= 400
        raise Error::API::Request.new(resp.body, status: resp.status, body: resp.body)
      end
      {req, resp}
    end

    private def run_usage(req : HTTP::Request, resp : HTTP::Response,
                          provider : Provider?) : {HTTP::Request, HTTP::Response}
      decoded = resp.decoded
      return {req, resp} unless decoded

      # Source the usage object via the provider hook (upstream
      # `provider.extract_usage(body, model)`), defaulting to the usage decode
      # already attached. The BaseProvider default returns that same decoded
      # usage, so OpenAI works without overriding the hook.
      usage = provider.try(&.extract_usage(req, resp)) || decoded.usage
      return {req, resp} unless usage

      # Compute and attach per-token cost from the model's catalog pricing
      # (USD per 1M tokens). `Usage` is a value type, so set cost on the local
      # copy and write it back onto the decoded response.
      if model = req.model
        usage.cost = usage.cost(model.cost.to_pricing)
      end
      decoded.usage = usage

      {req, resp}
    end
  end
end
