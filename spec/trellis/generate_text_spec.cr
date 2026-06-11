require "../spec_helper"

# Unit O DoD: Trellis.generate_text working end-to-end, OpenAI, fixture-backed,
# fully offline, and — critically — with NO OPENAI_API_KEY set (auth is skipped
# on fixture replay, so no key is ever needed for a recorded run).
describe "Trellis.generate_text" do
  it "returns text from a recorded fixture with NO API key set (auth-skip-on-replay)" do
    saved = ENV["OPENAI_API_KEY"]?
    ENV.delete("OPENAI_API_KEY")

    resp = Trellis.generate_text("openai:gpt-4o-mini", "Hi", fixture: "chat_basic")

    resp.should be_a(Trellis::Response)
    resp.text.should_not be_empty
    resp.finish_reason.should eq(Trellis::FinishReason::Stop)

    usage = resp.usage.not_nil!
    usage.input_tokens.should eq(11)
    usage.output_tokens.should eq(7)

    # Per-token cost is now wired through Steps.usage via provider.extract_usage
    # and LLMDB::Model pricing (gpt-4o-mini: 0.15 in / 0.60 out per 1M tokens).
    usage.cost.not_nil!.should be_close(5.85e-6, 1e-12)
  ensure
    if saved
      ENV["OPENAI_API_KEY"] = saved
    else
      ENV.delete("OPENAI_API_KEY")
    end
  end

  it "merges the assistant reply into the returned context (multi-turn parity)" do
    saved = ENV["OPENAI_API_KEY"]?
    ENV.delete("OPENAI_API_KEY")

    resp = Trellis.generate_text("openai:gpt-4o-mini", "Hi", fixture: "chat_basic")

    ctx = resp.context.not_nil!
    ctx.messages.size.should eq(2)
    ctx.messages.first.role.should eq(Trellis::Role::User)
    ctx.messages.first.content.first.text.should eq("Hi")
    ctx.messages.last.role.should eq(Trellis::Role::Assistant)
    ctx.messages.last.content.first.text.should eq(resp.text)
  ensure
    if saved
      ENV["OPENAI_API_KEY"] = saved
    else
      ENV.delete("OPENAI_API_KEY")
    end
  end

  it "is fully offline — the fixture short-circuits transport (deterministic result)" do
    saved = ENV["OPENAI_API_KEY"]?
    ENV.delete("OPENAI_API_KEY")

    # The request URL points at api.openai.com, which we never hit: the fixture
    # replay step returns the recorded response before transport runs. Two calls
    # yielding identical deterministic content prove the result came from disk.
    first = Trellis.generate_text("openai:gpt-4o-mini", "Hi", fixture: "chat_basic")
    second = Trellis.generate_text("openai:gpt-4o-mini", "Hi", fixture: "chat_basic")

    first.text.should eq(second.text)
    first.text.should eq("Hello! How can I help?")
  ensure
    if saved
      ENV["OPENAI_API_KEY"] = saved
    else
      ENV.delete("OPENAI_API_KEY")
    end
  end
end
