require "../spec_helper"

describe ReqLLM::Response do
  it "extracts text from the assistant message" do
    msg = ReqLLM::Message.new(ReqLLM::Role::Assistant,
      [ReqLLM::ContentPart.text("Hello "), ReqLLM::ContentPart.text("world")])
    resp = ReqLLM::Response.new(model: "openai:gpt-4o-mini", message: msg,
      finish_reason: ReqLLM::FinishReason::Stop)
    resp.text.should eq("Hello world")
    resp.finish_reason.should eq(ReqLLM::FinishReason::Stop)
    resp.ok?.should be_true
  end

  it "returns an empty string for text when no message is present" do
    resp = ReqLLM::Response.new(model: "openai:gpt-4o-mini")
    resp.text.should eq("")
  end

  it "normalizes wire finish reasons" do
    ReqLLM::FinishReason.from_wire("stop").should eq(ReqLLM::FinishReason::Stop)
    ReqLLM::FinishReason.from_wire("tool_calls").should eq(ReqLLM::FinishReason::ToolCalls)
    ReqLLM::FinishReason.from_wire("length").should eq(ReqLLM::FinishReason::Length)
  end

  it "maps nil and unknown wire finish reasons to Other" do
    ReqLLM::FinishReason.from_wire(nil).should eq(ReqLLM::FinishReason::Other)
    ReqLLM::FinishReason.from_wire("banana").should eq(ReqLLM::FinishReason::Other)
  end

  it "maps the Anthropic-specific wire finish reasons (AU3, additive)" do
    ReqLLM::FinishReason.from_wire("stop_sequence").should eq(ReqLLM::FinishReason::Stop)
    ReqLLM::FinishReason.from_wire("model_context_window_exceeded").should eq(ReqLLM::FinishReason::Length)
    ReqLLM::FinishReason.from_wire("refusal").should eq(ReqLLM::FinishReason::ContentFilter)
    # pause_turn has no Incomplete value in this port → Other (acceptable).
    ReqLLM::FinishReason.from_wire("pause_turn").should eq(ReqLLM::FinishReason::Other)
  end

  it "keeps the existing OpenAI/Google wire tokens unchanged after the AU3 extension" do
    ReqLLM::FinishReason.from_wire("stop").should eq(ReqLLM::FinishReason::Stop)
    ReqLLM::FinishReason.from_wire("end_turn").should eq(ReqLLM::FinishReason::Stop)
    ReqLLM::FinishReason.from_wire("tool_use").should eq(ReqLLM::FinishReason::ToolCalls)
    ReqLLM::FinishReason.from_wire("tool_calls").should eq(ReqLLM::FinishReason::ToolCalls)
    ReqLLM::FinishReason.from_wire("max_tokens").should eq(ReqLLM::FinishReason::Length)
    ReqLLM::FinishReason.from_wire("content_filter").should eq(ReqLLM::FinishReason::ContentFilter)
  end

  it "maps the Google-specific RECITATION wire finish reason (GU3, additive)" do
    ReqLLM::FinishReason.from_wire("RECITATION").should eq(ReqLLM::FinishReason::ContentFilter)
  end

  it "keeps the existing Google wire tokens unchanged after the GU3 extension" do
    ReqLLM::FinishReason.from_wire("STOP").should eq(ReqLLM::FinishReason::Stop)
    ReqLLM::FinishReason.from_wire("MAX_TOKENS").should eq(ReqLLM::FinishReason::Length)
    ReqLLM::FinishReason.from_wire("SAFETY").should eq(ReqLLM::FinishReason::ContentFilter)
    ReqLLM::FinishReason.from_wire("OTHER").should eq(ReqLLM::FinishReason::Other)
  end
end
