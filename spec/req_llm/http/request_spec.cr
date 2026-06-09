require "../../spec_helper"

describe ReqLLM::HTTP::Request do
  it "appends, prepends, and replaces request steps by name" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    req.append_request_step(:a) { |r| r }
    req.append_request_step(:b) { |r| r }
    req.prepend_request_step(:z) { |r| r }
    req.request_step_names.should eq([:z, :a, :b])

    req.replace_request_step(:a) { |r| r }
    req.request_step_names.should eq([:z, :a, :b]) # order preserved on replace
  end

  it "carries typed model/context state, not JSON bags" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    req.operation.should eq(:chat)
    req.model.should be_nil
  end
end
