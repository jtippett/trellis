require "../../spec_helper"
require "file_utils"

describe ReqLLM::Providers::Google do
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
