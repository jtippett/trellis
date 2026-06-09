require "../../spec_helper"

describe ReqLLM::Providers::OpenAI do
  describe "#decode_response" do
    it "decodes a Chat Completions response into text, finish_reason, and usage" do
      model = LLMDB.model("openai:gpt-4o-mini")
      provider = ReqLLM::Providers::OpenAI.new

      req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://api.openai.com/v1/chat/completions"))
      req.model = model

      resp = ReqLLM::Fixture.load_response("spec/fixtures/openai/chat_basic.json")
      _, resp = provider.decode_response(req, resp)

      decoded = resp.decoded.not_nil!
      decoded.text.should eq("Hello! How can I help?")
      decoded.finish_reason.should eq(ReqLLM::FinishReason::Stop)
      decoded.message.not_nil!.role.should eq(ReqLLM::Role::Assistant)

      usage = decoded.usage.not_nil!
      usage.input_tokens.should eq(11)
      usage.output_tokens.should eq(7)
    end
  end
end
