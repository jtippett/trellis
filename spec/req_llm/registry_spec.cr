require "../spec_helper"

# A minimal concrete provider used only to exercise the Registry. Implements the
# abstract contract methods trivially; the registry only cares about #id.
private class RegistryStubProvider < ReqLLM::BaseProvider
  def id : String
    "stub"
  end

  def default_base_url : String
    "https://stub.test/v1"
  end

  def default_env_key : String
    "STUB_API_KEY"
  end

  def prepare_request(operation, model, data, opts) : ReqLLM::HTTP::Request
    ReqLLM::HTTP::Request.new("POST", URI.parse(default_base_url))
  end

  def encode_body(req : ReqLLM::HTTP::Request) : ReqLLM::HTTP::Request
    req
  end

  def decode_response(req : ReqLLM::HTTP::Request, resp : ReqLLM::HTTP::Response) : {ReqLLM::HTTP::Request, ReqLLM::HTTP::Response}
    {req, resp}
  end
end

describe ReqLLM::Registry do
  it "registers a provider and fetches it back by its string id" do
    provider = RegistryStubProvider.new
    ReqLLM::Registry.register(provider)
    ReqLLM::Registry.fetch("stub").should be(provider)
  end

  it "raises Invalid::Parameter for an unknown provider id" do
    expect_raises(ReqLLM::Error::Invalid::Parameter, /unsupported provider: nope/) do
      ReqLLM::Registry.fetch("nope")
    end
  end
end
