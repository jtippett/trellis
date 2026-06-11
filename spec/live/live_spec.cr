require "../spec_helper"

# Live examples hit real paid APIs. They run ONLY when explicitly opted in via
# TRELLIS_LIVE=1 AND the provider key is present; otherwise pending! (so a normal
# `crystal spec` — even with keys exported — never makes a network call).
private def live?(key : String) : Bool
  ENV["TRELLIS_LIVE"]? == "1" && !(ENV[key]?.nil? || ENV[key]?.try(&.empty?))
end

# A minimal JSON Schema object with one required string property `name`. This is
# the exact type `generate_object` requires (generation.cr:118).
private def person_schema : Hash(String, JSON::Any)
  {
    "type"       => JSON::Any.new("object"),
    "properties" => JSON::Any.new({
      "name" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
    } of String => JSON::Any),
    "required" => JSON::Any.new([JSON::Any.new("name")]),
  } of String => JSON::Any
end

describe "live integration", tags: "live" do
  # ---- OpenAI ----
  it "OpenAI generate_text" do
    pending!("set TRELLIS_LIVE=1 + OPENAI_API_KEY") unless live?("OPENAI_API_KEY")
    resp = Trellis.generate_text("openai:gpt-4o-mini", "Reply with exactly: OK")
    resp.text.should_not be_empty
    resp.usage.try(&.input_tokens).should_not be_nil
  end

  it "OpenAI stream_text" do
    pending!("set TRELLIS_LIVE=1 + OPENAI_API_KEY") unless live?("OPENAI_API_KEY")
    stream = Trellis.stream_text("openai:gpt-4o-mini", "Count: 1 2 3")
    stream.text_stream.to_a.join.should_not be_empty
  end

  it "OpenAI generate_object" do
    pending!("set TRELLIS_LIVE=1 + OPENAI_API_KEY") unless live?("OPENAI_API_KEY")
    obj = Trellis.generate_object!("openai:gpt-4o-mini", "A person named Alice", person_schema)
    obj["name"].as_s.should_not be_empty
  end

  # ---- Anthropic ----
  it "Anthropic generate_text" do
    pending!("set TRELLIS_LIVE=1 + ANTHROPIC_API_KEY") unless live?("ANTHROPIC_API_KEY")
    resp = Trellis.generate_text("anthropic:claude-3-5-haiku-20241022", "Reply with exactly: OK")
    resp.text.should_not be_empty
    resp.usage.try(&.input_tokens).should_not be_nil
  end

  it "Anthropic stream_text" do
    pending!("set TRELLIS_LIVE=1 + ANTHROPIC_API_KEY") unless live?("ANTHROPIC_API_KEY")
    stream = Trellis.stream_text("anthropic:claude-3-5-haiku-20241022", "Count: 1 2 3")
    stream.text_stream.to_a.join.should_not be_empty
  end

  it "Anthropic generate_object" do
    pending!("set TRELLIS_LIVE=1 + ANTHROPIC_API_KEY") unless live?("ANTHROPIC_API_KEY")
    obj = Trellis.generate_object!("anthropic:claude-3-5-haiku-20241022", "A person named Alice", person_schema)
    obj["name"].as_s.should_not be_empty
  end

  # ---- Google ----
  it "Google generate_text" do
    pending!("set TRELLIS_LIVE=1 + GOOGLE_API_KEY") unless live?("GOOGLE_API_KEY")
    resp = Trellis.generate_text("google:gemini-2.0-flash", "Reply with exactly: OK")
    resp.text.should_not be_empty
    resp.usage.try(&.input_tokens).should_not be_nil
  end

  it "Google stream_text" do
    pending!("set TRELLIS_LIVE=1 + GOOGLE_API_KEY") unless live?("GOOGLE_API_KEY")
    stream = Trellis.stream_text("google:gemini-2.0-flash", "Count: 1 2 3")
    stream.text_stream.to_a.join.should_not be_empty
  end

  it "Google generate_object" do
    pending!("set TRELLIS_LIVE=1 + GOOGLE_API_KEY") unless live?("GOOGLE_API_KEY")
    obj = Trellis.generate_object!("google:gemini-2.0-flash", "A person named Alice", person_schema)
    obj["name"].as_s.should_not be_empty
  end
end
