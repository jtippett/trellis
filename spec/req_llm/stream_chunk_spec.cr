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
