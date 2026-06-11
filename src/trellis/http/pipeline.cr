require "./request"
require "./response"
require "./adapter"
require "../retry_policy"

module Trellis::HTTP
  module Pipeline
    extend self

    def run(req : Request, adapter : Adapter) : Trellis::Response
      http_resp : Response? = nil

      req.request_steps.each do |(_name, step)|
        case result = step.call(req)
        when Response then http_resp = result; break
        when Request  then req = result
        end
      end

      begin
        http_resp ||= perform(req, adapter) # Task 14 swaps in retry-aware perform
        req.response_steps.each do |(_name, step)|
          req, http_resp = step.call(req, http_resp.not_nil!)
        end
      rescue ex
        req.error_steps.each { |(_n, s)| ex = s.call(req, ex) }
        raise ex
      end

      http_resp.not_nil!.decoded ||
        raise Trellis::Error::API::Response.new("decode produced no response")
    end

    # Retry-aware transport. The retry policy lives on the request (read here,
    # never in an error step — see the Pipeline contract). The adapter is called
    # inside a loop: while the response is retryable (HTTP 429/5xx) and attempts
    # remain, wait (honoring a `Retry-After` header, else the policy's backoff)
    # and call again; otherwise return the response.
    def perform(req : Request, adapter : Adapter) : Response
      policy = Trellis::RetryPolicy.from(req)
      attempt = 0

      loop do
        resp = adapter.call(req)
        return resp unless policy.retryable?(resp.status) && attempt < policy.max_retries

        delay = retry_delay(resp, policy, attempt)
        sleep delay unless delay.zero?
        attempt += 1
      end
    end

    # The wait before the next retry: a numeric `Retry-After` response header
    # (seconds) takes precedence over the policy's exponential backoff. Split out
    # so specs can assert the computed span without any real sleeping.
    def retry_delay(resp : Response, policy : Trellis::RetryPolicy, attempt : Int32) : Time::Span
      if raw = resp.headers["Retry-After"]?
        if seconds = raw.to_i?
          return seconds.seconds
        end
      end
      policy.delay_for(attempt)
    end
  end
end
