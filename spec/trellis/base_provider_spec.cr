require "../spec_helper"

# A minimal concrete provider that implements the abstract contract trivially so
# we can observe how BaseProvider#attach wires the pipeline steps.
private class BaseProviderStub < Trellis::BaseProvider
  def id : String
    "stub"
  end

  def default_base_url : String
    "https://stub.test/v1"
  end

  def default_env_key : String
    "STUB_API_KEY"
  end

  def prepare_request(operation, model, data, opts) : Trellis::HTTP::Request
    Trellis::HTTP::Request.new("POST", URI.parse(default_base_url))
  end

  def encode_body(req : Trellis::HTTP::Request) : Trellis::HTTP::Request
    req.body = "{}"
    req
  end

  def decode_response(req : Trellis::HTTP::Request, resp : Trellis::HTTP::Response) : {Trellis::HTTP::Request, Trellis::HTTP::Response}
    {req, resp}
  end
end

private def response_step_names(req : Trellis::HTTP::Request) : Array(Symbol)
  req.response_steps.map { |(name, _)| name }
end

private def build_request : Trellis::HTTP::Request
  req = Trellis::HTTP::Request.new("POST", URI.parse("https://stub.test/v1"))
  req.model = LLMDB::Model.new("stub", "stub-model")
  req
end

describe Trellis::BaseProvider do
  describe "#attach" do
    it "sets the auth header and preserves req.model" do
      ENV["STUB_API_KEY"] = "sk-test"
      provider = BaseProviderStub.new
      req = build_request
      provider.attach(req)

      req.headers["Authorization"]?.should eq("Bearer sk-test")
      req.headers["Content-Type"]?.should eq("application/json")
      req.model.should_not be_nil
      req.model.not_nil!.provider.should eq("stub")
    ensure
      ENV.delete("STUB_API_KEY")
    end

    it "wires the fixed step order in replay mode (fixture set, not recording)" do
      ENV["STUB_API_KEY"] = "sk-test"
      provider = BaseProviderStub.new
      req = build_request
      req.fixture = "somename"
      provider.attach(req)

      req.request_step_names.should eq([:encode_body, :fixture])
      response_step_names(req).should eq([:error, :decode_response, :usage])
    ensure
      ENV.delete("STUB_API_KEY")
    end

    it "appends :fixture_capture last and omits the replay step in record mode" do
      ENV["STUB_API_KEY"] = "sk-test"
      ENV["CR_LLM_FIXTURES"] = "record"
      provider = BaseProviderStub.new
      req = build_request
      req.fixture = "somename"
      provider.attach(req)

      req.request_step_names.should eq([:encode_body])
      response_step_names(req).should eq([:error, :decode_response, :usage, :fixture_capture])
    ensure
      ENV.delete("STUB_API_KEY")
      ENV.delete("CR_LLM_FIXTURES")
    end

    it "wires NO fixture step in either list when req.fixture is nil (even in record mode)" do
      ENV["STUB_API_KEY"] = "sk-test"
      ENV["CR_LLM_FIXTURES"] = "record"
      provider = BaseProviderStub.new
      req = build_request # fixture left nil
      provider.attach(req)

      req.request_step_names.should eq([:encode_body])
      response_step_names(req).should eq([:error, :decode_response, :usage])
    ensure
      ENV.delete("STUB_API_KEY")
      ENV.delete("CR_LLM_FIXTURES")
    end

    it "sets a retry policy on the request" do
      ENV["STUB_API_KEY"] = "sk-test"
      provider = BaseProviderStub.new
      req = build_request
      provider.attach(req)

      req.retry.should_not be_nil
    ensure
      ENV.delete("STUB_API_KEY")
    end
  end
end
