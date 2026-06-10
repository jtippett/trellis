require "../../spec_helper"

# Helper: a tool-call fragment chunk. The first fragment for an index carries
# `name` + `metadata["id"]`; later fragments carry `metadata["arguments_fragment"]`
# string pieces to concatenate. `metadata["index"]` groups fragments.
private def tool_chunk(index : Int32, *, id : String? = nil, name : String? = nil,
                       fragment : String? = nil) : ReqLLM::StreamChunk
  metadata = {"index" => JSON::Any.new(index.to_i64)} of String => JSON::Any
  metadata["id"] = JSON::Any.new(id) if id
  metadata["arguments_fragment"] = JSON::Any.new(fragment) if fragment
  ReqLLM::StreamChunk.new(ReqLLM::ChunkType::ToolCall, name: name, metadata: metadata)
end

private def meta_chunk(*, finish_reason : String? = nil,
                       usage : Hash(String, JSON::Any)? = nil) : ReqLLM::StreamChunk
  metadata = {} of String => JSON::Any
  metadata["finish_reason"] = JSON::Any.new(finish_reason) if finish_reason
  metadata["usage"] = JSON::Any.new(usage) if usage
  ReqLLM::StreamChunk.new(ReqLLM::ChunkType::Meta, metadata: metadata)
end

private def usage_obj(input : Int32, output : Int32) : Hash(String, JSON::Any)
  {
    "input_tokens"  => JSON::Any.new(input.to_i64),
    "output_tokens" => JSON::Any.new(output.to_i64),
  } of String => JSON::Any
end

describe ReqLLM::ChunkAccumulator do
  it "concatenates content chunks into Response.text and captures meta" do
    acc = ReqLLM::ChunkAccumulator.new
    acc << ReqLLM::StreamChunk.text("Hello, ")
    acc << ReqLLM::StreamChunk.text("world!")
    acc << meta_chunk(finish_reason: "stop", usage: usage_obj(10, 5))

    resp = acc.finish("openai:gpt-4o")

    resp.text.should eq("Hello, world!")
    resp.finish_reason.should eq(ReqLLM::FinishReason::Stop)
    resp.usage.not_nil!.input_tokens.should eq(10)
    resp.usage.not_nil!.output_tokens.should eq(5)
    resp.ok?.should be_true
  end

  it "reassembles tool-call fragments into one ToolCall" do
    acc = ReqLLM::ChunkAccumulator.new
    acc << tool_chunk(0, id: "call_1", name: "get_weather")
    acc << tool_chunk(0, fragment: %({"loc))
    acc << tool_chunk(0, fragment: %(ation":"Paris"}))
    acc << meta_chunk(finish_reason: "tool_calls")

    resp = acc.finish("openai:gpt-4o")
    calls = resp.tool_calls

    calls.size.should eq(1)
    calls[0].id.should eq("call_1")
    calls[0].name.should eq("get_weather")
    calls[0].arguments.should eq(%({"location":"Paris"}))
    calls[0].args_map["location"].as_s.should eq("Paris")
    resp.finish_reason.should eq(ReqLLM::FinishReason::ToolCalls)
  end

  it "groups fragments for multiple tool calls by index, preserving order" do
    acc = ReqLLM::ChunkAccumulator.new
    acc << tool_chunk(0, id: "call_a", name: "f_a")
    acc << tool_chunk(1, id: "call_b", name: "f_b")
    acc << tool_chunk(0, fragment: %({"x":1}))
    acc << tool_chunk(1, fragment: %({"y":2}))

    calls = acc.finish("openai:gpt-4o").tool_calls
    calls.map(&.name).should eq(["f_a", "f_b"])
    calls[0].args_map["x"].as_i.should eq(1)
    calls[1].args_map["y"].as_i.should eq(2)
  end

  it "populates Response.usage from a meta chunk alongside content" do
    acc = ReqLLM::ChunkAccumulator.new
    acc << ReqLLM::StreamChunk.text("hi")
    acc << meta_chunk(usage: usage_obj(3, 7))

    resp = acc.finish("openai:gpt-4o")
    resp.usage.not_nil!.input_tokens.should eq(3)
    resp.usage.not_nil!.output_tokens.should eq(7)
    resp.usage.not_nil!.total_tokens.should eq(10)
  end

  it "captures thinking chunks as a thinking content part" do
    acc = ReqLLM::ChunkAccumulator.new
    acc << ReqLLM::StreamChunk.thinking("Let me ")
    acc << ReqLLM::StreamChunk.thinking("reason.")
    acc << ReqLLM::StreamChunk.text("Answer")

    resp = acc.finish("openai:gpt-4o")
    msg = resp.message.not_nil!
    thinking = msg.content.find { |p| p.type.thinking? }
    thinking.not_nil!.text.should eq("Let me reason.")
    resp.text.should eq("Answer")
  end

  it "returns a sane empty Response when no chunks were added (non-stream parity)" do
    acc = ReqLLM::ChunkAccumulator.new
    resp = acc.finish("openai:gpt-4o")

    resp.text.should eq("")
    resp.tool_calls.should be_empty
    # Parity with non-streaming decode: from_wire(nil) == Other, usage zeroed.
    resp.finish_reason.should eq(ReqLLM::FinishReason::Other)
    resp.usage.not_nil!.total_tokens.should eq(0)
    resp.message.not_nil!.role.should eq(ReqLLM::Role::Assistant)
  end

  it "merges the assistant message onto the input context like non-streaming decode" do
    ctx = ReqLLM::Context.new([ReqLLM::Context.user("Hi")])
    acc = ReqLLM::ChunkAccumulator.new
    acc << ReqLLM::StreamChunk.text("Hello")

    resp = acc.finish("openai:gpt-4o", ctx)
    merged = resp.context.not_nil!.messages
    merged.size.should eq(2)
    merged.first.role.should eq(ReqLLM::Role::User)
    merged.last.role.should eq(ReqLLM::Role::Assistant)
    # Input context is not mutated.
    ctx.messages.size.should eq(1)
  end

  it "supports add as an alias for <<" do
    acc = ReqLLM::ChunkAccumulator.new
    acc.add(ReqLLM::StreamChunk.text("a")).add(ReqLLM::StreamChunk.text("b"))
    acc.finish("m").text.should eq("ab")
  end
end
