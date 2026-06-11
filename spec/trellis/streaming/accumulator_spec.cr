require "../../spec_helper"

# Helper: a tool-call fragment chunk. The first fragment for an index carries
# `name` + `metadata["id"]`; later fragments carry `metadata["arguments_fragment"]`
# string pieces to concatenate. `metadata["index"]` groups fragments.
private def tool_chunk(index : Int32, *, id : String? = nil, name : String? = nil,
                       fragment : String? = nil) : Trellis::StreamChunk
  metadata = {"index" => JSON::Any.new(index.to_i64)} of String => JSON::Any
  metadata["id"] = JSON::Any.new(id) if id
  metadata["arguments_fragment"] = JSON::Any.new(fragment) if fragment
  Trellis::StreamChunk.new(Trellis::ChunkType::ToolCall, name: name, metadata: metadata)
end

private def meta_chunk(*, finish_reason : String? = nil,
                       usage : Hash(String, JSON::Any)? = nil) : Trellis::StreamChunk
  metadata = {} of String => JSON::Any
  metadata["finish_reason"] = JSON::Any.new(finish_reason) if finish_reason
  metadata["usage"] = JSON::Any.new(usage) if usage
  Trellis::StreamChunk.new(Trellis::ChunkType::Meta, metadata: metadata)
end

private def usage_obj(input : Int32, output : Int32) : Hash(String, JSON::Any)
  {
    "input_tokens"  => JSON::Any.new(input.to_i64),
    "output_tokens" => JSON::Any.new(output.to_i64),
  } of String => JSON::Any
end

describe Trellis::ChunkAccumulator do
  it "concatenates content chunks into Response.text and captures meta" do
    acc = Trellis::ChunkAccumulator.new
    acc << Trellis::StreamChunk.text("Hello, ")
    acc << Trellis::StreamChunk.text("world!")
    acc << meta_chunk(finish_reason: "stop", usage: usage_obj(10, 5))

    resp = acc.finish("openai:gpt-4o")

    resp.text.should eq("Hello, world!")
    resp.finish_reason.should eq(Trellis::FinishReason::Stop)
    resp.usage.not_nil!.input_tokens.should eq(10)
    resp.usage.not_nil!.output_tokens.should eq(5)
    resp.ok?.should be_true
  end

  it "reassembles tool-call fragments into one ToolCall" do
    acc = Trellis::ChunkAccumulator.new
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
    resp.finish_reason.should eq(Trellis::FinishReason::ToolCalls)
  end

  it "groups fragments for multiple tool calls by index, preserving order" do
    acc = Trellis::ChunkAccumulator.new
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
    acc = Trellis::ChunkAccumulator.new
    acc << Trellis::StreamChunk.text("hi")
    acc << meta_chunk(usage: usage_obj(3, 7))

    resp = acc.finish("openai:gpt-4o")
    resp.usage.not_nil!.input_tokens.should eq(3)
    resp.usage.not_nil!.output_tokens.should eq(7)
    resp.usage.not_nil!.total_tokens.should eq(10)
  end

  it "captures thinking chunks as a thinking content part" do
    acc = Trellis::ChunkAccumulator.new
    acc << Trellis::StreamChunk.thinking("Let me ")
    acc << Trellis::StreamChunk.thinking("reason.")
    acc << Trellis::StreamChunk.text("Answer")

    resp = acc.finish("openai:gpt-4o")
    msg = resp.message.not_nil!
    thinking = msg.content.find { |p| p.type.thinking? }
    thinking.not_nil!.text.should eq("Let me reason.")
    resp.text.should eq("Answer")
  end

  it "returns a sane empty Response when no chunks were added (non-stream parity)" do
    acc = Trellis::ChunkAccumulator.new
    resp = acc.finish("openai:gpt-4o")

    resp.text.should eq("")
    resp.tool_calls.should be_empty
    # Parity with non-streaming decode: from_wire(nil) == Other, usage zeroed.
    resp.finish_reason.should eq(Trellis::FinishReason::Other)
    resp.usage.not_nil!.total_tokens.should eq(0)
    resp.message.not_nil!.role.should eq(Trellis::Role::Assistant)
  end

  it "merges the assistant message onto the input context like non-streaming decode" do
    ctx = Trellis::Context.new([Trellis::Context.user("Hi")])
    acc = Trellis::ChunkAccumulator.new
    acc << Trellis::StreamChunk.text("Hello")

    resp = acc.finish("openai:gpt-4o", ctx)
    merged = resp.context.not_nil!.messages
    merged.size.should eq(2)
    merged.first.role.should eq(Trellis::Role::User)
    merged.last.role.should eq(Trellis::Role::Assistant)
    # Input context is not mutated.
    ctx.messages.size.should eq(1)
  end

  it "supports add as an alias for <<" do
    acc = Trellis::ChunkAccumulator.new
    acc.add(Trellis::StreamChunk.text("a")).add(Trellis::StreamChunk.text("b"))
    acc.finish("m").text.should eq("ab")
  end

  # USAGE MERGE (AU4): usage meta chunks merge per-field (larger value wins)
  # rather than wholesale replace, so providers that split usage across frames
  # (Anthropic: input/cache at message_start, output at message_delta)
  # accumulate complete totals. For a single-frame provider (OpenAI) where only
  # one frame carries usage, the merge-from-nil collapses to that lone value.
  it "yields the lone final usage when only the terminal frame carries it (OpenAI no-regression)" do
    acc = Trellis::ChunkAccumulator.new
    # An earlier meta frame carries finish_reason but NO usage...
    acc << meta_chunk(finish_reason: "stop")
    # ...and the terminal frame carries the only usage object.
    acc << meta_chunk(usage: usage_obj(11, 7))

    resp = acc.finish("openai:gpt-4o")
    resp.usage.not_nil!.input_tokens.should eq(11)
    resp.usage.not_nil!.output_tokens.should eq(7)
    resp.finish_reason.should eq(Trellis::FinishReason::Stop)
  end

  it "merges split usage across frames per-field (Anthropic split-usage)" do
    acc = Trellis::ChunkAccumulator.new
    # Frame A carries only input; frame B carries only output.
    acc << meta_chunk(usage: {"input_tokens" => JSON::Any.new(10_i64)})
    acc << meta_chunk(usage: {"output_tokens" => JSON::Any.new(5_i64)})

    resp = acc.finish("anthropic:claude-3-5-sonnet-20241022")
    resp.usage.not_nil!.input_tokens.should eq(10)
    resp.usage.not_nil!.output_tokens.should eq(5)
  end

  # FINISH-UPGRADE (GU4): a response that produced tool calls finishes as
  # ToolCalls. Gemini reports finishReason "STOP" even with functionCall parts,
  # and the part/finish frames may arrive separately, so resolving it here makes
  # the result frame-order-independent. Only Stop is upgraded; Length/
  # ContentFilter keep their real reason. This is a verified NO-OP for OpenAI
  # ("tool_calls") and Anthropic ("tool_use"), which never pair Stop with tool
  # calls.
  describe "finish-reason upgrade (Stop -> ToolCalls when tool calls present)" do
    it "upgrades a Stop finish to ToolCalls when tool calls were accumulated" do
      acc = Trellis::ChunkAccumulator.new
      acc << tool_chunk(0, id: "call_1", name: "get_weather", fragment: %({"location":"Paris"}))
      acc << meta_chunk(finish_reason: "stop")

      resp = acc.finish("google:gemini-2.0-flash")
      resp.finish_reason.should eq(Trellis::FinishReason::ToolCalls)
    end

    it "does NOT upgrade Length (truncated mid-call keeps its real reason)" do
      acc = Trellis::ChunkAccumulator.new
      acc << tool_chunk(0, id: "call_1", name: "get_weather", fragment: %({"loc))
      acc << meta_chunk(finish_reason: "length")

      resp = acc.finish("google:gemini-2.0-flash")
      resp.finish_reason.should eq(Trellis::FinishReason::Length)
    end

    it "leaves a Stop finish untouched when NO tool calls were accumulated" do
      acc = Trellis::ChunkAccumulator.new
      acc << Trellis::StreamChunk.text("Hi")
      acc << meta_chunk(finish_reason: "stop")

      resp = acc.finish("google:gemini-2.0-flash")
      resp.finish_reason.should eq(Trellis::FinishReason::Stop)
    end
  end
end
