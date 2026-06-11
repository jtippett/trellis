require "../../spec_helper"
require "file_utils"

describe ReqLLM::Providers::Anthropic do
  describe "#encode_chat_body" do
    it "encodes a basic chat body matching the canonical golden" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::System, "You are terse."),
        ReqLLM::Message.new(ReqLLM::Role::User, "Hi"),
      ])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate({temperature: 0.7})
      body = ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/anthropic/chat_basic.json")))
    end

    it "encodes sampling params matching the canonical golden" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::System, "You are terse."),
        ReqLLM::Message.new(ReqLLM::Role::User, "Hi"),
      ])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate({temperature: 0.7, top_p: 0.9, stop: ["END"]})
      body = ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/anthropic/chat_sampling.json")))
    end

    it "emits tools matching the canonical golden when the tools list is non-empty" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::User, "What's the weather in Paris?"),
      ])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")

      schema = {
        "properties" => JSON::Any.new({
          "location" => JSON::Any.new({"type" => JSON::Any.new("string")}),
        } of String => JSON::Any),
        "required" => JSON::Any.new([JSON::Any.new("location")]),
      } of String => JSON::Any
      tool = ReqLLM::Tool.new("get_weather", "Get the current weather for a location", schema)

      opts = ReqLLM::Options.validate({tools: [tool]})
      body = ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts)

      JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/anthropic/chat_tools.json")))
    end

    it "defaults max_tokens to 1024 when unset (Anthropic requires it)" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts))

      parsed["max_tokens"].should eq(JSON::Any.new(1024_i64))
    end

    it "omits system entirely when there is no system message" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts))

      parsed.as_h.has_key?("system").should be_false
    end

    it "collapses a lone plain-text system message to a bare string" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::System, "You are terse."),
        ReqLLM::Message.new(ReqLLM::Role::User, "Hi"),
      ])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts))

      parsed["system"].should eq(JSON::Any.new("You are terse."))
    end

    it "emits stream:false by default (value-based, upstream parity)" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts))

      parsed["stream"].should eq(JSON::Any.new(false))
    end

    it "omits tools entirely when the tools list is empty" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts))

      parsed.as_h.has_key?("tools").should be_false
    end

    it "wraps a scalar stop string into a 1-element stop_sequences array" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate({stop: "END"})
      parsed = JSON.parse(ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts))

      parsed["stop_sequences"].should eq(JSON::Any.new([JSON::Any.new("END")]))
    end

    it "folds two consecutive tool messages into one user message with two tool_result blocks" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::User, "What's the weather?"),
        ReqLLM::Message.new(ReqLLM::Role::Tool, "72F and sunny", tool_call_id: "toolu_1"),
        ReqLLM::Message.new(ReqLLM::Role::Tool, "Paris", tool_call_id: "toolu_2"),
      ])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts))

      messages = parsed["messages"].as_a
      # The user text message, then ONE merged user message of two tool_results.
      messages.size.should eq(2)
      merged = messages[1]
      merged["role"].should eq(JSON::Any.new("user"))
      blocks = merged["content"].as_a
      blocks.size.should eq(2)
      blocks[0]["type"].should eq(JSON::Any.new("tool_result"))
      blocks[0]["tool_use_id"].should eq(JSON::Any.new("toolu_1"))
      blocks[1]["type"].should eq(JSON::Any.new("tool_result"))
      blocks[1]["tool_use_id"].should eq(JSON::Any.new("toolu_2"))
    end

    it "emits is_error:true on a tool result whose metadata flags an error" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::Tool, "boom", tool_call_id: "toolu_1",
          metadata: {"is_error" => JSON::Any.new(true)}),
      ])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      parsed = JSON.parse(ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts))

      block = parsed["messages"].as_a[0]["content"].as_a[0]
      block["is_error"].should eq(JSON::Any.new(true))
    end

    it "raises when a tool message has no tool_call_id" do
      ctx = ReqLLM::Context.new([
        ReqLLM::Message.new(ReqLLM::Role::Tool, "result"),
      ])
      model = LLMDB.model("anthropic:claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)

      expect_raises(ReqLLM::Error::Invalid::Parameter, /tool_call_id/) do
        ReqLLM::Providers::Anthropic.new.encode_chat_body(model, ctx, opts)
      end
    end
  end

  describe "registration" do
    it "registers itself under the \"anthropic\" id" do
      ReqLLM::Registry.fetch("anthropic").should be_a(ReqLLM::Providers::Anthropic)
    end
  end

  describe "#prepare_request" do
    it "builds a POST to /v1/messages carrying typed state" do
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB::Model.new("anthropic", "claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate({temperature: 0.7})
      req = ReqLLM::Providers::Anthropic.new.prepare_request(:chat, model, ctx, opts)

      req.method.should eq("POST")
      req.url.to_s.should eq("https://api.anthropic.com/v1/messages")
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
        ReqLLM::Providers::Anthropic.new.prepare_request(:chat, model, ctx, opts)
      end
    end
  end

  describe "auth headers" do
    it "sets x-api-key + anthropic-version + Content-Type and NO Authorization" do
      prior_key = ENV["ANTHROPIC_API_KEY"]?
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
      ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
      model = LLMDB::Model.new("anthropic", "claude-3-5-sonnet-20241022")
      opts = ReqLLM::Options.validate(NamedTuple.new)
      provider = ReqLLM::Providers::Anthropic.new
      req = provider.prepare_request(:chat, model, ctx, opts)
      provider.attach(req)

      req.headers["x-api-key"]?.should eq("sk-ant-test")
      req.headers["anthropic-version"]?.should eq("2023-06-01")
      req.headers["Content-Type"]?.should eq("application/json")
      req.headers["Authorization"]?.should be_nil
    ensure
      if pk = prior_key
        ENV["ANTHROPIC_API_KEY"] = pk
      else
        ENV.delete("ANTHROPIC_API_KEY")
      end
    end

    it "AUTH-SKIP-ON-REPLAY: does not resolve a key when replaying an existing fixture" do
      prior_key = ENV["ANTHROPIC_API_KEY"]?
      ENV.delete("ANTHROPIC_API_KEY")
      tmp = File.tempname("cr_llm_fixtures")
      ReqLLM::Fixture.base_dir = tmp
      begin
        file = ReqLLM::Fixture.path(:anthropic, "chat_basic")
        Dir.mkdir_p(File.dirname(file))
        File.write(file, {
          status:  200,
          headers: {"content-type" => "application/json"},
          body:    %({"text":"from fixture"}),
        }.to_json)

        ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "Hi")])
        model = LLMDB::Model.new("anthropic", "claude-3-5-sonnet-20241022")
        opts = ReqLLM::Options.validate(NamedTuple.new)
        provider = ReqLLM::Providers::Anthropic.new
        req = provider.prepare_request(:chat, model, ctx, opts)
        req.fixture = "chat_basic"

        # No key in ENV: auth resolution is skipped on replay, so attach must
        # not raise, and no x-api-key header is set.
        provider.attach(req)
        req.headers["x-api-key"]?.should be_nil
        req.headers["anthropic-version"]?.should eq("2023-06-01")
      ensure
        ReqLLM::Fixture.base_dir = ReqLLM::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
        if pk = prior_key
          ENV["ANTHROPIC_API_KEY"] = pk
        else
          ENV.delete("ANTHROPIC_API_KEY")
        end
      end
    end
  end
end
