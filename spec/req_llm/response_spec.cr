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
end
