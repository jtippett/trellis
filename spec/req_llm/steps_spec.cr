require "../spec_helper"

private def build_request
  ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
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
  end
end
