require "../../spec_helper"

# Wrap a recorded chunk JSON string (the `data:` payload of one Messages SSE
# frame) as an SSE::Event, the way SU1's framer would emit it.
private def event(data : String) : ReqLLM::SSE::Event
  ReqLLM::SSE::Event.new(data: data)
end

describe ReqLLM::Providers::Anthropic do
  describe "#decode_stream_event" do
    provider = ReqLLM::Providers::Anthropic.new

    it "decodes a content_block_delta text_delta into one Content chunk" do
      data = %({"type":"content_block_delta","index":0,) +
             %("delta":{"type":"text_delta","text":"Hello"}})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      chunks[0].type.should eq(ReqLLM::ChunkType::Content)
      chunks[0].text.should eq("Hello")
    end

    it "decodes a message_delta stop_reason into a Meta chunk" do
      data = %({"type":"message_delta","delta":{"stop_reason":"end_turn"}})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      chunks[0].type.should eq(ReqLLM::ChunkType::Meta)
      chunks[0].metadata["finish_reason"].as_s.should eq("end_turn")
    end

    it "decodes a message_start usage into a normalized Meta usage chunk" do
      data = %({"type":"message_start","message":{"usage":) +
             %({"input_tokens":11,"cache_read_input_tokens":2,"output_tokens":1}}})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      c = chunks[0]
      c.type.should eq(ReqLLM::ChunkType::Meta)
      usage = c.metadata["usage"]
      usage["input_tokens"].as_i.should eq(11)
      usage["cached_tokens"].as_i.should eq(2)
      usage["output_tokens"].as_i.should eq(1)
      usage["reasoning_tokens"].as_i.should eq(0)
    end

    it "decodes a content_block_start tool_use into a ToolCall delta chunk" do
      data = %({"type":"content_block_start","index":0,"content_block":) +
             %({"type":"tool_use","id":"toolu_x","name":"get_weather","input":{}}})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      c = chunks[0]
      c.type.should eq(ReqLLM::ChunkType::ToolCall)
      c.name.should eq("get_weather")
      c.metadata["index"].as_i.should eq(0)
      c.metadata["id"].as_s.should eq("toolu_x")
      c.metadata["arguments_fragment"]?.should be_nil
    end

    it "decodes a content_block_delta input_json_delta into a ToolCall fragment" do
      data = %({"type":"content_block_delta","index":0,) +
             %("delta":{"type":"input_json_delta","partial_json":"{\\"loc"}})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      c = chunks[0]
      c.type.should eq(ReqLLM::ChunkType::ToolCall)
      c.metadata["index"].as_i.should eq(0)
      c.metadata["arguments_fragment"].as_s.should eq(%({"loc))
      c.name.should be_nil
    end

    it "decodes a content_block_delta thinking_delta into a Thinking chunk" do
      data = %({"type":"content_block_delta","index":0,) +
             %("delta":{"type":"thinking_delta","thinking":"Let me think"}})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      chunks[0].type.should eq(ReqLLM::ChunkType::Thinking)
      chunks[0].text.should eq("Let me think")
    end

    it "raises on an in-stream error frame (surfaced to the consumer)" do
      data = %({"type":"error","error":) +
             %({"type":"overloaded_error","message":"Overloaded"}})
      ex = expect_raises(ReqLLM::Error::API::Response, /Anthropic stream error/) do
        provider.decode_stream_event(event(data))
      end
      ex.message.not_nil!.should contain("Overloaded")
    end

    it "returns an empty array for terminal/keepalive frames" do
      provider.decode_stream_event(event(%({"type":"ping"}))).should be_empty
      provider.decode_stream_event(event(%({"type":"content_block_stop","index":0}))).should be_empty
      provider.decode_stream_event(event(%({"type":"message_stop"}))).should be_empty
    end

    it "returns an empty array for the [DONE] sentinel and blank frames" do
      provider.decode_stream_event(event("[DONE]")).should be_empty
      provider.decode_stream_event(event("")).should be_empty
    end

    it "folds tool_use start + input_json_delta deltas through the accumulator into one ToolCall (integration)" do
      frames = [
        %({"type":"message_start","message":{"usage":{"input_tokens":9}}}),
        %({"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_x","name":"get_weather","input":{}}}),
        %({"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"loc"}}),
        %({"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"ation\\":\\"Paris\\"}"}}),
        %({"type":"content_block_stop","index":0}),
        %({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}),
        %({"type":"message_stop"}),
      ]

      acc = ReqLLM::ChunkAccumulator.new
      frames.each do |data|
        provider.decode_stream_event(event(data)).each { |chunk| acc << chunk }
      end

      resp = acc.finish("anthropic:claude-3-5-sonnet-20241022")
      calls = resp.tool_calls
      calls.size.should eq(1)
      calls[0].id.should eq("toolu_x")
      calls[0].name.should eq("get_weather")
      calls[0].args_map["location"].as_s.should eq("Paris")
      resp.finish_reason.should eq(ReqLLM::FinishReason::ToolCalls)
    end

    it "folds a content stream with SPLIT usage through the accumulator, proving the merge (integration)" do
      frames = [
        %({"type":"message_start","message":{"usage":{"input_tokens":11,"cache_read_input_tokens":2}}}),
        %({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
        %({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Streaming "}}),
        %({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"works."}}),
        %({"type":"content_block_stop","index":0}),
        %({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}),
        %({"type":"message_stop"}),
      ]

      acc = ReqLLM::ChunkAccumulator.new
      frames.each do |data|
        provider.decode_stream_event(event(data)).each { |chunk| acc << chunk }
      end

      resp = acc.finish("anthropic:claude-3-5-sonnet-20241022")
      resp.text.should eq("Streaming works.")
      resp.finish_reason.should eq(ReqLLM::FinishReason::Stop)
      # SPLIT usage: input/cache arrived at message_start, output at
      # message_delta; the per-field merge keeps all three.
      resp.usage.not_nil!.input_tokens.should eq(11)
      resp.usage.not_nil!.output_tokens.should eq(7)
      resp.usage.not_nil!.cached_tokens.should eq(2)
    end
  end
end
