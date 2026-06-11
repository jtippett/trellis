require "../spec_helper"

describe Trellis::ToolCall do
  it "parses the arguments JSON string into a map via args_map" do
    tc = Trellis::ToolCall.new("call_1", "get_weather", %({"location":"Paris"}))
    tc.args_map["location"].should eq("Paris")
  end

  it "returns an empty map when arguments are not a JSON object" do
    tc = Trellis::ToolCall.new("call_1", "noop", "not-json")
    tc.args_map.should be_empty
  end

  it "round-trips id/name/arguments through from_wire -> to_wire" do
    wire = JSON.parse(
      %({"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\\"location\\":\\"Paris\\"}"}})
    )
    tc = Trellis::ToolCall.from_wire(wire)
    tc.id.should eq("call_1")
    tc.name.should eq("get_weather")
    tc.arguments.should eq(%({"location":"Paris"}))
    tc.to_wire.should eq(wire)
  end

  it "preserves builtin? and metadata flags across the round-trip" do
    wire = JSON.parse(
      %({"id":"call_2","type":"function","function":{"name":"web_search","arguments":"{}","builtin?":true,"metadata":{"source":"openai"}}})
    )
    tc = Trellis::ToolCall.from_wire(wire)
    tc.builtin?.should be_true
    tc.metadata["source"].should eq("openai")
    tc.to_wire.should eq(wire)
  end

  it "generates a call id when the wire form omits one" do
    wire = JSON.parse(%({"type":"function","function":{"name":"get_time","arguments":"{}"}}))
    tc = Trellis::ToolCall.from_wire(wire)
    tc.id.should start_with("call_")
  end
end
