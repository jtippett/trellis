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
- **Phase 1 is fully detailed below.** Phases 2+ are task-level roadmaps; expand each into bite-sized TDD steps (same structure) when reached, using what Phase 1 taught you. Do not pre-expand — provider detail depends on the OpenAI slice.
- **Definition of done for Phase 1:** `ReqLLM.generate_text("openai:gpt-4o-mini", "Hi")` returns a `Response` from a recorded fixture with no network, and a golden-encoding spec pins the request body. All specs green, formatted, committed.

---

## Pipeline contract (read before Tasks 10–15)

This is the load-bearing model. It faithfully reproduces Req's plugin pipeline while staying type-safe in Crystal. Codex review round 1 flagged that an earlier draft conflated transport and semantic responses; this section is the corrected contract every pipeline task must honor.

**Two response types, never conflated:**

- **`ReqLLM::HTTP::Response`** — transport level. Fields: `status : Int32`, `headers : HTTP::Headers`, `body : String` (raw bytes as received), `decoded : ReqLLM::Response?` (populated by the provider's decode step), `private : Hash(Symbol, String)` (small scratch). This is what response steps fold over.
- **`ReqLLM::Response`** — semantic level (the public result). It is produced by the decode step and stored in `HTTP::Response#decoded`. `Pipeline.run` returns `http_response.decoded`.

**`ReqLLM::HTTP::Request` carries typed state, not JSON bags** (codex blocker 1 — `JSON::Any` cannot hold a `Context`, `LLMDB::Model`, tools, or procs):

- `method`, `url`, `headers`, `body`
- `model : LLMDB::Model?`, `context : ReqLLM::Context?`, `operation : Symbol` (default `:chat`)
- `options : ReqLLM::Options::Validated?` (typed, validated request options)
- `retry : ReqLLM::RetryPolicy?` (read by the pipeline, not a step)
- `fixture : String?` (fixture name; `attach` wires the fixture step when set)
- `request_steps`, `response_steps`, `error_steps` (named)

**`Pipeline.run(req, adapter)` order** (codex blockers 2, 3, 4):

1. **Request steps** run in order. A step returns either a `Request` (continue) or an `HTTP::Response` (short-circuit — e.g. fixture replay supplies a raw response). On short-circuit, **skip transport but still run response steps** (so decode + usage execute on the fixture). Upstream fixture replay behaves exactly this way (`req_llm/test/support/fixture.ex:112`).
2. **Transport with retry** (only if not short-circuited): the pipeline calls `adapter.call(req)` inside a retry loop governed by `req.retry` — retry on status 429/5xx honoring `Retry-After`, capped with backoff. Retry lives **in the pipeline around the adapter**, never in an error step (an error step has no adapter to re-run).
3. **Response steps** fold `(req, http_resp) -> {req, http_resp}` in the fixed order `[:error, :decode_response, :usage]` (matching upstream `defaults.ex:585-591` and the Task 21 assertions): `Steps.error` raises `Error::API::Request` when `http_resp.status >= 400` (so a 4xx/5xx body is never decoded); then provider `decode_response` sets `http_resp.decoded`; then `Steps.usage` reads the decoded body and attaches `Usage`. In record mode `:fixture_capture` is appended after these.
4. **Error steps** transform a raised exception (terminal augmentation only). On any raise during 2–3, fold error steps, then re-raise.
5. Return `http_resp.decoded || raise Error::API::Response.new("decode produced no response")`.

**Provider `attach` step order is fixed** (codex high — upstream `provider/defaults.ex:585-591`). `attach(req)` must, in this order:

1. set `Content-Type`/auth headers and store `req.model`;
2. set `req.retry` policy (pipeline reads it; not a step);
3. append `Steps.error` (**response** step — raises on `status >= 400`);
4. prepend `encode_body` (**request** step — runs first);
5. append `decode_response` (**response** step);
6. append `Steps.usage` (**response** step);
7. wire the **fixture** last (see below).

This yields request-step order `[encode_body, …, fixture-replay]` and response-step order `[error, decode_response, usage, fixture-capture]`. The model lives in `req.model` (typed), so decode/usage/fixture all read it the same way.

**The fixture has two halves** (codex high — reconciles "request step" vs "response step"): a **request-step half** (replay) appended *last* among request steps, which short-circuits with the recorded `HTTP::Response`; and, in record mode only, a **response-step half** (capture) appended *last* among response steps, which writes the raw response to disk. In replay mode only the request-step half is wired; in record mode only the response-step half is wired. The facade never prepends the fixture — `attach` wires it; the facade only supplies the fixture *name*.

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

**Step 3: Write the entrypoint `src/cr_llm.cr`** — single require manifest:

```crystal
require "json"
require "./req_llm/error"

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

**Step 6: Run it.** `crystal spec spec/scaffold_spec.cr` → expect FAIL (`./req_llm/error` missing), then create the file in Task 2. (To keep this task self-green, temporarily comment the error require, or do Task 2 before first running specs. Prefer: write Task 2's file now since the require points at it.)

**Step 7: Commit**

```bash
crystal tool format
git add shard.yml .gitignore src/cr_llm.cr spec/
git commit -m "chore: scaffold cr_llm shard"
```

---

## Task 2: Error hierarchy

Mirrors `splode` usage in `./req_llm/lib/req_llm/error.ex`.

**Files:** Create `src/req_llm/error.cr`; Test `spec/req_llm/error_spec.cr`.

**Step 1: Failing spec**

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

**Step 2: Run red** — `undefined constant ReqLLM::Error`.

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

**Step 4: Run green. Step 5: Commit** `feat: error hierarchy`.

---

## Task 3: Key resolution and .env loader

Mirrors `./req_llm/lib/req_llm/keys.ex` and dotenvy. Precedence: explicit `api_key` → `ENV[<KEY>]` (loaded from `.env`).

**Files:** Create `src/req_llm/keys.cr`; Test `spec/req_llm/keys_spec.cr`.

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

**Step 2: Run red. Step 3: Implement `src/req_llm/keys.cr`**

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
      parse_env(File.read(path)).each { |k, v| ENV[k] ||= v }
    end
  end
end
```

**Step 4: green. Step 5: Commit** `feat: api key resolution and .env loader`.

---

## Task 4: Content model — enums and ContentPart

Mirrors `./req_llm/lib/req_llm/message/content_part.ex`.

**Files:** Create `src/req_llm/content_part.cr`; Test `spec/req_llm/content_part_spec.cr`.

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

**Step 2: red. Step 3: Implement `src/req_llm/content_part.cr`**

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

Add `require "./req_llm/content_part"` to `src/cr_llm.cr`.

**Step 4: green. Step 5: Commit** `feat: ContentPart and role/part enums`.

---

## Task 5: Message

Mirrors `./req_llm/lib/req_llm/message.ex`. Fields: `role`, `content` (Array(ContentPart)), `name`, `tool_call_id`, `tool_calls`, plus lossless round-trip metadata.

**Files:** Create `src/req_llm/message.cr`; Test `spec/req_llm/message_spec.cr`.

**Step 1: Failing spec**

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

**Step 2: red. Step 3: Implement** — constructor overloads for `String` (wrap to one text part) and `Array(ContentPart)`; `valid?` returns true when content non-empty or `tool_calls`/`tool_call_id` present. **Step 4: green. Step 5: Commit** `feat: Message`.

---

## Task 6: Context

Mirrors `./req_llm/lib/req_llm/context.ex`. **Upstream Context carries both `messages` and `tools`** (`context.ex:36`) — include `tools` (codex medium). A `class` wrapping `Array(Message)` + `Array(Tool)` with `append`, `prepend`, `concat`, `to_a`, and the `user`/`assistant`/`system` builder helpers.

**Files:** Create `src/req_llm/context.cr`; Test `spec/req_llm/context_spec.cr`.

**Step 1: Failing spec** covering: `Context.new(messages)`, `<<`/`append` adds a message, `Context.user("hi")` produces a `Message` of role `User`, and `Context.new(messages, tools)` exposes `#tools`.

**Step 2–5:** red → implement → green → commit `feat: Context`.

---

## Task 7: ToolCall and Tool

Mirrors `tool_call.ex` and `tool.ex`. We flatten the wire-nested OpenAI shape (`type`, `function: {name, arguments}`) into idiomatic `ToolCall(id, name, arguments)`, **but the plan requires (a) provider wire-conversion helpers `to_wire`/`from_wire` and (b) round-trip preservation of `builtin?` and `metadata` flags** (codex medium — upstream `tool_call.ex:39` keeps nested function + builtin/metadata). `Tool`: `name`, `description`, `parameter_schema` (Hash describing JSON Schema), `callback` (Proc), `to_json_schema`.

**Files:** Create `src/req_llm/tool_call.cr`, `src/req_llm/tool.cr`; Tests alongside.

**Step 1: Failing specs** — `ToolCall#args_map` parses the JSON string to `Hash(String, JSON::Any)`; `ToolCall.from_wire(json).to_wire` round-trips id/name/arguments/metadata; `Tool#to_json_schema` emits `{"type" => "object", "properties" => {...}, "required" => [...]}`; `Tool.new` rejects an invalid name (`valid_name?`). **Steps 2–5.** Commit `feat: Tool and ToolCall`.

---

## Task 8: Usage and cost

Mirrors `usage.ex` and `usage/cost.ex`. `Usage`: `input_tokens`, `output_tokens`, `reasoning_tokens`, `cached_tokens`, and `cost` derived from `LLMDB::Model` pricing.

**Files:** Create `src/req_llm/usage.cr`; Test alongside.

**Step 1: Failing spec** — given token counts and a pricing pair `{input: 0.15, output: 0.60}` (USD per 1M tokens), `Usage.cost(...)` returns the correct dollar amount. **Steps 2–5.** Commit `feat: Usage and cost`.

---

## Task 9: StreamChunk

Mirrors `stream_chunk.ex`. `type` enum (`Content | Thinking | ToolCall | Meta`), plus `text`, `name`, `arguments`, `metadata`. Constructors `.text`, `.thinking`, `.tool_call`, `.meta`.

**Files:** Create `src/req_llm/stream_chunk.cr`; Test alongside. TDD. Commit `feat: StreamChunk`.

---

## Task 10: Response and FinishReason

Mirrors `response.ex`. This task **fully specifies the semantic `Response`** so later tasks share one consistent shape (codex blocker 5). `finish_reason` is a **Crystal enum**, not a string (codex high — upstream normalizes to atoms `response.ex:38`, `defaults.ex:1551`).

**Files:** Create `src/req_llm/response.cr`; Test `spec/req_llm/response_spec.cr`.

**Step 1: Failing spec**

```crystal
require "../spec_helper"

describe ReqLLM::Response do
  it "extracts text from the assistant message" do
    msg = ReqLLM::Message.new(ReqLLM::Role::Assistant,
      [ReqLLM::ContentPart.text("Hello "), ReqLLM::ContentPart.text("world")])
    resp = ReqLLM::Response.new(model: "openai:gpt-4o-mini", message: msg,
      finish_reason: ReqLLM::FinishReason::Stop)
    resp.text.should eq("Hello world")
    resp.finish_reason.should eq(ReqLLM::FinishReason::Stop)
    resp.ok?.should be_true
  end

  it "normalizes wire finish reasons" do
    ReqLLM::FinishReason.from_wire("stop").should eq(ReqLLM::FinishReason::Stop)
    ReqLLM::FinishReason.from_wire("tool_calls").should eq(ReqLLM::FinishReason::ToolCalls)
    ReqLLM::FinishReason.from_wire("length").should eq(ReqLLM::FinishReason::Length)
  end
end
```

**Step 2: red. Step 3: Implement**

```crystal
module ReqLLM
  enum FinishReason
    Stop
    Length
    ToolCalls
    ContentFilter
    Error
    Other

    def self.from_wire(value : String?) : FinishReason
      case value
      when "stop", "end_turn", "STOP"            then Stop
      when "length", "max_tokens", "MAX_TOKENS"  then Length
      when "tool_calls", "tool_use"              then ToolCalls
      when "content_filter", "SAFETY"            then ContentFilter
      when nil                                   then Other
      else                                            Other
      end
    end
  end

  class Response
    getter model : String
    getter context : Context?
    getter message : Message?
    getter usage : Usage?
    getter finish_reason : FinishReason?
    getter object : JSON::Any?
    property error : Exception?

    def initialize(@model : String, *, @context = nil, @message = nil,
                   @usage = nil, @finish_reason = nil, @object = nil, @error = nil)
    end

    def text : String
      msg = @message
      return "" unless msg
      String.build do |io|
        msg.content.each { |p| io << p.text if p.type.text? && p.text }
      end
    end

    def tool_calls : Array(ToolCall)
      @message.try(&.tool_calls) || [] of ToolCall
    end

    def ok? : Bool
      @error.nil?
    end
  end
end
```

**Step 4: green. Step 5: Commit** `feat: Response and FinishReason enum`.

---

## Task 11: HTTP::Request, HTTP::Response, named steps

The pipeline core. Implements the **Pipeline contract** section above. Mirrors `./req_llm/lib/req_llm/provider.ex`.

**Files:** Create `src/req_llm/http/request.cr`, `src/req_llm/http/response.cr`; Test `spec/req_llm/http/request_spec.cr`.

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

  it "carries typed model/context state, not JSON bags" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    req.operation.should eq(:chat)
    req.model.should be_nil
  end
end
```

**Step 2: red. Step 3: Implement `src/req_llm/http/response.cr`**

```crystal
require "http/headers"

module ReqLLM::HTTP
  class Response
    property status : Int32
    property headers : ::HTTP::Headers
    property body : String
    property decoded : ReqLLM::Response?
    property private : Hash(Symbol, String)

    def initialize(@status, @headers, @body)
      @decoded = nil
      @private = {} of Symbol => String
    end
  end
end
```

**Implement `src/req_llm/http/request.cr`**

```crystal
require "http/headers"
require "uri"
require "./response" # HTTP::Response, referenced by the step alias return types

# Minimal forward-declared types so this file compiles standalone. Each is
# reopened with real fields/methods later (Crystal allows reopening an empty
# struct): Options::Validated in Task 20, RetryPolicy in Task 14, LLMDB::Model
# in Task 17. The manifest (src/cr_llm.cr) must require content_part, message,
# context, and response BEFORE http/request so the real types win at link time.
module ReqLLM
  module Options
    struct Validated
    end
  end

  struct RetryPolicy
  end
end

module LLMDB
  class Model
  end
end

module ReqLLM::HTTP
  # A request step returns a Request (continue) or an HTTP::Response (short-circuit
  # into the response phase — e.g. fixture replay). Response/error steps fold pairs.
  alias RequestStepProc  = Request -> (Request | Response)
  alias ResponseStepProc = (Request, Response) -> {Request, Response}
  alias ErrorStepProc    = (Request, Exception) -> Exception

  class Request
    property method : String
    property url : URI
    property headers : ::HTTP::Headers
    property body : (IO | String | Bytes | Nil)

    # Typed pipeline state (codex blocker 1: never JSON::Any for these).
    property model : LLMDB::Model?
    property context : ReqLLM::Context?
    property operation : Symbol
    property options : ReqLLM::Options::Validated?
    property retry : ReqLLM::RetryPolicy?
    property fixture : String? # fixture name; attach wires the fixture step when set

    getter request_steps : Array({Symbol, RequestStepProc})
    getter response_steps : Array({Symbol, ResponseStepProc})
    getter error_steps : Array({Symbol, ErrorStepProc})

    def initialize(@method, @url, @headers = ::HTTP::Headers.new, @body = nil)
      @operation = :chat
      @model = nil
      @context = nil
      @options = nil
      @fixture = nil
      @retry = nil
      @request_steps = [] of {Symbol, RequestStepProc}
      @response_steps = [] of {Symbol, ResponseStepProc}
      @error_steps = [] of {Symbol, ErrorStepProc}
    end

    def append_request_step(name : Symbol, &block : RequestStepProc)
      @request_steps << {name, block}; self
    end

    def prepend_request_step(name : Symbol, &block : RequestStepProc)
      @request_steps.unshift({name, block}); self
    end

    def replace_request_step(name : Symbol, &block : RequestStepProc)
      idx = @request_steps.index { |(n, _)| n == name }
      idx ? (@request_steps[idx] = {name, block}) : (@request_steps << {name, block})
      self
    end

    def append_response_step(name : Symbol, &block : ResponseStepProc)
      @response_steps << {name, block}; self
    end

    def append_error_step(name : Symbol, &block : ErrorStepProc)
      @error_steps << {name, block}; self
    end

    def request_step_names : Array(Symbol)
      @request_steps.map { |(n, _)| n }
    end
  end
end
```

> Note: the stub `Options::Validated` and `RetryPolicy` at the top of the file are replaced by the real types in Tasks 20 and 14. Keep them empty here so the file compiles standalone.

**Step 4: green. Step 5: Commit** `feat: HTTP::Request/Response with named step pipeline`.

---

## Task 12: Pipeline — short-circuit, transport, response folding

Implements steps 1, 3, 5 of the Pipeline contract (retry, step 2, lands in Task 14). Mirrors how `Req` runs steps.

**Files:** Create `src/req_llm/http/adapter.cr`, `src/req_llm/http/pipeline.cr`, `spec/support/fake_adapter.cr`; Test `spec/req_llm/http/pipeline_spec.cr`.

**Step 1: Failing spec**

```crystal
require "../../spec_helper"
require "../../support/fake_adapter"

describe ReqLLM::HTTP::Pipeline do
  it "short-circuits transport but still runs response steps" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    canned = ReqLLM::HTTP::Response.new(200, HTTP::Headers.new, %({"ok":true}))
    req.append_request_step(:fixture) { |_| canned }
    req.append_response_step(:decode) do |r, resp|
      resp.decoded = ReqLLM::Response.new(model: "x",
        message: ReqLLM::Message.new(ReqLLM::Role::Assistant, "hi"))
      {r, resp}
    end
    adapter = FakeAdapter.new # raises if called
    out = ReqLLM::HTTP::Pipeline.run(req, adapter)
    adapter.called?.should be_false   # transport skipped
    out.text.should eq("hi")          # decode still ran
  end

  it "runs the adapter then folds response steps" do
    req = ReqLLM::HTTP::Request.new("POST", URI.parse("https://x/y"))
    adapter = FakeAdapter.new(status: 200, body: %({"ok":true}))
    req.append_response_step(:decode) do |r, resp|
      resp.decoded = ReqLLM::Response.new(model: "x")
      {r, resp}
    end
    ReqLLM::HTTP::Pipeline.run(req, adapter)
    adapter.called?.should be_true
  end
end
```

**Step 2: red. Step 3: Implement**

```crystal
# src/req_llm/http/adapter.cr
module ReqLLM::HTTP
  module Adapter
    abstract def call(request : Request) : Response
  end
end
```

```crystal
# src/req_llm/http/pipeline.cr
module ReqLLM::HTTP
  module Pipeline
    extend self

    def run(req : Request, adapter : Adapter) : ReqLLM::Response
      http_resp : Response? = nil

      req.request_steps.each do |(_name, step)|
        case result = step.call(req)
        when Response then http_resp = result; break
        when Request  then req = result
        end
      end

      begin
        http_resp ||= perform(req, adapter) # Task 14 swaps in retry-aware perform
        req.response_steps.each do |(_name, step)|
          req, http_resp = step.call(req, http_resp.not_nil!)
        end
      rescue ex
        req.error_steps.each { |(_n, s)| ex = s.call(req, ex) }
        raise ex
      end

      http_resp.not_nil!.decoded ||
        raise ReqLLM::Error::API::Response.new("decode produced no response")
    end

    # Plain transport; Task 14 replaces with retry-aware version.
    def perform(req : Request, adapter : Adapter) : Response
      adapter.call(req)
    end
  end
end
```

`spec/support/fake_adapter.cr`: a class `include ReqLLM::HTTP::Adapter` with a `called?` flag; `call` returns a configured `HTTP::Response` or raises if constructed with no body.

**Step 4: green. Step 5: Commit** `feat: pipeline with short-circuit and response folding`.

---

## Task 13: Real adapter over HTTP::Client (local-server test)

**Files:** Create `src/req_llm/http/client_adapter.cr`; Test `spec/req_llm/http/client_adapter_spec.cr`.

**Step 1: Failing spec** — start a stdlib `HTTP::Server` on an ephemeral port, point a `Request` at it, assert status/body. Use @superpowers:condition-based-waiting to wait for the bind rather than sleeping.

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
      resp = ReqLLM::HTTP::ClientAdapter.new.call(req)
      resp.status.should eq(201)
      resp.body.should contain("echo")
    ensure
      server.close
    end
  end
end
```

**Step 2: red. Step 3: Implement `src/req_llm/http/client_adapter.cr`**

```crystal
require "http/client"

module ReqLLM::HTTP
  class ClientAdapter
    include Adapter

    def call(request : Request) : Response
      body = case b = request.body
             when IO    then b.gets_to_end
             when Bytes then String.new(b)
             else            b # String? | Nil
             end
      raw = ::HTTP::Client.exec(request.method, request.url.to_s,
        headers: request.headers, body: body)
      Response.new(raw.status_code, raw.headers, raw.body)
    end
  end
end
```

**Step 4: green. Step 5: Commit** `feat: HTTP::Client adapter`.

---

## Task 14: Shared steps + retry-aware transport

Mirrors `./req_llm/lib/req_llm/step/*.ex` and `provider/defaults.ex`. **Retry lives in the pipeline, not an error step** (codex blocker 4 — upstream attaches retry config before execution and the engine performs it, `step/retry.ex:52`).

**Files:** Create `src/req_llm/retry_policy.cr`, `src/req_llm/steps.cr`; Modify `src/req_llm/http/pipeline.cr` (`perform` → retry loop); Test `spec/req_llm/steps_spec.cr`, `spec/req_llm/retry_spec.cr`.

TDD, each its own red→green→commit:
- **`RetryPolicy`** — `max_retries`, `base_delay`, predicate `retryable?(status)` (429/5xx), plus `RetryPolicy.default`. The policy lives on `Request#retry`; the pipeline uses `req.retry || RetryPolicy.default`.
- **Pipeline `perform` retry loop** — call adapter; if `(req.retry || RetryPolicy.default).retryable?(resp.status)` and attempts remain, sleep `Retry-After`-or-backoff and retry. Test with a counter-based `FakeAdapter` that returns 503 twice then 200; assert 3 calls and a final 200. Use @superpowers:condition-based-waiting patterns (poll the counter), keep delays tiny in test via an injected clock/zero base_delay.
- **`Steps.error`** — response step: `raise Error::API::Request.new(resp.body, status: resp.status)` when `resp.status >= 400`. Reads `resp.status` directly (the contract preserves it).
- **`Steps.usage`** — response step: read `resp.decoded.try(&.usage)` already set by decode, or compute from the decoded body + `req.model` pricing; attach `Usage`.

Final commit `feat: retry-aware transport and shared steps`.

---

## Task 15: Fixture step (record/replay)

The test harness, built on the Pipeline contract's short-circuit-then-still-fold behavior (codex blocker 3). Mirrors `./req_llm/test/support/fixture.ex`.

**Fixture JSON schema (ours — specified here so agents don't invent incompatible files, codex medium):**

```json
{
  "status": 200,
  "headers": {"content-type": "application/json"},
  "body": "<raw response body string>"
}
```

(Phase 2 streaming extends this with `"stream": ["<sse frame>", ...]` instead of `"body"`.)

**Behavior:**
- `Fixture.step(provider, name)` returns a **request step**.
- **Replay (default):** if `spec/fixtures/<provider>/<name>.json` exists, parse it into a raw `HTTP::Response` (status/headers/body, `decoded == nil`) and **return it** — the pipeline skips transport but still runs the response steps in contract order `Steps.error`/`decode_response`/`Steps.usage`. No network, no keys.
- **Record (`ENV["CR_LLM_FIXTURES"]? == "record"`):** do not short-circuit; append a record-only response step **last** (named `:fixture_capture`, per the contract and Task 21) that serializes `{status, headers, body}` to the fixture path before returning the pair unchanged.

**Files:** Create `src/req_llm/fixture.cr`; Test `spec/req_llm/fixture_spec.cr`; Fixtures dir `spec/fixtures/`.

**Step 1: Failing spec** — write a fixture JSON to disk, attach `Fixture.step` + a decode response step, run the pipeline with a `FakeAdapter` that raises; assert the decoded text came from the fixture body and the adapter was never called.

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

Mirrors `LLMDB.Model`. Define as a **`class`** (reopening the empty stub from Task 11). Fields: `provider` (Symbol), `id`, `name`, `capabilities`, `limit` (context/output), `modalities`, `cost` (input/output/cached). `JSON::Serializable` for loading vendored data.

**Files:** Create `src/llmdb/model.cr`; Test alongside.

**Step 1: Failing spec** — construct from a JSON object matching the models.dev shape; assert `supports?(:tools)`, `context_limit`, `cost.input`. **Steps 2–5.** Commit `feat: LLMDB::Model`.

---

## Task 18: Vendored catalog + lookup (offline-seedable)

**Files:** Create `src/llmdb/data/models.json`, `src/llmdb/catalog.cr`, `src/llmdb.cr` facade; Test `spec/llmdb/catalog_spec.cr`.

**Seeding (offline-first — codex high; do not require network here):** seed `models.json` with the three flagship models, sourced in priority order:
1. `req_llm/priv/supported_models.json` (checked in locally) if it contains them, else
2. a committed minimal hand-authored subset using the models.dev field shape.

The live `models.dev` fetch is **Task 19's** job, not a prerequisite for this task.

**Step 1: Seed `models.json`** with `openai:gpt-4o-mini`, `anthropic:claude-sonnet-4-5`, `google:gemini-2.5-flash`.

**Step 2: Failing spec** — `LLMDB.model("openai:gpt-4o-mini")` returns a `Model` with the right `provider`, `context_limit`, cost. Unknown spec raises.

**Step 3: Implement** the catalog: embed the JSON at compile time via `{{ read_file("#{__DIR__}/data/models.json") }}`, parse once into a memoized `Hash(String, Model)` keyed `"provider:id"`. `LLMDB.model(spec)` parses via `LLMDB::Spec` and looks up.

**Steps 4–5.** Commit `feat: embedded models.dev catalog and lookup`.

---

## Task 19: sync_models automation task

**Files:** Create `tasks/sync_models.cr`, `.github/workflows/sync-models.yml`.

**Behavior:** fetch `https://models.dev/api.json`, normalize to our `Model` JSON shape, write `src/llmdb/data/models.json` with deterministic key order (clean diffs), bump a `LLMDB::VERSION` date constant. **Offline fallback:** accept `--source <path>` to normalize from a local file (e.g. `req_llm/priv/supported_models.json`) when the network is unavailable. The GitHub Action runs weekly and opens a PR when the data changed.

No unit spec (I/O automation); verify manually:
`crystal run tasks/sync_models.cr -- --source req_llm/priv/supported_models.json` → `models.json` rewritten; `crystal spec` still green; the three flagship models still resolve.

Commit `feat: models.dev sync task and weekly CI`.

---

## Task 20: Options validation

Mirrors `nimble_options` usage in `./req_llm/lib/req_llm/provider/options.ex`. Replaces the Task 11 stub `Options::Validated` with the real type.

**Files:** Create `src/req_llm/options.cr`; Test alongside.

**Step 1: Failing spec** — schema with `temperature` (Float64, range 0.0..2.0), `max_tokens` (Int32?, default nil), `stream` (Bool, default false). Validating `{temperature: 0.7}` returns a typed `Validated` with `stream == false`; `{temperature: 3.0}` raises `Invalid::Parameter`; an unknown key raises. **Steps 2–5.** Commit `feat: options schema validation`.

---

## Task 21: Provider abstraction, BaseProvider, Registry

Mirrors `./req_llm/lib/req_llm/provider.ex` and `provider/defaults.ex`. **`BaseProvider#attach` must follow the fixed step order in the Pipeline contract section** (codex high), storing the model in `req.model`.

**Files:** Create `src/req_llm/provider.cr`, `src/req_llm/base_provider.cr`, `src/req_llm/registry.cr`; Test `spec/req_llm/registry_spec.cr` and `spec/req_llm/base_provider_spec.cr`.

**Step 1: Failing specs** — (a) register a stub provider under `:stub`; `Registry.fetch(:stub)` returns it, unknown id raises `Invalid::Parameter`. (b) a stub provider's `attach(req)` in **replay** mode sets `req.model` and yields request-step names `[:encode_body, :fixture]` and response-step names `[:error, :decode_response, :usage]`; in **record** mode the response steps end with `:fixture_capture` and the request steps omit `:fixture`. Assert exactly the contract order.

**Step 2–3:** Define `Provider` module (abstract methods from design §4 + Pipeline contract), `BaseProvider` abstract class implementing `attach` in the fixed order with default `extract_usage`/`attach_stream`, and a `Registry`. **Steps 4–5.** Commit `feat: provider abstraction and registry`.

---

## Task 22: OpenAI provider — request encoding (canonical golden)

Mirrors `./req_llm/lib/req_llm/providers/openai.ex` chat encoding. Starts the **encoding fidelity gate**.

**Golden provenance (codex high — no Elixir runtime assumed):** create `spec/golden/openai/chat_basic.json` as a **canonical encoding spec** authored from the upstream encoder source (`providers/openai.ex` + `provider/defaults.ex` body builders) and any checked-in request bodies under `req_llm/test/`. Label it canonical, not parity. If an Elixir runtime later becomes available, regenerate it from the live encoder and diff — but the build does not block on that.

**Files:** Create `src/req_llm/providers/openai.cr`; Test `spec/req_llm/providers/openai_spec.cr`; Golden `spec/golden/openai/chat_basic.json`.

**Step 1: Author the golden** for a fixed input (`system: "You are terse."`, `user: "Hi"`, `model: gpt-4o-mini`, `temperature: 0.7`): `{"model","messages":[{role,content}],"temperature"}`.

**Step 2: Failing spec**

```crystal
require "../../spec_helper"

describe ReqLLM::Providers::OpenAI do
  it "encodes a basic chat body matching the canonical golden" do
    ctx = ReqLLM::Context.new([
      ReqLLM::Message.new(ReqLLM::Role::System, "You are terse."),
      ReqLLM::Message.new(ReqLLM::Role::User, "Hi"),
    ])
    model = LLMDB.model("openai:gpt-4o-mini")
    opts = ReqLLM::Options.validate({temperature: 0.7})
    body = ReqLLM::Providers::OpenAI.new.encode_chat_body(model, ctx, opts)
    JSON.parse(body).should eq(JSON.parse(File.read("spec/golden/openai/chat_basic.json")))
  end
end
```

**Step 3: Implement** `encode_chat_body` + auth/`attach` wiring to satisfy the golden. **Steps 4–5.** Commit `feat: OpenAI chat request encoding with golden test`.

---

## Task 23: OpenAI provider — response decoding (fixture)

**Files:** Modify `src/req_llm/providers/openai.cr` (add `decode_response`); Test `spec/req_llm/providers/openai_decode_spec.cr`; Fixture `spec/fixtures/openai/chat_basic.json` (real recorded Chat Completions response, or hand-authored from the documented shape).

**Step 1: Failing spec** — feed the fixture body through `decode_response`, assert `Response.text`, `finish_reason == FinishReason::Stop`, and `usage.input_tokens`/`output_tokens`. **Steps 2–5.** Commit `feat: OpenAI response decoding`.

---

## Task 24: ReqLLM.generate_text — end-to-end via fixture

The payoff. Mirrors `./req_llm/lib/req_llm/generation.ex` + the facade.

**Files:** Create `src/req_llm/generation.cr`; Modify `src/cr_llm.cr` (`ReqLLM.generate_text`); Test `spec/req_llm/generate_text_spec.cr`.

**Step 1: Failing spec**

```crystal
require "../spec_helper"

describe "ReqLLM.generate_text" do
  it "returns text from a recorded fixture without network" do
    resp = ReqLLM.generate_text("openai:gpt-4o-mini", "Hi", fixture: "chat_basic")
    resp.text.should_not be_empty
    resp.finish_reason.should eq(ReqLLM::FinishReason::Stop)
  end
end
```

**Step 2: red. Step 3: Implement** `generate_text`:
1. `LLMDB.model(spec)` → model; `Registry.fetch(model.provider)` → provider.
2. Build `Context` from the input; validate opts (`Options.validate`).
3. `provider.prepare_request(:chat, model, context, opts)` → `HTTP::Request`.
4. When `fixture:` is given, set the fixture name on the now-existing request (a dedicated `req.fixture : String?` field) — do **not** prepend a step in the facade (codex high). Then call `provider.attach(req)`, which wires steps in the contract order, sets `req.model`, and (replay mode) appends the fixture request-step half last so transport is skipped but response steps still decode.
5. `Pipeline.run(req, ClientAdapter.new)` → `Response`.

**Step 4: green** — fully offline via the fixture. **Step 5: Commit** `feat: generate_text end-to-end (OpenAI, fixture-backed)`.

---

## Task 25: OpenAI tool calls (encode + decode)

**Files:** Modify `src/req_llm/providers/openai.cr`; add golden `spec/golden/openai/chat_tools.json`, fixture `spec/fixtures/openai/chat_tools.json`.

TDD: encode a request with a `Tool` (assert `tools`/`tool_choice` shape against golden, using `Tool#to_json_schema` and `ToolCall#to_wire`); decode a tool-call response into `Response.tool_calls` (via `ToolCall.from_wire`, preserving metadata). Commit `feat: OpenAI tool calling`.

---

## Phase 1 exit checkpoint

Run: `crystal tool format --check && crystal spec`
Expected: all green, formatted. `ReqLLM.generate_text("openai:gpt-4o-mini", "Hi", fixture: "chat_basic")` works offline; golden specs pin the request shape.

Use @superpowers:requesting-code-review here before starting Phase 2.

---

# Phase 2 — Streaming (roadmap)

Expand each into TDD tasks when reached:

1. **SSE parser** (`src/req_llm/streaming/sse.cr`) — incremental `event:`/`data:` framing from an `IO`; spec feeds an `IO::Memory` of raw SSE and asserts parsed events. Mirrors `streaming/sse.ex`.
2. **Streaming adapter** (`src/req_llm/http/stream_adapter.cr`) — `HTTP::Client` block form yields the body `IO`; produce events behind the same `Request`. Fixture replay uses the `"stream"` array from the fixture schema.
3. **ChunkAccumulator** (`src/req_llm/streaming/accumulator.cr`) — fold `StreamChunk`s into a final `Response`; reassemble tool-call fragments; capture usage from the terminal meta chunk. Mirrors `provider/chunk_accumulator.ex`.
4. **StreamResponse + fibers/Channel** — producer fiber → bounded `Channel` → `Enumerable` consumer; `join` collapses to `Response`.
5. **OpenAI + Anthropic stream decode** — `decode_stream_event` per provider; recorded SSE fixtures.
6. **`ReqLLM.stream_text`** facade. End-to-end via recorded SSE fixture.

# Phase 3 — Anthropic provider (roadmap)

Mirrors `providers/anthropic*.ex`. TDD tasks: auth (`x-api-key` + `anthropic-version`), `encode_chat_body` (hoist `system`, content blocks) with canonical golden, `decode_response` (content blocks → parts, thinking) with fixture, tool calls, streaming decode. Register under `:anthropic`. Reuse every shared step and the fixed attach order.

# Phase 4 — Google (Gemini) provider (roadmap)

Mirrors `providers/google*.ex`. TDD tasks: auth (key via query/header), `encode_chat_body` (`contents`/`parts`, `generateContent`) with canonical golden, `decode_response`, `functionDeclarations` tool calls, `streamGenerateContent` decode. Register under `:google`.

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
