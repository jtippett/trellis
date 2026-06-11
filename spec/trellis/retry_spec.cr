require "../spec_helper"
require "../support/fake_adapter"

describe Trellis::HTTP::Pipeline do
  describe "retry-aware perform" do
    it "retries on 5xx then returns the first non-retryable response" do
      req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
      # Zero base delay keeps the loop instantaneous and deterministic.
      req.retry = Trellis::RetryPolicy.new(max_retries: 3, base_delay: Time::Span.zero)
      adapter = CountingAdapter.new([503, 503, 200])

      resp = Trellis::HTTP::Pipeline.perform(req, adapter)

      # 503, 503, then 200 — exactly three adapter calls, final status 200.
      adapter.calls.should eq(3)
      resp.status.should eq(200)
    end

    it "stops retrying once max_retries is exhausted" do
      req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
      req.retry = Trellis::RetryPolicy.new(max_retries: 2, base_delay: Time::Span.zero)
      adapter = CountingAdapter.new([503])

      resp = Trellis::HTTP::Pipeline.perform(req, adapter)

      # Initial call + 2 retries = 3 calls, still 503 on the last one.
      adapter.calls.should eq(3)
      resp.status.should eq(503)
    end

    it "does not retry a 200 response" do
      req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
      adapter = CountingAdapter.new([200])

      Trellis::HTTP::Pipeline.perform(req, adapter)

      adapter.calls.should eq(1)
    end

    it "honors a numeric Retry-After header over the backoff policy" do
      req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
      policy = Trellis::RetryPolicy.new(max_retries: 3, base_delay: Time::Span.zero)
      headers = HTTP::Headers{"Retry-After" => "5"}
      resp = Trellis::HTTP::Response.new(429, headers, "")

      # Asserts the computed wait, not an actual sleep: 5 seconds from the header.
      Trellis::HTTP::Pipeline.retry_delay(resp, policy, 0).should eq(5.seconds)
    end

    it "falls back to policy backoff when no Retry-After header is present" do
      req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
      policy = Trellis::RetryPolicy.new(max_retries: 3, base_delay: 10.milliseconds)
      resp = Trellis::HTTP::Response.new(503, HTTP::Headers.new, "")

      Trellis::HTTP::Pipeline.retry_delay(resp, policy, 1).should eq(20.milliseconds)
    end
  end
end
