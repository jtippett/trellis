require "../../spec_helper"

# Runs `block` in a fiber and FAILS FAST if it doesn't finish within `timeout`,
# so a deadlock regression in StreamResponse fails the spec instead of hanging
# CI forever (the consumer paths all block on Channel#receive?). Re-raises any
# exception the block raised, so `expect_raises` still works when wrapped.
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

# Builds a content chunk carrying text.
private def content(text : String) : ReqLLM::StreamChunk
  ReqLLM::StreamChunk.text(text)
end

# Builds a terminal meta chunk with finish_reason + usage.
private def meta(finish_reason : String, input : Int32, output : Int32) : ReqLLM::StreamChunk
  usage = {
    "input_tokens"  => JSON::Any.new(input.to_i64),
    "output_tokens" => JSON::Any.new(output.to_i64),
  } of String => JSON::Any
  data = {
    "finish_reason" => JSON::Any.new(finish_reason),
    "usage"         => JSON::Any.new(usage),
  } of String => JSON::Any
  ReqLLM::StreamChunk.meta(data)
end

# A StreamResponse whose producer emits a fixed list of chunks, in order.
private def fixed_stream(chunks : Array(ReqLLM::StreamChunk),
                         model : String = "test:model",
                         context : ReqLLM::Context? = nil) : ReqLLM::StreamResponse
  ReqLLM::StreamResponse.new(model, context) do |emit|
    chunks.each { |c| emit.call(c) }
  end
end

describe ReqLLM::StreamResponse do
  describe "#each" do
    it "yields all chunks in order and to_a returns them" do
      chunks = [content("Hel"), content("lo"), content("!"), meta("stop", 3, 5)]
      stream = fixed_stream(chunks)

      within do
        received = stream.to_a
        received.size.should eq(4)
        received[0].text.should eq("Hel")
        received[1].text.should eq("lo")
        received[2].text.should eq("!")
        received[3].type.should eq(ReqLLM::ChunkType::Meta)
      end
    end

    it "closes cleanly with no producer error and does not hang" do
      stream = fixed_stream([content("a")])
      within { stream.each { |_| } }
      stream.error.should be_nil
    end

    it "raises on a second consumption (single-consume contract)" do
      stream = fixed_stream([content("a")])
      within { stream.each { |_| } }

      expect_raises(ReqLLM::StreamResponse::AlreadyConsumed) do
        stream.each { |_| }
      end
    end
  end

  describe "#join" do
    it "folds chunks into a Response with concatenated text + meta" do
      chunks = [content("Hel"), content("lo"), content("!"), meta("stop", 7, 11)]
      stream = fixed_stream(chunks)

      within do
        response = stream.join
        response.text.should eq("Hello!")
        response.finish_reason.should eq(ReqLLM::FinishReason::Stop)
        response.usage.try(&.input_tokens).should eq(7)
        response.usage.try(&.output_tokens).should eq(11)
        response.model.should eq("test:model")
      end
    end

    it "threads the input context into the merged Response context" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "hi")])
      stream = fixed_stream([content("yo"), meta("stop", 1, 1)], context: ctx)

      within do
        response = stream.join
        response.context.should_not be_nil
        msgs = response.context.not_nil!.messages
        msgs.size.should eq(2)
        msgs.last.role.should eq(ReqLLM::Role::Assistant)
      end
    end
  end

  describe "#text_stream" do
    it "yields only the content text pieces, in order" do
      chunks = [content("a"), meta("stop", 1, 1), content("b"), content("c")]
      stream = fixed_stream(chunks)

      within { stream.text_stream.to_a.should eq(["a", "b", "c"]) }
    end
  end

  describe "error propagation" do
    it "re-raises a producer error to an #each consumer (no hang)" do
      stream = ReqLLM::StreamResponse.new("test:model", nil) do |emit|
        emit.call(content("partial"))
        raise "boom from producer"
      end

      seen = [] of String
      expect_raises(Exception, "boom from producer") do
        within { stream.each { |c| seen << (c.text || "") } }
      end
      # The chunk emitted before the raise still reached the consumer.
      seen.should eq(["partial"])
      stream.error.try(&.message).should eq("boom from producer")
    end

    it "re-raises a producer error through #join (no hang)" do
      stream = ReqLLM::StreamResponse.new("test:model", nil) do |emit|
        emit.call(content("x"))
        raise "join boom"
      end

      expect_raises(Exception, "join boom") do
        within { stream.join }
      end
    end

    it "re-raises a producer error through #text_stream (no hang)" do
      stream = ReqLLM::StreamResponse.new("test:model", nil) do |emit|
        emit.call(content("x"))
        raise "text boom"
      end

      expect_raises(Exception, "text boom") do
        within { stream.text_stream.to_a }
      end
    end
  end

  describe "#cancel" do
    it "lets a consumer abandon the stream without hanging the producer" do
      # Capacity 2, producer wants to emit far more than fits; without draining
      # it would block. cancel closes the channel so the producer's send raises
      # ClosedError internally and the fiber terminates cleanly.
      stream = ReqLLM::StreamResponse.new("test:model", nil, capacity: 2) do |emit|
        100.times { |i| emit.call(content(i.to_s)) }
      end

      first = nil.as(String?)
      within do
        stream.each do |chunk|
          first = chunk.text
          stream.cancel
          break
        end
      end

      first.should eq("0")
      # Cancellation is not an error.
      stream.error.should be_nil
    end
  end
end
