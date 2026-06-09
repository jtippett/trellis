require "../spec_helper"

private def build_request
  ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
end

# A trivial provider whose extract_usage returns the decoded usage (the
# BaseProvider default), so we can exercise the live Steps.usage seam.
private class UsageStubProvider < ReqLLM::BaseProvider
  def id : String
    "openai"
  end

  def default_base_url : String
    "https://stub/v1"
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

describe ReqLLM::Steps do
  describe ".error" do
    it "is a named response step keyed :error" do
      name, _step = ReqLLM::Steps.error
      name.should eq(:error)
    end

    it "raises Error::API::Request carrying status and body for 4xx" do
      req = build_request
      resp = ReqLLM::HTTP::Response.new(401, HTTP::Headers.new, %({"error":"nope"}))
      _name, step = ReqLLM::Steps.error

      ex = expect_raises(ReqLLM::Error::API::Request) do
        step.call(req, resp)
      end
      ex.status.should eq(401)
      ex.body.should eq(%({"error":"nope"}))
    end

    it "raises for 5xx as well" do
      req = build_request
      resp = ReqLLM::HTTP::Response.new(503, HTTP::Headers.new, "down")
      _name, step = ReqLLM::Steps.error
      expect_raises(ReqLLM::Error::API::Request) { step.call(req, resp) }
    end

    it "passes through a 2xx response unchanged" do
      req = build_request
      resp = ReqLLM::HTTP::Response.new(200, HTTP::Headers.new, %({"ok":true}))
      _name, step = ReqLLM::Steps.error

      out_req, out_resp = step.call(req, resp)
      out_req.should be(req)
      out_resp.should be(resp)
    end

    it "attaches to a request's response steps under :error" do
      req = build_request
      ReqLLM::Steps.attach_error(req)
      req.response_steps.map { |(n, _)| n }.should eq([:error])
    end
  end

  describe ".usage" do
    it "is a named response step keyed :usage" do
      name, _step = ReqLLM::Steps.usage
      name.should eq(:usage)
    end

    it "preserves the token usage that decode attached to the decoded response" do
      req = build_request
      resp = ReqLLM::HTTP::Response.new(200, HTTP::Headers.new, %({"ok":true}))
      resp.decoded = ReqLLM::Response.new(
        model: "openai:gpt-4o-mini",
        usage: ReqLLM::Usage.new(input_tokens: 10, output_tokens: 5),
      )
      _name, step = ReqLLM::Steps.usage

      _out_req, out_resp = step.call(req, resp)
      usage = out_resp.decoded.not_nil!.usage.not_nil!
      usage.input_tokens.should eq(10)
      usage.output_tokens.should eq(5)
    end

    it "passes through when there is no decoded response" do
      req = build_request
      resp = ReqLLM::HTTP::Response.new(200, HTTP::Headers.new, "")
      _name, step = ReqLLM::Steps.usage

      out_req, out_resp = step.call(req, resp)
      out_req.should be(req)
      out_resp.should be(resp)
    end

    it "attaches to a request's response steps under :usage" do
      req = build_request
      ReqLLM::Steps.attach_usage(req)
      req.response_steps.map { |(n, _)| n }.should eq([:usage])
    end

    it "computes and stores per-token cost from req.model pricing via provider.extract_usage" do
      provider = UsageStubProvider.new
      req = build_request
      req.model = LLMDB.model("openai:gpt-4o-mini") # 0.15 in / 0.60 out per 1M

      resp = ReqLLM::HTTP::Response.new(200, HTTP::Headers.new, %({"ok":true}))
      resp.decoded = ReqLLM::Response.new(
        model: "openai:gpt-4o-mini",
        usage: ReqLLM::Usage.new(input_tokens: 11, output_tokens: 7),
      )

      _name, step = ReqLLM::Steps.usage(provider)
      _out_req, out_resp = step.call(req, resp)

      usage = out_resp.decoded.not_nil!.usage.not_nil!
      usage.input_tokens.should eq(11)
      usage.output_tokens.should eq(7)
      # 11/1M * 0.15 + 7/1M * 0.60 = 5.85e-6
      usage.cost.not_nil!.should be_close(5.85e-6, 1e-12)
    end
  end
end
