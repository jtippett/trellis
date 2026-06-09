require "../spec_helper"

describe ReqLLM::Error do
  it "API::Request carries status and body" do
    err = ReqLLM::Error::API::Request.new("boom", status: 429, body: "rate limited")
    err.status.should eq(429)
    err.body.should eq("rate limited")
    err.message.should eq("boom")
  end

  it "subclasses share a common base" do
    ReqLLM::Error::Invalid::Parameter.new("bad").is_a?(ReqLLM::Error).should be_true
  end
end
