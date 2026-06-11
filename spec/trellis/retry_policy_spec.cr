require "../spec_helper"

describe Trellis::RetryPolicy do
  it "is retryable for 429 and 5xx, not for 2xx/4xx-other" do
    policy = Trellis::RetryPolicy.default
    policy.retryable?(429).should be_true
    policy.retryable?(500).should be_true
    policy.retryable?(503).should be_true
    policy.retryable?(200).should be_false
    policy.retryable?(400).should be_false
    policy.retryable?(404).should be_false
  end

  it "exposes sane defaults" do
    policy = Trellis::RetryPolicy.default
    policy.max_retries.should eq(3)
    policy.base_delay.should be > Time::Span.zero
  end

  it "computes exponential backoff per attempt" do
    policy = Trellis::RetryPolicy.new(max_retries: 3, base_delay: 10.milliseconds)
    policy.delay_for(0).should eq(10.milliseconds)
    policy.delay_for(1).should eq(20.milliseconds)
    policy.delay_for(2).should eq(40.milliseconds)
  end

  it "supports a zero base delay so tests need not sleep" do
    policy = Trellis::RetryPolicy.new(max_retries: 3, base_delay: Time::Span.zero)
    policy.delay_for(0).should eq(Time::Span.zero)
    policy.delay_for(5).should eq(Time::Span.zero)
  end

  it "reads the policy from a request, defaulting when unset" do
    req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
    Trellis::RetryPolicy.from(req).max_retries.should eq(Trellis::RetryPolicy.default.max_retries)

    custom = Trellis::RetryPolicy.new(max_retries: 7, base_delay: Time::Span.zero)
    req.retry = custom
    Trellis::RetryPolicy.from(req).max_retries.should eq(7)
  end
end
