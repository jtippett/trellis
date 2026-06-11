require "../spec_helper"
require "../support/fake_adapter"
require "file_utils"

# Append a decode response step that turns the raw HTTP body into a semantic
# Response whose assistant text is the value of the JSON "text" key (or, when
# the body is not JSON, the raw body itself). Used by several fixture specs.
private def append_text_decode(req)
  req.append_response_step(:decode) do |r, resp|
    text =
      begin
        JSON.parse(resp.body)["text"].as_s
      rescue
        resp.body
      end
    resp.decoded = Trellis::Response.new(model: "openai:gpt-4o-mini",
      message: Trellis::Message.new(Trellis::Role::Assistant, text))
    {r, resp}
  end
end

describe Trellis::Fixture do
  describe ".path" do
    it "builds spec/fixtures/<provider>/<name>.json under the base dir" do
      Trellis::Fixture.path(:openai, "chat_basic", base: "tmp/fix")
        .should eq("tmp/fix/openai/chat_basic.json")
    end

    it "defaults to the configured base dir" do
      Trellis::Fixture.path(:openai, "chat_basic")
        .should eq("spec/fixtures/openai/chat_basic.json")
    end
  end

  describe ".record?" do
    it "is true only when CR_LLM_FIXTURES is record" do
      Trellis::Fixture.record?.should be_false
      ENV["CR_LLM_FIXTURES"] = "record"
      Trellis::Fixture.record?.should be_true
    ensure
      ENV.delete("CR_LLM_FIXTURES")
    end
  end

  describe "write/load round-trip" do
    it "preserves status, headers, and body" do
      tmp = File.tempname("trellis_fixtures")
      Trellis::Fixture.base_dir = tmp
      begin
        headers = ::HTTP::Headers.new
        headers["content-type"] = "application/json"
        resp = Trellis::HTTP::Response.new(200, headers, %({"ok":true}))

        file = Trellis::Fixture.path(:openai, "hdr")
        Trellis::Fixture.write_response(file, resp)

        loaded = Trellis::Fixture.load_response(file)
        loaded.status.should eq(200)
        loaded.headers["content-type"].should eq("application/json")
        loaded.body.should eq(%({"ok":true}))
        loaded.decoded.should be_nil
      ensure
        Trellis::Fixture.base_dir = Trellis::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
      end
    end

    it "joins multi-value headers with ', ' on capture" do
      tmp = File.tempname("trellis_fixtures")
      Trellis::Fixture.base_dir = tmp
      begin
        headers = ::HTTP::Headers.new
        headers.add("set-cookie", "a=1")
        headers.add("set-cookie", "b=2")
        resp = Trellis::HTTP::Response.new(200, headers, "")

        file = Trellis::Fixture.path(:openai, "multi")
        Trellis::Fixture.write_response(file, resp)
        loaded = Trellis::Fixture.load_response(file)
        loaded.headers["set-cookie"].should eq("a=1, b=2")
      ensure
        Trellis::Fixture.base_dir = Trellis::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
      end
    end
  end

  describe "replay (request-step half)" do
    it "short-circuits transport but still folds response steps" do
      tmp = File.tempname("trellis_fixtures")
      Trellis::Fixture.base_dir = tmp
      begin
        file = Trellis::Fixture.path(:openai, "chat_basic")
        Dir.mkdir_p(File.dirname(file))
        File.write(file, {
          status:  200,
          headers: {"content-type" => "application/json"},
          body:    %({"text":"from fixture"}),
        }.to_pretty_json)

        req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
        Trellis::Fixture.attach(req, :openai, "chat_basic")
        append_text_decode(req)

        req.request_step_names.should eq([:fixture])

        adapter = FakeAdapter.new # raises if transport is invoked
        out = Trellis::HTTP::Pipeline.run(req, adapter)

        adapter.called?.should be_false
        out.text.should eq("from fixture")
      ensure
        Trellis::Fixture.base_dir = Trellis::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
      end
    end

    it "passes the request through when the fixture is missing" do
      tmp = File.tempname("trellis_fixtures")
      Trellis::Fixture.base_dir = tmp
      begin
        req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
        Trellis::Fixture.attach(req, :openai, "absent")
        append_text_decode(req)

        adapter = FakeAdapter.new(status: 200, body: %({"text":"from network"}))
        out = Trellis::HTTP::Pipeline.run(req, adapter)

        adapter.called?.should be_true
        out.text.should eq("from network")
      ensure
        Trellis::Fixture.base_dir = Trellis::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
      end
    end
  end

  describe "corrupt fixture file" do
    it "raises a Trellis::Error naming the fixture path" do
      tmp = File.tempname("trellis_fixtures")
      Trellis::Fixture.base_dir = tmp
      begin
        file = Trellis::Fixture.path(:openai, "corrupt")
        Dir.mkdir_p(File.dirname(file))
        File.write(file, "this is not json {{{")

        req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
        Trellis::Fixture.attach(req, :openai, "corrupt")
        append_text_decode(req)

        adapter = FakeAdapter.new # raises if transport is invoked
        ex = expect_raises(Trellis::Error) do
          Trellis::HTTP::Pipeline.run(req, adapter)
        end
        ex.message.not_nil!.should contain(file)
        ex.message.not_nil!.should contain("malformed fixture")
      ensure
        Trellis::Fixture.base_dir = Trellis::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
      end
    end

    it "raises a typed error for valid JSON that is not an object" do
      tmp = File.tempname("trellis_fixtures")
      Trellis::Fixture.base_dir = tmp
      begin
        file = Trellis::Fixture.path(:openai, "notobject")
        Dir.mkdir_p(File.dirname(file))
        File.write(file, "[1, 2, 3]") # valid JSON, wrong top-level shape

        req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
        Trellis::Fixture.attach(req, :openai, "notobject")
        append_text_decode(req)

        ex = expect_raises(Trellis::Error) do
          Trellis::HTTP::Pipeline.run(req, FakeAdapter.new)
        end
        ex.message.not_nil!.should contain("malformed fixture")
      ensure
        Trellis::Fixture.base_dir = Trellis::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
      end
    end
  end

  describe "record then replay" do
    it "captures the raw response in record mode, then replays it" do
      tmp = File.tempname("trellis_fixtures")
      Trellis::Fixture.base_dir = tmp
      begin
        # --- record half ---
        ENV["CR_LLM_FIXTURES"] = "record"
        begin
          req = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
          Trellis::Fixture.attach(req, :openai, "recorded")
          # In record mode the replay step is NOT wired as a request step.
          req.request_step_names.should eq([] of Symbol)
          req.response_steps.map { |(n, _)| n }.should eq([:fixture_capture])
          append_text_decode(req)

          adapter = FakeAdapter.new(status: 201, body: %({"text":"hello recorded"}))
          Trellis::HTTP::Pipeline.run(req, adapter)
          adapter.called?.should be_true
        ensure
          ENV.delete("CR_LLM_FIXTURES")
        end

        file = Trellis::Fixture.path(:openai, "recorded")
        File.exists?(file).should be_true
        parsed = JSON.parse(File.read(file))
        parsed["status"].as_i.should eq(201)
        parsed["body"].as_s.should eq(%({"text":"hello recorded"}))

        # --- replay half (default mode) ---
        req2 = Trellis::HTTP::Request.new("POST", URI.parse("https://x/y"))
        Trellis::Fixture.attach(req2, :openai, "recorded")
        append_text_decode(req2)

        adapter2 = FakeAdapter.new # raises if transport is invoked
        out = Trellis::HTTP::Pipeline.run(req2, adapter2)
        adapter2.called?.should be_false
        out.text.should eq("hello recorded")
      ensure
        Trellis::Fixture.base_dir = Trellis::Fixture::DEFAULT_BASE_DIR
        FileUtils.rm_rf(tmp)
      end
    end
  end
end
