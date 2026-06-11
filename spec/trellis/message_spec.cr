require "../spec_helper"

describe Trellis::Message do
  it "wraps a string into a single text part" do
    msg = Trellis::Message.new(Trellis::Role::User, "hi")
    msg.content.size.should eq(1)
    msg.content.first.text.should eq("hi")
  end

  it "accepts explicit content parts" do
    parts = [Trellis::ContentPart.text("a"), Trellis::ContentPart.text("b")]
    Trellis::Message.new(Trellis::Role::Assistant, parts).content.size.should eq(2)
  end

  it "is invalid when empty" do
    Trellis::Message.new(Trellis::Role::User, [] of Trellis::ContentPart).valid?.should be_false
  end

  it "is valid when empty but carrying a tool_call_id" do
    msg = Trellis::Message.new(Trellis::Role::Tool, [] of Trellis::ContentPart, tool_call_id: "call_1")
    msg.valid?.should be_true
  end

  it "exposes lossless round-trip metadata fields" do
    msg = Trellis::Message.new(Trellis::Role::User, "hi")
    msg.metadata.should eq({} of String => JSON::Any)
    msg.reasoning_details.should be_nil
  end
end
