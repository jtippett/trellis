# Phase 3 — Anthropic provider (implementation plan)

Status: DRAFT (pre-codex-review)
Author: Claude
Date: 2026-06-11
Depends on: Phase 1 (core pipeline + OpenAI) and Phase 2 (streaming) — both complete on `master`.

## Goal

Add `ReqLLM::Providers::Anthropic`, a faithful idiomatic-Crystal port of the
upstream Anthropic Messages-API provider
(`req_llm/lib/req_llm/providers/anthropic.ex`, `anthropic/context.ex`,
`anthropic/response.ex`), wired into the existing provider-agnostic pipeline.
The whole generation/streaming machinery dispatches via
`Registry.fetch(model.provider)` and `provider.decode_stream_event(event)`, so
Phase 3 is **purely**: implement the provider class, register it, add the
manifest `require`. No changes to `generation.cr`, `registry.cr`, `pipeline.cr`,
`stream_adapter.cr`, or `stream_response.cr` — except two small, well-scoped
shared changes called out explicitly (FinishReason wire tokens in AU3, usage
merge in AU4), each with a regression guard.

## Scope (this phase)

IN: chat `encode_body` (system hoisting, content blocks, tools), non-streaming
`decode_response` (text + thinking + tool_use blocks, stop_reason, cache-aware
usage), streaming `decode_stream_event` (the Messages SSE event protocol),
`attach_stream`, auth (`x-api-key` + `anthropic-version`), registration.

OUT (deferred — matches what the OpenAI provider deferred; track in memory, NOT
bugs): OAuth / Claude-subscription auth + billing-header shaping; prompt caching
(`anthropic_prompt_cache*`, `cache_control` breakpoints); web_search / web_fetch
server tools; thinking/reasoning **budget translation** (`reasoning_effort`,
`thinking: {type: enabled/adaptive}`, `output_config`, max_tokens bumping);
`anthropic_top_k`, `anthropic_metadata`, `anthropic_version` as a settable
option; `tool_choice` setting; multimodal image/file content **encode**;
structured-output / `:object` operation (that is Phase 5); the stateful
`reasoning_details` round-trip with signatures (we decode thinking text only).

Decoding is permissive: we still *decode* a `thinking` block's text into a
`ContentPart.thinking` and a tool_use block into a `ToolCall`; we simply don't
do the upstream reasoning-signature accumulation machinery.

## Architectural facts the implementer must rely on (verified)

1. **Dispatch is provider-agnostic.** `ReqLLM.generate_text` /
   `ReqLLM.stream_text` (`src/req_llm/generation.cr`) resolve the provider with
   `Registry.fetch(model.provider)` and call `prepare_request` / `attach` /
   `attach_stream` / `decode_stream_event` abstractly. Registering the provider
   and adding the manifest `require` is all the wiring needed.

2. **`BaseProvider#attach`** (`src/req_llm/base_provider.cr`) wires the fixed
   contract step order (headers → retry → error → encode_body → decode_response →
   usage → fixture). Anthropic subclasses `BaseProvider` and supplies `id`,
   `default_base_url`, `default_env_key`, `prepare_request`, `encode_body`,
   `decode_response`, `attach_stream`, `decode_stream_event` — exactly like
   `OpenAI`. Do NOT re-implement `attach`.

3. **Auth differs.** `BaseProvider#apply_common_headers` sets
   `Authorization: Bearer`. Anthropic must instead set `x-api-key` +
   `anthropic-version` (+ `Content-Type`). `apply_common_headers` is
   `protected` and overridable; override it in Anthropic, preserving the
   AUTH-SKIP-ON-REPLAY guard (`Fixture.will_replay?`) so offline fixture runs
   need no key. It is shared by both `attach` and `attach_stream`, so overriding
   once covers both paths.

4. **`FinishReason.from_wire`** (`src/req_llm/response.cr`) already maps
   `end_turn`, `max_tokens`, `tool_use` correctly. It does NOT yet map
   `stop_sequence` or `refusal`. AU3 extends it (additive, non-colliding).
   Because the streaming `ChunkAccumulator` also routes `finish_reason` through
   `from_wire`, extending it once gives streaming/non-streaming parity for free.

5. **`ChunkAccumulator`** (`src/req_llm/streaming/accumulator.cr`) folds chunks
   to a `Response`. Its tool-call delta contract (`metadata["index"]`/`["id"]`/
   `["arguments_fragment"]` + `name`) maps cleanly onto Anthropic streaming:
   `content_block_start{tool_use}` → `tool_call_delta(index, id:, name:)`;
   `content_block_delta{input_json_delta}` → `tool_call_delta(index,
   arguments_fragment:)`. AU4 makes ONE change: usage meta chunks **merge
   per-field (take the larger value)** instead of wholesale replace, because
   Anthropic splits usage across `message_start` (input/cache) and
   `message_delta` (output). For single-frame providers (OpenAI) this is
   identical to replace.

6. **`StreamAdapter`** drives both live and fixture replay through
   `provider.decode_stream_event(event)` (single-arg, event only). Anthropic
   switches on `data["type"]` inside the SSE payload (NOT the SSE `event:`
   line), matching upstream. The provider needs no adapter changes.

7. **`Tool#to_json_schema`** (`src/req_llm/tool.cr`) produces the normalized
   JSON-Schema object. Anthropic tool shape is
   `{name, description, input_schema: <to_json_schema>}` (vs OpenAI's
   `{type:"function", function:{...}}`). `strict` is emitted only when set
   (upstream `to_anthropic_format`).

8. **Goldens are authored from upstream encoder source** (no Elixir runtime),
   matching upstream's REAL output shape. We control both encoder and golden;
   pin a deterministic key order (documented below) and assert byte-shape via
   `JSON.parse(body).should eq(JSON.parse(golden))` (order-insensitive compare,
   same as OpenAI specs).

## Wire-shape reference (the contracts to port)

### Request body — `POST {base}/v1/messages`

Built by `Anthropic.Context.encode_request` + `build_request_body`:

```json
{
  "model": "claude-3-5-sonnet-20241022",
  "system": "You are terse.",
  "messages": [
    {"role": "user", "content": "Hi"}
  ],
  "max_tokens": 1024,
  "temperature": 0.7,
  "stream": false
}
```

Rules (port these exactly):
- **`model`** — `model.id` (we have no `provider_model_id`; use `id`).
- **`system`** — hoisted from `Role::System` messages. Split system vs
  non-system. A single plain-text system message collapses to a **bare string**;
  multiple/none → omit when empty, else an array of `{type:"text", text:...}`
  blocks. Blank (whitespace-only) system text is dropped. (Upstream
  `encode_system_messages` + `normalize_system_content`.)
- **`messages`** — non-system messages, each `{role, content}`. `content` is a
  bare string when it is a single plain text part, else an array of content
  blocks. `Role::Tool` messages become `{role:"user", content:[{type:
  "tool_result", tool_use_id:<id>, content:<text>}]}`. Assistant messages with
  `tool_calls` emit `tool_use` blocks `{type:"tool_use", id, name, input:<map>}`
  appended after any text block. (Upstream `encode_message`.)
- **`max_tokens`** — ALWAYS present (Anthropic requires it). Default `1024`
  when unset (`default_max_tokens(_) -> 1024`).
- **`temperature`, `top_p`** — emitted only when set (value-based `maybe_put`).
- **`stop_sequences`** — from the generation `:stop` option (string → 1-element
  list; array → as-is). Upstream `translate_stop_parameter`.
- **`stream`** — ALWAYS present (`maybe_put` keeps non-nil `false`); the
  streaming path forces `true`. (Mirror OpenAI's `stream` handling.)
- **`tools`** — present only when non-empty; each
  `{name, description, input_schema}` (+ `strict:true` only when set).
- **nil values filtered** (`filter_nil_values`) — so absent `system`/`tools`
  keys never appear.

Key order to emit (deterministic; pin in goldens): `model`, `system?`,
`messages`, `max_tokens`, `temperature?`, `top_p?`, `stop_sequences?`,
`stream`, `tools?`. (`?` = only when present.)

### Response body — non-streaming

```json
{
  "id": "msg_01...",
  "type": "message",
  "role": "assistant",
  "model": "claude-3-5-sonnet-20241022",
  "content": [
    {"type": "text", "text": "Hello!"}
  ],
  "stop_reason": "end_turn",
  "usage": {"input_tokens": 10, "output_tokens": 20}
}
```

Decode rules (`Anthropic.Response.decode_response`):
- **content blocks → parts/tool_calls**: `{type:"text"}` → `ContentPart.text`;
  `{type:"thinking", thinking|text}` → `ContentPart.thinking`;
  `{type:"tool_use", id, name, input}` → `ToolCall.new(id, name, input.to_json)`.
- **message**: `Role::Assistant`, the decoded parts (always at least one text
  part — even empty "" — to match the streaming `finish` shape and OpenAI
  decode), `tool_calls:` when any.
- **stop_reason → FinishReason** via `FinishReason.from_wire` (extended in AU3).
- **usage**: `input_tokens`, `output_tokens`,
  `cache_read_input_tokens` → `cached_tokens`,
  `cache_creation_input_tokens` (tracked but our `Usage` has no field — see AU3
  note). Build `ReqLLM::Usage` with the fields it has.
- **context merge**: input messages + appended assistant reply (dup input,
  preserve tools) — identical pattern to OpenAI `decode_response`.

### Streaming — Messages SSE event protocol

Each SSE frame's `data` is a JSON object with a `type`. Switch on it
(`Anthropic.Response.decode_stream_event`):

| event `type` | emit |
|---|---|
| `message_start` (`message.usage`) | `StreamChunk.meta({"usage" => <normalized>})` when usage present (carries `input_tokens`, `cache_read`) |
| `content_block_start` `{text}` | `StreamChunk.text(text)` if non-empty |
| `content_block_start` `{thinking}` | `StreamChunk.thinking(text)` if non-empty |
| `content_block_start` `{tool_use, id, name}` (with `index`) | `StreamChunk.tool_call_delta(index, id:, name:)` |
| `content_block_delta` `{text_delta, text}` | `StreamChunk.text(text)` |
| `content_block_delta` `{thinking_delta, thinking}` | `StreamChunk.thinking(text)` |
| `content_block_delta` `{input_json_delta, partial_json}` (with `index`) | `StreamChunk.tool_call_delta(index, arguments_fragment: partial_json)` |
| `message_delta` (`delta.stop_reason`, top-level `usage`) | `StreamChunk.meta({"finish_reason" => stop_reason})` + a usage meta chunk when usage present |
| `message_stop` | `[]` (terminal; nothing to fold — our accumulator needs no terminal marker) |
| `ping` | `[]` |
| `error` (`{type:"error", error:{...}}`) | RAISE `Error::API::Response` (200-OK in-stream error; streaming bypasses `Steps.error`) |
| unknown | `[]` |

Usage normalization for streaming must map to the accumulator's CANONICAL keys
(`input_tokens`, `output_tokens`, `reasoning_tokens`, `cached_tokens` as Int64
`JSON::Any`), same as OpenAI's `normalize_stream_usage`. Anthropic source keys:
`input_tokens`, `output_tokens`, `cache_read_input_tokens` → `cached_tokens`.

Note our single-arg `decode_stream_event` is stateless, so the thinking
signature/`content_block_stop` reasoning-details machinery is intentionally not
ported (deferred); `content_block_stop` → `[]`.

---

## Unit AU1 — Provider skeleton, identity, auth, prepare_request, registration

**Files:**
- NEW `src/req_llm/providers/anthropic.cr`
- EDIT `src/cr_llm.cr` (add `require "./req_llm/providers/anthropic"` after the
  OpenAI require, before `generation`)
- NEW `spec/req_llm/providers/anthropic_spec.cr`

**Implement** (mirror `OpenAI` structure):

```crystal
require "json"
require "uri"
require "../base_provider"
require "../registry"
require "../context"
require "../message"
require "../content_part"
require "../response"
require "../usage"
require "../tool_call"
require "../options"

module ReqLLM::Providers
  class Anthropic < ReqLLM::BaseProvider
    DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
    DEFAULT_MAX_TOKENS        = 1024

    def id : String
      "anthropic"
    end

    def default_base_url : String
      "https://api.anthropic.com"
    end

    def default_env_key : String
      "ANTHROPIC_API_KEY"
    end

    # POST <base>/v1/messages carrying typed pipeline state.
    def prepare_request(operation : Symbol, model : LLMDB::Model, data, opts) : HTTP::Request
      ensure_provider!(model)
      context = data.as(ReqLLM::Context)
      url = URI.parse("#{default_base_url}/v1/messages")
      req = HTTP::Request.new("POST", url)
      req.operation = operation
      req.model = model
      req.context = context
      req.options = opts.as(ReqLLM::Options::Validated)
      req
    end

    # Anthropic auth: x-api-key + anthropic-version (NOT Authorization: Bearer).
    # Overrides BaseProvider#apply_common_headers; preserves AUTH-SKIP-ON-REPLAY
    # so offline fixture replays need no key. Shared by attach + attach_stream.
    protected def apply_common_headers(req : HTTP::Request) : Nil
      req.headers["Content-Type"] = "application/json"
      req.headers["anthropic-version"] = DEFAULT_ANTHROPIC_VERSION
      unless ReqLLM::Fixture.will_replay?(req, id)
        api_key = ReqLLM::Keys.resolve(default_env_key, explicit_api_key(req))
        req.headers["x-api-key"] = api_key
      end
    end

    private def ensure_provider!(model : LLMDB::Model) : Nil
      return if model.provider == id
      raise ReqLLM::Error::Invalid::Parameter.new(
        "model provider #{model.provider.inspect} does not match provider #{id.inspect}")
    end

    # AU2 fills these:
    def encode_body(req : HTTP::Request) : HTTP::Request
      raise "AU2"
    end

    def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      raise "AU3"
    end
  end
end

ReqLLM::Registry.register(ReqLLM::Providers::Anthropic.new)
```

**Tests (TDD — write first, watch fail, implement):**
- registration: `Registry.fetch("anthropic").should be_a(Anthropic)`.
- `prepare_request`: builds `POST https://api.anthropic.com/v1/messages`,
  carries `operation/model/context/options`.
- `prepare_request` provider guard: a non-anthropic model raises
  `Error::Invalid::Parameter` matching `/provider/`.
- auth headers (call `attach` with a model whose provider is anthropic, after
  setting `ANTHROPIC_API_KEY` via `ENV`): `x-api-key` set to the key,
  `anthropic-version` == `"2023-06-01"`, NO `Authorization` header, Content-Type
  json. (Set/clear `ENV["ANTHROPIC_API_KEY"]` in the spec; restore after.)
- AUTH-SKIP-ON-REPLAY: with a fixture name whose file exists and no key in ENV,
  `attach` does NOT raise (key resolution skipped). Use a temp fixture dir
  (`Fixture.base_dir=`) like the existing fixture specs.

Because `encode_body`/`decode_response` raise until AU2/AU3, AU1 specs must not
run a full pipeline; they test `prepare_request`, header state after `attach`,
and registration only. (`attach` itself does not call `encode_body`.)

**Verify:** `crystal spec spec/req_llm/providers/anthropic_spec.cr` green;
`crystal build src/cr_llm.cr -o /dev/null` compiles.

---

## Unit AU2 — `encode_chat_body` + canonical goldens

**Files:**
- EDIT `src/req_llm/providers/anthropic.cr` (replace the AU1 `encode_body` stub;
  add a public `encode_chat_body(model, context, opts, *, stream : Bool? = nil)`
  returning a JSON String, plus private encoders)
- NEW `spec/golden/anthropic/chat_basic.json`, `chat_tools.json`,
  `chat_sampling.json`
- EDIT `spec/req_llm/providers/anthropic_spec.cr` (add `#encode_chat_body`
  describe block)

**Implement** (port `Anthropic.Context` + `build_request_body`; value-based
`maybe_put` semantics, `filter_nil_values`):

```crystal
def encode_body(req : HTTP::Request) : HTTP::Request
  model   = req.model.as(LLMDB::Model)
  context = req.context.as(ReqLLM::Context)
  opts    = req.options.as(ReqLLM::Options::Validated)
  req.body = encode_chat_body(model, context, opts)
  req
end

def encode_chat_body(model : LLMDB::Model, context : ReqLLM::Context,
                     opts : ReqLLM::Options::Validated,
                     *, stream : Bool? = nil) : String
  body = {} of String => JSON::Any
  body["model"] = JSON::Any.new(model.id)

  system, non_system = partition_system(context.messages)
  if encoded_system = encode_system(system)   # JSON::Any? (bare String or Array, already wrapped)
    body["system"] = encoded_system
  end
  encoded_msgs = merge_consecutive_tool_results(non_system.map { |m| encode_message(m) })
  body["messages"] = JSON::Any.new(encoded_msgs.map { |m| JSON::Any.new(m) })

  body["max_tokens"] = JSON::Any.new((opts.fetch_int?(:max_tokens) || DEFAULT_MAX_TOKENS).to_i64)

  if t = opts.fetch_float?(:temperature)
    body["temperature"] = JSON::Any.new(t)
  end
  if tp = opts.fetch_float?(:top_p)
    body["top_p"] = JSON::Any.new(tp)
  end
  case stop = opts.fetch_stop
  when String        then body["stop_sequences"] = JSON::Any.new([JSON::Any.new(stop)])
  when Array(String) then body["stop_sequences"] = JSON::Any.new(stop.map { |s| JSON::Any.new(s) })
  end

  stream_flag = stream.nil? ? opts.fetch_bool(:stream) : stream
  body["stream"] = JSON::Any.new(stream_flag)

  tools = opts.fetch_tools
  unless tools.empty?
    body["tools"] = JSON::Any.new(tools.map { |t| JSON::Any.new(encode_tool(t)) })
  end

  body.to_json
end
```

Helpers to port faithfully:
- `partition_system(messages)` → `{system_msgs, non_system_msgs}` by
  `role.system?`.
- `encode_system(system_msgs) : JSON::Any?` — map each system message to text
  block(s) (`{type:"text", text:...}`), drop whitespace-only, flatten;
  `[]` → `nil`; a lone plain `{type:text}` block → `JSON::Any.new(text)` (bare
  string); else `JSON::Any.new(blocks_array)`. RETURN A WRAPPED `JSON::Any` (not
  a raw `String | Array` union) so the `body["system"] = ...` assignment
  type-checks against `Hash(String, JSON::Any)` — mirror how OpenAI's
  `encode_content` returns `JSON::Any` (`openai.cr:346`).
- `encode_message(message) : Hash(String, JSON::Any)`:
  - `Role::Tool` → `{"role"=>"user", "content"=>[tool_result_block]}` where the
    block is `{type:"tool_result", tool_use_id:<message.tool_call_id>,
    content:<encoded>}`. The real `Message` (message.cr:12) has NO message-level
    text getter — `content` is `Array(ContentPart)` and `tool_call_id` is a
    getter. Build the `content` value by reusing `encode_content(message.content)`
    (so it collapses to a bare string or array of blocks just like any message).
    `tool_call_id` is `String?`: when nil, RAISE
    `Error::Invalid::Parameter` ("tool message missing tool_call_id") rather
    than emitting a block with a nil id. Also propagate the error flag (upstream
    context.ex:148-150): when `message.metadata["is_error"]?` is truthy, add
    `"is_error" => JSON::Any.new(true)` to the block (omit otherwise — never emit
    `is_error: false`). Unit-test an error tool result emits `is_error: true`.
  - assistant with `tool_calls` → content blocks = text block(s) (only when the
    message has non-empty text) ++ `tool_use` blocks `{type:"tool_use", id:tc.id,
    name:tc.name, input:<tc.args_map>}` (one per tool call). Note `content` here
    must be the ARRAY form (blocks), not a bare string, because tool_use blocks
    coexist with text.
  - otherwise → `{role:<wire>, content:<encode_content>}`.
- `merge_consecutive_tool_results(encoded_messages) : Array(Hash(String,
  JSON::Any))` — port `context.ex:79` `merge_consecutive_tool_results`: fold
  adjacent `{role:"user"}` messages whose content arrays are BOTH entirely
  `tool_result` blocks into a single `{role:"user"}` message concatenating their
  blocks. Leaves all other messages untouched. (Without this, multi-tool turns
  emit consecutive user messages instead of one — a fidelity gap.) Add a unit
  test: two consecutive `Role::Tool` messages → one user message with two
  `tool_result` blocks.
- `encode_content(parts)` → bare `JSON::Any` String for a single plain text
  part; else `JSON::Any` array of `{type:"text", text:...}` blocks (text parts
  only in scope; non-text parts skipped — multimodal deferred); empty → bare
  `""`. (Returns `JSON::Any`, same as the OpenAI sibling.)
- `role_to_wire`: user→"user", assistant→"assistant" (system handled by
  hoist; tool handled above).
- `encode_tool(tool)` → `{"name", "description", "input_schema"=>
  tool.to_json_schema}` (+ `"strict"=>true` only when `tool.strict`).

**Goldens** (author to match the emitted shape; pin key order):

`chat_basic.json` — context `[System "You are terse.", User "Hi"]`, opts
`{temperature: 0.7}`, model `anthropic:claude-3-5-sonnet-20241022` (pick a real
catalog id — verify with `LLMDB.model`):
```json
{
  "model": "claude-3-5-sonnet-20241022",
  "system": "You are terse.",
  "messages": [{"role": "user", "content": "Hi"}],
  "max_tokens": 1024,
  "temperature": 0.7,
  "stream": false
}
```

`chat_sampling.json` — opts `{temperature: 0.7, top_p: 0.9, stop: ["END"]}`:
includes `"top_p": 0.9`, `"stop_sequences": ["END"]`. (No
frequency/presence_penalty — Anthropic drops those; they are simply not
emitted by our encoder, which never reads them here.)

`chat_tools.json` — one `get_weather` tool (schema `{properties:{location:
{type:string}}, required:[location]}`), user "What's the weather in Paris?":
```json
{
  "model": "...",
  "messages": [{"role": "user", "content": "What's the weather in Paris?"}],
  "max_tokens": 1024,
  "stream": false,
  "tools": [{
    "name": "get_weather",
    "description": "Get the current weather for a location",
    "input_schema": {"type": "object", "properties": {"location": {"type": "string"}}, "required": ["location"]}
  }]
}
```
(Exact `input_schema` shape = whatever `Tool#to_json_schema` emits for that
schema — author the golden from the real `to_json_schema` output, like the
OpenAI tools golden.)

**Tests:** basic/tools/sampling goldens via
`JSON.parse(body).should eq(JSON.parse(File.read(golden)))`; plus:
`max_tokens` defaults to 1024 when unset; `system` omitted when no system
message; `system` is a bare string for a lone text system message; `stream`
emits `false` by default; `tools` omitted when empty; `stop_sequences` from a
scalar `stop` string wraps to a 1-element array.

**Verify:** spec green; `crystal tool format` clean.

---

## Unit AU3 — `decode_response` + fixture + FinishReason tokens

**Files:**
- EDIT `src/req_llm/response.cr` (extend `FinishReason.from_wire`)
- EDIT `src/req_llm/providers/anthropic.cr` (replace `decode_response` stub +
  private decoders)
- NEW `spec/fixtures/anthropic/chat_basic.json` (raw Messages response),
  `spec/fixtures/anthropic/chat_tools.json`
- EDIT `spec/req_llm/providers/anthropic_spec.cr` and/or NEW
  `spec/req_llm/providers/anthropic_decode_spec.cr`
- EDIT `spec/req_llm/response_spec.cr` (from_wire cases — if that spec exists;
  else add to an appropriate spec)

**FinishReason change** (additive, tokens don't collide with existing):
```crystal
when "stop", "end_turn", "stop_sequence", "STOP", "completed"            then Stop
when "length", "max_tokens", "max_output_tokens",
     "model_context_window_exceeded", "MAX_TOKENS"                       then Length
when "content_filter", "refusal", "SAFETY"                              then ContentFilter
```
(Add `stop_sequence` to the Stop arm, `model_context_window_exceeded` to the
Length arm, and `refusal` to the ContentFilter arm — all per upstream
`anthropic/response.ex:415-425`. `pause_turn` → `Other` is acceptable; we have
no `Incomplete` enum value and adding one is out of scope.) Test the new tokens
map correctly AND that the existing OpenAI/Google tokens are unchanged.

**Implement** `decode_response` (port `Anthropic.Response.decode_response` +
`decode_anthropic_response` non-streaming branch, mirror OpenAI's context
merge):
```crystal
def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
  model = req.model.as(LLMDB::Model)
  data  = JSON.parse(resp.body)

  model_name = data["model"]?.try(&.as_s?) || model.id
  finish_reason = ReqLLM::FinishReason.from_wire(data["stop_reason"]?.try(&.as_s?))

  # PARITY with ChunkAccumulator#finish (accumulator.cr:105): build EXACTLY one
  # concatenated text part (even ""), then ONE concatenated thinking part only
  # when thinking is non-empty, then tool_calls. decode_content returns the
  # joined strings + tool calls, NOT a pre-built parts list, so this shape is
  # identical to a folded stream of the same logical content.
  text, thinking, tool_calls = decode_content(data["content"]?)
  parts = [ReqLLM::ContentPart.text(text)]
  parts << ReqLLM::ContentPart.thinking(thinking) unless thinking.empty?

  message = ReqLLM::Message.new(ReqLLM::Role::Assistant, parts,
    tool_calls: tool_calls.empty? ? nil : tool_calls)

  usage = decode_usage(data["usage"]?)

  input = req.context
  merged = input ? input.messages.dup : [] of ReqLLM::Message
  merged << message
  tools = input.try(&.tools) || [] of ReqLLM::Tool

  resp.decoded = ReqLLM::Response.new(
    model: model_name,
    context: ReqLLM::Context.new(merged, tools),
    message: message,
    usage: usage,
    finish_reason: finish_reason)
  {req, resp}
end
```
- `decode_content(content : JSON::Any?)` → `{String, String, Array(ToolCall)}`
  = `{concatenated_text, concatenated_thinking, tool_calls}`: iterate blocks,
  CONCATENATING into two `String::Builder`s and a tool-call list — mirroring how
  `ChunkAccumulator#finish` (accumulator.cr:105) folds a stream into ONE text
  part + ONE thinking part. `text` block → append its `text` to the text
  builder; `thinking` block (key `thinking` or `text`) → append to the thinking
  builder; `tool_use` block → `ToolCall.new(id, name, input.to_json)` where
  `input` is the block's `input` object (default `{}` when absent). Returns the
  two joined strings (each possibly "") + the tool-call array. This guarantees
  `join == decode` for the same logical content (no multiple text parts, no
  thinking-only message lacking a text part).
- `decode_usage(usage : JSON::Any?)` → `ReqLLM::Usage`:
  `input_tokens`, `output_tokens`,
  `cached_tokens = cache_read_input_tokens`,
  `reasoning_tokens = reasoning_output_tokens` (upstream response.ex:363,368 —
  Crystal `Usage#reasoning_tokens` exists at usage.cr:11; this is usage-decode
  parity, NOT reasoning-budget support). `cache_creation_input_tokens` has no
  `Usage` field → drop with a `# DEFERRED` note, same posture as upstream-extra
  usage we already skip. Absent usage → zeroed `Usage.new` (parity with OpenAI
  `decode_usage`).

**IMPORTANT reconciliation** (decode/stream parity): make `decode_content`
produce the SAME message shape `ChunkAccumulator#finish` does for equivalent
content — one text part holding the concatenated text (possibly ""), an
optional single thinking part holding concatenated thinking, then tool_calls.
The accumulator concatenates all thinking into ONE part; decode should do the
same (collect thinking block texts, join, one `ContentPart.thinking`). State
this explicitly so AU4's integration test can assert `join` ≈ `decode`.

**Fixtures** (raw `{status, headers, body}` envelope like
`spec/fixtures/openai/chat_basic.json`; `body` is the escaped JSON string):
- `chat_basic.json`: a `message` with one text block, `stop_reason:"end_turn"`,
  `usage:{input_tokens:10, output_tokens:7}`.
- `chat_tools.json`: content `[{type:text,...}, {type:tool_use, id:"toolu_1",
  name:"get_weather", input:{location:"Paris"}}]`, `stop_reason:"tool_use"`.

**Tests:**
- decode basic fixture → `response.text == "..."`, `finish_reason == Stop`,
  `usage.input_tokens == 10`, `usage.output_tokens == 7`, context has the
  appended assistant message.
- decode tools fixture → `response.tool_calls.size == 1`, id `toolu_1`, name
  `get_weather`, `args_map["location"].as_s == "Paris"`,
  `finish_reason == ToolCalls`.
- cached tokens: a fixture/usage with `cache_read_input_tokens` populates
  `usage.cached_tokens`.
- End-to-end offline: `ReqLLM.generate_text("anthropic:<id>", "Hi",
  fixture: "chat_basic")` returns a costed `Response` with NO key in ENV (auth
  skipped on replay) — proves AU1+AU2+AU3 compose through the real pipeline.

**Verify:** specs green; full suite green; format clean.

---

## Unit AU4 — `decode_stream_event` + accumulator usage-merge

**Files:**
- EDIT `src/req_llm/streaming/accumulator.cr` (usage merge)
- EDIT `src/req_llm/providers/anthropic.cr` (`decode_stream_event`)
- NEW `spec/req_llm/providers/anthropic_stream_spec.cr`
- EDIT `spec/req_llm/streaming/accumulator_spec.cr` (usage-merge unit + OpenAI
  no-regression)

**Accumulator change** — replace wholesale usage replace with per-field max
merge so split-usage providers fold correctly:
```crystal
private def add_meta(chunk : StreamChunk) : Nil
  if reason = chunk.metadata["finish_reason"]?.try(&.as_s?)
    @finish_reason_wire = reason
  end
  if usage_any = chunk.metadata["usage"]?
    if parsed = parse_usage(usage_any)
      @usage = merge_usage(@usage, parsed)
    end
  end
end

# Per-field max merge: a provider may split usage across frames (Anthropic:
# input/cache at message_start, output at message_delta). Token counts are
# monotonic cumulative, so max is order-independent and correct. For a
# single-frame provider (OpenAI) this equals replace.
private def merge_usage(old : Usage?, new : Usage) : Usage
  return new unless o = old
  Usage.new(
    input_tokens:     Math.max(o.input_tokens, new.input_tokens),
    output_tokens:    Math.max(o.output_tokens, new.output_tokens),
    reasoning_tokens: Math.max(o.reasoning_tokens, new.reasoning_tokens),
    cached_tokens:    Math.max(o.cached_tokens, new.cached_tokens))
end
```
(`Usage` getters confirmed: `input_tokens`/`output_tokens`/`reasoning_tokens`/
`cached_tokens` — usage.cr:9-12.) ALSO update the accumulator's class doc
comment (accumulator.cr:44-47) which currently says usage "Latest meta usage
wins (terminal capture)" — change it to "Usage meta chunks MERGE per-field
(larger value wins), so providers that split usage across frames (Anthropic:
input/cache at message_start, output at message_delta) accumulate complete
totals; for a single-frame provider (OpenAI) this equals replace." Otherwise a
future reader reintroduces replace semantics.

**`decode_stream_event`** (port `Anthropic.Response.decode_stream_event/2`,
single-arg/stateless subset):
```crystal
def decode_stream_event(event : ReqLLM::SSE::Event) : Array(ReqLLM::StreamChunk)
  decode_stream_event(event.data)
end

def decode_stream_event(data : String) : Array(ReqLLM::StreamChunk)
  chunks = [] of ReqLLM::StreamChunk
  stripped = data.strip
  return chunks if stripped.empty? || stripped == "[DONE]"
  parsed = JSON.parse(stripped)

  # In-stream error frame: Anthropic streams `{"type":"error","error":{...}}`
  # on a 200 OK connection (overloaded, server error). Streaming bypasses
  # Steps.error, so surface it by raising — same posture as the OpenAI sibling
  # (openai.cr:246) so a live failure isn't silently swallowed. Raising
  # propagates to the consumer via the producer fiber.
  if parsed["type"]?.try(&.as_s?) == "error"
    err = parsed["error"]?
    message = err.try(&.["message"]?).try(&.as_s?) ||
              err.try(&.["type"]?).try(&.as_s?) || parsed.to_json
    raise ReqLLM::Error::API::Response.new("Anthropic stream error: #{message}")
  end

  case parsed["type"]?.try(&.as_s?)
  when "message_start"
    if usage = parsed.dig?("message", "usage")
      if n = normalize_stream_usage(usage)
        chunks << ReqLLM::StreamChunk.meta({"usage" => n})
      end
    end
  when "content_block_start"
    index = parsed["index"]?.try(&.as_i?) || 0
    block = parsed["content_block"]?
    chunks.concat(decode_block_start(block, index))
  when "content_block_delta"
    index = parsed["index"]?.try(&.as_i?) || 0
    delta = parsed["delta"]?
    chunks.concat(decode_block_delta(delta, index))
  when "message_delta"
    if reason = parsed.dig?("delta", "stop_reason").try(&.as_s?)
      chunks << ReqLLM::StreamChunk.meta({"finish_reason" => JSON::Any.new(reason)})
    end
    if usage = parsed["usage"]?
      if n = normalize_stream_usage(usage)
        chunks << ReqLLM::StreamChunk.meta({"usage" => n})
      end
    end
  else
    # message_stop / content_block_stop / ping / unknown → []
  end
  chunks
end
```
Helpers:
- `decode_block_start(block, index)`: `text` → `[StreamChunk.text(t)]` (if
  non-empty); `thinking` → `[StreamChunk.thinking(t)]`; `tool_use{id,name}` →
  `[StreamChunk.tool_call_delta(index, id:, name:)]`; else `[]`.
- `decode_block_delta(delta, index)`: `text_delta{text}` →
  `StreamChunk.text`; `thinking_delta{thinking|text}` →
  `StreamChunk.thinking`; `input_json_delta{partial_json}` →
  `StreamChunk.tool_call_delta(index, arguments_fragment: partial_json)`;
  else `[]`. (Empty text → emit nothing, matching upstream guards.)
- `normalize_stream_usage(usage)` → canonical-key `JSON::Any` object:
  `input_tokens`, `output_tokens`,
  `reasoning_tokens = reasoning_output_tokens` (0 default — same source key as
  non-streaming `decode_usage`, for parity),
  `cached_tokens = cache_read_input_tokens` (0 default). Returns nil when not an
  object.

**Tests** (`anthropic_stream_spec.cr` — mirror `openai_stream_spec.cr`):
- content_block_delta text_delta → one Content chunk with the text.
- message_delta stop_reason → Meta chunk with `finish_reason`.
- message_start usage → Meta usage chunk normalized
  (`input_tokens`/`cached_tokens`).
- tool_use start + input_json_delta deltas fold through `ChunkAccumulator`
  into ONE tool call (id, name, `args_map["location"]=="Paris"`).
- content stream + split usage (`message_start{input:11,cache_read:2}` then
  `message_delta{output:7, stop_reason:"end_turn"}` then `message_stop`) folds
  through the accumulator into `text`, `finish_reason == Stop`,
  `usage.input_tokens == 11`, `usage.output_tokens == 7`,
  `usage.cached_tokens == 2` — proving the merge.
- `ping`, `content_block_stop`, `message_stop`, blank, `[DONE]` → `[]`.
- in-stream error frame `{"type":"error","error":{"type":"overloaded_error",
  "message":"Overloaded"}}` RAISES `Error::API::Response` matching
  `/Anthropic stream error/` (parity with OpenAI's in-stream error handling;
  streaming bypasses `Steps.error`).

**Accumulator regression:** add a focused spec asserting that two OpenAI-style
usage frames where only the FINAL carries usage still yields exactly that
final usage (merge-from-nil == that value), and that the existing OpenAI
streaming integration specs remain green (run them).

**Verify:** `crystal spec` full suite green (esp. existing
`openai_stream_spec.cr` and `stream_response_spec.cr` — the accumulator change
must not regress them); format clean.

---

## Unit AU5 — `attach_stream` + stream fixture + end-to-end

**Files:**
- EDIT `src/req_llm/providers/anthropic.cr` (`attach_stream`)
- NEW `spec/fixtures/anthropic/chat_stream.json` (recorded SSE frames in the
  `{"stream":[...]}` schema)
- NEW/EDIT `spec/req_llm/providers/anthropic_stream_spec.cr` (e2e via
  `stream_text` fixture replay)

**Implement** (mirror OpenAI `attach_stream`; Anthropic adds the SSE Accept
header and uses the shared overridden `apply_common_headers` for x-api-key):
```crystal
def attach_stream(req : HTTP::Request) : HTTP::Request
  model   = req.model.as(LLMDB::Model)
  context = req.context.as(ReqLLM::Context)
  opts    = req.options.as(ReqLLM::Options::Validated)

  apply_common_headers(req) # x-api-key + anthropic-version + content-type
  req.headers["Accept"] = "text/event-stream"
  req.body = encode_chat_body(model, context, opts, stream: true)
  req
end
```

**Stream fixture** `chat_stream.json` — author a realistic short Messages SSE
sequence (each entry a raw `data: {...}\n\n` frame; include the `event:` lines
too if helpful but our SSE parser keys on `data`):
```json
{ "stream": [
  "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":11,\"cache_read_input_tokens\":2}}}\n\n",
  "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
  "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Streaming \"}}\n\n",
  "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"works.\"}}\n\n",
  "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
  "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n",
  "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
] }
```
(Usage is deliberately SPLIT to exercise the per-field merge: `input_tokens` +
`cache_read_input_tokens` arrive at `message_start`, the cumulative
`output_tokens` at `message_delta`. The `join` assertions below check all three
survive the merge.)
(Confirm `SSE.each_event` tolerates the `event:` lines + multi-line frames —
it does per SU1; if a frame must be a lone `data:` line, drop the `event:`
prefixes. Verify against `src/req_llm/streaming/sse.cr`.)

**Tests:**
- e2e replay: `ReqLLM.stream_text("anthropic:<id>", "Hi",
  fixture: "chat_stream")`; collect `text_stream` → `["Streaming ", "works."]`;
  `join` → `text == "Streaming works."`, `finish_reason == Stop`,
  `usage.input_tokens == 11`, `usage.output_tokens == 3`,
  `usage.cached_tokens == 2` (proving the split-usage per-field merge end to
  end). No key in ENV.
- `attach_stream` header/body unit: `Accept == "text/event-stream"`,
  `x-api-key` present (with a key in ENV) / skipped on replay, body has
  `"stream":true`.

**Optional live validation (only if `ANTHROPIC_API_KEY` is available in the
login shell, like the OpenAI live test):** a throwaway root script doing a real
`stream_text` against a cheap Claude model, then `join`. Mirror the OpenAI live
test procedure (run via `zsh -lc`, delete after, NEVER leak the key into the
transcript). If no key is available, SKIP — the fixture replay is the tested
contract.

**Verify:** full `crystal spec` green; `crystal tool format --check` clean;
update memory (`cr-llm-status.md`) marking Phase 3 complete.

---

## Cross-cutting verification (phase exit)

1. `crystal build src/cr_llm.cr -o /dev/null` — compiles.
2. `crystal spec` — entire suite green (existing OpenAI + streaming specs MUST
   stay green; the only shared edits are FinishReason tokens + accumulator
   usage-merge, both with regression guards).
3. `crystal tool format --check` — clean.
4. Provider-support: `Registry.fetch("anthropic")` resolves; an
   `anthropic:<id>` round-trips offline via fixture with no key.
5. Update `memory/cr-llm-status.md` + `MEMORY.md` pointer.

## Open items (VERIFIED during planning — noted for the implementer)

- VERIFIED `src/req_llm/message.cr`: `Message.new(role, content : Array(ContentPart),
  *, tool_call_id = nil, tool_calls = nil, ...)` and a `Message#tool_call_id`
  getter both exist — `tool_result` encode and assistant-with-tool_calls encode
  are both supported.
- VERIFIED `src/req_llm/usage.cr`: `Usage.new(input_tokens = 0, output_tokens = 0,
  reasoning_tokens = 0, cached_tokens = 0, cost = nil)`; getters
  `input_tokens`/`output_tokens`/`reasoning_tokens`/`cached_tokens`. `Usage` has
  NO `cache_creation_tokens` field → drop `cache_creation_input_tokens` on decode
  (DEFERRED, matches the existing posture; `cache_write` never contributes to
  this exchange's cost per `usage.cr`).
- VERIFIED catalog model id: `anthropic:claude-3-5-sonnet-20241022` is present in
  `src/llmdb/data/models.json` (priced) — use it for goldens/fixtures/e2e.
- STILL INSPECT `src/req_llm/tool.cr`: `to_json_schema` output shape for the
  weather schema — author the tools golden's `input_schema` from the REAL
  `to_json_schema` output (as the OpenAI tools golden was authored).
- STILL INSPECT `src/req_llm/streaming/sse.cr`: confirm `Event#data` and
  multi-line/`event:`-line tolerance for the stream fixture (SU1 parser keys on
  `data`).

## Execution

Subagent-driven development: one fresh subagent per unit (AU1→AU5), TDD, then a
`superpowers:code-reviewer` pass between units; fix Critical/Important before
proceeding. Final review + `finishing-a-development-branch` (merge to master
locally, per the established pattern). Subagents must NOT modify `req_llm/`
(vendored reference) or `docs/plans/`.
