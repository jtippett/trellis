require "../spec_helper"

describe ReqLLM::Tool do
  it "emits an OpenAI-style JSON schema via to_json_schema" do
    tool = ReqLLM::Tool.new(
      "get_weather",
      "Get current weather",
      {
        "properties" => JSON::Any.new({
          "location" => JSON::Any.new({"type" => JSON::Any.new("string")}),
        }),
        "required" => JSON::Any.new([JSON::Any.new("location")]),
      } of String => JSON::Any
    )

    schema = tool.to_json_schema
    schema["type"].should eq("object")
    schema["properties"].as_h["location"].as_h["type"].should eq("string")
    schema["required"].as_a.map(&.as_s).should eq(["location"])
  end

  it "defaults properties and required when the schema is empty" do
    tool = ReqLLM::Tool.new("get_time", "Get the current time")
    schema = tool.to_json_schema
    schema["type"].should eq("object")
    schema["properties"].as_h.should be_empty
    schema["required"].as_a.should be_empty
  end

  it "rejects an invalid tool name" do
    expect_raises(ReqLLM::Error::Invalid::Parameter, /invalid/i) do
      ReqLLM::Tool.new("123 invalid", "desc")
    end
  end

  it "validates names with valid_name?" do
    ReqLLM::Tool.valid_name?("get_weather").should be_true
    ReqLLM::Tool.valid_name?("get-weather").should be_true
    ReqLLM::Tool.valid_name?("_private").should be_true
    ReqLLM::Tool.valid_name?("123invalid").should be_false
    ReqLLM::Tool.valid_name?("has space").should be_false
    ReqLLM::Tool.valid_name?("a" * 65).should be_false
  end

  it "stores and exposes a callback proc" do
    callback = ->(args : Hash(String, JSON::Any)) { args["msg"] }
    tool = ReqLLM::Tool.new("echo", "Echoes input", {} of String => JSON::Any, callback)
    tool.callback.should_not be_nil
    tool.callback.not_nil!.call({"msg" => JSON::Any.new("hi")}).should eq("hi")
  end
end
