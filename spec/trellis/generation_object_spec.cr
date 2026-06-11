require "../spec_helper"

# OU1 DoD: Trellis.generate_object working end-to-end via the OpenAI json_schema
# path, fixture-backed, fully offline, with NO OPENAI_API_KEY set (auth is
# skipped on fixture replay). The schema-violating fixture proves validation
# fires.
describe "Trellis.generate_object" do
  person_schema = {
    "type"       => JSON::Any.new("object"),
    "properties" => JSON::Any.new({
      "name" => JSON::Any.new({"type" => JSON::Any.new("string")}),
      "age"  => JSON::Any.new({"type" => JSON::Any.new("integer")}),
    } of String => JSON::Any),
    "required" => JSON::Any.new([JSON::Any.new("name")]),
  } of String => JSON::Any

  it "returns the parsed, validated object from a recorded fixture (no API key)" do
    saved = ENV["OPENAI_API_KEY"]?
    ENV.delete("OPENAI_API_KEY")

    resp = Trellis.generate_object(
      "openai:gpt-4o-mini", "Give me a person", person_schema, fixture: "object_basic")

    resp.should be_a(Trellis::Response)
    obj = resp.object.not_nil!
    obj["name"].as_s.should eq("Alice")
    obj["age"].as_i.should eq(30)
  ensure
    if saved
      ENV["OPENAI_API_KEY"] = saved
    else
      ENV.delete("OPENAI_API_KEY")
    end
  end

  it "generate_object! returns just the object" do
    saved = ENV["OPENAI_API_KEY"]?
    ENV.delete("OPENAI_API_KEY")

    obj = Trellis.generate_object!(
      "openai:gpt-4o-mini", "Give me a person", person_schema, fixture: "object_basic")

    obj["name"].as_s.should eq("Alice")
  ensure
    if saved
      ENV["OPENAI_API_KEY"] = saved
    else
      ENV.delete("OPENAI_API_KEY")
    end
  end

  it "returns the validated object from an Anthropic tool_use fixture (no API key)" do
    saved = ENV["ANTHROPIC_API_KEY"]?
    ENV.delete("ANTHROPIC_API_KEY")

    resp = Trellis.generate_object(
      "anthropic:claude-3-5-sonnet-20241022", "Give me a person", person_schema,
      fixture: "object_basic")

    resp.should be_a(Trellis::Response)
    obj = resp.object.not_nil!
    obj["name"].as_s.should eq("Alice")
    obj["age"].as_i.should eq(30)
  ensure
    if saved
      ENV["ANTHROPIC_API_KEY"] = saved
    else
      ENV.delete("ANTHROPIC_API_KEY")
    end
  end

  it "returns the validated object from a Google candidate-text fixture (no API key)" do
    saved = ENV["GOOGLE_API_KEY"]?
    ENV.delete("GOOGLE_API_KEY")

    resp = Trellis.generate_object(
      "google:gemini-2.0-flash", "Give me a person", person_schema,
      fixture: "object_basic")

    resp.should be_a(Trellis::Response)
    obj = resp.object.not_nil!
    obj["name"].as_s.should eq("Alice")
    obj["age"].as_i.should eq(30)
  ensure
    if saved
      ENV["GOOGLE_API_KEY"] = saved
    else
      ENV.delete("GOOGLE_API_KEY")
    end
  end

  it "raises Error::Validation when the fixture content violates the schema" do
    saved = ENV["OPENAI_API_KEY"]?
    ENV.delete("OPENAI_API_KEY")

    expect_raises(Trellis::Error::Validation, /age/) do
      Trellis.generate_object(
        "openai:gpt-4o-mini", "Give me a person", person_schema, fixture: "object_invalid")
    end
  ensure
    if saved
      ENV["OPENAI_API_KEY"] = saved
    else
      ENV.delete("OPENAI_API_KEY")
    end
  end
end
