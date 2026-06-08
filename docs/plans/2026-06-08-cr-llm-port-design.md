# cr_llm — Crystal port of req_llm: Design

Date: 2026-06-08
Status: Approved (brainstorm complete)

## Goal

Port Elixir's `req_llm` to Crystal at high quality. Two priorities, in order:

1. **Quality** — faithful behavior, well-tested, clean idiomatic Crystal.
2. **Maintenance & automation** — model data flows from models.dev with zero
   code edits, mirroring how upstream stays current.

## Source under study

The reference Elixir library is vendored at `./req_llm/` (~58k LOC, ~140
modules: 50+ providers, SSE + WebSocket streaming, OpenTelemetry, Bedrock AWS
event streams, OAuth, embeddings, images, speech/transcription, rerank). Its
model catalog is already extracted into a separate package, `llm_db`
(`LLMDB.Model`), which vendors models.dev data and is released date-versioned
(e.g. `2026.5.2`).

## Locked decisions

- **Scope (first milestone):** full core architecture + three flagship
  providers — OpenAI, Anthropic, Google — built so the remaining providers are
  mechanical additions.
- **HTTP layer:** Crystal stdlib `HTTP::Client` for transport, plus our own
  Req-equivalent request/response **step pipeline**. The pipeline is the part
  of req_llm worth admiring, so we own it rather than adopt a third-party HTTP
  shard.
- **Fidelity:** idiomatic Crystal with faithful behavior. Same architecture and
  observable behavior; structure follows Crystal idioms (real types over
  keyword lists, Crystal naming).

## Toolchain

Crystal 1.20.2, Shards 0.20.0.

---

## 1. Shape & repo structure

One Crystal shard. We mirror Elixir's `llm_db` / `req_llm` split as **two
namespaces in one shard** — `LLMDB::*` (catalog) and `ReqLLM::*` (engine +
providers). The namespace boundary keeps a future standalone extraction
mechanical; we do not split shards yet (YAGNI).

The shard lives at the repo root; `./req_llm/` remains as the reference clone.

```
cr_llm/
├─ shard.yml
├─ src/
│  ├─ req_llm.cr                  # public facade: ReqLLM.generate_text, etc.
│  ├─ req_llm/
│  │   ├─ http/                   # Req-equivalent pipeline over HTTP::Client
│  │   ├─ model_spec.cr           # "provider:model" parsing
│  │   ├─ context.cr message.cr content_part.cr tool.cr tool_call.cr
│  │   ├─ response.cr stream_chunk.cr streaming/ (sse.cr, accumulator.cr)
│  │   ├─ options.cr schema.cr error.cr
│  │   ├─ provider.cr base_provider.cr registry.cr
│  │   └─ providers/{openai,anthropic,google}.cr
│  └─ llmdb/
│      ├─ model.cr query.cr spec.cr enrich.cr
│      └─ data/models.json        # vendored models.dev catalog (the same data)
├─ tasks/                         # automation scripts (sync_models.cr)
├─ spec/                          # specs + recorded fixtures (cassettes)
└─ docs/plans/
```

### Dependency translation (Elixir → Crystal)

| Elixir              | Crystal                                   |
|---------------------|-------------------------------------------|
| `jason`             | stdlib `JSON`                             |
| `req`               | our step pipeline (Section 2)             |
| `nimble_options`    | small options validator we write          |
| `zoi` / `jsv`       | Crystal types + a JSON-Schema helper      |
| `server_sent_events`| our SSE parser                            |
| `websockex`         | stdlib `HTTP::WebSocket` (deferred)       |
| `dotenvy`           | tiny `.env` loader                        |
| `uniq`              | stdlib `UUID`                             |
| `splode`            | Crystal exception hierarchy               |
| `ex_aws_auth`       | SigV4 helper (deferred, Bedrock)          |
| `llm_db`            | our `LLMDB` namespace                     |

---

## 2. The pipeline (Req-equivalent), the heart

A `ReqLLM::HTTP::Request` carries the call plus ordered steps; a `Pipeline` runs
them around stdlib `HTTP::Client`.

```crystal
class ReqLLM::HTTP::Request
  property method : String
  property url : URI
  property headers : HTTP::Headers
  property body : IO | String | Bytes | Nil
  property options : Hash(Symbol, JSON::Any)   # per-request opts
  property private : Hash(Symbol, ...)          # provider scratch space
  property req_steps  : Array(RequestStep)
  property resp_steps : Array(ResponseStep)
  property error_steps : Array(ErrorStep)
end
```

A step is a **named** callable, so providers can `append` / `prepend` /
`replace` by name (Req's ergonomics). Request steps may short-circuit by
returning a `Response` (cache hit, fixture replay); otherwise the adapter fires,
then response steps fold over the result.

```crystal
alias RequestStep  = {Symbol, Request -> Request | Response}
alias ResponseStep = {Symbol, (Request, Response) -> {Request, Response}}
```

`Pipeline.run(req)`: fold `req_steps` (stop early on a `Response`) → if none
short-circuited, `Adapter.call` → fold `resp_steps` → on a raised error, fold
`error_steps`.

**Shared steps shipped once, reused by every provider:** `encode_body`,
`decode_response`, `retry` (honoring `Retry-After`), `usage`/cost, `error`, and
`fixture` (record/replay). A provider's `attach` wires its own
`encode_body`/`decode_response` plus auth into these slots.

The adapter is one interface, so streaming SSE and (later) WebSocket are
alternate adapters behind the same `Request`.

---

## 3. Core data model

Crystal supplies fields and types natively; we add `JSON::Serializable` for wire
I/O and small `validate` methods where runtime checks matter. Shapes follow
upstream.

```crystal
enum ReqLLM::Role     ; User; Assistant; System; Tool; end
enum ReqLLM::PartType ; Text; ImageUrl; VideoUrl; Image; File; Thinking; end

struct ReqLLM::ContentPart
  include JSON::Serializable
  property type : PartType
  property text : String?
  property url : String?
  property data : Bytes?
  property file_id : String?
  property media_type : String?
  property filename : String?
  property metadata : Hash(String, JSON::Any) = {} of String => JSON::Any
  # constructors: .text, .image_url, .image(bytes, media_type), .file, .thinking
end

struct ReqLLM::Message
  property role : Role
  property content : Array(ContentPart) = [] of ContentPart
  property name : String?
  property tool_call_id : String?
  property tool_calls : Array(ToolCall)?
  property metadata, provider_data, reasoning_details   # lossless round-trip
end

class ReqLLM::Context
  property messages : Array(Message)
end
```

Same treatment for `Tool`, `ToolCall`, `StreamChunk`
(`content | thinking | tool_call | meta`), and `Response` (carries `context`,
`message`, `usage`, `finish_reason`, a `stream` handle, and `.text` /
`.tool_calls` / `.object` accessors).

`struct` for small immutable values (ContentPart, ToolCall, StreamChunk);
`class` for the larger mutable carriers (Context, Response, Request).

---

## 4. Provider abstraction & the three providers

A `Provider` module interface plus a `BaseProvider` abstract class holding the
shared OpenAI-shaped defaults.

```crystal
module ReqLLM::Provider
  abstract def id : Symbol
  abstract def default_base_url : String
  abstract def default_env_key : String
  abstract def prepare_request(op, model, data, opts) : HTTP::Request
  abstract def attach(req, model, opts) : HTTP::Request
  abstract def encode_body(req) : HTTP::Request
  abstract def decode_response(req, resp) : {HTTP::Request, Response}
  def extract_usage(body, model) : Usage?            # overridable default
  def attach_stream(model, ctx, opts) : HTTP::Request # default streaming build
end
```

A `Registry` maps `:openai | :anthropic | :google` → instance.

- **OpenAI** — reference implementation: Chat Completions encode/decode, tool
  calls, SSE streaming. Its encoders become the shared defaults future
  OpenAI-compatible providers reuse.
- **Anthropic** — Messages API: `system` hoisted out, `content` blocks,
  `x-api-key` + `anthropic-version` headers, named SSE events, thinking blocks.
- **Google (Gemini)** — `contents`/`parts`, `generateContent` /
  `streamGenerateContent`, key via query/header, `functionDeclarations` tools.

Each provider file is small (auth + encode + decode + usage); retry, error,
cost, fixtures, and SSE come from shared steps. This keeps provider #4…#50
mechanical.

---

## 5. Model catalog & models.dev automation (priority #2)

We replicate `llm_db`'s strategy: vendor models.dev's data, regenerate it
automatically, version by date.

- **Source of truth — the same files.** models.dev publishes the full catalog
  at `https://models.dev/api.json` (capabilities, context/output limits,
  modalities, pricing). We vendor it; we never hand-maintain model data.
- **Vendored data.** `src/llmdb/data/models.json`, committed, embedded at
  compile time via `{{ read_file }}` so the shard is self-contained (no runtime
  download). `LLMDB::VERSION` is a date constant mirroring `llm_db`.
- **API**, faithful to LLMDB:
  ```crystal
  LLMDB.model("openai:gpt-4o-mini")
  LLMDB::Query.candidates(require: [:tools, :vision], prefer: [:anthropic])
  LLMDB::Spec.parse("anthropic:claude-sonnet-4-5")
  LLMDB::Enrich.enrich(model, inline_overrides)
  ```
  `LLMDB::Model` drives `ReqLLM::ModelHelpers` (`supports_tools?`,
  `supports_vision?`, pricing/cost).
- **Automation.** `tasks/sync_models.cr` fetches `api.json`, normalizes,
  rewrites `models.json`, bumps `VERSION`. A GitHub Actions weekly cron runs it
  and opens a PR when the data changed. Model and price changes land with zero
  code edits.

---

## 6. Streaming

Crystal expresses Elixir's `StreamServer` directly with **fibers + a
`Channel`**.

- **Transport.** Stdlib `HTTP::Client` block form yields a streaming body `IO`.
  A streaming adapter sits behind the same `ReqLLM::HTTP::Request`, so providers
  reuse their normal `attach`/auth.
- **SSE parser.** `ReqLLM::SSE` reads the `IO`, accumulates `event:` / `data:`
  frames, emits one parsed event per blank line. Provider decode handles
  Anthropic's named events and OpenAI's `[DONE]` sentinel.
- **Flow.**
  ```crystal
  stream = ReqLLM.stream_text("anthropic:claude-sonnet-4-5", ctx)
  stream.each { |chunk| print chunk.text }   # content|thinking|tool_call|meta
  resp = stream.join                          # collapse to full Response
  ```
  A producer fiber reads socket → SSE → provider `decode_stream_event` →
  `StreamChunk`s onto a bounded `Channel` (backpressure). A `ChunkAccumulator`
  folds chunks into the final `Context`/`Response`, so `stream.join` matches the
  non-streaming struct (tool-call fragments reassembled, usage from the terminal
  `meta` chunk).
- **Cancellation & errors** propagate by closing the channel and surfacing
  through the same `error_steps`.

---

## 7. Options, errors, structured output

**Options validation** (replacing `nimble_options`). Each operation/provider
declares an options schema; we validate, default, and coerce per request.

```crystal
SCHEMA = ReqLLM::Options.schema({
  temperature: {type: Float64, range: 0.0..2.0},
  max_tokens:  {type: Int32, default: nil},
  tools:       {type: Array(Tool), default: [] of Tool},
  stream:      {type: Bool, default: false},
})
opts = SCHEMA.validate(user_opts)   # typed, defaulted; raises Invalid::Parameter
```

Providers extend the base schema with their own keys (`reasoning_effort`,
`anthropic_version`, …).

**Errors** (replacing `splode`):

```
ReqLLM::Error
├─ Invalid::Parameter / Invalid::Schema / Invalid::Role
├─ API::Request   (network, timeout, 4xx/5xx with status + body)
├─ API::Response  (unparseable/unexpected payload)
└─ Validation     (response failed schema)
```

Methods come in two forms: raising (`generate_text`) and result-returning where
Elixir returns `{:ok | :error}`.

**Structured output** (`generate_object`, replacing `zoi`/`jsv`). A schema DSL
builds JSON Schema for the wire and validates the result.

```crystal
schema = ReqLLM.schema({name: {type: String, required: true},
                        age:  {type: Int32, required: true}})
ReqLLM.generate_object("openai:gpt-4o-mini", "A person named John, 30", schema)
```

Under the hood: OpenAI `response_format: json_schema`; Anthropic/Google via a
synthetic tool call. The returned JSON is validated before return.

---

## 8. Testing strategy

Tests anchor the port. Upstream's Req fixture step (record real responses,
replay offline) falls out of Section 2's short-circuit pipeline.

**Fixture/cassette step.**
- **Replay (default, CI):** loads `spec/fixtures/<provider>/<name>.json` and
  short-circuits with a recorded `Response` — no network, no keys.
- **Record (`CR_LLM_FIXTURES=record` + real keys):** runs the real call, writes
  the response. Same mechanism for streaming (recorded SSE frames).

**Pyramid (Crystal's built-in `spec`):**
1. **Pure unit specs** — structs, `Options.validate`, schema→JSON-Schema, SSE
   parser, pipeline step ordering/short-circuit, error mapping.
2. **Provider specs against fixtures** — `generate_text`, tool calls, streaming,
   `generate_object` for the three providers. Deterministic, offline.
3. **Golden-encoding specs (fidelity gate)** — for fixed inputs, assert our
   request JSON matches reference bodies captured from the Elixir lib. Drift
   from req_llm fails a spec.
4. **Live integration (opt-in tag)** — real-API smoke tests, manual/nightly,
   never blocking CI.

**CI (GitHub Actions):** `crystal spec` (unit + fixtures + golden) on every
push; weekly `sync_models`; live tests behind a manual workflow.

---

## Implementation order

Foundation (shard, error tree, `.env`) → pipeline + adapter → core structs →
catalog (`LLMDB` + sync task) → OpenAI (reference) → fixture/golden test
harness → Anthropic → Google → streaming → options/schema + structured output →
CI + sync automation.
