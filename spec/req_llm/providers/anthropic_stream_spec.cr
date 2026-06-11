require "../../spec_helper"

# Wrap a recorded chunk JSON string (the `data:` payload of one Messages SSE
# frame) as an SSE::Event, the way SU1's framer would emit it.
private def event(data : String) : ReqLLM::SSE::Event
  ReqLLM::SSE::Event.new(data: data)
end

# Runs `block` in a fiber and FAILS FAST if it doesn't finish within `timeout`,
# so a deadlock regression fails the spec instead of hanging CI forever (the
# consuming paths block on Channel#receive?). Re-raises any exception the block
# raised, so `expect_raises` still works when wrapped. Mirrors the helper in
# `stream_text_spec.cr` / `stream_response_spec.cr`.
private def within(timeout = 2.seconds, &block)
  done = Channel(Exception?).new(1)
  spawn do
    block.call
    done.send(nil)
  rescue ex
    done.send(ex)
  end

  select
  when err = done.receive
    raise err if err
  when timeout(timeout)
    fail("operation did not complete within #{timeout} (possible deadlock)")
  end
end

# Runs `block` with ANTHROPIC_API_KEY removed, restoring the prior value after,
# so the offline contract is proven (no key needed on fixture replay) without
# leaking ENV state to other specs.
private def without_anthropic_key(&)
  saved = ENV["ANTHROPIC_API_KEY"]?
  ENV.delete("ANTHROPIC_API_KEY")
  yield
ensure
  if saved
    ENV["ANTHROPIC_API_KEY"] = saved
  else
    ENV.delete("ANTHROPIC_API_KEY")
  end
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
        # message_start carries a small nonzero output_tokens (as real Anthropic
        # does), so the output merge is a genuine max(2, 7)==7 — not max-from-0.
        %({"type":"message_start","message":{"usage":{"input_tokens":11,"cache_read_input_tokens":2,"output_tokens":2}}}),
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

  describe "#attach_stream" do
    it "sets Accept: text/event-stream, x-api-key, and a streaming body (with key)" do
      prior_key = ENV["ANTHROPIC_API_KEY"]?
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB::Model.new("anthropic", "claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      provider = ReqLLM::Providers::Anthropic.new
      req = provider.prepare_request(:chat, model, ctx, opts)
      provider.attach_stream(req)

      req.headers["Accept"]?.should eq("text/event-stream")
      req.headers["x-api-key"]?.should eq("sk-ant-test")
      req.headers["anthropic-version"]?.should eq("2023-06-01")
      req.headers["Content-Type"]?.should eq("application/json")
      req.headers["Authorization"]?.should be_nil
      body = req.body.as(String)
      JSON.parse(body)["stream"].should eq(JSON::Any.new(true))
      body.should contain(%("stream":true))
    ensure
      if pk = prior_key
        ENV["ANTHROPIC_API_KEY"] = pk
      else
        ENV.delete("ANTHROPIC_API_KEY")
      end
    end

    it "AUTH-SKIP-ON-REPLAY: omits x-api-key but sets Accept/anthropic-version (no key)" do
      without_anthropic_key do
        ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
        model = LLMDB::Model.new("anthropic", "claude-3-5-sonnet-20241022")
        opts = ReqLLM::Options.validate(NamedTuple.new)
        provider = ReqLLM::Providers::Anthropic.new
        req = provider.prepare_request(:chat, model, ctx, opts)
        # The recorded chat_stream fixture exists, so will_replay? is true and
        # no key is resolved.
        req.fixture = "chat_stream"

        provider.attach_stream(req)
        req.headers["x-api-key"]?.should be_nil
        req.headers["Accept"]?.should eq("text/event-stream")
        req.headers["anthropic-version"]?.should eq("2023-06-01")
      end
    end
  end

  # End-to-end: ReqLLM.stream_text streams tokens offline from a recorded SSE
  # fixture with NO ANTHROPIC_API_KEY set (auth skipped on replay). Exercises the
  # real SSE parser + decode_stream_event + StreamResponse accumulator, and
  # proves the split-usage per-field merge survives end to end.
  describe "ReqLLM.stream_text (offline fixture replay)" do
    it "streams ordered content chunks from the recorded SSE fixture with NO key" do
      without_anthropic_key do
        stream = ReqLLM.stream_text(
          "anthropic:claude-3-5-sonnet-20241022", "Hi", fixture: "chat_stream")

        within do
          stream.text_stream.to_a.should eq(["Streaming ", "works."])
        end
      end
    end

    it "joins the stream into a Response (text, finish reason, split usage)" do
      without_anthropic_key do
        # Fresh stream — StreamResponse is single-consume, so join needs its own.
        stream = ReqLLM.stream_text(
          "anthropic:claude-3-5-sonnet-20241022", "Hi", fixture: "chat_stream")

        within do
          response = stream.join
          response.text.should eq("Streaming works.")
          response.finish_reason.should eq(ReqLLM::FinishReason::Stop)

          usage = response.usage.not_nil!
          usage.input_tokens.should eq(11)
          usage.output_tokens.should eq(3)
          usage.cached_tokens.should eq(2)
        end
      end
    end
  end
end
