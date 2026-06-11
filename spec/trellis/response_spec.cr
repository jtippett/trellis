require "../spec_helper"

describe Trellis::Response do
  it "extracts text from the assistant message" do
    msg = Trellis::Message.new(Trellis::Role::Assistant,
      [Trellis::ContentPart.text("Hello "), Trellis::ContentPart.text("world")])
    resp = Trellis::Response.new(model: "openai:gpt-4o-mini", message: msg,
      finish_reason: Trellis::FinishReason::Stop)
    resp.text.should eq("Hello world")
    resp.finish_reason.should eq(Trellis::FinishReason::Stop)
    resp.ok?.should be_true
  end

  it "returns an empty string for text when no message is present" do
    resp = Trellis::Response.new(model: "openai:gpt-4o-mini")
    resp.text.should eq("")
  end

  it "normalizes wire finish reasons" do
    Trellis::FinishReason.from_wire("stop").should eq(Trellis::FinishReason::Stop)
    Trellis::FinishReason.from_wire("tool_calls").should eq(Trellis::FinishReason::ToolCalls)
    Trellis::FinishReason.from_wire("length").should eq(Trellis::FinishReason::Length)
  end

  it "maps nil and unknown wire finish reasons to Other" do
    Trellis::FinishReason.from_wire(nil).should eq(Trellis::FinishReason::Other)
    Trellis::FinishReason.from_wire("banana").should eq(Trellis::FinishReason::Other)
  end

  it "maps the Anthropic-specific wire finish reasons (AU3, additive)" do
    Trellis::FinishReason.from_wire("stop_sequence").should eq(Trellis::FinishReason::Stop)
    Trellis::FinishReason.from_wire("model_context_window_exceeded").should eq(Trellis::FinishReason::Length)
    Trellis::FinishReason.from_wire("refusal").should eq(Trellis::FinishReason::ContentFilter)
    # pause_turn has no Incomplete value in this port → Other (acceptable).
    Trellis::FinishReason.from_wire("pause_turn").should eq(Trellis::FinishReason::Other)
  end

  it "keeps the existing OpenAI/Google wire tokens unchanged after the AU3 extension" do
    Trellis::FinishReason.from_wire("stop").should eq(Trellis::FinishReason::Stop)
    Trellis::FinishReason.from_wire("end_turn").should eq(Trellis::FinishReason::Stop)
    Trellis::FinishReason.from_wire("tool_use").should eq(Trellis::FinishReason::ToolCalls)
    Trellis::FinishReason.from_wire("tool_calls").should eq(Trellis::FinishReason::ToolCalls)
    Trellis::FinishReason.from_wire("max_tokens").should eq(Trellis::FinishReason::Length)
    Trellis::FinishReason.from_wire("content_filter").should eq(Trellis::FinishReason::ContentFilter)
  end

  it "maps the Google-specific RECITATION wire finish reason (GU3, additive)" do
    Trellis::FinishReason.from_wire("RECITATION").should eq(Trellis::FinishReason::ContentFilter)
  end

  it "keeps the existing Google wire tokens unchanged after the GU3 extension" do
    Trellis::FinishReason.from_wire("STOP").should eq(Trellis::FinishReason::Stop)
    Trellis::FinishReason.from_wire("MAX_TOKENS").should eq(Trellis::FinishReason::Length)
    Trellis::FinishReason.from_wire("SAFETY").should eq(Trellis::FinishReason::ContentFilter)
    Trellis::FinishReason.from_wire("OTHER").should eq(Trellis::FinishReason::Other)
  end

  describe "#unwrap_object" do
    it "extracts the object from a structured_output tool call's raw arguments" do
      tc = Trellis::ToolCall.new("call_1", "structured_output", %({"name":"Alice","age":30}))
      msg = Trellis::Message.new(Trellis::Role::Assistant, "", tool_calls: [tc])
      resp = Trellis::Response.new(model: "anthropic:claude", message: msg)

      obj = resp.unwrap_object
      obj["name"].as_s.should eq("Alice")
      obj["age"].as_i.should eq(30)
    end

    it "extracts a top-level array from a structured_output tool call" do
      tc = Trellis::ToolCall.new("call_1", "structured_output", %([1,2,3]))
      msg = Trellis::Message.new(Trellis::Role::Assistant, "", tool_calls: [tc])
      resp = Trellis::Response.new(model: "anthropic:claude", message: msg)

      resp.unwrap_object.as_a.map(&.as_i).should eq([1, 2, 3])
    end

    it "parses a JSON object from assistant text (json_schema mode)" do
      msg = Trellis::Message.new(Trellis::Role::Assistant, %({"name":"Bob"}))
      resp = Trellis::Response.new(model: "openai:gpt-4o-mini", message: msg)

      resp.unwrap_object["name"].as_s.should eq("Bob")
    end

    it "parses a top-level JSON array from assistant text" do
      msg = Trellis::Message.new(Trellis::Role::Assistant, %(["a","b"]))
      resp = Trellis::Response.new(model: "openai:gpt-4o-mini", message: msg)

      resp.unwrap_object.as_a.map(&.as_s).should eq(["a", "b"])
    end

    it "raises Error::Validation when neither tool call nor text yields JSON" do
      msg = Trellis::Message.new(Trellis::Role::Assistant, "not json at all")
      resp = Trellis::Response.new(model: "openai:gpt-4o-mini", message: msg)

      expect_raises(Trellis::Error::Validation, /no structured output/) do
        resp.unwrap_object
      end
    end
  end
end
