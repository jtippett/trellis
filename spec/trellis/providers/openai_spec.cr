require "../../spec_helper"

describe Trellis::Providers::OpenAI do
  describe "#encode_chat_body" do
    it "encodes a basic chat body matching the canonical golden" do
      ctx = Trellis::Context.new([
        Trellis::Message.new(Trellis::Role::System, "You are terse."),
        Trellis::Message.new(Trellis::Role::User, "Hi"),
      ])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate({temperature: 0.7})
      body = Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/openai/chat_basic.json")))
    end

    it "emits stream:false (value-based, upstream parity)" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate(NamedTuple.new)
      parsed = JSON.parse(Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts))

      parsed["stream"].should eq(JSON::Any.new(false))
    end

    it "omits tools entirely when the tools list is empty" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate(NamedTuple.new)
      parsed = JSON.parse(Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts))

      parsed.as_h.has_key?("tools").should be_false
    end

    it "omits temperature when unset" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate(NamedTuple.new)
      parsed = JSON.parse(Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts))

      parsed.as_h.has_key?("temperature").should be_false
    end

    it "emits tools matching the canonical golden when the tools list is non-empty" do
      ctx = Trellis::Context.new([
        Trellis::Message.new(Trellis::Role::User, "What's the weather in Paris?"),
      ])
      model = LLMDB.model("openai:gpt-4o-mini")

      schema = {
        "properties" => JSON::Any.new({
          "location" => JSON::Any.new({"type" => JSON::Any.new("string")}),
        } of String => JSON::Any),
        "required" => JSON::Any.new([JSON::Any.new("location")]),
      } of String => JSON::Any
      tool = Trellis::Tool.new("get_weather", "Get the current weather for a location", schema)

      opts = Trellis::Options.validate({tools: [tool]})
      body = Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/openai/chat_tools.json")))
    end

    it "emits strict and full schema fidelity matching the strict golden" do
      ctx = Trellis::Context.new([
        Trellis::Message.new(Trellis::Role::User, "What's the weather in Paris?"),
      ])
      model = LLMDB.model("openai:gpt-4o-mini")

      schema = {
        "type"                 => JSON::Any.new("object"),
        "additionalProperties" => JSON::Any.new(false),
        "properties"           => JSON::Any.new({
          "location" => JSON::Any.new({"type" => JSON::Any.new("string")}),
        } of String => JSON::Any),
        "required" => JSON::Any.new([JSON::Any.new("location")]),
      } of String => JSON::Any
      tool = Trellis::Tool.new(
        "get_weather", "Get the current weather for a location", schema, strict: true)

      opts = Trellis::Options.validate({tools: [tool]})
      body = Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/openai/chat_tools_strict.json")))
    end

    it "omits tool_choice by default (upstream only emits when explicitly set)" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB.model("openai:gpt-4o-mini")
      tool = Trellis::Tool.new("get_weather", "Get the current weather")
      opts = Trellis::Options.validate({tools: [tool]})
      parsed = JSON.parse(Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts))

      parsed.as_h.has_key?("tool_choice").should be_false
    end

    it "encodes sampling params matching the canonical golden" do
      ctx = Trellis::Context.new([
        Trellis::Message.new(Trellis::Role::System, "You are terse."),
        Trellis::Message.new(Trellis::Role::User, "Hi"),
      ])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate({
        temperature:       0.7,
        top_p:             0.9,
        frequency_penalty: 0.5,
        presence_penalty:  0.2,
        seed:              42,
        stop:              ["END"],
      })
      body = Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/openai/chat_sampling.json")))
    end

    it "omits sampling params when unset" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate(NamedTuple.new)
      parsed = JSON.parse(Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts)).as_h

      parsed.has_key?("top_p").should be_false
      parsed.has_key?("frequency_penalty").should be_false
      parsed.has_key?("presence_penalty").should be_false
      parsed.has_key?("seed").should be_false
      parsed.has_key?("stop").should be_false
    end

    it "encodes stop as a String scalar" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate({stop: "END"})
      parsed = JSON.parse(Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts))

      parsed["stop"].should eq(JSON::Any.new("END"))
    end

    it "encodes stop as an Array(String)" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate({stop: ["END", "STOP"]})
      parsed = JSON.parse(Trellis::Providers::OpenAI.new.encode_chat_body(model, ctx, opts))

      parsed["stop"].should eq(JSON::Any.new([JSON::Any.new("END"), JSON::Any.new("STOP")]))
    end
  end

  describe "#encode_object_body" do
    it "emits response_format json_schema with strict:true + enforced schema (golden)" do
      ctx = Trellis::Context.new([
        Trellis::Message.new(Trellis::Role::User, "Give me a person"),
      ])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate(NamedTuple.new)

      schema = {
        "type"       => JSON::Any.new("object"),
        "properties" => JSON::Any.new({
          "name" => JSON::Any.new({"type" => JSON::Any.new("string")}),
          "age"  => JSON::Any.new({"type" => JSON::Any.new("integer")}),
        } of String => JSON::Any),
        "required" => JSON::Any.new([JSON::Any.new("name")]),
      } of String => JSON::Any

      body = Trellis::Providers::OpenAI.new.encode_object_body(
        model, ctx, opts, schema, "output_schema")

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/openai/object_basic.json")))
    end
  end

  describe "registration" do
    it "registers itself under the \"openai\" id" do
      Trellis::Registry.fetch("openai").should be_a(Trellis::Providers::OpenAI)
    end
  end

  describe "#prepare_request" do
    it "raises when model.provider does not match the provider id" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB::Model.new("anthropic", "claude-3-5-sonnet")
      opts = Trellis::Options.validate(NamedTuple.new)

      expect_raises(Trellis::Error::Invalid::Parameter, /provider/) do
        Trellis::Providers::OpenAI.new.prepare_request(:chat, model, ctx, opts)
      end
    end

    it "builds a POST to /chat/completions carrying typed state" do
      ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "Hi")])
      model = LLMDB.model("openai:gpt-4o-mini")
      opts = Trellis::Options.validate({temperature: 0.7})
      req = Trellis::Providers::OpenAI.new.prepare_request(:chat, model, ctx, opts)

      req.method.should eq("POST")
      req.url.to_s.should eq("https://api.openai.com/v1/chat/completions")
      req.operation.should eq(:chat)
      req.model.should eq(model)
      req.context.should eq(ctx)
      req.options.should eq(opts)
    end
  end
end
