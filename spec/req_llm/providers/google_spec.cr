require "../../spec_helper"
require "file_utils"

describe ReqLLM::Providers::Google do
  describe "#encode_chat_body" do
    it "encodes a basic chat body matching the canonical golden" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::System, "You are terse."),
        ReqLLM::Message.new(ReqLLM::Role::User, "Hi"),
      ])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate({temperature: 0.7})
      body = ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/google/chat_basic.json")))
    end

    it "encodes sampling params matching the canonical golden" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::System, "You are terse."),
        ReqLLM::Message.new(ReqLLM::Role::User, "Hi"),
      ])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate({temperature: 0.7, top_p: 0.9, max_tokens: 256, stop: ["END"]})
      body = ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/google/chat_sampling.json")))
    end

    it "emits tools matching the canonical golden when the tools list is non-empty" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::User, "What's the weather in Paris?"),
      ])
      model = LLMDB.model("google:gemini-2.0-flash")

      schema = {
        "properties" => JSON::Any.new({
          "location" => JSON::Any.new({"type" => JSON::Any.new("string")}),
        } of String => JSON::Any),
        "required" => JSON::Any.new([JSON::Any.new("location")]),
      } of String => JSON::Any
      tool = ReqLLM::Tool.new("get_weather", "Get the current weather for a location", schema)

      opts = ReqLLM::Options.validate({tools: [tool]})
      body = ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/google/chat_tools.json")))
    end

    it "omits systemInstruction when there is no system message" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      parsed.as_h.has_key?("systemInstruction").should be_false
    end

    it "OMITS maxOutputTokens when max_tokens is unset (Gemini does not require it)" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate({temperature: 0.7})
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      parsed["generationConfig"].as_h.has_key?("maxOutputTokens").should be_false
    end

    it "omits generationConfig entirely when no sampling params are set" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      parsed.as_h.has_key?("generationConfig").should be_false
    end

    it "encodes an assistant message with role \"model\"" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::User, "Hi"),
        ReqLLM::Message.new(ReqLLM::Role::Assistant, "Hello!"),
      ])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      contents = parsed["contents"].as_a
      contents[1]["role"].should eq(JSON::Any.new("model"))
      contents[1]["parts"].as_a[0]["text"].should eq(JSON::Any.new("Hello!"))
    end

    it "omits tools entirely when the tools list is empty" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      parsed.as_h.has_key?("tools").should be_false
    end

    it "wraps a scalar stop string into a 1-element stopSequences array" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate({stop: "END"})
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      parsed["generationConfig"]["stopSequences"].should eq(JSON::Any.new([JSON::Any.new("END")]))
    end

    it "encodes an assistant message with tool_calls as a functionCall part with DECODED args" do
      tc = ReqLLM::ToolCall.new("call_1", "get_weather", %({"location":"Paris"}))
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::User, "Weather in Paris?"),
        ReqLLM::Message.new(ReqLLM::Role::Assistant, "Let me check.", tool_calls: [tc]),
      ])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      assistant = parsed["contents"].as_a[1]
      assistant["role"].should eq(JSON::Any.new("model"))
      parts = assistant["parts"].as_a
      parts[0]["text"].should eq(JSON::Any.new("Let me check."))
      fc = parts[1]["functionCall"]
      fc["name"].should eq(JSON::Any.new("get_weather"))
      # args is the DECODED object, not the JSON string.
      fc["args"]["location"].should eq(JSON::Any.new("Paris"))
    end

    it "folds two consecutive tool messages into ONE user entry with two functionResponse parts" do
      tc1 = ReqLLM::ToolCall.new("call_1", "get_weather", %({"city":"Paris"}))
      tc2 = ReqLLM::ToolCall.new("call_2", "get_conditions", %({"city":"Paris"}))
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::User, "Weather?"),
        ReqLLM::Message.new(ReqLLM::Role::Assistant, "", tool_calls: [tc1, tc2]),
        ReqLLM::Message.new(ReqLLM::Role::Tool, "72F", name: "get_weather", tool_call_id: "call_1"),
        ReqLLM::Message.new(ReqLLM::Role::Tool, "Sunny", name: "get_conditions", tool_call_id: "call_2"),
      ])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      contents = parsed["contents"].as_a
      # User, model (tool calls), then ONE merged user entry of two functionResponse parts.
      contents.size.should eq(3)
      merged = contents[2]
      merged["role"].should eq(JSON::Any.new("user"))
      parts = merged["parts"].as_a
      parts.size.should eq(2)
      parts[0]["functionResponse"]["name"].should eq(JSON::Any.new("get_weather"))
      parts[0]["functionResponse"]["response"]["content"].should eq(JSON::Any.new("72F"))
      parts[1]["functionResponse"]["name"].should eq(JSON::Any.new("get_conditions"))
      parts[1]["functionResponse"]["response"]["content"].should eq(JSON::Any.new("Sunny"))
    end

    it "uses \"unknown\" as the functionResponse name when the message has none" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::Tool, "result", tool_call_id: "call_1"),
      ])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts))

      part = parsed["contents"].as_a[0]["parts"].as_a[0]
      part["functionResponse"]["name"].should eq(JSON::Any.new("unknown"))
    end

    it "raises when a tool message has no tool_call_id" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::Tool, "result"),
      ])
      model = LLMDB.model("google:gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)

      expect_raises(ReqLLM::Error::Invalid::Parameter, /tool_call_id/) do
        ReqLLM::Providers::Google.new.encode_chat_body(model, ctx, opts)
      end
    end
  end

  describe "registration" do
    it "registers itself under the \"google\" id" do
      ReqLLM::Registry.fetch("google").should be_a(ReqLLM::Providers::Google)
    end
  end

  describe "#prepare_request" do
    it "builds a POST to /models/<id>:generateContent carrying typed state" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB::Model.new("google", "gemini-2.0-flash")
      opts = ReqLLM::Options.validate({temperature: 0.7})
      req = ReqLLM::Providers::Google.new.prepare_request(:chat, model, ctx, opts)

      req.method.should eq("POST")
      req.url.to_s.should eq(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")
      req.operation.should eq(:chat)
      req.model.should eq(model)
      req.context.should eq(ctx)
      req.options.should eq(opts)
    end

    it "raises when model.provider does not match the provider id" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB::Model.new("openai", "gpt-4o-mini")
      opts = ReqLLM::Options.validate(NamedTuple.new)

      expect_raises(ReqLLM::Error::Invalid::Parameter, /provider/) do
        ReqLLM::Providers::Google.new.prepare_request(:chat, model, ctx, opts)
      end
    end
  end

  describe "catalog" do
    it "resolves the google:gemini-2.0-flash model id" do
      model = LLMDB.model("google:gemini-2.0-flash")
      model.provider.should eq("google")
      model.id.should eq("gemini-2.0-flash")
    end
  end

  describe "auth headers" do
    it "sets x-goog-api-key + Content-Type and NO Authorization" do
      prior_key = ENV["GOOGLE_API_KEY"]?
      ENV["GOOGLE_API_KEY"] = "goog-test"
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB::Model.new("google", "gemini-2.0-flash")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      provider = ReqLLM::Providers::Google.new
      req = provider.prepare_request(:chat, model, ctx, opts)
      provider.attach(req)

      req.headers["x-goog-api-key"]?.should eq("goog-test")
      req.headers["Content-Type"]?.should eq("application/json")
      req.headers["Authorization"]?.should be_nil
    ensure
      if pk = prior_key
        ENV["GOOGLE_API_KEY"] = pk
      else
        ENV.delete("GOOGLE_API_KEY")
      end
    end

    it "AUTH-SKIP-ON-REPLAY: does not resolve a key when replaying an existing fixture" do
      prior_key = ENV["GOOGLE_API_KEY"]?
      ENV.delete("GOOGLE_API_KEY")
      tmp = File.tempname("cr_llm_fixtures")
      ReqLLM::Fixture.base_dir = tmp
      begin
        file = ReqLLM::Fixture.path(:google, "chat_basic")
        Dir.mkdir_p(File.dirname(file))
        File.write(file, {
          status:  200,
          headers: {"content-type" => "application/json"},
          body:    %({"text":"from fixture"}),
        }.to_json)

        ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
        model = LLMDB::Model.new("google", "gemini-2.0-flash")
        opts = ReqLLM::Options.validate(NamedTuple.new)
        provider = ReqLLM::Providers::Google.new
        req = provider.prepare_request(:chat, model, ctx, opts)
        req.fixture = "chat_basic"

        # No key in ENV: auth resolution is skipped on replay, so attach must
        # not raise, and no x-goog-api-key header is set.
        provider.attach(req)
        req.headers["x-goog-api-key"]?.should be_nil
        req.headers["Content-Type"]?.should eq("application/json")
      ensure
        ReqLLM::Fixture.base_dir = ReqLLM::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
        if pk = prior_key
          ENV["GOOGLE_API_KEY"] = pk
        else
          ENV.delete("GOOGLE_API_KEY")
        end
      end
    end
  end
end
