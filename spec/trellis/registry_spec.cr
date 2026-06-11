require "../spec_helper"

# A minimal concrete provider used only to exercise the Registry. Implements the
# abstract contract methods trivially; the registry only cares about #id.
private class RegistryStubProvider < Trellis::BaseProvider
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
    req
  end

  def decode_response(req : Trellis::HTTP::Request, resp : Trellis::HTTP::Response) : {Trellis::HTTP::Request, Trellis::HTTP::Response}
    {req, resp}
  end
end

describe Trellis::Registry do
  it "registers a provider and fetches it back by its string id" do
    provider = RegistryStubProvider.new
    Trellis::Registry.register(provider)
    Trellis::Registry.fetch("stub").should be(provider)
  end

  it "raises Invalid::Parameter for an unknown provider id" do
    expect_raises(Trellis::Error::Invalid::Parameter, /unsupported provider: nope/) do
      Trellis::Registry.fetch("nope")
    end
  end
end
