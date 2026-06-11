require "../../spec_helper"

describe ReqLLM::Providers::Anthropic do
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
      ENV.delete("ANTHROPIC_API_KEY")
    end

    it "AUTH-SKIP-ON-REPLAY: does not resolve a key when replaying an existing fixture" do
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
      end
    end
  end
end
