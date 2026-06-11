require "../../spec_helper"

describe Trellis::Providers::OpenAI do
  describe "#decode_response" do
    it "decodes a Chat Completions response into text, finish_reason, and usage" do
      model = LLMDB.model("openai:gpt-4o-mini")
      provider = Trellis::Providers::OpenAI.new

      req = Trellis::HTTP::Request.new("POST", URI.parse("https://api.openai.com/v1/chat/completions"))
      req.model = model

      resp = Trellis::Fixture.load_response("spec/fixtures/openai/chat_basic.json")
      _, resp = provider.decode_response(req, resp)

      decoded = resp.decoded.not_nil!
      decoded.text.should eq("Hello! How can I help?")
      decoded.finish_reason.should eq(Trellis::FinishReason::Stop)
      decoded.message.not_nil!.role.should eq(Trellis::Role::Assistant)

      usage = decoded.usage.not_nil!
      usage.input_tokens.should eq(11)
      usage.output_tokens.should eq(7)
    end

    it "decodes tool_calls into Response#tool_calls with parsed args and ToolCalls finish" do
      model = LLMDB.model("openai:gpt-4o-mini")
      provider = Trellis::Providers::OpenAI.new

      req = Trellis::HTTP::Request.new("POST", URI.parse("https://api.openai.com/v1/chat/completions"))
      req.model = model

      resp = Trellis::Fixture.load_response("spec/fixtures/openai/chat_tools.json")
      _, resp = provider.decode_response(req, resp)

      decoded = resp.decoded.not_nil!
      decoded.finish_reason.should eq(Trellis::FinishReason::ToolCalls)

      calls = decoded.tool_calls
      calls.size.should eq(1)
      call = calls.first
      call.id.should eq("call_abc123")
      call.name.should eq("get_weather")
      call.args_map["location"].should eq(JSON::Any.new("Paris"))

      decoded.message.not_nil!.role.should eq(Trellis::Role::Assistant)
    end
  end
end

describe "Trellis.generate_text with tool calls" do
  it "returns the tool call end-to-end from a recorded fixture" do
    saved = ENV["OPENAI_API_KEY"]?
    ENV.delete("OPENAI_API_KEY")

    resp = Trellis.generate_text("openai:gpt-4o-mini", "What's the weather in Paris?", fixture: "chat_tools")

    resp.finish_reason.should eq(Trellis::FinishReason::ToolCalls)
    call = resp.tool_calls.first
    call.name.should eq("get_weather")
    call.args_map["location"].should eq(JSON::Any.new("Paris"))
  ensure
    if saved
      ENV["OPENAI_API_KEY"] = saved
    else
      ENV.delete("OPENAI_API_KEY")
    end
  end
end
