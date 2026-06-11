# Phase 4 — Google (Gemini) provider (implementation plan)

Status: DRAFT (pre-codex-review)
Author: Claude
Date: 2026-06-11
Depends on: Phases 1-3 complete on `master` (core pipeline, OpenAI, streaming, Anthropic).

## Goal

Add `ReqLLM::Providers::Google`, a faithful idiomatic-Crystal port of the chat +
streaming paths of the upstream Google Gemini provider
(`req_llm/lib/req_llm/providers/google.ex`), wired into the existing
provider-agnostic pipeline. Like Phases 1-3, this is purely: implement the
provider class, register it, add the manifest `require`. The
generation/streaming machinery dispatches via `Registry.fetch(model.provider)`
and `provider.decode_stream_event(event)`, so no changes to `generation.cr`,
`registry.cr`, `pipeline.cr`, `stream_adapter.cr`, or `stream_response.cr` are
needed — except ONE small additive shared change (FinishReason `RECITATION`
token in GU3), with a regression guard.

The Gemini API differs more from our OpenAI baseline than Anthropic did, in
three structural ways the implementer must internalize:

1. **Endpoint encodes the operation, and streaming uses a DIFFERENT endpoint.**
   Non-streaming: `POST {base}/models/{id}:generateContent`. Streaming:
   `POST {base}/models/{id}:streamGenerateContent?alt=sse`. There is **no
   `stream` field in the request body** — streaming is purely endpoint + query.
   So `attach_stream` REWRITES the request URL (path + query); the body is
   byte-identical to the non-streaming body.
2. **Roles + shapes differ.** Gemini uses `contents: [{role, parts}]` with role
   `"user"` or `"model"` (assistant→model; system is hoisted to a separate
   `systemInstruction`; tool results map to role `"user"`). Parts are
   `{text}`, `{functionCall:{name,args}}`, `{functionResponse:{name,response}}`,
   `{inlineData}`. Sampling lives under `generationConfig`
   (`temperature`/`maxOutputTokens`/`topP`/`topK`/`stopSequences`). Tools are
   `tools: [{functionDeclarations: [{name, description, parameters}]}]`.
3. **Streaming frames are full response deltas, not typed events.** Each SSE
   `data:` is a partial `GenerateContentResponse`
   (`{candidates:[{content:{parts:[...]}, finishReason?}], usageMetadata?}`),
   NOT an OpenAI/Anthropic-style typed event. `functionCall` parts arrive
   COMPLETE (name + full args object) in a single frame — not fragmented.

## Scope (this phase)

IN: chat `encode_body` (systemInstruction hoist, `contents`/`parts`,
`generationConfig`, `functionDeclarations` tools, `merge_consecutive_roles`),
non-streaming `decode_response` (candidates → text + thinking + functionCall
tool_calls, finishReason, usageMetadata), streaming `decode_stream_event`
(`streamGenerateContent` SSE deltas), `attach_stream` (endpoint rewrite +
`alt=sse`), auth (`x-goog-api-key` header), registration.

OUT (deferred — track in memory, NOT bugs; same posture as OpenAI/Anthropic
deferrals): embeddings (`:embedContent`), image/Imagen (`:predict`/image
`generateContent`), `:object`/structured output (Phase 5), Google Search
grounding + `url_context` + `safetySettings`, `cachedContent` context caching,
thinking-budget/level translation (`google_thinking_budget`/`_level`,
`reasoning_effort`, `thinkingConfig`), the stateful `reasoning_details` +
`thoughtSignature` round-trip (we decode thinking TEXT only), `tool_choice` →
`toolConfig`, `google_candidate_count`/`response_modalities`, `topK`/`user`,
multimodal image/file/video `inlineData`/`fileData` ENCODE (text parts only),
v1 vs v1beta switching (we always use v1beta), and the JSON-array streaming
protocol (we always request `alt=sse`, so the SSE adapter handles framing).

Decoding stays permissive: a `thought:true` text part still decodes into a
`ContentPart.thinking`, and a `functionCall` part into a `ToolCall`.

## Architectural facts the implementer must rely on (verified)

1. **Dispatch is provider-agnostic.** `generate_text`/`stream_text`
   (`generation.cr`) resolve the provider via `Registry.fetch(model.provider)`
   and call `prepare_request`/`attach`/`attach_stream`/`decode_stream_event`
   abstractly. Registering + the manifest `require` is all the wiring.

2. **`BaseProvider#attach`** wires the fixed contract order (headers → retry →
   error → encode_body → decode_response → usage → fixture). Google subclasses
   `BaseProvider` and supplies `id`/`default_base_url`/`default_env_key`/
   `prepare_request`/`encode_body`/`decode_response`/`attach_stream`/
   `decode_stream_event` — exactly like OpenAI/Anthropic. Do NOT re-implement
   `attach`.

3. **Auth = `x-goog-api-key` header.** Upstream defaults to a `?key=` query
   param but fully supports the `x-goog-api-key` header (its
   `google_auth_header: true` mode, google.ex:1978-1985). We DELIBERATELY use
   the header: it keeps the API key out of the URL (and therefore out of any
   logged/fixtured URL), and parallels the Anthropic `apply_common_headers`
   override. Override `apply_common_headers` to set `Content-Type` +
   `x-goog-api-key` (NOT `Authorization`), preserving AUTH-SKIP-ON-REPLAY
   (`Fixture.will_replay?`). It is shared by `attach` + `attach_stream`.

4. **`req.url` is a mutable `URI`** (http/request.cr:38 `property url : URI`).
   `attach_stream` rewrites it from `:generateContent` to
   `:streamGenerateContent` and sets `query = "alt=sse"`. `prepare_request`
   builds the non-streaming URL.

5. **`FinishReason.from_wire`** (response.cr) already maps `STOP`→Stop,
   `MAX_TOKENS`→Length, `SAFETY`→ContentFilter — all Gemini tokens. It does NOT
   map `RECITATION`; GU3 adds it (→ContentFilter, additive, non-colliding).
   Because the streaming `ChunkAccumulator` routes finish_reason through
   `from_wire`, the extension gives streaming/non-streaming parity for free.
   **Tool-call finish caveat:** Gemini returns `finishReason: "STOP"` even when
   the candidate contains `functionCall` parts; the meaningful finish is
   `ToolCalls`. Two complementary fixes (see GU3/GU4):
   - **Non-streaming** `decode_response`: when the candidate has `functionCall`
     parts, set `FinishReason::ToolCalls` directly (mirrors upstream
     google.ex:1764-1768).
   - **Streaming**: rather than a fragile per-frame override (the `functionCall`
     part and the `finishReason:"STOP"` frame may arrive separately, and the
     accumulator's "latest finish wins" would then yield `Stop`), GU4 adds ONE
     small, PROVIDER-AGNOSTIC rule to `ChunkAccumulator#finish`: **if tool calls
     were accumulated AND the resolved finish_reason is `Stop`, upgrade it to
     `ToolCalls`.** This is a verified NO-OP for OpenAI (wire `tool_calls`) and
     Anthropic (wire `tool_use`) — they never emit `Stop` alongside tool calls —
     so it only ever fires for Gemini. It makes streaming parity independent of
     SSE frame timing. (Only `Stop` is upgraded, never `Length`/`ContentFilter`,
     so a truncated-mid-tool-call response keeps its real reason.)

6. **`ChunkAccumulator`** (accumulator.cr) — ONE small additive change in GU4
   (the finish-reason upgrade in fact #5); otherwise relied upon as-is.
   - Gemini streams `functionCall` parts COMPLETE (full args object) in one
     frame. Emit them as `StreamChunk.tool_call(name, args_hash, metadata)` with
     metadata `{"index" => i, "id" => call_id}` where `i` is the functionCall's
     position among functionCall parts in the current event. The accumulator's
     `add_tool_call` reads `metadata["index"]` to group and `chunk.arguments`
     (the struct field, set by `.tool_call`) as the pre-assembled args
     (`has_fragments` stays false → `args.to_json`). This yields the same
     `ToolCall` the non-streaming decode produces.
     **Index caveat (known limitation):** the accumulator groups tool calls
     SOLELY by `metadata["index"]`. Gemini delivers all `functionCall` parts of
     a response COMPLETE and CO-LOCATED in a single content frame (upstream's
     primary decode arm assumes this — google.ex:2630), so position-within-event
     indexing gives distinct indices for parallel calls. GU4 MUST add an
     integration test with TWO `functionCall` parts in ONE frame proving two
     distinct `ToolCall`s. If Gemini ever split parallel calls across separate
     frames, they would collide at index 0 — document this as a deferred
     limitation (not in scope; Gemini does not do this today).
   - Usage: Gemini sends `usageMetadata` cumulatively across frames; the
     per-field-max `merge_usage` added in Phase 3 (AU4) already folds it
     correctly. Verify, don't re-change.

7. **`Tool#to_json_schema`** (tool.cr) preserves ALL top-level schema keys
   (incl. `additionalProperties`/`$schema`). Google's `functionDeclarations`
   forbid `$schema` and `additionalProperties` (schema.ex:707 + `to_google_format`
   at 710-719), so GU2 DEEP-STRIPS those two keys from the parameters schema.

8. **`StreamAdapter`** drives both live and fixture replay through
   `SSE.each_event` → `provider.decode_stream_event(event)`. Gemini `alt=sse`
   emits `data: {full GenerateContentResponse}\n\n` frames (no `[DONE]`
   sentinel; the stream just ends at EOF). The decoder switches on the JSON
   shape (`candidates`/`usageMetadata`), NOT a `type` field. No adapter change.

## Wire-shape reference (the contracts to port)

### Request body — `POST {base}/models/{id}:generateContent`

```json
{
  "systemInstruction": {"parts": [{"text": "You are terse."}]},
  "contents": [
    {"role": "user", "parts": [{"text": "Hi"}]}
  ],
  "generationConfig": {"temperature": 0.7, "maxOutputTokens": 1024}
}
```

Rules (port `encode_chat_body` + `split_messages_for_gemini` +
`convert_*_to_gemini`, encoding DIRECTLY from our `Context` — do NOT route
through an OpenAI-format intermediary as upstream does):
- **`systemInstruction`** — hoisted from `Role::System` messages: join their
  text with `"\n\n"` into `{parts: [{text: combined}]}`. Omit entirely when
  there are no system messages (or the combined text is empty).
- **`contents`** — non-system messages mapped to `{role, parts}`:
  - role: `User`→`"user"`, `Assistant`→`"model"`, `Tool`→`"user"`.
  - parts for a normal message: each text `ContentPart` → `{text}` (non-text
    parts skipped — multimodal deferred). A `Role::Tool` message → a single
    `{functionResponse: {name: <tool name>, response: {content: <text>}}}` part
    (see tool-result rules below). An assistant message with `tool_calls` →
    text part(s) (if any) ++ one `{functionCall: {name, args: <args_map>}}` per
    call (args is the DECODED object, not the JSON string).
  - **`merge_consecutive_roles`**: after mapping, fold consecutive entries with
    the SAME role into one (concatenating their `parts`). Critical for parallel
    tool results: N `Role::Tool` messages all map to role `"user"` and must
    become ONE `{role:"user"}` entry with N `functionResponse` parts. Port
    google.ex:2248-2261.
- **tool_result part** (`build_tool_result_part`, google.ex:2371-2415):
  `{functionResponse: {name, response}}`. `name` = the message's tool name —
  our `Message` has no tool name field, only `tool_call_id`; upstream falls
  back to `"unknown"` when absent (tool_result_name/1). Use the message's
  `name` getter if set, else `"unknown"`. `response` = `{content: <text>}`
  where text is `encode_content_text(message.content)` (join text parts). (When
  `tool_call_id` is nil, raise `Error::Invalid::Parameter` — same posture as
  Anthropic AU2.)
- **`generationConfig`** — value-based (`maybe_put`): `temperature`,
  `maxOutputTokens` (from `max_tokens`), `topP` (from `top_p`),
  `stopSequences` (from `stop`: string→1-elem array; array as-is). Omit the
  whole `generationConfig` key when it would be empty. (Defer `topK`,
  `candidateCount`, `thinkingConfig`.)
- **`tools`** — present only when the tools list is non-empty:
  `[{functionDeclarations: [<decl>, ...]}]` where each decl is
  `{name, description, parameters: <to_json_schema DEEP-STRIPPED of "$schema"
  and "additionalProperties">}`. (Defer `toolConfig`/grounding/url_context.)
- nil values omitted throughout (`maybe_put` semantics) — absent
  `systemInstruction`/`tools`/`generationConfig` keys never appear.

Key order to emit (deterministic; pin in goldens): `systemInstruction?`,
`contents`, `tools?`, `generationConfig?`.

### Response body — non-streaming

```json
{
  "candidates": [
    {
      "content": {"role": "model", "parts": [{"text": "Hello!"}]},
      "finishReason": "STOP"
    }
  ],
  "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 7, "totalTokenCount": 17}
}
```

Decode rules (port `convert_google_to_openai_format` +
`convert_google_parts_to_content` + `extract_tool_calls` + the usage
normalization, but build our `Response` DIRECTLY):
- Take `candidates[0]`. Its `content.parts`:
  - `{text}` with `thought != true` → append to the text builder.
  - `{text, thought: true}` → append to the thinking builder.
  - `{functionCall: {name, args}}` → `ToolCall.new(id, name, args.to_json)`
    where `id` = `functionCall["id"]` if present else `ToolCall.generate_id`.
    (`args` is an object → JSON-encode for our `arguments` string.)
- Build the message PARITY-style (matches `ChunkAccumulator#finish` and the
  Anthropic decode): EXACTLY one text `ContentPart` (even `""`), then ONE
  thinking part only when thinking non-empty, then tool_calls. `decode_content`
  returns `{text, thinking, tool_calls}` (joined strings), NOT a parts list.
- **finish_reason**: if tool_calls present → `FinishReason::ToolCalls`
  (regardless of the wire `STOP`); else `FinishReason.from_wire(finishReason)`.
- **usage** (`normalize_google_usage`, google.ex:632-651): `input =
  promptTokenCount` — and when that key is absent, fall back to
  `sum(promptTokensDetails[].tokenCount)`, else 0 (port google.ex:633-636 /
  `google_token_details_count`); `reasoning = thoughtsTokenCount || 0`;
  `cached = cachedContentTokenCount || 0`; `output = google_output_tokens`:
  if `candidatesTokenCount` is an int → `candidatesTokenCount + reasoning`;
  elsif `totalTokenCount` int → `max(0, total - input)`; elsif `reasoning > 0`
  → `reasoning`; else 0. Map into `ReqLLM::Usage(input/output/reasoning/cached)`.
  Absent `usageMetadata` → zeroed `Usage.new`.
- **context merge**: input messages + appended assistant reply, preserve tools,
  no mutation — identical pattern to OpenAI/Anthropic.
- model name: `data["modelVersion"]?`/`req.model.id` fallback (Gemini returns
  `modelVersion`, not `model`; use `model.id` if absent).

### Streaming — `streamGenerateContent?alt=sse`

Each SSE `data:` payload is a partial `GenerateContentResponse`. Port
`decode_google_event` + `extract_chunks_from_parts` (google.ex:2626+,
2548+). Switch on the JSON shape (NOT a `type` field):
- For any frame with `candidates[0].content.parts`, emit chunks from the parts
  (`extract_chunks_from_parts`):
  - `{text}` non-empty, `thought != true` → `StreamChunk.text(text)`.
  - `{text, thought:true}` non-empty → `StreamChunk.thinking(text)`.
  - `{functionCall:{name,args}}` → `StreamChunk.tool_call(name, args_hash,
    {"index" => i, "id" => id})` (i = position among functionCall parts in THIS
    event; id from `functionCall["id"]` or generated). Pre-assembled args.
- If the frame's `candidates[0]` has a non-null `finishReason`, emit a trailing
  `StreamChunk.meta({"finish_reason" => <raw wire string>})`. Emit the RAW
  `finishReason` (e.g. `"STOP"`) — do NOT do a per-frame `tool_calls` override.
  The accumulator's GU4 finish-upgrade rule (tool calls present + `Stop` →
  `ToolCalls`) handles the Gemini-STOP-with-tool-calls case independent of
  whether the `functionCall` and the `finishReason` frames are co-located.
- If the frame has `usageMetadata`, emit `StreamChunk.meta({"usage" =>
  <normalized>})` (canonical keys via the SHARED `normalize_google_usage`
  helper → `input_tokens`/`output_tokens`/`reasoning_tokens`/`cached_tokens`).
- Frames with none of the above → `[]`. No `[DONE]` sentinel exists; blank
  frames → `[]`.

Reference table:

| frame shape | emit |
|---|---|
| `candidates[0].content.parts` (text/thought/functionCall) | text/thinking/tool_call chunks |
| `candidates[0].finishReason` non-null | `meta{finish_reason: <raw wire>}` (accumulator upgrades Stop→ToolCalls when tool calls were seen) |
| top-level `usageMetadata` | `meta{usage}` (normalized canonical keys) |
| anything else / blank | `[]` |

(Note: Gemini's stateless single-arg decode means the `thoughtSignature`
reasoning round-trip is deferred; `thought:true` text still decodes to a
Thinking chunk.)

---

## Unit GU1 — Provider skeleton, identity, auth, prepare_request, registration

**Files:**
- NEW `src/req_llm/providers/google.cr`
- EDIT `src/cr_llm.cr` (add `require "./req_llm/providers/google"` after the
  anthropic require, before `generation`)
- NEW `spec/req_llm/providers/google_spec.cr`

**Implement** (mirror Anthropic's GU1-equivalent structure):

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
  class Google < ReqLLM::BaseProvider
    # NOTE: NO DEFAULT_MAX_TOKENS constant. Unlike Anthropic, Gemini does NOT
    # require maxOutputTokens; GU2 OMITS it when unset.

    def id : String
      "google"
    end

    def default_base_url : String
      "https://generativelanguage.googleapis.com/v1beta"
    end

    def default_env_key : String
      "GOOGLE_API_KEY"
    end

    # POST <base>/models/<id>:generateContent carrying typed pipeline state.
    def prepare_request(operation : Symbol, model : LLMDB::Model, data, opts) : HTTP::Request
      ensure_provider!(model)
      context = data.as(ReqLLM::Context)
      url = URI.parse("#{default_base_url}/models/#{model.id}:generateContent")
      req = HTTP::Request.new("POST", url)
      req.operation = operation
      req.model = model
      req.context = context
      req.options = opts.as(ReqLLM::Options::Validated)
      req
    end

    # Google auth: x-goog-api-key header (NOT Authorization: Bearer, NOT the
    # ?key= query param — keeps the key out of the URL). Overrides
    # BaseProvider#apply_common_headers; preserves AUTH-SKIP-ON-REPLAY. Shared by
    # attach + attach_stream.
    protected def apply_common_headers(req : HTTP::Request) : Nil
      req.headers["Content-Type"] = "application/json"
      unless ReqLLM::Fixture.will_replay?(req, id)
        api_key = ReqLLM::Keys.resolve(default_env_key, explicit_api_key(req))
        req.headers["x-goog-api-key"] = api_key
      end
    end

    private def ensure_provider!(model : LLMDB::Model) : Nil
      return if model.provider == id
      raise ReqLLM::Error::Invalid::Parameter.new(
        "model provider #{model.provider.inspect} does not match provider #{id.inspect}")
    end

    def encode_body(req : HTTP::Request) : HTTP::Request
      raise "GU2"
    end

    def decode_response(req : HTTP::Request, resp : HTTP::Response) : {HTTP::Request, HTTP::Response}
      raise "GU3"
    end
  end
end

ReqLLM::Registry.register(ReqLLM::Providers::Google.new)
```

**Tests (TDD):** registration (`Registry.fetch("google")`); `prepare_request`
builds `POST https://generativelanguage.googleapis.com/v1beta/models/<id>:generateContent`
carrying typed state; provider-guard raise on a non-google model; auth headers
(with `GOOGLE_API_KEY` set, capture/restore ENV) `x-goog-api-key` == key, no
`Authorization`, Content-Type json; AUTH-SKIP-ON-REPLAY (temp fixture dir via
`Fixture.base_dir=`, `FileUtils.rm_rf` cleanup, capture/restore ENV — follow the
Anthropic spec's hygiene exactly). Use a real catalog id: verify
`LLMDB.model("google:gemini-2.0-flash")` resolves; use whatever does.

**Verify:** `crystal spec spec/req_llm/providers/google_spec.cr` green; full
suite green; `crystal build src/cr_llm.cr -o /dev/null`; `crystal tool format`.
GU1 verification is NON-STREAMING ONLY — `decode_stream_event`/`attach_stream`
inherit `BaseProvider`'s raising stubs until GU4/GU5, so do not smoke-test
streaming yet. (`attach` itself does not call `encode_body`, so post-`attach`
header assertions are safe.)

---

## Unit GU2 — `encode_chat_body` + canonical goldens

**Files:**
- EDIT `src/req_llm/providers/google.cr` (replace `encode_body` stub; add public
  `encode_chat_body(model, context, opts) : String` + private encoders)
- NEW `spec/golden/google/chat_basic.json`, `chat_tools.json`,
  `chat_sampling.json`
- EDIT `spec/req_llm/providers/google_spec.cr`

**Implement** per the Wire-shape "Request body" rules. Note: encode takes NO
`stream` kwarg (Gemini streaming is endpoint-based; the body is identical).

```crystal
def encode_body(req : HTTP::Request) : HTTP::Request
  model   = req.model.as(LLMDB::Model)
  context = req.context.as(ReqLLM::Context)
  opts    = req.options.as(ReqLLM::Options::Validated)
  req.body = encode_chat_body(model, context, opts)
  req
end

def encode_chat_body(model : LLMDB::Model, context : ReqLLM::Context,
                     opts : ReqLLM::Options::Validated) : String
  body = {} of String => JSON::Any

  system, non_system = partition_system(context.messages)
  if si = encode_system_instruction(system)   # JSON::Any? ({parts:[{text}]})
    body["systemInstruction"] = si
  end

  contents = merge_consecutive_roles(non_system.map { |m| encode_message(m) })
  body["contents"] = JSON::Any.new(contents.map { |c| JSON::Any.new(c) })

  tools = opts.fetch_tools
  unless tools.empty?
    decls = tools.map { |t| JSON::Any.new(encode_tool(t)) }
    body["tools"] = JSON::Any.new([JSON::Any.new(
      {"functionDeclarations" => JSON::Any.new(decls)} of String => JSON::Any)])
  end

  if gc = encode_generation_config(opts)       # JSON::Any? (nil when empty)
    body["generationConfig"] = gc
  end

  body.to_json
end
```

Helpers (all returning `JSON::Any` where assigned, like the Anthropic sibling):
- `partition_system` → `{system_msgs, non_system_msgs}` by `role.system?`.
- `encode_system_instruction(system_msgs) : JSON::Any?` — join each system
  message's text (text parts joined) with `"\n\n"`; nil when empty/blank; else
  `JSON::Any.new({"parts" => [{"text" => combined}]})`.
- `encode_message(message) : Hash(String, JSON::Any)` → `{"role" => <wire>,
  "parts" => [...]}`:
  - role: User→"user", Assistant→"model", Tool→"user", System→"user" (System
    won't reach here post-partition).
  - `Role::Tool` → parts `[{functionResponse: {name, response:{content:<text>}}}]`
    (name = `message.name || "unknown"`; text = joined text parts; RAISE
    `Error::Invalid::Parameter` when `tool_call_id` nil).
  - assistant with `tool_calls` → text `{text}` parts (skip empty) ++ one
    `{functionCall: {name: tc.name, args: tc.args_map}}` per call.
  - otherwise → text `{text}` parts (skip non-text; multimodal deferred). If a
    message has no encodable parts, emit `parts: []` (Gemini tolerates it; or
    emit `[{text:""}]` — match upstream `convert_single_message_to_gemini`
    which yields `[%{text: ""}]` for an empty string content; PREFER
    `[{text:""}]` for a bare empty message to avoid an empty-parts edge).
- `merge_consecutive_roles(entries) : Array(Hash(String, JSON::Any))` — port
  google.ex:2248-2261: fold consecutive same-`role` entries into one,
  concatenating `parts` arrays.
- `encode_generation_config(opts) : JSON::Any?` — build a Hash with `temperature`
  (fetch_float?), `maxOutputTokens` (fetch_int? :max_tokens),
  `topP` (fetch_float? :top_p), `stopSequences` (fetch_stop → array; string →
  1-elem). Return nil when the hash is empty, else wrapped `JSON::Any`.
- `encode_tool(tool) : Hash(String, JSON::Any)` → `{"name", "description",
  "parameters" => deep_strip(tool.to_json_schema, ["$schema",
  "additionalProperties"])}`. `deep_strip` recursively deletes those keys from
  every nested object (port `deep_delete_keys`).
- `role_to_wire`, text-extraction helpers as needed.

**Goldens** (author from REAL encoder output; model `google:gemini-2.0-flash`):
- `chat_basic.json` — `[System "You are terse.", User "Hi"]`, `{temperature:0.7}`:
  `{"systemInstruction":{"parts":[{"text":"You are terse."}]},"contents":[{"role":"user","parts":[{"text":"Hi"}]}],"generationConfig":{"temperature":0.7}}`
  (NOTE: no `maxOutputTokens` — Gemini does NOT require max_tokens, so it is
  OMITTED when unset. This is a key difference from Anthropic.)
- `chat_sampling.json` — `{temperature:0.7, top_p:0.9, max_tokens:256, stop:["END"]}`:
  generationConfig has `temperature`, `maxOutputTokens:256`, `topP:0.9`,
  `stopSequences:["END"]`.
- `chat_tools.json` — one `get_weather` tool, user "What's the weather in Paris?":
  `{"contents":[{"role":"user","parts":[{"text":"What's the weather in Paris?"}]}],"tools":[{"functionDeclarations":[{"name":"get_weather","description":"Get the current weather for a location","parameters":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]}}]}]}`
  (`parameters` = the REAL `to_json_schema` output minus `$schema`/
  `additionalProperties` — author from the actual stripped output).

**Tests:** the 3 goldens via order-insensitive `JSON.parse(...).should eq(...)`;
PLUS: `systemInstruction` omitted when no system message; `maxOutputTokens`
OMITTED when `max_tokens` unset; `generationConfig` omitted entirely when no
sampling params set; assistant role encodes as `"model"`; tools omitted when
empty; `stop` scalar → 1-elem `stopSequences`; an assistant message with
`tool_calls` emits a `functionCall` part with the DECODED args object; two
consecutive `Role::Tool` messages fold into ONE `{role:"user"}` entry with two
`functionResponse` parts (merge_consecutive_roles); a tool message with nil
`tool_call_id` raises.

**Verify:** spec green; full suite green; format clean.

---

## Unit GU3 — `decode_response` + fixtures + FinishReason `RECITATION`

**Files:**
- EDIT `src/req_llm/response.cr` (add `RECITATION` to the ContentFilter arm)
- EDIT `src/req_llm/providers/google.cr` (replace `decode_response` stub +
  private decoders + the shared `normalize_google_usage`)
- NEW `spec/fixtures/google/chat_basic.json`, `chat_tools.json`
- NEW `spec/req_llm/providers/google_decode_spec.cr` (mirror anthropic_decode_spec)
- EDIT `spec/req_llm/response_spec.cr` (RECITATION case + unchanged-tokens guard)

**FinishReason change** (additive): add `"RECITATION"` to the ContentFilter arm:
```crystal
when "content_filter", "refusal", "RECITATION", "SAFETY" then ContentFilter
```
(`STOP`/`MAX_TOKENS` already mapped. Gemini `"OTHER"` → `Other` is acceptable.)
Test RECITATION→ContentFilter and that existing tokens are unchanged.

**Implement `decode_response`** per the Wire-shape "Response body" rules. Build
the message PARITY-style (one text part + optional one thinking part +
tool_calls) so `stream.join == decode`. `decode_content(candidate) →
{text, thinking, tool_calls}`. finish_reason: `tool_calls` present →
`FinishReason::ToolCalls`, else `from_wire(finishReason)`. `normalize_google_usage`
shared with GU4. Context merge like OpenAI/Anthropic. Absent candidates/empty
content → one empty text part (parity). Use nilable accessors throughout (no
throwing `.as_*`); `functionCall.args` absent → `{}`.

**Fixtures** ({status,headers,body} envelope, body = escaped JSON):
- `chat_basic.json`: one text part candidate, `finishReason:"STOP"`,
  `usageMetadata:{promptTokenCount:10, candidatesTokenCount:7, totalTokenCount:17}`.
- `chat_tools.json`: candidate parts `[{functionCall:{name:"get_weather",
  args:{location:"Paris"}}}]`, `finishReason:"STOP"` (deliberately STOP, to
  prove the tool_calls override), usageMetadata present.

**Tests:**
- decode basic → text, `finish_reason == Stop`, usage `input 10 / output 7`,
  context has appended assistant message.
- decode tools → 1 tool call (name `get_weather`,
  `args_map["location"]=="Paris"`), `finish_reason == ToolCalls` (proves the
  STOP→ToolCalls override).
- usage: `thoughtsTokenCount` → `reasoning_tokens`; output =
  candidates + reasoning; `cachedContentTokenCount` → `cached_tokens`; the
  total-fallback branch (`output = max(0, total-input)` when candidates absent).
- PARITY: decode a thought+text candidate → message is exactly `[Text,
  Thinking]` (concatenated), matching `ChunkAccumulator#finish`.
- e2e offline: `ReqLLM.generate_text("google:gemini-2.0-flash", "Hi",
  fixture:"chat_basic")` returns a costed Response, NO key in ENV.

**Verify:** specs green; full suite green (response_spec RECITATION + OpenAI/
Anthropic finish tokens unchanged); format clean.

---

## Unit GU4 — `decode_stream_event` + accumulator finish-upgrade

**Files:**
- EDIT `src/req_llm/streaming/accumulator.cr` (the finish-reason upgrade)
- EDIT `src/req_llm/providers/google.cr` (`decode_stream_event` + helpers)
- NEW `spec/req_llm/providers/google_stream_spec.cr` (mirror the others)
- EDIT `spec/req_llm/streaming/accumulator_spec.cr` (finish-upgrade unit +
  OpenAI/Anthropic no-regression)

**Accumulator change** (small, additive, provider-agnostic) — in
`ChunkAccumulator#finish`, after resolving `finish_reason`, upgrade `Stop` →
`ToolCalls` when tool calls were accumulated:
```crystal
finish_reason = FinishReason.from_wire(@finish_reason_wire)
# A response that produced tool calls finishes as ToolCalls. Some providers
# (Gemini) report finishReason "STOP" even with functionCall parts, and the
# part/finish frames may not co-locate; resolving it here makes the result
# frame-order-independent. NO-OP for OpenAI ("tool_calls") and Anthropic
# ("tool_use"), which already resolve to ToolCalls and never pair Stop with
# tool calls. Only Stop is upgraded — Length/ContentFilter (truncated or
# filtered mid-call) keep their real reason.
if finish_reason.stop? && !@tool_order.empty?
  finish_reason = FinishReason::ToolCalls
end
```
(Confirm `@tool_order` is the per-index tool-call order list and `FinishReason`
has a `stop?` predicate — enums get `#stop?` in Crystal. Update the class doc
comment to record this rule.)

**`decode_stream_event`** per the Wire-shape "Streaming" rules. Two overloads
(SSE::Event → `event.data`, and the String worker). Parse JSON, guard blank →
`[]`. Then:
- `extract_chunks_from_parts(parts)` → text/thinking/tool_call chunks (port
  google.ex:2548+). Tool calls: `StreamChunk.tool_call(name, args_hash,
  {"index" => i, "id" => id})` — pre-assembled, `i` = position among
  functionCall parts in this event.
- emit a trailing `meta{finish_reason: <RAW wire>}` when
  `candidates[0].finishReason` is non-null (emit the raw `"STOP"`; the
  accumulator upgrade above handles the tool-calls case — NO per-frame
  override).
- emit `meta{usage}` when `usageMetadata` present (shared `normalize_google_usage`
  → canonical keys, wrapped as `JSON::Any`).

**Tests** (`google_stream_spec.cr`):
- a frame with a text part → one Content chunk.
- a frame with a `thought:true` text part → one Thinking chunk.
- a frame with `finishReason:"STOP"` (no functionCall) → `meta{finish_reason
  "STOP"}` (raw; `from_wire`→Stop).
- a frame with a `functionCall` part → one ToolCall chunk (pre-assembled, with
  `index`/`id` metadata).
- a frame with `usageMetadata` → `meta{usage}` normalized (input/output/
  reasoning/cached).
- INTEGRATION: a realistic Gemini stream (a few text-part frames, then a final
  frame with `finishReason:"STOP"` + `usageMetadata`) folded through
  `ChunkAccumulator` → `text` concatenated, `finish_reason == Stop`, usage
  correct.
- INTEGRATION (tool call, CO-LOCATED): a single frame with a complete
  `functionCall` part + `finishReason:"STOP"` + `usageMetadata` folds through
  the accumulator into ONE ToolCall (name, args `location==Paris`),
  `finish_reason == ToolCalls` (proves the accumulator finish-upgrade).
- INTEGRATION (tool call, SEPARATED frames): frame A has the `functionCall`
  part (no finish); a LATER frame B has `finishReason:"STOP"` (no parts). Folded
  → still ONE ToolCall and `finish_reason == ToolCalls` (proves the upgrade is
  frame-order-independent — the whole point of moving it into the accumulator).
- INTEGRATION (PARALLEL tool calls in ONE frame): a frame whose parts contain
  TWO `functionCall`s → accumulator yields TWO distinct `ToolCall`s (proves
  position-within-event indexing; documents the co-location assumption).
- blank/`{}`/unrelated frame → `[]`.

**Accumulator regression** (`accumulator_spec.cr`):
- finish-upgrade unit: feed a tool-call chunk + a `meta{finish_reason "stop"}`
  → `finish` yields `ToolCalls`. Feed a tool-call chunk + `meta{finish_reason
  "length"}` → stays `Length` (only Stop upgrades). Feed a meta `stop` with NO
  tool calls → stays `Stop` (no spurious upgrade).
- OpenAI/Anthropic NO-REGRESSION: run `openai_stream_spec.cr`,
  `anthropic_stream_spec.cr`, `stream_response_spec.cr` — all green (they send
  `tool_calls`/`tool_use`, never `Stop`-with-tool-calls, so the rule is inert).

**Verify:** spec green; full suite green (OpenAI/Anthropic streaming unaffected
— the finish-upgrade is a verified no-op for them); format clean.

---

## Unit GU5 — `attach_stream` + stream fixture + end-to-end

**Files:**
- EDIT `src/req_llm/providers/google.cr` (`attach_stream`)
- NEW `spec/fixtures/google/chat_stream.json` (`{"stream":[...]}` schema)
- EDIT/NEW `spec/req_llm/providers/google_stream_spec.cr` (e2e via `stream_text`)

**Implement** — `attach_stream` REWRITES the URL to the streaming endpoint
(there is no `stream` body flag):
```crystal
def attach_stream(req : HTTP::Request) : HTTP::Request
  model   = req.model.as(LLMDB::Model)
  context = req.context.as(ReqLLM::Context)
  opts    = req.options.as(ReqLLM::Options::Validated)

  # Rewrite :generateContent -> :streamGenerateContent and request SSE framing.
  uri = req.url.dup
  uri.path = uri.path.sub(":generateContent", ":streamGenerateContent")
  uri.query = "alt=sse"
  req.url = uri

  apply_common_headers(req)               # x-goog-api-key (AUTH-SKIP-ON-REPLAY)
  req.headers["Accept"] = "text/event-stream"
  req.body = encode_chat_body(model, context, opts)  # identical body; no stream flag
  req
end
```
(Confirm `URI#dup` + assignment works; if `req.url.path=`/`query=` mutate in
place that's fine too. Verify the rewritten `request_target` includes
`?alt=sse` — `StreamAdapter.live` uses `uri.request_target`.)

**Stream fixture** `chat_stream.json` — author realistic Gemini `alt=sse`
frames (each a `data: {GenerateContentResponse}\n\n`; NO `[DONE]`). E.g. two
text-delta frames then a final frame carrying `finishReason:"STOP"` +
`usageMetadata`:
```json
{ "stream": [
  "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Streaming \"}]}}]}\n\n",
  "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"works.\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":11,\"candidatesTokenCount\":3,\"totalTokenCount\":14}}\n\n"
] }
```
(Verify `SSE.each_event` parses lone `data:` frames — it does per SU1.)

**Tests:**
- e2e replay: `ReqLLM.stream_text("google:gemini-2.0-flash", "Hi",
  fixture:"chat_stream")` — `text_stream.to_a` → `["Streaming ", "works."]`;
  `join` → `text == "Streaming works."`, `finish_reason == Stop`,
  `usage.input_tokens == 11`, `usage.output_tokens == 3`. No key in ENV. Wrap
  consumption in the `within` fail-fast helper.
- `attach_stream` unit: with a key (capture/restore), URL path ends
  `:streamGenerateContent`, query == `alt=sse`, `Accept == "text/event-stream"`,
  `x-goog-api-key` present; on replay (existing fixture, no key) `x-goog-api-key`
  absent but URL/Accept set. Body has NO `stream` key.

**Optional live validation** (ONLY if `GOOGLE_API_KEY` is available — check
`zsh -lc 'test -n "$GOOGLE_API_KEY" && echo PRESENT || echo ABSENT'`; never
print the key). If PRESENT: throwaway root script doing a real
`stream_text("google:gemini-2.0-flash", ...)`, print streamed tokens + join
Response (text, finish_reason, tokens, cost_str), run via `zsh -lc`, report
output WITHOUT the key, DELETE the script. If ABSENT: skip — fixture replay is
the authoritative contract. NEVER leak the key (it would be in the
`x-goog-api-key` header, not the URL with this design — still never print
headers).

**Verify:** full `crystal spec` green; `crystal tool format --check` clean;
update memory (`cr-llm-status.md`) marking Phase 4 complete.

---

## Cross-cutting verification (phase exit)

1. `crystal build src/cr_llm.cr -o /dev/null`.
2. `crystal spec` — entire suite green (existing OpenAI/Anthropic/streaming
   specs MUST stay green; the shared edits are the `RECITATION` token (GU3) and
   the `ChunkAccumulator` finish-upgrade (GU4) — both verified no-ops for the
   existing providers, each with a regression guard).
3. `crystal tool format --check`.
4. `Registry.fetch("google")` resolves; a `google:<id>` round-trips offline via
   fixture with no key.
5. Update `memory/cr-llm-status.md` + `MEMORY.md`.

## Open items (VERIFIED during planning)

- VERIFIED `Tool#to_json_schema` (tool.cr) preserves all top-level keys incl.
  `$schema`/`additionalProperties` → GU2 deep-strips those two for Google.
- VERIFIED `req.url` is a mutable `URI` `property` (http/request.cr:38) → GU5
  rewrites path/query.
- VERIFIED `FinishReason.from_wire` already maps `STOP`/`MAX_TOKENS`/`SAFETY`;
  only `RECITATION` is missing (GU3 adds it).
- VERIFIED `ChunkAccumulator` `merge_usage` (Phase 3) handles cumulative usage;
  `add_tool_call` groups by `metadata["index"]` and accepts pre-assembled
  `arguments` — so Gemini's complete-functionCall streaming needs no accumulator
  change.
- STILL INSPECT during impl: confirm `LLMDB.model("google:gemini-2.0-flash")`
  resolves and is priced (else pick another google id from
  `src/llmdb/data/models.json`); confirm `Message#name` getter exists for the
  tool-result `name` (message.cr has `name : String?` — verify) and the exact
  `URI` mutation API (`dup` + setters vs in-place).

## Execution

Subagent-driven development: one fresh subagent per unit (GU1→GU5), TDD, a
`superpowers:code-reviewer` pass between units (fix Critical/Important before
proceeding), final whole-phase review, then `finishing-a-development-branch`
(merge to master locally, per the established pattern). Subagents must NOT
modify `req_llm/` (vendored reference) or `docs/plans/`.
