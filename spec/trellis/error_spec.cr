require "../spec_helper"

describe Trellis::Error do
  it "API::Request carries status and body" do
    err = Trellis::Error::API::Request.new("boom", status: 429, body: "rate limited")
    err.status.should eq(429)
    err.body.should eq("rate limited")
    err.message.should eq("boom")
  end

  it "subclasses share a common base" do
    Trellis::Error::Invalid::Parameter.new("bad").is_a?(Trellis::Error).should be_true
  end
end
