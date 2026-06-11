require "../../spec_helper"

# Build a raw HTTP::Response carrying a Gemini generateContent JSON body, so
# decode tests can exercise arbitrary candidate/usage shapes without a fixture.
private def google_response(body : String) : Trellis::HTTP::Response
  headers = ::HTTP::Headers.new
  headers["content-type"] = "application/json"
  Trellis::HTTP::Response.new(200, headers, body)
end

private def google_req
  model = LLMDB.model("google:gemini-2.0-flash")
  req = Trellis::HTTP::Request.new("POST",
    URI.parse("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"))
  req.model = model
  req.context = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
  req
end

describe Trellis::Providers::Google do
  describe "#decode_response" do
    it "decodes a basic generateContent response into text, finish_reason, and usage" do
      provider = Trellis::Providers::Google.new
      resp = Trellis::Fixture.load_response("spec/fixtures/google/chat_basic.json")
      _, resp = provider.decode_response(google_req, resp)

      decoded = resp.decoded.not_nil!
      decoded.text.should eq("Hello! How can I help?")
      decoded.finish_reason.should eq(Trellis::FinishReason::Stop)
      decoded.message.not_nil!.role.should eq(Trellis::Role::Assistant)

      usage = decoded.usage.not_nil!
      usage.input_tokens.should eq(10)
      usage.output_tokens.should eq(7)
    end

    it "merges the assistant reply into the returned context" do
      provider = Trellis::Providers::Google.new
      resp = Trellis::Fixture.load_response("spec/fixtures/google/chat_basic.json")
      _, resp = provider.decode_response(google_req, resp)

      ctx = resp.decoded.not_nil!.context.not_nil!
      ctx.messages.size.should eq(2)
      ctx.messages.first.role.should eq(Trellis::Role::User)
      ctx.messages.last.role.should eq(Trellis::Role::Assistant)
      ctx.messages.last.content.first.text.should eq("Hello! How can I help?")
    end

    it "uses modelVersion for the response model when present" do
      provider = Trellis::Providers::Google.new
      resp = Trellis::Fixture.load_response("spec/fixtures/google/chat_basic.json")
      _, resp = provider.decode_response(google_req, resp)
      resp.decoded.not_nil!.model.should eq("gemini-2.0-flash")
    end

    it "decodes functionCall parts into tool_calls and overrides STOP to ToolCalls" do
      provider = Trellis::Providers::Google.new
      resp = Trellis::Fixture.load_response("spec/fixtures/google/chat_tools.json")
      _, resp = provider.decode_response(google_req, resp)

      decoded = resp.decoded.not_nil!
      # Wire finishReason is "STOP" but functionCall parts force ToolCalls.
      decoded.finish_reason.should eq(Trellis::FinishReason::ToolCalls)

      calls = decoded.tool_calls
      calls.size.should eq(1)
      call = calls.first
      call.name.should eq("get_weather")
      call.args_map["location"].should eq(JSON::Any.new("Paris"))
    end

    it "keeps Length (does NOT upgrade) for a truncated tool call (MAX_TOKENS + functionCall)" do
      provider = Trellis::Providers::Google.new
      # functionCall present BUT finishReason is MAX_TOKENS: the args may be
      # incomplete, so the truncation signal must survive (only STOP upgrades).
      body = {
        "candidates" => [{
          "content" => {"role" => "model", "parts" => [
            {"functionCall" => {"name" => "get_weather", "args" => {"loc" => "Par"}}},
          ]},
          "finishReason" => "MAX_TOKENS",
        }],
      }.to_json
      _, resp = provider.decode_response(google_req, google_response(body))

      decoded = resp.decoded.not_nil!
      decoded.finish_reason.should eq(Trellis::FinishReason::Length)
      decoded.tool_calls.size.should eq(1)
    end

    it "uses functionCall id when present, else generates one" do
      provider = Trellis::Providers::Google.new
      body = {
        "candidates" => [{
          "content" => {"role" => "model", "parts" => [
            {"functionCall" => {"id" => "fc_123", "name" => "f", "args" => {} of String => JSON::Any}},
          ]},
        }],
      }.to_json
      _, resp = provider.decode_response(google_req, google_response(body))
      resp.decoded.not_nil!.tool_calls.first.id.should eq("fc_123")

      body2 = {
        "candidates" => [{
          "content" => {"role" => "model", "parts" => [
            {"functionCall" => {"name" => "f", "args" => {} of String => JSON::Any}},
          ]},
        }],
      }.to_json
      _, resp2 = provider.decode_response(google_req, google_response(body2))
      resp2.decoded.not_nil!.tool_calls.first.id.should_not be_empty
    end
  end

  describe "#decode_response usage normalization" do
    it "maps thoughtsTokenCount to reasoning and adds it to candidates for output" do
      provider = Trellis::Providers::Google.new
      body = {
        "candidates"    => [{"content" => {"role" => "model", "parts" => [{"text" => "ok"}]}, "finishReason" => "STOP"}],
        "usageMetadata" => {
          "promptTokenCount"     => 10,
          "candidatesTokenCount" => 7,
          "thoughtsTokenCount"   => 4,
          "totalTokenCount"      => 21,
        },
      }.to_json
      _, resp = provider.decode_response(google_req, google_response(body))
      usage = resp.decoded.not_nil!.usage.not_nil!
      usage.input_tokens.should eq(10)
      usage.reasoning_tokens.should eq(4)
      # output = candidatesTokenCount + reasoning
      usage.output_tokens.should eq(11)
    end

    it "maps cachedContentTokenCount to cached_tokens" do
      provider = Trellis::Providers::Google.new
      body = {
        "candidates"    => [{"content" => {"role" => "model", "parts" => [{"text" => "ok"}]}, "finishReason" => "STOP"}],
        "usageMetadata" => {
          "promptTokenCount"        => 10,
          "candidatesTokenCount"    => 7,
          "cachedContentTokenCount" => 6,
        },
      }.to_json
      _, resp = provider.decode_response(google_req, google_response(body))
      resp.decoded.not_nil!.usage.not_nil!.cached_tokens.should eq(6)
    end

    it "uses the total fallback for output when candidatesTokenCount is absent" do
      provider = Trellis::Providers::Google.new
      body = {
        "candidates"    => [{"content" => {"role" => "model", "parts" => [{"text" => "ok"}]}, "finishReason" => "STOP"}],
        "usageMetadata" => {
          "promptTokenCount" => 10,
          "totalTokenCount"  => 25,
        },
      }.to_json
      _, resp = provider.decode_response(google_req, google_response(body))
      usage = resp.decoded.not_nil!.usage.not_nil!
      usage.input_tokens.should eq(10)
      # output = max(0, total - input) = 15
      usage.output_tokens.should eq(15)
    end

    it "falls back to summing promptTokensDetails when promptTokenCount is absent" do
      provider = Trellis::Providers::Google.new
      body = {
        "candidates"    => [{"content" => {"role" => "model", "parts" => [{"text" => "ok"}]}, "finishReason" => "STOP"}],
        "usageMetadata" => {
          "promptTokensDetails"  => [{"tokenCount" => 4}, {"tokenCount" => 6}],
          "candidatesTokenCount" => 3,
        },
      }.to_json
      _, resp = provider.decode_response(google_req, google_response(body))
      usage = resp.decoded.not_nil!.usage.not_nil!
      usage.input_tokens.should eq(10)
      usage.output_tokens.should eq(3)
    end

    it "defaults to a zeroed Usage when usageMetadata is absent" do
      provider = Trellis::Providers::Google.new
      body = {
        "candidates" => [{"content" => {"role" => "model", "parts" => [{"text" => "ok"}]}, "finishReason" => "STOP"}],
      }.to_json
      _, resp = provider.decode_response(google_req, google_response(body))
      usage = resp.decoded.not_nil!.usage.not_nil!
      usage.input_tokens.should eq(0)
      usage.output_tokens.should eq(0)
    end
  end

  # PARITY with ChunkAccumulator#finish: decode_response must produce the SAME
  # message shape a folded stream of equivalent content does — EXACTLY one
  # concatenated text part (even ""), then ONE concatenated thinking part only
  # when thinking is non-empty, then tool_calls.
  describe "#decode_response stream parity" do
    it "produces one text part then one thinking part (matching accumulator finish)" do
      provider = Trellis::Providers::Google.new
      body = {
        "candidates" => [{
          "content" => {"role" => "model", "parts" => [
            {"text" => "Let me think. ", "thought" => true},
            {"text" => "Still thinking.", "thought" => true},
            {"text" => "Answer."},
          ]},
          "finishReason" => "STOP",
        }],
      }.to_json
      _, resp = provider.decode_response(google_req, google_response(body))
      parts = resp.decoded.not_nil!.message.not_nil!.content

      parts.size.should eq(2)
      parts[0].type.should eq(Trellis::PartType::Text)
      parts[0].text.should eq("Answer.")
      parts[1].type.should eq(Trellis::PartType::Thinking)
      parts[1].text.should eq("Let me think. Still thinking.")

      # Equivalent folded stream → same [Text, Thinking] shape.
      acc = Trellis::ChunkAccumulator.new
      acc << Trellis::StreamChunk.thinking("Let me think. ")
      acc << Trellis::StreamChunk.thinking("Still thinking.")
      acc << Trellis::StreamChunk.text("Answer.")
      acc_parts = acc.finish("gemini-2.0-flash").message.not_nil!.content
      parts.map(&.type).should eq(acc_parts.map(&.type))
    end

    it "produces a single empty text part when candidates/content are absent" do
      provider = Trellis::Providers::Google.new
      body = {"usageMetadata" => {"promptTokenCount" => 1, "totalTokenCount" => 1}}.to_json
      _, resp = provider.decode_response(google_req, google_response(body))
      parts = resp.decoded.not_nil!.message.not_nil!.content

      parts.size.should eq(1)
      parts[0].type.should eq(Trellis::PartType::Text)
      parts[0].text.should eq("")
    end
  end
end

# End-to-end offline: GU1 (auth/skeleton) + GU2 (encode) + GU3 (decode) compose
# through the real pipeline + cost step, with NO key in ENV (auth skipped on
# replay).
describe "Trellis.generate_text (google, offline fixture)" do
  it "returns a costed Response from a recorded fixture with no API key set" do
    saved = ENV["GOOGLE_API_KEY"]?
    ENV.delete("GOOGLE_API_KEY")

    resp = Trellis.generate_text("google:gemini-2.0-flash", "Hi", fixture: "chat_basic")

    resp.should be_a(Trellis::Response)
    resp.text.should eq("Hello! How can I help?")
    resp.finish_reason.should eq(Trellis::FinishReason::Stop)

    usage = resp.usage.not_nil!
    usage.input_tokens.should eq(10)
    usage.output_tokens.should eq(7)
    usage.cost.should_not be_nil
  ensure
    if saved
      ENV["GOOGLE_API_KEY"] = saved
    else
      ENV.delete("GOOGLE_API_KEY")
    end
  end
end
