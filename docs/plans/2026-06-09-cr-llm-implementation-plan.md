# cr_llm Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port Elixir's `req_llm` to Crystal — core engine plus OpenAI, Anthropic, and Google — with a request/response step pipeline over stdlib `HTTP::Client`, a models.dev-driven catalog, and a record/replay test harness.

**Architecture:** One shard, two namespaces — `LLMDB::*` (catalog vendored from models.dev) and `ReqLLM::*` (engine + providers). Providers are thin plugins that wire encode/decode/auth steps into a shared named-step pipeline. See `docs/plans/2026-06-08-cr-llm-port-design.md` for the full design and rationale.

**Tech Stack:** Crystal 1.20.2, Shards 0.20.0. Stdlib only at runtime (`HTTP::Client`, `JSON`, `URI`, `UUID`, `Channel`). Crystal's built-in `spec` for tests.

**Reference source:** The Elixir library is vendored at `./req_llm/`. When a task says "mirror upstream X", read the named file under `./req_llm/lib/` first.

---

## How to work this plan

- **TDD, always.** Write the failing spec, run it red, write minimal code, run it green, commit. Never write implementation before a failing test.
- **One commit per task** (the final step of each task). Conventional-commit messages.
- **Run `crystal tool format` before each commit.** CI rejects unformatted code.
- **Phase 1 is fully detailed below.** Phases 2+ are task-level roadmaps; expand each into bite-sized TDD steps (same structure) when you reach it, using what Phase 1 taught you. Do not pre-expand — provider detail depends on the OpenAI slice.
- **Definition of done for Phase 1:** `ReqLLM.generate_text("openai:gpt-4o-mini", "Hi")` returns a `Response` from a recorded fixture with no network, and a golden-encoding spec pins the request body. All specs green, formatted, committed.

---

# Phase 1 — OpenAI vertical slice

## Task 1: Project scaffold

**Files:**
- Create: `shard.yml`
- Create: `.gitignore`
- Create: `src/cr_llm.cr`
- Create: `spec/spec_helper.cr`
- Create: `spec/scaffold_spec.cr`

**Step 1: Write `shard.yml`**

```yaml
name: cr_llm
version: 0.1.0
crystal: ">= 1.20.0"
license: Apache-2.0
authors:
  - James Tippett <james@lvl4.net>
targets:
  cr_llm:
    main: src/cr_llm.cr
```

**Step 2: Write `.gitignore`**

```
/lib/
/bin/
/.shards/
*.dwarf
.DS_Store
/spec/fixtures/**/*.tmp
.env
```

**Step 3: Write the entrypoint `src/cr_llm.cr`**

```crystal
module ReqLLM
  VERSION = "0.1.0"
end

module LLMDB
end
```

**Step 4: Write `spec/spec_helper.cr`**

```crystal
require "spec"
require "../src/cr_llm"
```

**Step 5: Write the failing scaffold spec `spec/scaffold_spec.cr`**

```crystal
require "./spec_helper"

describe ReqLLM do
  it "has a version" do
    ReqLLM::VERSION.should eq("0.1.0")
  end
end
```

**Step 6: Run it**

Run: `crystal spec spec/scaffold_spec.cr`
Expected: PASS (1 example, 0 failures).

**Step 7: Commit**

```bash
crystal tool format
git add shard.yml .gitignore src/cr_llm.cr spec/
git commit -m "chore: scaffold cr_llm shard"
```

---

## Task 2: Error hierarchy

Mirrors `splode` usage in `./req_llm/lib/req_llm/error.ex`.

**Files:**
- Create: `src/req_llm/error.cr`
- Test: `spec/req_llm/error_spec.cr`
- Modify: `src/cr_llm.cr` (add `require "./req_llm/error"`)

**Step 1: Write the failing spec**

```crystal
require "../spec_helper"

describe ReqLLM::Error do
  it "API::Request carries status and body" do
    err = ReqLLM::Error::API::Request.new("boom", status: 429, body: "rate limited")
    err.status.should eq(429)
    err.body.should eq("rate limited")
    err.message.should eq("boom")
  end

  it "subclasses share a common base" do
    ReqLLM::Error::Invalid::Parameter.new("bad").is_a?(ReqLLM::Error).should be_true
  end
end
```

**Step 2: Run it**

Run: `crystal spec spec/req_llm/error_spec.cr`
Expected: FAIL — `undefined constant ReqLLM::Error`.

**Step 3: Implement `src/req_llm/error.cr`**

```crystal
module ReqLLM
  class Error < Exception
    module Invalid
      class Parameter < Error; end
      class Schema < Error; end
      class Role < Error; end
    end

    module API
      class Request < Error
        getter status : Int32?
        getter body : String?

        def initialize(message : String, @status : Int32? = nil, @body : String? = nil)
          super(message)
        end
      end

      class Response < Error; end
    end

    class Validation < Error; end
  end
end
```

**Step 4: Wire the require** in `src/cr_llm.cr` (add `require "./req_llm/error"` after the module opens — or restructure so requires sit at top of file referencing the modules). Keep `src/cr_llm.cr` as the single require manifest:

```crystal
require "./req_llm/error"

module ReqLLM
  VERSION = "0.1.0"
end

module LLMDB
end
```

**Step 5: Run it**

Run: `crystal spec spec/req_llm/error_spec.cr`
Expected: PASS.

**Step 6: Commit**

```bash
crystal tool format
git add src/req_llm/error.cr spec/req_llm/error_spec.cr src/cr_llm.cr
git commit -m "feat: error hierarchy"
```

---

## Task 3: Key resolution and .env loader

Mirrors `./req_llm/lib/req_llm/keys.ex` and the dotenvy usage. Precedence: explicit `api_key` opt → `ENV[<KEY>]` (loaded from `.env`).

**Files:**
- Create: `src/req_llm/keys.cr`
- Test: `spec/req_llm/keys_spec.cr`
- Modify: `src/cr_llm.cr`

**Step 1: Failing spec**

```crystal
require "../spec_helper"

describe ReqLLM::Keys do
  it "prefers an explicit key over the environment" do
    ReqLLM::Keys.resolve("OPENAI_API_KEY", explicit: "sk-explicit").should eq("sk-explicit")
  end

  it "falls back to the environment" do
    ENV["OPENAI_API_KEY"] = "sk-env"
    ReqLLM::Keys.resolve("OPENAI_API_KEY").should eq("sk-env")
  ensure
    ENV.delete("OPENAI_API_KEY")
  end

  it "raises a clear error when missing" do
    expect_raises(ReqLLM::Error::Invalid::Parameter, /OPENAI_API_KEY/) do
      ReqLLM::Keys.resolve("OPENAI_API_KEY")
    end
  end

  it "parses a .env string into pairs" do
    pairs = ReqLLM::Keys.parse_env("# comment\nFOO=bar\nBAZ=\"qux\"\n")
    pairs["FOO"].should eq("bar")
    pairs["BAZ"].should eq("qux")
  end
end
```

**Step 2: Run red.** Expected: FAIL — undefined `ReqLLM::Keys`.

**Step 3: Implement `src/req_llm/keys.cr`**

```crystal
module ReqLLM
  module Keys
    extend self

    def resolve(env_key : String, explicit : String? = nil) : String
      return explicit if explicit && !explicit.empty?
      if value = ENV[env_key]?
        return value unless value.empty?
      end
      raise Error::Invalid::Parameter.new(
        "Missing API key: set #{env_key} in the environment or pass api_key:")
    end

    # Minimal dotenv parser: KEY=VALUE per line, # comments, optional quotes.
    def parse_env(contents : String) : Hash(String, String)
      result = {} of String => String
      contents.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        key, _, raw = line.partition('=')
        next if key.empty?
        value = raw.strip
        if (value.starts_with?('"') && value.ends_with?('"')) ||
           (value.starts_with?('\'') && value.ends_with?('\''))
          value = value[1..-2]
        end
        result[key.strip] = value
      end
      result
    end

    def load_env_file(path : String = ".env") : Nil
      return unless File.exists?(path)
      parse_env(File.read(path)).each do |k, v|
        ENV[k] ||= v
      end
    end
  end
end
```

**Step 4: Run green.** **Step 5: Commit** `feat: api key resolution and .env loader`.

---

## Task 4: Content model — enums and ContentPart

Mirrors `./req_llm/lib/req_llm/message/content_part.ex`.

**Files:**
- Create: `src/req_llm/content_part.cr`
- Test: `spec/req_llm/content_part_spec.cr`

**Step 1: Failing spec**

```crystal
require "../spec_helper"

describe ReqLLM::ContentPart do
  it "builds a text part" do
    part = ReqLLM::ContentPart.text("hello")
    part.type.should eq(ReqLLM::PartType::Text)
    part.text.should eq("hello")
  end

  it "builds an image_url part" do
    part = ReqLLM::ContentPart.image_url("https://x/y.png")
    part.type.should eq(ReqLLM::PartType::ImageUrl)
    part.url.should eq("https://x/y.png")
  end

  it "builds a binary image part with media type" do
    part = ReqLLM::ContentPart.image(Bytes[1, 2, 3], "image/png")
    part.type.should eq(ReqLLM::PartType::Image)
    part.media_type.should eq("image/png")
    part.data.should eq(Bytes[1, 2, 3])
  end

  it "builds a thinking part" do
    ReqLLM::ContentPart.thinking("reasoning").type.should eq(ReqLLM::PartType::Thinking)
  end
end
```

**Step 2: Run red.**

**Step 3: Implement `src/req_llm/content_part.cr`**

```crystal
module ReqLLM
  enum Role
    User
    Assistant
    System
    Tool
  end

  enum PartType
    Text
    ImageUrl
    VideoUrl
    Image
    File
    Thinking
  end

  struct ContentPart
    getter type : PartType
    getter text : String?
    getter url : String?
    getter data : Bytes?
    getter file_id : String?
    getter media_type : String?
    getter filename : String?
    getter metadata : Hash(String, JSON::Any)

    def initialize(@type, *, @text = nil, @url = nil, @data = nil,
                   @file_id = nil, @media_type = nil, @filename = nil,
                   @metadata = {} of String => JSON::Any)
    end

    def self.text(text : String, metadata = {} of String => JSON::Any)
      new(PartType::Text, text: text, metadata: metadata)
    end

    def self.thinking(text : String, metadata = {} of String => JSON::Any)
      new(PartType::Thinking, text: text, metadata: metadata)
    end

    def self.image_url(url : String, metadata = {} of String => JSON::Any)
      new(PartType::ImageUrl, url: url, metadata: metadata)
    end

    def self.video_url(url : String, metadata = {} of String => JSON::Any)
      new(PartType::VideoUrl, url: url, metadata: metadata)
    end

    def self.image(data : Bytes, media_type : String, metadata = {} of String => JSON::Any)
      new(PartType::Image, data: data, media_type: media_type, metadata: metadata)
    end

    def self.file(data : Bytes, filename : String, media_type : String)
      new(PartType::File, data: data, filename: filename, media_type: media_type)
    end

    def self.file_id(id : String, media_type : String? = nil)
      new(PartType::File, file_id: id, media_type: media_type)
    end
  end
end
```

Add `require "json"` at the top of `src/cr_llm.cr` and `require "./req_llm/content_part"`.

**Step 4: Run green.** **Step 5: Commit** `feat: ContentPart and role/part enums`.

---

## Task 5: Message

Mirrors `./req_llm/lib/req_llm/message.ex`. Fields: `role`, `content` (Array(ContentPart)), `name`, `tool_call_id`, `tool_calls`, plus lossless round-trip metadata.

**Files:** Create `src/req_llm/message.cr`; Test `spec/req_llm/message_spec.cr`.

**Step 1: Failing spec** — cover: build from a plain string content (auto-wraps to one text part), `valid?` (non-empty content or tool fields), and round-trip of `metadata`.

```crystal
require "../spec_helper"

describe ReqLLM::Message do
  it "wraps a string into a single text part" do
    msg = ReqLLM::Message.new(ReqLLM::Role::User, "hi")
    msg.content.size.should eq(1)
    msg.content.first.text.should eq("hi")
  end

  it "accepts explicit content parts" do
    parts = [ReqLLM::ContentPart.text("a"), ReqLLM::ContentPart.text("b")]
    ReqLLM::Message.new(ReqLLM::Role::Assistant, parts).content.size.should eq(2)
  end

  it "is invalid when empty" do
    ReqLLM::Message.new(ReqLLM::Role::User, [] of ReqLLM::ContentPart).valid?.should be_false
  end
end
```

**Step 2: Run red. Step 3: Implement** — constructor overloads for `String` and `Array(ContentPart)`; `valid?` returns true when content non-empty or `tool_calls`/`tool_call_id` present. **Step 4: green. Step 5: Commit** `feat: Message`.

---

## Task 6: Context

Mirrors `./req_llm/lib/req_llm/context.ex`. A `class` (mutable carrier) wrapping `Array(Message)` with `append`, `prepend`, `concat`, `to_a`, and the `user`/`assistant`/`system` builder helpers.

**Files:** Create `src/req_llm/context.cr`; Test `spec/req_llm/context_spec.cr`.

**Step 1: Failing spec** covering: `Context.new([...])`, `<<`/`append` returns self with message added, and the `Context.user("hi")` class helper produces a `Message` of role `User`.

**Step 2–5:** red → implement → green → commit `feat: Context`.

---

## Task 7: ToolCall and Tool

Mirrors `tool_call.ex` and `tool.ex`. `ToolCall`: `id`, `name`, `arguments` (raw JSON string) + `args_map`. `Tool`: `name`, `description`, `parameter_schema` (Hash describing JSON Schema), `callback` (Proc), `to_json_schema`.

**Files:** Create `src/req_llm/tool_call.cr`, `src/req_llm/tool.cr`; Tests alongside.

**Step 1: Failing specs** — `ToolCall#args_map` parses JSON string to `Hash(String, JSON::Any)`; `Tool#to_json_schema` emits `{"type" => "object", "properties" => {...}, "required" => [...]}` from a parameter spec; `Tool.new` rejects an invalid name (`valid_name?`). **Steps 2–5** per task.

Commit `feat: Tool and ToolCall`.

---

## Task 8: Usage and cost

Mirrors `usage.ex` and `usage/cost.ex`. `Usage`: `input_tokens`, `output_tokens`, `reasoning_tokens`, `cached_tokens`, and `cost` derived from `LLMDB::Model` pricing.

**Files:** Create `src/req_llm/usage.cr`; Test alongside.

**Step 1: Failing spec** — given input/output token counts and a pricing pair `{input: 0.15, output: 0.60}` (USD per 1M tokens), `Usage.cost(...)` returns the correct dollar amount. **Steps 2–5.** Commit `feat: Usage and cost`.

---

## Task 9: StreamChunk

Mirrors `stream_chunk.ex`. `type` enum (`Content | Thinking | ToolCall | Meta`), plus `text`, `name`, `arguments`, `metadata`. Constructors `.text`, `.thinking`, `.tool_call`, `.meta`.

**Files:** Create `src/req_llm/stream_chunk.cr`; Test alongside. TDD as above. Commit `feat: StreamChunk`.

---

## Task 10: Response

Mirrors `response.ex`. A `class` carrying `model`, `context`, `message` (the assistant reply), `usage`, `finish_reason`, optional `stream`/`object`. Accessors: `text` (concatenate text parts of `message`), `tool_calls`, `usage`, `finish_reason`, `ok?`.

**Files:** Create `src/req_llm/response.cr`; Test `spec/req_llm/response_spec.cr`.

**Step 1: Failing spec**

```crystal
require "../spec_helper"

describe ReqLLM::Response do
  it "extracts text from the assistant message" do
    msg = ReqLLM::Message.new(ReqLLM::Role::Assistant,
      [ReqLLM::ContentPart.text("Hello "), ReqLLM::ContentPart.text("world")])
    resp = ReqLLM::Response.new(model: "openai:gpt-4o-mini", message: msg)
    resp.text.should eq("Hello world")
  end
end
```

**Steps 2–5.** Commit `feat: Response`.

---

## Task 11: HTTP::Request and named steps

The pipeline core. Mirrors how `Req.Request` threads steps; see `./req_llm/lib/req_llm/provider.ex`.

**Files:**
- Create: `src/req_llm/http/request.cr`
- Test: `spec/req_llm/http/request_spec.cr`

**Step 1: Failing spec**

```crystal
require "../../spec_helper"

describe ReqLLM::HTTP::Request do
  it "appends, prepends, and replaces request steps by name" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    req.append_request_step(:a) { |r| r }
    req.append_request_step(:b) { |r| r }
    req.prepend_request_step(:z) { |r| r }
    req.request_step_names.should eq([:z, :a, :b])

    req.replace_request_step(:a) { |r| r }
    req.request_step_names.should eq([:z, :a, :b]) # order preserved on replace
  end
end
```

**Step 2: Run red.**

**Step 3: Implement `src/req_llm/http/request.cr`**

```crystal
require "http/headers"
require "uri"

module ReqLLM::HTTP
  # A request step may return a Request (continue) or a Response (short-circuit).
  alias RequestStepProc = Request -> (Request | ReqLLM::Response)
  alias ResponseStepProc = (Request, ReqLLM::Response) -> {Request, ReqLLM::Response}
  alias ErrorStepProc = (Request, Exception) -> (ReqLLM::Response | Exception)

  class Request
    property method : String
    property url : URI
    property headers : HTTP::Headers
    property body : (IO | String | Bytes | Nil)
    property options : Hash(Symbol, JSON::Any)
    property private : Hash(Symbol, JSON::Any)

    getter request_steps : Array({Symbol, RequestStepProc})
    getter response_steps : Array({Symbol, ResponseStepProc})
    getter error_steps : Array({Symbol, ErrorStepProc})

    def initialize(@method, @url, @headers = HTTP::Headers.new, @body = nil)
      @options = {} of Symbol => JSON::Any
      @private = {} of Symbol => JSON::Any
      @request_steps = [] of {Symbol, RequestStepProc}
      @response_steps = [] of {Symbol, ResponseStepProc}
      @error_steps = [] of {Symbol, ErrorStepProc}
    end

    def append_request_step(name : Symbol, &block : RequestStepProc)
      @request_steps << {name, block}
      self
    end

    def prepend_request_step(name : Symbol, &block : RequestStepProc)
      @request_steps.unshift({name, block})
      self
    end

    def replace_request_step(name : Symbol, &block : RequestStepProc)
      idx = @request_steps.index { |(n, _)| n == name }
      if idx
        @request_steps[idx] = {name, block}
      else
        @request_steps << {name, block}
      end
      self
    end

    def append_response_step(name : Symbol, &block : ResponseStepProc)
      @response_steps << {name, block}
      self
    end

    def append_error_step(name : Symbol, &block : ErrorStepProc)
      @error_steps << {name, block}
      self
    end

    def request_step_names : Array(Symbol)
      @request_steps.map { |(n, _)| n }
    end
  end
end
```

**Step 4: Run green. Step 5: Commit** `feat: HTTP::Request with named step pipeline`.

---

## Task 12: Pipeline with short-circuit, against a fake adapter

**Files:**
- Create: `src/req_llm/http/adapter.cr` (the adapter interface + a `FakeAdapter` for tests lives in spec support)
- Create: `src/req_llm/http/pipeline.cr`
- Create: `spec/support/fake_adapter.cr`
- Test: `spec/req_llm/http/pipeline_spec.cr`

**Step 1: Failing spec** — two behaviors:

```crystal
require "../../spec_helper"
require "../../support/fake_adapter"

describe ReqLLM::HTTP::Pipeline do
  it "short-circuits when a request step returns a Response" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    canned = ReqLLM::Response.new(model: "x", message: nil)
    req.append_request_step(:cache) { |_| canned }
    adapter = FakeAdapter.new # would raise if called
    resp = ReqLLM::HTTP::Pipeline.run(req, adapter)
    resp.should be(canned)
    adapter.called?.should be_false
  end

  it "runs the adapter then folds response steps" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    adapter = FakeAdapter.new(status: 200, body: %({"ok":true}))
    req.append_response_step(:tag) { |r, resp| resp.private[:tag] = JSON::Any.new("done"); {r, resp} }
    resp = ReqLLM::HTTP::Pipeline.run(req, adapter)
    adapter.called?.should be_true
    resp.private[:tag].as_s.should eq("done")
  end
end
```

(Adjust `Response.new` signature/`private` access to match Task 10; add a `private` Hash to `Response` if not present.)

**Step 2: Run red.**

**Step 3: Implement** the adapter interface and pipeline:

```crystal
# src/req_llm/http/adapter.cr
module ReqLLM::HTTP
  # Raw transport result before provider decoding.
  struct RawResponse
    getter status : Int32
    getter headers : ::HTTP::Headers
    getter body : String
    def initialize(@status, @headers, @body); end
  end

  module Adapter
    abstract def call(request : Request) : RawResponse
  end
end
```

```crystal
# src/req_llm/http/pipeline.cr
module ReqLLM::HTTP
  module Pipeline
    extend self

    def run(req : Request, adapter : Adapter) : ReqLLM::Response
      # 1. request steps (may short-circuit by returning a Response)
      req.request_steps.each do |(_name, step)|
        case result = step.call(req)
        when ReqLLM::Response then return result
        when Request          then req = result
        end
      end

      # 2. transport + 3. response steps, with error steps on raise
      begin
        raw = adapter.call(req)
        resp = ReqLLM::Response.from_raw(req, raw) # provider decode wires in here
        req.response_steps.each do |(_name, step)|
          req, resp = step.call(req, resp)
        end
        resp
      rescue ex
        req.error_steps.each do |(_name, step)|
          case handled = step.call(req, ex)
          when ReqLLM::Response then return handled
          when Exception        then ex = handled
          end
        end
        raise ex
      end
    end
  end
end
```

Note: `Response.from_raw` is a seam — for now a minimal version that stores the raw body; providers replace it via a response step (`decode_response`). Add a `spec/support/fake_adapter.cr` implementing `ReqLLM::HTTP::Adapter` with a `called?` flag.

**Step 4: Run green. Step 5: Commit** `feat: pipeline with short-circuit and error steps`.

---

## Task 13: Real adapter over HTTP::Client (tested against a local server)

**Files:**
- Create: `src/req_llm/http/client_adapter.cr`
- Test: `spec/req_llm/http/client_adapter_spec.cr`

**Step 1: Failing spec** — spin up a stdlib `HTTP::Server` on an ephemeral port in the spec, point a `Request` at it, assert the adapter returns the right status/body. Use `condition-based-waiting` (@superpowers:condition-based-waiting) to wait for the server to bind rather than sleeping.

```crystal
require "../../spec_helper"
require "http/server"

describe ReqLLM::HTTP::ClientAdapter do
  it "performs a real POST and returns status + body" do
    server = HTTP::Server.new do |ctx|
      ctx.response.status_code = 201
      ctx.response.print %({"echo":"hi"})
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      req = ReqLLM::HTTP::Request.new("POST",
        URI.parse("http://#{address.address}:#{address.port}/v1/chat"))
      req.body = %({"q":"hi"})
      raw = ReqLLM::HTTP::ClientAdapter.new.call(req)
      raw.status.should eq(201)
      raw.body.should contain("echo")
    ensure
      server.close
    end
  end
end
```

**Step 2: Run red.**

**Step 3: Implement `src/req_llm/http/client_adapter.cr`**

```crystal
require "http/client"

module ReqLLM::HTTP
  class ClientAdapter
    include Adapter

    def call(request : Request) : RawResponse
      body = case b = request.body
             when IO     then b.gets_to_end
             when Bytes  then String.new(b)
             else             b # String? | Nil
             end
      response = ::HTTP::Client.exec(
        request.method,
        request.url.to_s,
        headers: request.headers,
        body: body,
      )
      RawResponse.new(response.status_code, response.headers, response.body)
    end
  end
end
```

**Step 4: Run green. Step 5: Commit** `feat: HTTP::Client adapter`. (Streaming adapter comes in Phase 4.)

---

## Task 14: Shared steps — encode_body, decode wiring, error, retry, usage

Mirrors `./req_llm/lib/req_llm/step/*.ex` and `provider/defaults.ex`. These are reusable building blocks providers compose. Implement each as a small module returning a named step closure.

**Files:** Create `src/req_llm/steps.cr`; Test `spec/req_llm/steps_spec.cr`.

Implement, TDD each:
- `Steps.error` — a response step that raises `Error::API::Request.new(body, status: ...)` when `raw.status >= 400`.
- `Steps.retry` — an error step that retries `Error::API::Request` with status 429/5xx, honoring `Retry-After`, capped retries with backoff. Test with a counter-based fake adapter and `condition-based-waiting`.
- `Steps.usage` — a response step that reads usage from the decoded body and attaches `Usage` (provider supplies the extractor).

Each: failing spec → implement → green → commit. Final commit `feat: shared pipeline steps`.

---

## Task 15: Fixture step (record/replay)

The test harness. Reuses the short-circuit seam from Task 12. Mirrors `./req_llm/lib/req_llm/step/fixture.ex`.

**Files:**
- Create: `src/req_llm/fixture.cr`
- Test: `spec/req_llm/fixture_spec.cr`
- Fixtures dir: `spec/fixtures/`

**Behavior:**
- `Fixture.step(provider, name)` returns a request step.
- **Replay mode (default):** if `spec/fixtures/<provider>/<name>.json` exists, parse it into a `RawResponse`, decode to a `Response`, and short-circuit.
- **Record mode (`ENV["CR_LLM_FIXTURES"]? == "record"`):** do not short-circuit; instead append a response step that writes the raw status/headers/body to the fixture path.

**Step 1: Failing spec** — write a fixture JSON to a temp path, attach the replay step, run the pipeline with a `FakeAdapter` that would raise, assert the response came from the fixture (adapter never called).

**Steps 2–5.** Commit `feat: fixture record/replay step`.

---

## Task 16: LLMDB — spec parsing

Mirrors `LLMDB.Spec.parse`. Parse `"provider:model"` and `"provider:model@tag"`.

**Files:** Create `src/llmdb/spec.cr`; Test `spec/llmdb/spec_spec.cr`.

**Step 1: Failing spec**

```crystal
require "../spec_helper"

describe LLMDB::Spec do
  it "parses provider and model" do
    parsed = LLMDB::Spec.parse("openai:gpt-4o-mini")
    parsed.provider.should eq(:openai)
    parsed.model.should eq("gpt-4o-mini")
  end

  it "rejects a spec without a colon" do
    expect_raises(ReqLLM::Error::Invalid::Parameter) { LLMDB::Spec.parse("gpt-4o") }
  end
end
```

**Steps 2–5.** Commit `feat: LLMDB spec parsing`.

---

## Task 17: LLMDB::Model

Mirrors `LLMDB.Model`. Fields: `provider` (Symbol), `id`, `name`, `capabilities` (Hash(String, Bool) or typed), `limit` (context/output), `modalities`, `cost` (input/output/cached). `JSON::Serializable` for loading from vendored data.

**Files:** Create `src/llmdb/model.cr`; Test alongside.

**Step 1: Failing spec** — construct from a JSON object matching the models.dev shape; assert `supports?(:tools)`, `context_limit`, and `cost.input`. **Steps 2–5.** Commit `feat: LLMDB::Model`.

---

## Task 18: Vendored catalog + lookup

**Files:**
- Create: `src/llmdb/data/models.json` (a small hand-seeded subset for now: the three flagship models — replaced wholesale by the sync task in Task 19)
- Create: `src/llmdb/catalog.cr`
- Create: `src/llmdb.cr` facade (`LLMDB.model`, `LLMDB.models`, `LLMDB.providers`)
- Test: `spec/llmdb/catalog_spec.cr`

**Step 1: Seed `models.json`** with three entries (`openai:gpt-4o-mini`, `anthropic:claude-sonnet-4-5`, `google:gemini-2.5-flash`) using the real models.dev field shape (read `https://models.dev/api.json` once to copy exact keys; commit the subset).

**Step 2: Failing spec** — `LLMDB.model("openai:gpt-4o-mini")` returns a `Model` with the right `provider`, `context_limit`, and cost. Unknown spec raises.

**Step 3: Implement** the catalog: embed the JSON at compile time via `{{ read_file("#{__DIR__}/data/models.json") }}`, parse once into a memoized `Hash(String, Model)` keyed by `"provider:id"`. `LLMDB.model(spec)` parses via `LLMDB::Spec` and looks up.

**Steps 4–5.** Commit `feat: embedded models.dev catalog and lookup`.

---

## Task 19: sync_models automation task

**Files:**
- Create: `tasks/sync_models.cr`
- Modify: `shard.yml` (no new target needed; run via `crystal run tasks/sync_models.cr`)
- Create: `.github/workflows/sync-models.yml`

**Behavior:** fetch `https://models.dev/api.json`, normalize to our `Model` JSON shape, write `src/llmdb/data/models.json` sorted deterministically (stable key order so diffs are clean), and bump a `LLMDB::VERSION` date constant. The GitHub Action runs weekly, runs the task, and opens a PR if `git status` shows changes.

This task has no unit spec (it is I/O automation); verify manually:

Run: `crystal run tasks/sync_models.cr`
Expected: `src/llmdb/data/models.json` rewritten; `crystal spec` still green; the three flagship models still resolve.

Commit `feat: models.dev sync task and weekly CI`.

---

## Task 20: Options validation

Mirrors `nimble_options` usage in `./req_llm/lib/req_llm/provider/options.ex`.

**Files:** Create `src/req_llm/options.cr`; Test alongside.

**Step 1: Failing spec** — a schema with `temperature` (Float64, range 0.0..2.0), `max_tokens` (Int32?, default nil), `stream` (Bool, default false). Validating `{temperature: 0.7}` returns a typed result with `stream == false`; validating `{temperature: 3.0}` raises `Invalid::Parameter`; an unknown key raises.

**Steps 2–5.** Commit `feat: options schema validation`.

---

## Task 21: Provider abstraction, BaseProvider, Registry

Mirrors `./req_llm/lib/req_llm/provider.ex` and `provider/defaults.ex`.

**Files:** Create `src/req_llm/provider.cr`, `src/req_llm/base_provider.cr`, `src/req_llm/registry.cr`; Test `spec/req_llm/registry_spec.cr`.

**Step 1: Failing spec** — register a stub provider under `:stub`, assert `ReqLLM::Registry.fetch(:stub)` returns it and an unknown id raises `Invalid::Parameter`.

**Step 2–3:** Define the `Provider` module (abstract methods from the design §4), a `BaseProvider` abstract class with default `extract_usage`/`attach_stream`, and a `Registry` mapping symbols to instances. **Steps 4–5.** Commit `feat: provider abstraction and registry`.

---

## Task 22: OpenAI provider — request encoding (golden)

Mirrors `./req_llm/lib/req_llm/providers/openai.ex` chat encoding. This is where the **golden-encoding fidelity gate** starts.

**Files:**
- Create: `src/req_llm/providers/openai.cr`
- Test: `spec/req_llm/providers/openai_spec.cr`
- Golden: `spec/golden/openai/chat_basic.json`

**Step 1: Capture the golden body.** From the Elixir lib, encode a fixed input (`system: "You are terse."`, `user: "Hi"`, `model: gpt-4o-mini`, `temperature: 0.7`) and save the exact request JSON to `spec/golden/openai/chat_basic.json`. (Read `req_llm`'s OpenAI encoder to reproduce the shape: `model`, `messages: [{role, content}]`, `temperature`, etc.)

**Step 2: Failing spec**

```crystal
require "../../spec_helper"

describe ReqLLM::Providers::OpenAI do
  it "encodes a basic chat body matching the golden" do
    ctx = ReqLLM::Context.new([
      ReqLLM::Message.new(ReqLLM::Role::System, "You are terse."),
      ReqLLM::Message.new(ReqLLM::Role::User, "Hi"),
    ])
    model = LLMDB.model("openai:gpt-4o-mini")
    body = ReqLLM::Providers::OpenAI.new.encode_chat_body(model, ctx, {temperature: 0.7})
    expected = JSON.parse(File.read("spec/golden/openai/chat_basic.json"))
    JSON.parse(body).should eq(expected)
  end
end
```

**Step 3: Implement** `encode_chat_body` (and the auth/`attach` wiring) to satisfy the golden. **Steps 4–5.** Commit `feat: OpenAI chat request encoding with golden test`.

---

## Task 23: OpenAI provider — response decoding (fixture)

**Files:**
- Modify: `src/req_llm/providers/openai.cr` (add `decode_response`)
- Test: `spec/req_llm/providers/openai_decode_spec.cr`
- Fixture: `spec/fixtures/openai/chat_basic.json` (a real recorded Chat Completions response; hand-author from the OpenAI docs shape if no key available)

**Step 1: Failing spec** — feed the fixture body to `decode_response`, assert the resulting `Response.text`, `finish_reason`, and `usage.input_tokens`/`output_tokens`.

**Steps 2–5.** Commit `feat: OpenAI response decoding`.

---

## Task 24: ReqLLM.generate_text facade — end-to-end via fixture

The payoff. Mirrors `./req_llm/lib/req_llm/generation.ex` + the `ReqLLM` facade.

**Files:**
- Create: `src/req_llm/generation.cr`
- Modify: `src/cr_llm.cr` (define `ReqLLM.generate_text`)
- Test: `spec/req_llm/generate_text_spec.cr`

**Step 1: Failing spec**

```crystal
require "../spec_helper"

describe "ReqLLM.generate_text" do
  it "returns text from a recorded fixture without network" do
    resp = ReqLLM.generate_text("openai:gpt-4o-mini", "Hi",
      fixture: "chat_basic")
    resp.text.should_not be_empty
    resp.finish_reason.should eq("stop")
  end
end
```

**Step 2: Run red.**

**Step 3: Implement** `generate_text`:
1. `LLMDB.model(spec)` → model.
2. `Registry.fetch(model.provider)` → provider.
3. Build `Context` from the string/messages input.
4. `provider.prepare_request(:chat, model, context, opts)` → `HTTP::Request`, with `attach` wiring `encode_body`/`decode_response`/`error`/`usage` steps.
5. When `fixture:` is given, prepend `Fixture.step(:openai, name)` (replay) so the adapter is never hit.
6. `Pipeline.run(req, ClientAdapter.new)` → `Response`.

**Step 4: Run green** — fully offline via the fixture. **Step 5: Commit** `feat: generate_text end-to-end (OpenAI, fixture-backed)`.

---

## Task 25: OpenAI tool calls (encode + decode)

**Files:** Modify `src/req_llm/providers/openai.cr`; add golden `spec/golden/openai/chat_tools.json` and fixture `spec/fixtures/openai/chat_tools.json`.

TDD: encode a request with a `Tool` (assert `tools`/`tool_choice` shape against golden); decode a tool-call response into `Response.tool_calls`. Commit `feat: OpenAI tool calling`.

---

## Phase 1 exit checkpoint

Run: `crystal tool format --check && crystal spec`
Expected: all green, formatted. `ReqLLM.generate_text("openai:gpt-4o-mini", "Hi", fixture: "chat_basic")` works offline; golden specs pin the request shape.

Use @superpowers:requesting-code-review here before starting Phase 2.

---

# Phase 2 — Streaming (roadmap)

Expand each into TDD tasks when reached:

1. **SSE parser** (`src/req_llm/streaming/sse.cr`) — incremental `event:`/`data:` framing from an `IO`; spec feeds a `IO::Memory` of raw SSE and asserts parsed events. Mirrors `streaming/sse.ex`.
2. **Streaming adapter** (`src/req_llm/http/stream_adapter.cr`) — `HTTP::Client` block form yields the body `IO`; produce events behind the same `Request`.
3. **ChunkAccumulator** (`src/req_llm/streaming/accumulator.cr`) — fold `StreamChunk`s into a final `Response`; reassemble tool-call fragments; capture usage from the terminal meta chunk. Mirrors `provider/chunk_accumulator.ex`.
4. **StreamResponse + fibers/Channel** — producer fiber → bounded `Channel` → `Enumerable` consumer; `join` collapses to `Response`.
5. **OpenAI + Anthropic stream decode** — `decode_stream_event` per provider; recorded SSE fixtures.
6. **`ReqLLM.stream_text`** facade. End-to-end via recorded SSE fixture.

# Phase 3 — Anthropic provider (roadmap)

Mirrors `providers/anthropic*.ex`. TDD tasks: auth (`x-api-key` + `anthropic-version`), `encode_chat_body` (hoist `system`, content blocks) with golden, `decode_response` (content blocks → parts, thinking) with fixture, tool calls, streaming decode. Register under `:anthropic`. Reuse every shared step.

# Phase 4 — Google (Gemini) provider (roadmap)

Mirrors `providers/google*.ex`. TDD tasks: auth (key via query/header), `encode_chat_body` (`contents`/`parts`, `generateContent`) with golden, `decode_response`, `functionDeclarations` tool calls, `streamGenerateContent` decode. Register under `:google`.

# Phase 5 — Structured output (roadmap)

Mirrors `schema.ex`, `generation.ex` object path. TDD tasks: `ReqLLM.schema({...})` → JSON Schema; `generate_object` via OpenAI `response_format: json_schema`; Anthropic/Google via synthetic tool call; validate returned JSON against the schema (`Error::Validation` on mismatch). Goldens + fixtures per provider.

# Phase 6 — CI and release hardening (roadmap)

- `.github/workflows/ci.yml` — `crystal tool format --check` + `crystal spec` on push.
- Wire the weekly `sync-models.yml` from Task 19 to open PRs.
- Live integration specs behind a manual workflow + tag (real keys).
- README with the public API and a provider-support matrix generated from `LLMDB`.

---

## Skills to use during execution

- @superpowers:test-driven-development — every task.
- @superpowers:condition-based-waiting — server/retry specs (Tasks 13, 14).
- @superpowers:requesting-code-review — at each phase exit checkpoint.
- @superpowers:verification-before-completion — before any "done" claim.
