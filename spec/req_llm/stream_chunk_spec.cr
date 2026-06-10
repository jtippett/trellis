require "../spec_helper"

describe ReqLLM::StreamChunk do
  it ".text builds a content chunk carrying text" do
    chunk = ReqLLM::StreamChunk.text("Hello world")
    chunk.type.should eq(ReqLLM::ChunkType::Content)
    chunk.text.should eq("Hello world")
  end

  it ".thinking builds a thinking chunk carrying text" do
    chunk = ReqLLM::StreamChunk.thinking("Let me think...")
    chunk.type.should eq(ReqLLM::ChunkType::Thinking)
    chunk.text.should eq("Let me think...")
  end

  it ".tool_call builds a tool_call chunk with name and arguments" do
    chunk = ReqLLM::StreamChunk.tool_call("get_weather", {"city" => JSON::Any.new("NYC")})
    chunk.type.should eq(ReqLLM::ChunkType::ToolCall)
    chunk.name.should eq("get_weather")
    chunk.arguments.not_nil!["city"].should eq("NYC")
  end

  it ".tool_call_delta builds a tool_call chunk with the accumulator's delta metadata" do
    chunk = ReqLLM::StreamChunk.tool_call_delta(
      0, id: "call_x", name: "get_weather", arguments_fragment: %({"loc))
    chunk.type.should eq(ReqLLM::ChunkType::ToolCall)
    chunk.name.should eq("get_weather")
    chunk.metadata["index"].as_i.should eq(0)
    chunk.metadata["id"].as_s.should eq("call_x")
    chunk.metadata["arguments_fragment"].as_s.should eq(%({"loc))
  end

  it ".tool_call_delta omits absent optional keys (index always present)" do
    chunk = ReqLLM::StreamChunk.tool_call_delta(1, arguments_fragment: %(ation"}))
    chunk.name.should be_nil
    chunk.metadata["index"].as_i.should eq(1)
    chunk.metadata["id"]?.should be_nil
    chunk.metadata["arguments_fragment"].as_s.should eq(%(ation"}))
  end

  it ".meta builds a meta chunk and merges extra metadata" do
    chunk = ReqLLM::StreamChunk.meta(
      {"finish_reason" => JSON::Any.new("stop")},
      {"model" => JSON::Any.new("gpt-4o-mini")}
    )
    chunk.type.should eq(ReqLLM::ChunkType::Meta)
    chunk.metadata["finish_reason"].should eq("stop")
    chunk.metadata["model"].should eq("gpt-4o-mini")
  end
end
