require "../spec_helper"

describe ReqLLM::Message do
  it "wraps a string into a single text part" do
    msg = ReqLLM::Message.new(ReqLLM::Role::User, "hi")
    msg.content.size.should eq(1)
    msg.content.first.text.should eq("hi")
  end

  it "accepts explicit content parts" do
    parts = [ReqLLM::ContentPart.text("a"), ReqLLM::ContentPart.text("b")]
    ReqLLM::Message.new(ReqLLM::Role::Assistant, parts).content.size.should eq(2)
  end

  it "is invalid when empty" do
    ReqLLM::Message.new(ReqLLM::Role::User, [] of ReqLLM::ContentPart).valid?.should be_false
  end

  it "is valid when empty but carrying a tool_call_id" do
    msg = ReqLLM::Message.new(ReqLLM::Role::Tool, [] of ReqLLM::ContentPart, tool_call_id: "call_1")
    msg.valid?.should be_true
  end

  it "exposes lossless round-trip metadata fields" do
    msg = ReqLLM::Message.new(ReqLLM::Role::User, "hi")
    msg.metadata.should eq({} of String => JSON::Any)
    msg.reasoning_details.should be_nil
  end
end
