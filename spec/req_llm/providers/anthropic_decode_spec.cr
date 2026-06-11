require "../../spec_helper"

# Build a raw HTTP::Response carrying an Anthropic Messages-API JSON body, so
# decode tests can exercise arbitrary content shapes without a fixture file.
private def anthropic_response(body : String) : ReqLLM::HTTP::Response
  headers = ::HTTP::Headers.new
  headers["content-type"] = "application/json"
  ReqLLM::HTTP::Response.new(200, headers, body)
end

private def anthropic_req
  model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
  req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://api.anthropic.com/v1/messages"))
  req.model = model
  req.context = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
  req
end

describe ReqLLM::Providers::Anthropic do
  describe "#decode_response" do
    it "decodes a basic Messages response into text, finish_reason, and usage" do
      provider = ReqLLM::Providers::Anthropic.new
      resp = ReqLLM::Fixture.load_response("spec/fixtures/anthropic/chat_basic.json")
      _, resp = provider.decode_response(anthropic_req, resp)

      decoded = resp.decoded.not_nil!
      decoded.text.should eq("Hello! How can I help?")
      decoded.finish_reason.should eq(ReqLLM::FinishReason::Stop)
      decoded.message.not_nil!.role.should eq(ReqLLM::Role::Assistant)

      usage = decoded.usage.not_nil!
      usage.input_tokens.should eq(10)
      usage.output_tokens.should eq(7)
    end

    it "merges the assistant reply into the returned context" do
      provider = ReqLLM::Providers::Anthropic.new
      resp = ReqLLM::Fixture.load_response("spec/fixtures/anthropic/chat_basic.json")
      _, resp = provider.decode_response(anthropic_req, resp)

      ctx = resp.decoded.not_nil!.context.not_nil!
      ctx.messages.size.should eq(2)
      ctx.messages.first.role.should eq(ReqLLM::Role::User)
      ctx.messages.last.role.should eq(ReqLLM::Role::Assistant)
      ctx.messages.last.content.first.text.should eq("Hello! How can I help?")
    end

    it "decodes tool_use blocks into Response#tool_calls with ToolCalls finish" do
      provider = ReqLLM::Providers::Anthropic.new
      resp = ReqLLM::Fixture.load_response("spec/fixtures/anthropic/chat_tools.json")
      _, resp = provider.decode_response(anthropic_req, resp)

      decoded = resp.decoded.not_nil!
      decoded.finish_reason.should eq(ReqLLM::FinishReason::ToolCalls)

      calls = decoded.tool_calls
      calls.size.should eq(1)
      call = calls.first
      call.id.should eq("toolu_1")
      call.name.should eq("get_weather")
      call.args_map["location"].should eq(JSON::Any.new("Paris"))
    end

    it "maps cache_read_input_tokens to cached_tokens and reasoning_output_tokens to reasoning_tokens" do
      provider = ReqLLM::Providers::Anthropic.new
      body = {
        "model"       => "claude-3-5-sonnet-20241022",
        "content"     => [{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage"       => {
          "input_tokens"            => 10,
          "output_tokens"           => 7,
          "cache_read_input_tokens" => 4,
          "reasoning_output_tokens" => 3,
        },
      }.to_json
      _, resp = provider.decode_response(anthropic_req, anthropic_response(body))

      usage = resp.decoded.not_nil!.usage.not_nil!
      usage.input_tokens.should eq(10)
      usage.output_tokens.should eq(7)
      usage.cached_tokens.should eq(4)
      usage.reasoning_tokens.should eq(3)
    end

    it "defaults to a zeroed Usage when the response carries no usage" do
      provider = ReqLLM::Providers::Anthropic.new
      body = {
        "model"       => "claude-3-5-sonnet-20241022",
        "content"     => [{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
      }.to_json
      _, resp = provider.decode_response(anthropic_req, anthropic_response(body))

      usage = resp.decoded.not_nil!.usage.not_nil!
      usage.input_tokens.should eq(0)
      usage.output_tokens.should eq(0)
    end
  end

  # PARITY with ChunkAccumulator#finish: decode_response must produce the SAME
  # message shape a folded stream of the equivalent content does — EXACTLY one
  # concatenated text part (even ""), then ONE concatenated thinking part only
  # when thinking is non-empty, then tool_calls. This guarantees
  # `stream.join == decode` for equivalent content.
  describe "#decode_response stream parity" do
    it "produces exactly one text part for a text-only response (matching accumulator finish)" do
      provider = ReqLLM::Providers::Anthropic.new
      body = {
        "model"       => "claude-3-5-sonnet-20241022",
        "content"     => [{"type" => "text", "text" => "Hello world"}],
        "stop_reason" => "end_turn",
      }.to_json
      _, resp = provider.decode_response(anthropic_req, anthropic_response(body))
      parts = resp.decoded.not_nil!.message.not_nil!.content

      # Accumulator finish shape for the equivalent single text chunk.
      acc = ReqLLM::ChunkAccumulator.new
      acc << ReqLLM::StreamChunk.text("Hello world")
      acc_parts = acc.finish("claude-3-5-sonnet-20241022").message.not_nil!.content

      parts.size.should eq(1)
      parts[0].type.should eq(ReqLLM::PartType::Text)
      parts[0].text.should eq("Hello world")
      parts.map(&.type).should eq(acc_parts.map(&.type))
    end

    it "produces one text part then one thinking part (matching accumulator finish)" do
      provider = ReqLLM::Providers::Anthropic.new
      body = {
        "model"   => "claude-3-5-sonnet-20241022",
        "content" => [
          {"type" => "thinking", "thinking" => "Let me think. "},
          {"type" => "thinking", "thinking" => "Still thinking."},
          {"type" => "text", "text" => "Answer."},
        ],
        "stop_reason" => "end_turn",
      }.to_json
      _, resp = provider.decode_response(anthropic_req, anthropic_response(body))
      parts = resp.decoded.not_nil!.message.not_nil!.content

      parts.size.should eq(2)
      parts[0].type.should eq(ReqLLM::PartType::Text)
      parts[0].text.should eq("Answer.")
      parts[1].type.should eq(ReqLLM::PartType::Thinking)
      # Thinking blocks are concatenated into ONE part (accumulator parity).
      parts[1].text.should eq("Let me think. Still thinking.")

      # Equivalent folded stream: thinking deltas then text → same [Text, Thinking].
      acc = ReqLLM::ChunkAccumulator.new
      acc << ReqLLM::StreamChunk.thinking("Let me think. ")
      acc << ReqLLM::StreamChunk.thinking("Still thinking.")
      acc << ReqLLM::StreamChunk.text("Answer.")
      acc_parts = acc.finish("claude-3-5-sonnet-20241022").message.not_nil!.content
      parts.map(&.type).should eq(acc_parts.map(&.type))
    end

    it "produces a single empty text part when content is empty (matching accumulator finish)" do
      provider = ReqLLM::Providers::Anthropic.new
      body = {
        "model"       => "claude-3-5-sonnet-20241022",
        "content"     => [] of String,
        "stop_reason" => "end_turn",
      }.to_json
      _, resp = provider.decode_response(anthropic_req, anthropic_response(body))
      parts = resp.decoded.not_nil!.message.not_nil!.content

      parts.size.should eq(1)
      parts[0].type.should eq(ReqLLM::PartType::Text)
      parts[0].text.should eq("")
    end
  end
end

# End-to-end offline: AU1 (auth/skeleton) + AU2 (encode) + AU3 (decode) compose
# through the real pipeline + cost step, with NO key in ENV (auth skipped on
# replay).
describe "ReqLLM.generate_text (anthropic, offline fixture)" do
  it "returns a costed Response from a recorded fixture with no API key set" do
    saved = ENV["ANTHROPIC_API_KEY"]?
    ENV.delete("ANTHROPIC_API_KEY")

    resp = ReqLLM.generate_text("anthropic:claude-3-5-sonnet-20241022", "Hi", fixture: "chat_basic")

    resp.should be_a(ReqLLM::Response)
    resp.text.should eq("Hello! How can I help?")
    resp.finish_reason.should eq(ReqLLM::FinishReason::Stop)

    usage = resp.usage.not_nil!
    usage.input_tokens.should eq(10)
    usage.output_tokens.should eq(7)
    # Cost is wired through Steps.usage with the priced catalog model.
    usage.cost.should_not be_nil
  ensure
    if saved
      ENV["ANTHROPIC_API_KEY"] = saved
    else
      ENV.delete("ANTHROPIC_API_KEY")
    end
  end
end
