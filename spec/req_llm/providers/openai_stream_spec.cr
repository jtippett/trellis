require "../../spec_helper"

# Wrap a recorded chunk JSON string (the `data:` payload of one SSE frame) as an
# SSE::Event, the way SU1's framer would emit it.
private def event(data : String) : ReqLLM::SSE::Event
  ReqLLM::SSE::Event.new(data: data)
end

describe ReqLLM::Providers::OpenAI do
  describe "#decode_stream_event" do
    provider = ReqLLM::Providers::OpenAI.new

    it "decodes a content delta frame into one Content chunk" do
      data = %({"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      chunks[0].type.should eq(ReqLLM::ChunkType::Content)
      chunks[0].text.should eq("Hello")
    end

    it "skips an empty content delta frame" do
      data = %({"choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]})
      provider.decode_stream_event(event(data)).should be_empty
    end

    it "decodes a tool_call delta carrying id + name into a ToolCall chunk" do
      data = %({"choices":[{"index":0,"delta":{"tool_calls":[) +
             %({"index":0,"id":"call_x","type":"function",) +
             %("function":{"name":"get_weather","arguments":""}}]}}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      c = chunks[0]
      c.type.should eq(ReqLLM::ChunkType::ToolCall)
      c.name.should eq("get_weather")
      c.metadata["index"].as_i.should eq(0)
      c.metadata["id"].as_s.should eq("call_x")
      # arguments == "" is not emitted as a fragment.
      c.metadata["arguments_fragment"]?.should be_nil
    end

    it "decodes a tool_call delta carrying an arguments fragment" do
      data = %({"choices":[{"index":0,"delta":{"tool_calls":[) +
             %({"index":0,"function":{"arguments":"{\\"loc"}}]}}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      c = chunks[0]
      c.type.should eq(ReqLLM::ChunkType::ToolCall)
      c.metadata["index"].as_i.should eq(0)
      c.metadata["arguments_fragment"].as_s.should eq(%({"loc))
      c.name.should be_nil
    end

    it "decodes a finish_reason frame into a Meta chunk" do
      data = %({"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      chunks[0].type.should eq(ReqLLM::ChunkType::Meta)
      chunks[0].metadata["finish_reason"].as_s.should eq("stop")
    end

    it "decodes a content + finish_reason frame into both a Content and a Meta chunk" do
      data = %({"choices":[{"index":0,"delta":{"content":"!"},"finish_reason":"stop"}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(2)
      chunks[0].type.should eq(ReqLLM::ChunkType::Content)
      chunks[0].text.should eq("!")
      chunks[1].type.should eq(ReqLLM::ChunkType::Meta)
      chunks[1].metadata["finish_reason"].as_s.should eq("stop")
    end

    it "decodes a usage-only final frame into a Meta chunk with normalized usage" do
      data = %({"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,) +
             %("total_tokens":18,"completion_tokens_details":{"reasoning_tokens":3},) +
             %("prompt_tokens_details":{"cached_tokens":2}}})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      c = chunks[0]
      c.type.should eq(ReqLLM::ChunkType::Meta)
      usage = c.metadata["usage"]
      usage["input_tokens"].as_i.should eq(11)
      usage["output_tokens"].as_i.should eq(7)
      usage["reasoning_tokens"].as_i.should eq(3)
      usage["cached_tokens"].as_i.should eq(2)
    end

    it "returns an empty array for the [DONE] sentinel" do
      provider.decode_stream_event(event("[DONE]")).should be_empty
    end

    it "returns an empty array for a blank data frame (no JSON.parse crash)" do
      provider.decode_stream_event(event("")).should be_empty
    end

    it "folds decoded tool-call frames through the accumulator into one ToolCall (integration)" do
      frames = [
        %({"choices":[{"index":0,"delta":{"role":"assistant","content":null}}]}),
        %({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}),
        %({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"loc"}}]}}]}),
        %({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ation\\":\\"Paris\\"}"}}]}}]}),
        %({"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}),
        %({"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":12,"total_tokens":21}}),
        "[DONE]",
      ]

      acc = ReqLLM::ChunkAccumulator.new
      frames.each do |data|
        provider.decode_stream_event(event(data)).each { |chunk| acc << chunk }
      end

      resp = acc.finish("openai:gpt-4o")
      calls = resp.tool_calls
      calls.size.should eq(1)
      calls[0].id.should eq("call_x")
      calls[0].name.should eq("get_weather")
      calls[0].args_map["location"].as_s.should eq("Paris")
      resp.finish_reason.should eq(ReqLLM::FinishReason::ToolCalls)
      resp.usage.not_nil!.input_tokens.should eq(9)
      resp.usage.not_nil!.output_tokens.should eq(12)
    end

    it "folds a content stream through the accumulator into Response.text (integration)" do
      frames = [
        %({"choices":[{"index":0,"delta":{"content":"Hello, "},"finish_reason":null}]}),
        %({"choices":[{"index":0,"delta":{"content":"world!"},"finish_reason":"stop"}]}),
        %({"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}),
        "[DONE]",
      ]

      acc = ReqLLM::ChunkAccumulator.new
      frames.each do |data|
        provider.decode_stream_event(event(data)).each { |chunk| acc << chunk }
      end

      resp = acc.finish("openai:gpt-4o")
      resp.text.should eq("Hello, world!")
      resp.finish_reason.should eq(ReqLLM::FinishReason::Stop)
      resp.usage.not_nil!.output_tokens.should eq(2)
    end
  end
end
