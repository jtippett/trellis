require "../spec_helper"

describe Trellis::Tool do
  it "emits an OpenAI-style JSON schema via to_json_schema" do
    tool = Trellis::Tool.new(
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
    tool = Trellis::Tool.new("get_time", "Get the current time")
    schema = tool.to_json_schema
    schema["type"].should eq("object")
    schema["properties"].as_h.should be_empty
    schema["required"].as_a.should be_empty
  end

  it "preserves all top-level schema keys via to_json_schema" do
    tool = Trellis::Tool.new(
      "lookup",
      "Look something up",
      {
        "description"          => JSON::Any.new("A lookup request"),
        "additionalProperties" => JSON::Any.new(false),
        "$defs"                => JSON::Any.new({
          "Id" => JSON::Any.new({"type" => JSON::Any.new("string")}),
        } of String => JSON::Any),
        "properties" => JSON::Any.new({
          "id" => JSON::Any.new({"$ref" => JSON::Any.new("#/$defs/Id")}),
        } of String => JSON::Any),
        "required" => JSON::Any.new([JSON::Any.new("id")]),
      } of String => JSON::Any
    )

    schema = tool.to_json_schema
    schema["type"].should eq("object")
    schema["description"].should eq("A lookup request")
    schema["additionalProperties"].should eq(false)
    schema["$defs"].as_h["Id"].as_h["type"].should eq("string")
    schema["properties"].as_h["id"].as_h["$ref"].should eq("#/$defs/Id")
    schema["required"].as_a.map(&.as_s).should eq(["id"])
  end

  it "does not clobber an explicit non-object type" do
    tool = Trellis::Tool.new(
      "stringy",
      "A stringy tool",
      {"type" => JSON::Any.new("string")} of String => JSON::Any
    )
    tool.to_json_schema["type"].should eq("string")
  end

  it "defaults strict to false and exposes it via the constructor" do
    Trellis::Tool.new("plain", "Plain tool").strict.should be_false
    Trellis::Tool.new("strict_tool", "Strict tool", strict: true).strict.should be_true
  end

  it "rejects an invalid tool name" do
    expect_raises(Trellis::Error::Invalid::Parameter, /invalid/i) do
      Trellis::Tool.new("123 invalid", "desc")
    end
  end

  it "validates names with valid_name?" do
    Trellis::Tool.valid_name?("get_weather").should be_true
    Trellis::Tool.valid_name?("get-weather").should be_true
    Trellis::Tool.valid_name?("_private").should be_true
    Trellis::Tool.valid_name?("123invalid").should be_false
    Trellis::Tool.valid_name?("has space").should be_false
    Trellis::Tool.valid_name?("a" * 65).should be_false
  end

  it "stores and exposes a callback proc" do
    callback = ->(args : Hash(String, JSON::Any)) { args["msg"] }
    tool = Trellis::Tool.new("echo", "Echoes input", {} of String => JSON::Any, callback)
    tool.callback.should_not be_nil
    tool.callback.not_nil!.call({"msg" => JSON::Any.new("hi")}).should eq("hi")
  end
end
