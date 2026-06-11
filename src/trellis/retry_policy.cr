require "./http/request"

module Trellis
  # Retry configuration carried on `HTTP::Request#retry` and read by the
  # pipeline (never an error step — see the Pipeline contract). Mirrors the
  # intent of `ReqLLM.Step.Retry` (step/retry.ex): retry transient transport
  # responses (HTTP 429 and 5xx) a bounded number of times.
  #
  # Reopened as a `struct` to match the forward declaration in
  # `src/trellis/http/request.cr` (a class-vs-struct mismatch is a hard compile
  # error).
  struct RetryPolicy
    getter max_retries : Int32
    # Base backoff delay. A `Time::Span.zero` disables waiting entirely, which
    # keeps retry specs fast and deterministic.
    getter base_delay : Time::Span

    def initialize(@max_retries : Int32 = 3, @base_delay : Time::Span = 500.milliseconds)
    end

    # Sane defaults: 3 retries with a small exponential base delay.
    def self.default : RetryPolicy
      new
    end

    # Read the policy off a request, defaulting when none is set. The pipeline
    # uses this so `req.retry || RetryPolicy.default` semantics live in one place.
    def self.from(req : HTTP::Request) : RetryPolicy
      req.retry || default
    end

    # Retry on rate-limit (429) and server errors (5xx).
    def retryable?(status : Int32) : Bool
      status == 429 || (status >= 500 && status <= 599)
    end

    # Exponential backoff for a zero-based attempt number. `delay_for(0)` is the
    # base delay; each subsequent attempt doubles it. A zero base delay yields
    # zero, so callers can sleep unconditionally without real wall-clock waits.
    def delay_for(attempt : Int32) : Time::Span
      return Time::Span.zero if base_delay.zero?
      base_delay * (2 ** attempt)
    end
  end
end
