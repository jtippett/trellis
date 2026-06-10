require "../spec_helper"

# Runs `block` in a fiber and FAILS FAST if it doesn't finish within `timeout`,
# so a deadlock regression fails the spec instead of hanging CI forever (the
# consuming paths block on Channel#receive?). Re-raises any exception the block
# raised, so `expect_raises` still works when wrapped.
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

# Runs `block` with OPENAI_API_KEY removed, restoring the prior value after, so
# the offline contract is proven (no key needed on fixture replay) without
# leaking ENV state to other specs.
private def without_openai_key(&)
  saved = ENV["OPENAI_API_KEY"]?
  ENV.delete("OPENAI_API_KEY")
  yield
ensure
  if saved
    ENV["OPENAI_API_KEY"] = saved
  else
    ENV.delete("OPENAI_API_KEY")
  end
end

# DoD: ReqLLM.stream_text streams tokens end-to-end through OpenAI, fully
# offline from a recorded SSE fixture, with NO OPENAI_API_KEY set (auth is
# skipped on fixture replay). Exercises the real SSE parser + decode_stream_event
# + StreamResponse accumulator.
describe "ReqLLM.stream_text" do
  it "streams ordered content chunks from a recorded SSE fixture with NO API key" do
    without_openai_key do
      stream = ReqLLM.stream_text("openai:gpt-4o-mini", "Hi", fixture: "chat_stream")

      within do
        stream.text_stream.to_a.should eq(["Hello", ", ", "world!"])
      end
    end
  end

  it "joins the stream into a Response (text, finish reason, usage + cost)" do
    without_openai_key do
      # Fresh stream — StreamResponse is single-consume, so join needs its own.
      stream = ReqLLM.stream_text("openai:gpt-4o-mini", "Hi", fixture: "chat_stream")

      within do
        response = stream.join
        response.text.should eq("Hello, world!")
        response.finish_reason.should eq(ReqLLM::FinishReason::Stop)

        usage = response.usage.not_nil!
        usage.input_tokens.should eq(9)
        usage.output_tokens.should eq(3)
        # Cost threaded from gpt-4o-mini pricing (0.15 in / 0.60 out per 1M):
        # 9 * 0.15e-6 + 3 * 0.60e-6 = 3.15e-6.
        usage.cost.not_nil!.should be_close(3.15e-6, 1e-12)

        response.model.should eq("openai:gpt-4o-mini")
      end
    end
  end

  it "threads the input prompt into the merged Response context" do
    without_openai_key do
      stream = ReqLLM.stream_text("openai:gpt-4o-mini", "Hi", fixture: "chat_stream")

      within do
        ctx = stream.join.context.not_nil!
        ctx.messages.size.should eq(2)
        ctx.messages.first.role.should eq(ReqLLM::Role::User)
        ctx.messages.first.content.first.text.should eq("Hi")
        ctx.messages.last.role.should eq(ReqLLM::Role::Assistant)
        ctx.messages.last.content.first.text.should eq("Hello, world!")
      end
    end
  end
end
