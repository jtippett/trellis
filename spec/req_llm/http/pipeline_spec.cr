require "../../spec_helper"
require "../../support/fake_adapter"

describe ReqLLM::HTTP::Pipeline do
  it "short-circuits transport but still runs response steps" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    canned = ReqLLM::HTTP::Response.new(200, HTTP::Headers.new, %({"ok":true}))
    req.append_request_step(:fixture) { |_| canned }
    req.append_response_step(:decode) do |r, resp|
      resp.decoded = ReqLLM::Response.new(model: "x",
        message: ReqLLM::Message.new(ReqLLM::Role::Assistant, "hi"))
      {r, resp}
    end
    adapter = FakeAdapter.new # raises if called
    out = ReqLLM::HTTP::Pipeline.run(req, adapter)
    adapter.called?.should be_false # transport skipped
    out.text.should eq("hi")        # decode still ran
  end

  it "runs the adapter then folds response steps" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    adapter = FakeAdapter.new(status: 200, body: %({"ok":true}))
    req.append_response_step(:decode) do |r, resp|
      resp.decoded = ReqLLM::Response.new(model: "x")
      {r, resp}
    end
    ReqLLM::HTTP::Pipeline.run(req, adapter)
    adapter.called?.should be_true
  end
end
