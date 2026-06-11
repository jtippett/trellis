# Phase 5 — Structured output (`generate_object`) (implementation plan)

Status: DRAFT (pre-codex-review)
Author: Claude
Date: 2026-06-11
Depends on: Phases 1-4 complete on `master` (core pipeline, OpenAI, streaming, Anthropic, Google).

## Goal

Add `ReqLLM.generate_object(spec, prompt, schema, **opts) : Response` (and
`generate_object!` → the object) — the structured-output entry point, a faithful
idiomatic-Crystal port of the upstream `:object` operation
(`generation.ex` `generate_object`/`execute_generate_object`, `response.ex`
`unwrap_object`/`decode_object`, and each provider's `prepare_request(:object)`).
The model is asked to emit data matching a caller-supplied JSON Schema; the
result is parsed into `response.object` and validated against that schema.

### Key architectural insight (the design this plan rests on)

Across all three providers, structured output reduces to **two strategies**:
1. **json_schema mode** — the model returns the object as JSON TEXT in the
   normal assistant message content. Used by **OpenAI** (`response_format:
   {type:"json_schema", ...}`) and **Google** (`generationConfig.responseMimeType:
   "application/json"` + `responseSchema`/`responseJsonSchema`).
2. **tool_strict mode** — a synthetic `structured_output` tool is injected and
   the model is FORCED (via `tool_choice`) to call it; the object is that tool
   call's arguments. Used by **Anthropic** (its native json_schema output is
   beta; the synthetic tool is the robust path and reuses our existing tool
   encode/decode).

Therefore **only request-ENCODING differs per provider**. The normal pipeline
(`attach` → encode_body → transport → decode_response → usage) already produces
a `Response` carrying the assistant `message` (text + any tool_calls). The
**unwrap + validation are SHARED**: after the pipeline, `generate_object`
extracts the object — preferring a `structured_output` tool call's args, else
parsing `response.text` as JSON — then validates it against the schema and sets
`response.object`. This keeps per-provider changes small (each provider's
`encode_body` gains an `:object` branch; decode is unchanged) and the core logic
in one shared place.

## Scope (this phase)

IN: `ReqLLM.generate_object`/`generate_object!`; a JSON-Schema input (a
`Hash(String, JSON::Any)` — the same shape Tools already accept, NOT a
NimbleOptions/Zoi port); the `:object` operation plumbing
(`req.object_schema`); a minimal JSON Schema **validator** (`ReqLLM::Schema.validate`
→ `Error::Validation` on mismatch); shared **unwrap** (`Response.unwrap_object`);
OpenAI object via `response_format: json_schema` (OU1); Anthropic object via the
synthetic `structured_output` tool + `tool_choice` (OU2); Google object via
`responseMimeType` + `responseSchema`/`responseJsonSchema` (OU3). Goldens +
fixtures + offline e2e per provider.

OUT (deferred — track in memory, NOT bugs): `stream_object` (streaming
structured output); the Cache layer (`ReqLLM.Cache` — we have no cache);
type-coercion of loose model output (`coerce_object_types`/JSV coercion — we
validate strictly instead); `ReqLLM.schema(keyword)` NimbleOptions/Zoi
compilation (we accept JSON Schema maps directly); Anthropic NATIVE json_schema
output_format (beta — we use the synthetic tool); OpenAI/Anthropic
`:auto`/`:json_schema`/`:tool_strict` MODE selection options (each provider uses
its single best strategy); array/`anyOf`/`$defs` schema features in the
validator beyond a documented subset; the `name`/`description` schema metadata
beyond a default `"output_schema"` name.

## Architectural facts the implementer must rely on (verified)

1. **`Response#object`** (`response.cr`) already exists as a settable
   `property object : JSON::Any?`. `generate_object` sets it post-pipeline.
2. **`Error::Validation < Error`** (`error.cr:24`) exists, takes a message
   string. The validator raises it on schema mismatch.
3. **`req.operation : Symbol`** exists (`http/request.cr:45`). GU5/phase-4 set it
   in `prepare_request`. Phase 5 adds a new field `property object_schema :
   Hash(String, JSON::Any)?` (+ `object_schema_name : String?`) to
   `HTTP::Request`, set out-of-band by `generate_object` (like `fixture`/
   `api_key`) — it is NOT a generation option (the Options schema would reject
   it). Providers' `encode_body` read it; the shared unwrap does not need it
   (it works off the decoded Response) but validation does.
4. **The pipeline is reused verbatim.** `generate_object` mirrors
   `generate_text` (`generation.cr`): resolve model+provider, normalize prompt
   to Context, validate `**opts`, `prepare_request(:object, ...)`, stash
   `object_schema`/`fixture`/`api_key`, `attach`, `Pipeline.run` → Response.
   Then unwrap + validate + set `object`.
5. **`Response#text`** concatenates text parts; **`Response#tool_calls`** returns
   the assistant tool calls; **`ToolCall#arguments`** is the RAW args JSON string
   (`#args_map` coerces to a Hash and would drop a top-level array — unwrap uses
   `#arguments`). Unwrap uses these — no provider-specific decode changes needed.
6. **`Tool`** supports `strict : Bool` and a JSON-Schema `parameter_schema`. The
   Anthropic synthetic tool is `Tool.new("structured_output", "...", schema,
   strict: true)`.
7. **`enforce_strict_recursive`** (upstream adapter_helpers.ex): an object schema
   in strict mode must have `required` = ALL property keys and
   `additionalProperties: false`, recursing into nested `properties` and array
   `items`. Phase 5 ports a focused `Schema.enforce_strict` used by the OpenAI
   `json_schema` body and the Anthropic synthetic tool schema.
8. **`encode_chat_body`** in each provider is reused; the `:object` branch adds
   provider-specific keys to the SAME body. Anthropic's encode currently has NO
   `tool_choice` support (deferred Phase 3) — OU2 adds it (only what `:object`
   needs: `tool_choice: {type:"tool", name:"structured_output"}`).

## Shared design

### `HTTP::Request` new field
Add to `http/request.cr` (real fields, initialized nil):
```crystal
property object_schema : Hash(String, JSON::Any)?
property object_schema_name : String?
```

### `ReqLLM::Schema` (NEW `src/req_llm/schema.cr`, module `ReqLLM::Schema`)
> NOTE: distinct from `ReqLLM::Options::Schema` (option validation). This is the
> OUTPUT JSON-Schema validator + helpers.
- `Schema.enforce_strict(schema : Hash(String, JSON::Any)) : Hash(String,
  JSON::Any)` — port `enforce_strict_recursive` (object → required=all keys +
  additionalProperties:false, recurse `properties` values and array `items`;
  leave other nodes unchanged). Pure; returns a new hash (don't mutate input).
  SCOPE: recurse `properties` + array `items` ONLY. `$defs`/`anyOf`/`oneOf`
  enforcement is DEFERRED (upstream adapter_helpers.ex also recurses those, but
  Phase 5 schemas are flat object/array/scalar; the validator is likewise
  permissive on those keywords — see `Schema.validate`). A schema using
  `$defs`/`anyOf` in OpenAI strict mode is out of scope this phase; document it.
- `Schema.validate(data : JSON::Any, schema : Hash(String, JSON::Any)) : Nil` —
  a MINIMAL JSON Schema validator. Raises `Error::Validation` with a precise
  message (path + expected vs got) on the FIRST mismatch; returns on success.
  Supported subset (document it):
  - top-level/any `"type"`: `object`/`string`/`integer`/`number`/`boolean`/
    `array`/`null` — type-check `data`.
  - object: each key in `"required"` must be present; each present property
    whose name is in `"properties"` recurses against its subschema; unknown
    extra keys are allowed UNLESS `additionalProperties == false` (then a
    non-property key is a violation).
  - array: each element recurses against `"items"` (when `items` is an object
    schema).
  - a schema with no recognized `"type"` (or an unsupported keyword) passes that
    node (permissive — we validate what we understand). NOTE in a comment that
    this is a deliberate subset, not full JSON Schema.

### Shared unwrap (`Response.unwrap_object` in `response.cr`)
```crystal
# Extract the structured object from a completed Response, regardless of mode:
#   * tool_strict mode (Anthropic): the `structured_output` tool call's args.
#   * json_schema mode (OpenAI/Google): the assistant text parsed as JSON.
# Returns the object as JSON::Any, or raises Error::Validation when neither
# yields a JSON object/array.
def unwrap_object : JSON::Any
  if tc = tool_calls.find { |c| c.name == "structured_output" }
    # Parse the RAW arguments JSON, NOT tc.args_map: args_map returns
    # Hash(String, JSON::Any) and rescues a non-object to `{}`, which would
    # silently drop a top-level ARRAY structured output. Anthropic decode keeps
    # the raw tool_use input in `tc.arguments` (a JSON string), so parse it
    # directly and accept either a Hash or an Array.
    parsed = (JSON.parse(tc.arguments) rescue nil)
    case parsed.try(&.raw)
    when Hash, Array then return parsed.not_nil!
    end
  end
  txt = text
  unless txt.empty?
    parsed = (JSON.parse(txt) rescue nil)
    case parsed.try(&.raw)
    when Hash, Array then return parsed.not_nil!
    end
  end
  raise Error::Validation.new("no structured output found in response")
end
```
(VERIFIED: `ToolCall#name : String` + `#arguments : String` (the raw JSON);
`Response#text : String` + `#tool_calls : Array(ToolCall)` all exist.)

### `ReqLLM.generate_object` (in `generation.cr`)
```crystal
def self.generate_object(spec : String, prompt : String | Context,
                         schema : Hash(String, JSON::Any), *,
                         name : String = "output_schema",
                         fixture : String? = nil, api_key : String? = nil,
                         **opts) : Response
  model = LLMDB.model(spec)
  provider = Registry.fetch(model.provider)

  context = case prompt
            in String  then Context.new([Message.new(Role::User, prompt)])
            in Context then prompt
            end
  validated = Options.validate(opts)

  req = provider.prepare_request(:object, model, context, validated)
  req.object_schema = schema
  req.object_schema_name = name
  req.fixture = fixture if fixture
  req.api_key = api_key if api_key
  provider.attach(req)

  response = HTTP::Pipeline.run(req, HTTP::ClientAdapter.new)
  object = response.unwrap_object          # raises Error::Validation if absent
  Schema.validate(object, schema)          # raises Error::Validation on mismatch
  response.object = object
  response
end

# Returns just the object (a JSON::Any). Raises on error / missing object.
def self.generate_object!(spec, prompt, schema, **opts) : JSON::Any
  generate_object(spec, prompt, schema, **opts).object.not_nil!
end
```
- `prepare_request(:object, ...)` in each provider must NOT raise/differ from
  `:chat` at the prepare stage beyond what's needed (OpenAI/Google build the
  same URL; the `:object` encoding happens in `encode_body` reading
  `req.object_schema`). The base providers currently ignore `operation` in
  `prepare_request` (they build the chat URL regardless) — that's fine; just
  pass `:object` through so `encode_body`/decode can branch on it.

### Encode threading (EXACT — do not "pass through" vaguely)
All three providers' `encode_body(req)` TODAY discard `req.operation` and call
`encode_chat_body(model, context, opts)` (openai.cr:52, anthropic.cr:72,
google.cr:109). For `:object`, each unit makes `encode_body` the dispatch point,
reading the new `req.object_schema`/`req.object_schema_name` fields directly off
`req`. The required shape (adapt per provider):
```crystal
def encode_body(req : HTTP::Request) : HTTP::Request
  model = req.model.as(LLMDB::Model)
  context = req.context.as(ReqLLM::Context)
  opts = req.options.as(ReqLLM::Options::Validated)
  if req.operation == :object && (schema = req.object_schema)
    req.body = encode_object_body(model, context, opts, schema, req.object_schema_name || "output_schema")
  else
    req.body = encode_chat_body(model, context, opts)
  end
  req
end
```
Each provider implements a PUBLIC `encode_object_body(model, context, opts,
schema, name) : String` (public so a golden test can exercise it directly with a
real schema — see the golden-test note below) that builds the provider's object
body. This is the explicit signature the subagent must add; adding the request
fields without this dispatch would emit no object-mode keys.

**Golden tests drive `encode_object_body` directly** (it is public), passing the
schema + name explicitly — analogous to how the existing chat goldens call the
public `encode_chat_body`. The offline e2e tests additionally exercise the full
`encode_body(req)` path (request fields set by `generate_object`), so both the
helper and the request-threading are covered.

---

### Fixture envelope (ALL object fixtures)
Non-streaming fixtures use the existing `{status, headers, body}` envelope where
`body` is the response as an ESCAPED JSON STRING (see
`spec/fixtures/openai/chat_basic.json`). For OpenAI/Google object fixtures, that
inner body's assistant content/candidate text is itself a JSON object rendered
as a string (i.e. JSON-in-a-string-in-the-envelope — escape carefully). For the
Anthropic object fixture, the inner body has a `tool_use` content block named
`structured_output` with an `input` object. Author with `.to_json`/`to_pretty_json`
of a Crystal value rather than hand-escaping, to avoid invalid offline fixtures.

## Unit OU1 — Shared framework + JSON Schema validator + OpenAI object

**Files:**
- EDIT `src/req_llm/http/request.cr` (add `object_schema`/`object_schema_name`)
- NEW `src/req_llm/schema.cr` (`ReqLLM::Schema.validate` + `enforce_strict`)
- EDIT `src/cr_llm.cr` (require `./req_llm/schema` before generation; the new
  Request fields need no new require)
- EDIT `src/req_llm/response.cr` (add `unwrap_object`)
- EDIT `src/req_llm/generation.cr` (add `generate_object`/`generate_object!`)
- EDIT `src/req_llm/providers/openai.cr` (`:object` branch in encode → add
  `response_format`)
- NEW `spec/req_llm/schema_spec.cr` (validator + enforce_strict)
- NEW `spec/req_llm/generation_object_spec.cr` (generate_object e2e + unwrap)
- NEW `spec/golden/openai/object_basic.json` (the object request body)
- NEW `spec/fixtures/openai/object_basic.json` (a response whose content is the
  JSON object)

**OpenAI `:object` encode** — implement the public `encode_object_body(model,
context, opts, schema, name)` (called by the `encode_body` dispatch above) that
builds the normal chat body PLUS:
```json
"response_format": {
  "type": "json_schema",
  "json_schema": {"name": "<name>", "strict": true, "schema": <Schema.enforce_strict(schema)>}
}
```
Reuse the existing chat-body construction (messages, model, stream:false) and
add the `response_format` key — e.g. factor the shared body assembly so
`encode_object_body` = chat body + `response_format`, or build the base hash and
`maybe_put` the response_format. (Tools are typically absent for object mode.)
Decode is UNCHANGED — the response content is the JSON text, and the shared
`unwrap_object` parses it.

**Tests (TDD):**
- `Schema.validate` unit: a conforming object passes; a missing required key
  raises `Error::Validation`; a wrong-typed property raises; nested object +
  array element type mismatch raises; `additionalProperties:false` + an extra
  key raises; an unknown/typeless node passes (documented subset).
- `Schema.enforce_strict` unit: object → all keys required +
  additionalProperties:false, recursing into a nested object property.
- `Response#unwrap_object` unit: from a `structured_output` tool call → its args;
  from assistant text that is a JSON object → parsed; from text that's a JSON
  array → parsed; from neither → raises.
- OpenAI object body golden: the public `encode_object_body(model, context,
  opts, schema, name)` for a `{name:string, age:integer}` schema emits the
  `response_format` json_schema shape with `strict:true` + enforced schema →
  matches `object_basic.json`. (The full `encode_body(req)` dispatch is covered
  by the offline e2e below.)
- e2e offline: `ReqLLM.generate_object("openai:gpt-4o-mini", "...", schema,
  fixture:"object_basic")` → `response.object` is the parsed map (e.g.
  `object["name"].as_s == "Alice"`), validated, NO key in ENV (capture/restore).
- validation failure e2e: a fixture whose JSON content violates the schema (e.g.
  age is a string) → `generate_object` raises `Error::Validation`.

**Verify:** `crystal spec` full suite green; build; format.

---

## Unit OU2 — Anthropic object (synthetic `structured_output` tool)

**Files:**
- EDIT `src/req_llm/providers/anthropic.cr` (`:object` branch in encode →
  inject the synthetic tool + `tool_choice`; add minimal `tool_choice` support)
- NEW `spec/fixtures/anthropic/object_basic.json` (a response with a `tool_use`
  block named `structured_output`)
- EDIT `spec/req_llm/providers/anthropic_spec.cr` (object encode) + the object
  e2e (in `generation_object_spec.cr` or the anthropic spec)

**Anthropic `:object` encode** — implement the public `encode_object_body(model,
context, opts, schema, name)` (called by the `encode_body` dispatch). It builds
the normal Messages body but with:
- a synthetic tool `Tool.new("structured_output", "Generate structured output
  matching the provided schema", Schema.enforce_strict(schema), strict: true)`
  encoded via the existing `encode_tool` as the tools list (object mode ignores
  user tools — the forced tool IS the output channel).
- `tool_choice: {"type" => "tool", "name" => "structured_output"}` in the body
  (this is the minimal `tool_choice` support OU2 adds — ONLY the forced-tool
  shape; general tool_choice remains deferred). Note the existing "tools omitted
  when empty" guard does not interfere: object mode always has the synthetic
  tool, so `tools` is non-empty.
- The rest of the Messages body (system hoist, contents, max_tokens default
  1024) is unchanged via the shared body construction. Decode already turns the
  `tool_use` block into a `structured_output` tool call → shared `unwrap_object`
  reads its raw arguments.

**Tests (TDD):**
- object encode: body has `tools:[{name:"structured_output", input_schema:
  <enforced>, ...}]` and `tool_choice:{type:"tool", name:"structured_output"}`.
- e2e offline: `generate_object("anthropic:claude-3-5-sonnet-20241022", "...",
  schema, fixture:"object_basic")` → `response.object` from the tool call args,
  validated, NO key.
- (Optional) a golden for the object request body.

**Verify:** full suite green; build; format. (No regression to Phase-3
non-object Anthropic specs — the `:object` branch is operation-gated.)

---

## Unit OU3 — Google object (`responseMimeType` + `responseSchema`)

**Files:**
- EDIT `src/req_llm/providers/google.cr` (`:object` branch in encode →
  `generationConfig.responseMimeType` + responseSchema/responseJsonSchema +
  `convert_to_google_schema`)
- NEW `spec/fixtures/google/object_basic.json` (a candidate whose text is the
  JSON object)
- EDIT `spec/req_llm/providers/google_spec.cr` (object encode) + object e2e

**Google `:object` encode** — implement the public `encode_object_body(model,
context, opts, schema, name)` (called by the `encode_body` dispatch). It builds
the normal Gemini body but sets in `generationConfig`:
- `responseMimeType: "application/json"`.
- schema: if the model is gemini-2.5+/gemini-3 (`json_schema_supported?`:
  id starts with `gemini-2.5`/`gemini-3`) → `responseJsonSchema: <plain
  json_schema>`; ELSE → `responseSchema: <convert_to_google_schema(schema)>`.
  Port `convert_to_google_schema` (google.ex:1298-1343): delete
  `additionalProperties`; map `"type"` value to UPPERCASE
  (object→OBJECT/array→ARRAY/string→STRING/integer→INTEGER/number→NUMBER/
  boolean→BOOLEAN/null→NULL); recurse `properties` values and object `items`;
  add `propertyOrdering` = property key order when an object has properties.
- The rest of the body is unchanged. Decode is UNCHANGED — the candidate text is
  the JSON object; shared `unwrap_object` parses it.
- Use `google:gemini-2.0-flash` for the fixture/golden so the `responseSchema`
  (uppercase-type) conversion path is exercised. (A `gemini-2.5-flash` test can
  additionally assert the `responseJsonSchema` plain-passthrough branch.)

**Tests (TDD):**
- `convert_to_google_schema` unit: types uppercased, additionalProperties
  dropped, nested properties recursed, propertyOrdering added.
- object encode (gemini-2.0-flash): generationConfig has
  `responseMimeType:"application/json"` + `responseSchema` (uppercase types);
  (gemini-2.5-flash): `responseJsonSchema` (plain). 
- e2e offline: `generate_object("google:gemini-2.0-flash", "...", schema,
  fixture:"object_basic")` → `response.object` parsed from candidate text,
  validated, NO key.

**Verify:** full suite green; build; format.

---

## Cross-cutting verification (phase exit)

1. `crystal build src/cr_llm.cr -o /dev/null`.
2. `crystal spec` — entire suite green (existing chat/stream specs for all three
   providers MUST stay green; the `:object` encode branches are operation-gated;
   no shared streaming/accumulator change this phase).
3. `crystal tool format --check`.
4. `generate_object` round-trips offline via fixture for ALL THREE providers
   with no key, and a schema-violating fixture raises `Error::Validation`.
5. Update `memory/cr-llm-status.md` + `MEMORY.md`.

## Open items (VERIFIED during planning)

- VERIFIED `Response#object` settable property + `Error::Validation` exist.
- VERIFIED `req.operation` exists; Phase 5 adds `object_schema`/
  `object_schema_name` real fields to `HTTP::Request`.
- VERIFIED catalog keys resolve: `openai:gpt-4o-mini`,
  `anthropic:claude-3-5-sonnet-20241022`, `google:gemini-2.0-flash`,
  `google:gemini-2.5-flash`.
- VERIFIED `enforce_strict_recursive` shape (object→required-all +
  additionalProperties:false). Our port recurses `properties` + array `items`
  ONLY; `$defs`/`anyOf`/`oneOf` recursion is explicitly DEFERRED (see
  `Schema.enforce_strict` scope note) — consistent with the validator's
  permissive handling of those keywords.
- STILL INSPECT during impl: exact `ToolCall#name`/`#arguments` (raw JSON string;
  unwrap parses this, NOT `#args_map`), `Response#text`/
  `#tool_calls` signatures (used by unwrap); how each provider's `encode_chat_body`
  is structured so the `:object` branch threads `response_format`/`tool_choice`/
  `responseSchema` cleanly (mirror the existing value-based `maybe_put` style);
  whether `prepare_request(:object)` needs any change beyond passing the
  operation through (it should not — encode/decode branch on `req.operation`).

## Execution

Subagent-driven development: one fresh subagent per unit (OU1→OU3), TDD, a
`superpowers:code-reviewer` pass between units (fix Critical/Important before
proceeding), final whole-phase review, then `finishing-a-development-branch`
(merge to master locally). Subagents must NOT modify `req_llm/` (vendored
reference) or `docs/plans/`.
