require "../../spec_helper"

# Wrap a recorded chunk JSON string (the `data:` payload of one Gemini
# `streamGenerateContent?alt=sse` frame) as an SSE::Event, the way the framer
# emits it.
private def event(data : String) : ReqLLM::SSE::Event
  ReqLLM::SSE::Event.new(data: data)
end

# Build a raw HTTP::Response carrying a Gemini generateContent JSON body, so the
# tool-call parity test can decode the equivalent non-streaming candidate.
private def google_response(body : String) : ReqLLM::HTTP::Response
  headers = ::HTTP::Headers.new
  headers["content-type"] = "application/json"
  ReqLLM::HTTP::Response.new(200, headers, body)
end

private def google_req
  model = LLMDB.model("google:gemini-2.0-flash")
  req = ReqLLM::HTTP::Request.new("POST",
    URI.parse("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"))
  req.model = model
  req.context = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
  req
end

# Runs `block` in a fiber and FAILS FAST if it doesn't finish within `timeout`,
# so a deadlock regression fails the spec instead of hanging CI forever (the
# consuming paths block on Channel#receive?). Re-raises any exception the block
# raised. Mirrors the helper in `anthropic_stream_spec.cr`.
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

# Runs `block` with GOOGLE_API_KEY removed, restoring the prior value after, so
# the offline contract is proven (no key needed on fixture replay) without
# leaking ENV state to other specs.
private def without_google_key(&)
  saved = ENV["GOOGLE_API_KEY"]?
  ENV.delete("GOOGLE_API_KEY")
  yield
ensure
  if saved
    ENV["GOOGLE_API_KEY"] = saved
  else
    ENV.delete("GOOGLE_API_KEY")
  end
end

describe ReqLLM::Providers::Google do
  describe "#decode_stream_event" do
    provider = ReqLLM::Providers::Google.new

    it "decodes a text part into one Content chunk" do
      data = %({"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]}}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      chunks[0].type.should eq(ReqLLM::ChunkType::Content)
      chunks[0].text.should eq("Hello")
    end

    it "decodes a thought:true text part into one Thinking chunk" do
      data = %({"candidates":[{"content":{"role":"model","parts":[{"text":"Hmm","thought":true}]}}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      chunks[0].type.should eq(ReqLLM::ChunkType::Thinking)
      chunks[0].text.should eq("Hmm")
    end

    it "decodes a finishReason STOP (no functionCall) into a raw Meta finish_reason" do
      data = %({"candidates":[{"content":{"role":"model","parts":[{"text":"Done"}]},"finishReason":"STOP"}]})
      chunks = provider.decode_stream_event(event(data))

      # text chunk + meta finish_reason
      chunks.size.should eq(2)
      chunks[0].type.should eq(ReqLLM::ChunkType::Content)
      chunks[1].type.should eq(ReqLLM::ChunkType::Meta)
      # Raw wire token (NOT upgraded per-frame); the accumulator upgrades it.
      chunks[1].metadata["finish_reason"].as_s.should eq("STOP")
    end

    it "decodes a functionCall part into one ToolCall chunk with index/id metadata" do
      data = %({"candidates":[{"content":{"role":"model","parts":) +
             %([{"functionCall":{"id":"fc_1","name":"get_weather","args":{"location":"Paris"}}}]}}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      c = chunks[0]
      c.type.should eq(ReqLLM::ChunkType::ToolCall)
      c.name.should eq("get_weather")
      c.metadata["index"].as_i.should eq(0)
      c.metadata["id"].as_s.should eq("fc_1")
      c.arguments.not_nil!["location"].as_s.should eq("Paris")
    end

    it "generates a tool-call id when functionCall has none" do
      data = %({"candidates":[{"content":{"role":"model","parts":) +
             %([{"functionCall":{"name":"f","args":{}}}]}}]})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      chunks[0].metadata["id"].as_s.should_not be_empty
    end

    it "decodes a usageMetadata frame into a normalized Meta usage chunk" do
      data = %({"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":7,) +
             %("thoughtsTokenCount":2,"cachedContentTokenCount":3}})
      chunks = provider.decode_stream_event(event(data))

      chunks.size.should eq(1)
      c = chunks[0]
      c.type.should eq(ReqLLM::ChunkType::Meta)
      usage = c.metadata["usage"]
      usage["input_tokens"].as_i.should eq(10)
      # output = candidatesTokenCount + reasoning = 7 + 2
      usage["output_tokens"].as_i.should eq(9)
      usage["reasoning_tokens"].as_i.should eq(2)
      usage["cached_tokens"].as_i.should eq(3)
    end

    it "returns an empty array for blank / {} / unrelated frames" do
      provider.decode_stream_event(event("")).should be_empty
      provider.decode_stream_event(event("{}")).should be_empty
      provider.decode_stream_event(event(%({"candidates":[]}))).should be_empty
      provider.decode_stream_event(event(%({"foo":"bar"}))).should be_empty
    end

    it "accepts the raw String overload directly" do
      chunks = provider.decode_stream_event(
        %({"candidates":[{"content":{"role":"model","parts":[{"text":"x"}]}}]}))
      chunks.size.should eq(1)
      chunks[0].text.should eq("x")
    end
  end

  describe "#decode_stream_event integration (folded through ChunkAccumulator)" do
    provider = ReqLLM::Providers::Google.new

    it "folds a co-located functionCall + STOP + usage into ONE ToolCall finishing as ToolCalls" do
      frames = [
        %({"candidates":[{"content":{"role":"model","parts":[{"functionCall":) +
        %({"id":"fc_1","name":"get_weather","args":{"location":"Paris"}}}]},) +
        %("finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":4,"totalTokenCount":16}}),
      ]

      acc = ReqLLM::ChunkAccumulator.new
      frames.each do |data|
        provider.decode_stream_event(event(data)).each { |chunk| acc << chunk }
      end

      resp = acc.finish("google:gemini-2.0-flash")
      calls = resp.tool_calls
      calls.size.should eq(1)
      calls[0].name.should eq("get_weather")
      calls[0].args_map["location"].as_s.should eq("Paris")
      # Wire was "STOP" but tool calls were accumulated -> upgraded.
      resp.finish_reason.should eq(ReqLLM::FinishReason::ToolCalls)
      resp.usage.not_nil!.input_tokens.should eq(12)
    end

    it "folds SEPARATED functionCall and STOP frames into ONE ToolCall finishing as ToolCalls (frame-order-independent)" do
      frames = [
        # Frame A: the functionCall part, NO finishReason.
        %({"candidates":[{"content":{"role":"model","parts":[{"functionCall":) +
        %({"id":"fc_1","name":"get_weather","args":{"location":"Paris"}}}]}}]}),
        # Frame B: finishReason only, NO parts.
        %({"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":4,"totalTokenCount":16}}),
      ]

      acc = ReqLLM::ChunkAccumulator.new
      frames.each do |data|
        provider.decode_stream_event(event(data)).each { |chunk| acc << chunk }
      end

      resp = acc.finish("google:gemini-2.0-flash")
      resp.tool_calls.size.should eq(1)
      resp.tool_calls[0].args_map["location"].as_s.should eq("Paris")
      # The upgrade fires even though STOP arrived in a SEPARATE frame.
      resp.finish_reason.should eq(ReqLLM::FinishReason::ToolCalls)
    end

    it "folds TWO functionCall parts in ONE frame into TWO distinct ToolCalls" do
      data = %({"candidates":[{"content":{"role":"model","parts":[) +
             %({"functionCall":{"id":"fc_1","name":"get_weather","args":{"location":"Paris"}}},) +
             %({"functionCall":{"id":"fc_2","name":"get_time","args":{"zone":"CET"}}}) +
             %(]},"finishReason":"STOP"}]})

      acc = ReqLLM::ChunkAccumulator.new
      provider.decode_stream_event(event(data)).each { |chunk| acc << chunk }

      calls = acc.finish("google:gemini-2.0-flash").tool_calls
      calls.size.should eq(2)
      calls.map(&.name).should eq(["get_weather", "get_time"])
      calls[0].args_map["location"].as_s.should eq("Paris")
      calls[1].args_map["zone"].as_s.should eq("CET")
    end

    it "folds a text stream + final STOP/usage frame into text, finish Stop, usage" do
      frames = [
        %({"candidates":[{"content":{"role":"model","parts":[{"text":"Streaming "}]}}]}),
        %({"candidates":[{"content":{"role":"model","parts":[{"text":"works."}]},"finishReason":"STOP"}],) +
        %("usageMetadata":{"promptTokenCount":11,"candidatesTokenCount":3,"totalTokenCount":14}}),
      ]

      acc = ReqLLM::ChunkAccumulator.new
      frames.each do |data|
        provider.decode_stream_event(event(data)).each { |chunk| acc << chunk }
      end

      resp = acc.finish("google:gemini-2.0-flash")
      resp.text.should eq("Streaming works.")
      resp.finish_reason.should eq(ReqLLM::FinishReason::Stop)
      resp.usage.not_nil!.input_tokens.should eq(11)
      resp.usage.not_nil!.output_tokens.should eq(3)
    end
  end

  # TOOL-CALL PARITY: a folded Gemini tool-call STREAM must produce the same
  # message / tool_calls / finish_reason as the non-streaming `decode_response`
  # of the equivalent candidate (`stream.join == decode`).
  describe "#decode_stream_event tool-call parity with #decode_response" do
    it "yields identical tool_calls + finish_reason + message shape" do
      provider = ReqLLM::Providers::Google.new

      # Equivalent single-candidate non-streaming body.
      body = {
        "candidates" => [{
          "content" => {"role" => "model", "parts" => [
            {"functionCall" => {"id" => "fc_1", "name" => "get_weather", "args" => {"location" => "Paris"}}},
          ]},
          "finishReason" => "STOP",
        }],
        "usageMetadata" => {"promptTokenCount" => 12, "candidatesTokenCount" => 4, "totalTokenCount" => 16},
      }.to_json
      _, decoded_resp = provider.decode_response(google_req, google_response(body))
      decoded = decoded_resp.decoded.not_nil!

      # Equivalent streamed frame, folded.
      frame = %({"candidates":[{"content":{"role":"model","parts":[{"functionCall":) +
              %({"id":"fc_1","name":"get_weather","args":{"location":"Paris"}}}]},) +
              %("finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":4,"totalTokenCount":16}})
      acc = ReqLLM::ChunkAccumulator.new
      provider.decode_stream_event(event(frame)).each { |chunk| acc << chunk }
      streamed = acc.finish("gemini-2.0-flash")

      # finish_reason parity.
      streamed.finish_reason.should eq(decoded.finish_reason)
      streamed.finish_reason.should eq(ReqLLM::FinishReason::ToolCalls)

      # tool_calls parity (name + decoded args).
      streamed.tool_calls.size.should eq(decoded.tool_calls.size)
      streamed.tool_calls[0].name.should eq(decoded.tool_calls[0].name)
      streamed.tool_calls[0].args_map["location"].as_s.should eq(
        decoded.tool_calls[0].args_map["location"].as_s)

      # message part shape parity (one empty text part, no thinking).
      streamed.message.not_nil!.content.map(&.type).should eq(
        decoded.message.not_nil!.content.map(&.type))
      streamed.text.should eq(decoded.text)
    end
  end

  describe "#attach_stream" do
    it "rewrites the URL to :streamGenerateContent?alt=sse, sets Accept + x-goog-api-key, and a body with NO stream flag (with key)" do
      prior_key = ENV["GOOGLE_API_KEY"]?
      ENV["GOOGLE_API_KEY"] = "test-google-key"
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB::Model.new("google", "gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      provider = ReqLLM::Providers::Google.new
      req = provider.prepare_request(:chat, model, ctx, opts)
      provider.attach_stream(req)

      req.url.path.ends_with?(":streamGenerateContent").should be_true
      req.url.query.should eq("alt=sse")
      req.url.request_target.should contain("?alt=sse")
      req.headers["Accept"]?.should eq("text/event-stream")
      req.headers["x-goog-api-key"]?.should eq("test-google-key")
      req.headers["Content-Type"]?.should eq("application/json")
      req.headers["Authorization"]?.should be_nil

      body = JSON.parse(req.body.as(String))
      body.as_h.has_key?("stream").should be_false
    ensure
      if pk = prior_key
        ENV["GOOGLE_API_KEY"] = pk
      else
        ENV.delete("GOOGLE_API_KEY")
      end
    end

    it "AUTH-SKIP-ON-REPLAY: omits x-goog-api-key but rewrites URL + sets Accept (no key)" do
      without_google_key do
        ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
        model = LLMDB::Model.new("google", "gemini-2.0-flash")
        opts = ReqLLM::Options.validate(NamedTuple.new)
        provider = ReqLLM::Providers::Google.new
        req = provider.prepare_request(:chat, model, ctx, opts)
        # The recorded chat_stream fixture exists, so will_replay? is true and no
        # key is resolved.
        req.fixture = "chat_stream"

        provider.attach_stream(req)
        req.headers["x-goog-api-key"]?.should be_nil
        req.headers["Accept"]?.should eq("text/event-stream")
        req.url.path.ends_with?(":streamGenerateContent").should be_true
        req.url.query.should eq("alt=sse")
      end
    end
  end

  # End-to-end: ReqLLM.stream_text streams tokens offline from a recorded SSE
  # fixture with NO GOOGLE_API_KEY set (auth skipped on replay). Exercises the
  # real SSE parser + decode_stream_event + StreamResponse accumulator.
  describe "ReqLLM.stream_text (offline fixture replay)" do
    it "streams ordered content chunks from the recorded SSE fixture with NO key" do
      without_google_key do
        stream = ReqLLM.stream_text(
          "google:gemini-2.0-flash", "Hi", fixture: "chat_stream")

        within do
          stream.text_stream.to_a.should eq(["Streaming ", "works."])
        end
      end
    end

    it "joins the stream into a Response (text, finish reason, usage)" do
      without_google_key do
        # Fresh stream — StreamResponse is single-consume, so join needs its own.
        stream = ReqLLM.stream_text(
          "google:gemini-2.0-flash", "Hi", fixture: "chat_stream")

        within do
          response = stream.join
          response.text.should eq("Streaming works.")
          response.finish_reason.should eq(ReqLLM::FinishReason::Stop)

          usage = response.usage.not_nil!
          usage.input_tokens.should eq(11)
          usage.output_tokens.should eq(3)
        end
      end
    end
  end
end
