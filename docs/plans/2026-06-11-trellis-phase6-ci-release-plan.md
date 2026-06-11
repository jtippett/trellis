# Phase 6 — CI & release hardening (implementation plan)

Status: DRAFT (pre-codex-review)
Author: Claude
Date: 2026-06-11
Depends on: Phases 1-5 complete on `master` (full library: OpenAI/Anthropic/Google,
chat + streaming + tools + structured output). Library renamed to **Trellis**
(module `Trellis`, shard `trellis`, `src/trellis/`, repo
https://github.com/jtippett/trellis).

## Goal

Make the repo CI-ready and release-ready: a push/PR CI workflow, opt-in live
integration specs + a manual workflow to run them, and a README with the public
API + a provider-support matrix generated from `LLMDB`. The weekly
`sync-models.yml` already exists and opens PRs on catalog diff — verify it needs
no changes post-rename.

Crystal pin: **1.20.2** (matches `crystal --version` and `sync-models.yml`).
This is infra/docs, not library logic — no `src/trellis/*` behavior changes.

## Scope (this phase)

IN: `.github/workflows/ci.yml` (format-check + spec + build on push/PR);
opt-in live integration specs (`spec/live/`, tagged `live`, gated behind a
`TRELLIS_LIVE` flag + per-provider key) + `.github/workflows/live.yml`
(manual, secrets); `tasks/provider_matrix.cr` (a generator reading `LLMDB` +
`Trellis::Registry`); `README.md` embedding the matrix; verify `sync-models.yml`.

OUT (deferred): publishing to a shards registry / git tags / release automation;
`shards install` caching (no dependencies — `shard.yml` has none); docs site /
API doc generation (`crystal docs`); benchmarking; coverage; pushing to the
remote (the user merges to master locally and will push when ready).

## Architectural facts the implementer must rely on (verified)

1. **`sync-models.yml` already exists** (`.github/workflows/sync-models.yml`):
   weekly cron + `workflow_dispatch`, runs `crystal run tasks/sync_models.cr`,
   `crystal spec`, detects a diff in `src/llmdb/data/models.json`/`src/llmdb.cr`,
   and opens a PR via `peter-evans/create-pull-request@v6`. It does NOT reference
   the old `cr_llm`/`ReqLLM` names (it runs the task + spec + greps llmdb paths),
   so the rename did NOT break it. PU1 just verifies this and pins crystal 1.20.2
   consistently.
2. **`crystal spec` tags**: Crystal's spec runner supports
   `it "...", tags: "live"` and CLI `--tag live` (run ONLY tagged) / `--tag
   ~live` (EXCLUDE tagged). With no `--tag`, ALL examples run. `pending!(msg)`
   skips an example at runtime (counts as pending, not failure).
3. **Live-spec safety**: live examples make REAL paid API calls. They MUST be
   double-gated: (a) an explicit opt-in env `TRELLIS_LIVE == "1"` (so a
   contributor who merely has `OPENAI_API_KEY` exported does NOT hit the API on
   a normal `crystal spec`), AND (b) the relevant provider key present. When
   either is absent → `pending!`. Tagged `live` so the manual workflow targets
   them and normal CI can exclude them.
4. **`LLMDB` public API** (verified): `LLMDB.models : Array(Model)`,
   `LLMDB.providers : Array(String)`, `LLMDB::VERSION : String`,
   `LLMDB::Model#provider`/`#id`/`#cost` (Cost has `#priced?`). The catalog has
   ~5142 models / ~140 providers.
5. **`Trellis::Registry`** maps provider id → provider. The 3 IMPLEMENTED
   providers self-register on require. **`Trellis::Registry.ids : Array(String)`
   ALREADY EXISTS** (registry.cr:32-34, returns the registered ids) — the matrix
   generator MUST use it (do NOT hardcode the 3 or add a new helper). Note the
   ids are in registration/hash order; sort for stable display.
6. **Public API surface** (for the README): `Trellis.generate_text(spec, prompt,
   **opts) : Response`, `Trellis.stream_text(...) : StreamResponse` (with
   `each`/`join`/`text_stream`), `Trellis.generate_object(spec, prompt, schema,
   **opts) : Response` / `generate_object!`. Options: temperature, max_tokens,
   top_p, stop, tools, etc. (`Trellis::Options::BASE_SCHEMA`). `fixture:` for
   offline replay; `api_key:` out-of-band. Errors: `Trellis::Error` tree.

## Unit PU1 — CI workflow + sync-models verification

**Files:**
- NEW `.github/workflows/ci.yml`
- (verify, likely no change) `.github/workflows/sync-models.yml`

**`ci.yml`** — on `push` + `pull_request` (to any branch; or just `main`/
`master` + PRs):
```yaml
name: ci
on:
  push:
  pull_request:
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: crystal-lang/install-crystal@v1
        with:
          crystal: "1.20.2"
      - name: Format check
        run: crystal tool format --check
      - name: Build
        run: crystal build src/trellis.cr -o /dev/null
      - name: Spec
        run: crystal spec
```
Notes:
- No `shards install` step — `shard.yml` declares no dependencies (adding it is
  harmless but unnecessary; omit to keep CI minimal, or include `shards install`
  defensively if the implementer prefers — document the choice).
- `crystal spec` runs the offline suite; live specs (PU2) are `pending!` without
  `TRELLIS_LIVE`, so they stay green here (no secrets in `ci.yml`). Confirm this
  interaction once PU2 lands (run order independent).
- Pin `crystal: "1.20.2"` to match local + sync-models.
- Action versions: use `actions/checkout@v4` + `crystal-lang/install-crystal@v1`
  — INTENTIONALLY matching the existing `sync-models.yml` (which uses `@v4`) for
  consistency across workflows. (checkout v5/v6 exist but changed runner
  requirements; v4 is fully supported and keeps all three workflows uniform.
  Deliberate choice, not an oversight.)
- Verify `sync-models.yml` still works post-rename (it doesn't reference
  cr_llm/ReqLLM); make NO change unless a real break is found.

**Verify:** the three commands the workflow runs (`crystal tool format --check`,
`crystal build src/trellis.cr -o /dev/null`, `crystal spec`) all pass locally
(they do — 351/0). YAML is well-formed (parse with a YAML check or `ruby -ryaml`/
`python -c`). Cannot run the GH workflow locally — correctness = valid YAML +
pinned action versions (`actions/checkout@v4`, `crystal-lang/install-crystal@v1`)
+ the commands proven locally.

**Commit** on the phase branch.

## Unit PU2 — Live integration specs + manual workflow

**Files:**
- NEW `spec/live/live_spec.cr` (tagged `live`, double-gated)
- NEW `.github/workflows/live.yml` (manual, secrets)

**`spec/live/live_spec.cr`** — a small real-API smoke per provider, double-gated.
NOTE: the sketch below uses `...`/`pending!(...)` as SHORTHAND — the implementer
writes real, compiling Crystal: a real `pending!` message string in every
example, and a real `Hash(String, JSON::Any)` schema for `generate_object` (the
exact type `generate_object` requires — generation.cr:118). Use EXACT catalog
ids (no wildcards): `openai:gpt-4o-mini`, `anthropic:claude-3-5-haiku-20241022`,
`google:gemini-2.0-flash` (all verified present). Helper:
```crystal
require "../spec_helper"

# Live examples hit real paid APIs. They run ONLY when explicitly opted in via
# TRELLIS_LIVE=1 AND the provider key is present; otherwise pending! (so a normal
# `crystal spec` — even with keys exported — never makes a network call).
private def live?(key : String) : Bool
  ENV["TRELLIS_LIVE"]? == "1" && !(ENV[key]?.nil? || ENV[key]?.try(&.empty?))
end

describe "live integration", tags: "live" do
  it "OpenAI generate_text" do
    pending!("set TRELLIS_LIVE=1 + OPENAI_API_KEY") unless live?("OPENAI_API_KEY")
    resp = Trellis.generate_text("openai:gpt-4o-mini", "Reply with exactly: OK")
    resp.text.should_not be_empty
    resp.usage.try(&.input_tokens).should_not be_nil
  end

  it "OpenAI stream_text" do
    pending!(...) unless live?("OPENAI_API_KEY")
    stream = Trellis.stream_text("openai:gpt-4o-mini", "Count: 1 2 3")
    stream.text_stream.to_a.join.should_not be_empty
  end

  it "OpenAI generate_object" do
    pending!(...) unless live?("OPENAI_API_KEY")
    schema = {...{type:object, properties:{name:string}, required:[name]}...}
    obj = Trellis.generate_object!("openai:gpt-4o-mini", "A person named Alice", schema)
    obj["name"].as_s.should_not be_empty
  end

  # Same trio for Anthropic ("anthropic:claude-3-5-haiku-20241022",
  # ANTHROPIC_API_KEY) and Google ("google:gemini-2.0-flash", GOOGLE_API_KEY).
  # A real generate_object schema looks like:
  #   schema = {"type" => JSON::Any.new("object"),
  #             "properties" => JSON::Any.new({"name" => JSON::Any.new({"type" => JSON::Any.new("string")})} of String => JSON::Any),
  #             "required" => JSON::Any.new([JSON::Any.new("name")])} of String => JSON::Any
end
```
Use cheap models (gpt-4o-mini, claude-3-5-haiku-*, gemini-2.0-flash). Keep
prompts tiny. Each provider's three examples gate on its own key.

**`.github/workflows/live.yml`** — manual only:
```yaml
name: live
on:
  workflow_dispatch: {}
permissions:
  contents: read
jobs:
  live:
    runs-on: ubuntu-latest
    env:
      TRELLIS_LIVE: "1"
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      GOOGLE_API_KEY: ${{ secrets.GOOGLE_API_KEY }}
    steps:
      - uses: actions/checkout@v4
      - uses: crystal-lang/install-crystal@v1
        with: { crystal: "1.20.2" }
      - name: Live specs
        run: crystal spec spec/live --tag live
```
(A provider whose secret isn't configured → its examples `pending!`, not fail —
so the workflow is usable with any subset of keys.)

**Verify:** `crystal spec` (no env) → the new live examples are PENDING, suite
still green (351 examples + N pending, 0 failures). `crystal build` clean. YAML
well-formed. Do NOT run live for real here (no keys / costs) — the `pending!`
path is the tested contract, exactly like the per-phase offline fixtures.

**Commit** on the phase branch.

## Unit PU3 — README + provider-support matrix generator

**Files:**
- NEW `tasks/provider_matrix.cr`
- NEW `README.md` (embedding the generated matrix snapshot)
- (NO registry change needed — `Trellis::Registry.ids` already exists at
  registry.cr:32-34; the generator uses it directly.)

**`tasks/provider_matrix.cr`** — `require "../src/trellis"` (resolves the same way
`tasks/sync_models.cr` requires; from `tasks/`, `../src/trellis`), then produce a
markdown table of the IMPLEMENTED providers — iterate `Trellis::Registry.ids`
(the existing accessor; `.sort` for stable order) — with their catalog model
counts (from `LLMDB`) and capability columns. All three
implemented providers support chat/streaming/tools/structured-output, so:
```
| Provider  | id          | Models | Chat | Streaming | Tools | Structured |
|-----------|-------------|-------:|:----:|:---------:|:-----:|:----------:|
| OpenAI    | `openai`    |    NNN |  ✓   |     ✓     |   ✓   |     ✓      |
| Anthropic | `anthropic` |    NNN |  ✓   |     ✓     |   ✓   |     ✓      |
| Google    | `google`    |    NNN |  ✓   |     ✓     |   ✓   |     ✓      |
```
- Model count per provider = `LLMDB.models.count { |m| m.provider == id }`.
- Print a header line: `Catalog: <LLMDB.models.size> models across
  <LLMDB.providers.size> providers (models.dev snapshot <LLMDB::VERSION>).` and
  note that Trellis IMPLEMENTS 3 of those providers (the rest are catalog-only).
- Output the markdown to STDOUT. The generator is the source of truth; the
  README embeds a committed snapshot between HTML markers
  `<!-- PROVIDER_MATRIX:START -->` ... `<!-- PROVIDER_MATRIX:END -->` so it can
  be regenerated. (Optionally the task can rewrite the README between the
  markers; simplest is print-to-stdout + paste. Document how to regenerate.)

**`README.md`** — concise, accurate, covering:
- One-line description + the Trellis = CR+LLM name note + Apache-2.0 + the
  upstream `req_llm` lineage (a faithful Crystal port).
- Install (`shards`): a `dependencies:` snippet pointing at the git repo
  (`github: jtippett/trellis`).
- Quick start: `Trellis.generate_text("openai:gpt-4o-mini", "Hello")` → text;
  `stream_text` (each/join/text_stream); `generate_object` with a JSON-Schema
  map. Show reading the API key from `OPENAI_API_KEY` (and `.env`).
- Provider-support matrix (the embedded snapshot).
- Options (temperature/max_tokens/top_p/stop/tools); `Response` exposes
  `text`/`tool_calls`/`usage`/`object` (NOT `cost_str` — that is on
  `Trellis::Usage`, so show `resp.usage.try(&.cost_str)` or
  `if u = resp.usage`); error types (`Trellis::Error`); and the offline
  `fixture:` mechanism (point at `examples/` + the spec fixtures). Verify every
  shown method against `src/trellis/{generation,response,usage}.cr`.
- A short "how it works" note: models.dev-driven `LLMDB` catalog + the named-step
  HTTP pipeline (faithful port of Elixir `req_llm`).
- Keep code samples COPY-RUNNABLE and accurate to the real API (verify method
  names/signatures against `src/trellis/generation.cr`). Do NOT invent options.

**Verify:** `crystal run tasks/provider_matrix.cr` prints a sane matrix (real
model counts > 0 for each of the 3; catalog totals match `LLMDB`); the README's
embedded matrix matches that output; every README code sample compiles
conceptually (method names exist in `src/trellis/`); `crystal build` +
`crystal spec` still green; format clean. (`Registry.ids` already exists and is
spec-covered — no registry change in this unit.)

**Commit** on the phase branch.

## Cross-cutting verification (phase exit)

1. `crystal build src/trellis.cr -o /dev/null`; `crystal tool format --check`;
   `crystal spec` (green; live specs pending).
2. All workflow YAML well-formed; action versions pinned; commands proven local.
3. `tasks/provider_matrix.cr` runs and matches the README snapshot.
4. Update `memory/cr-llm-status.md` + `MEMORY.md` (Phase 6 done → project
   feature-complete per the original roadmap).

## Open items (VERIFIED during planning)

- VERIFIED `sync-models.yml` exists + opens PRs + doesn't reference the old name.
- VERIFIED `crystal --version` = 1.20.2 (pin target).
- VERIFIED `LLMDB.models`/`.providers`/`VERSION` + `Model#provider` for the matrix.
- VERIFIED `Trellis::Registry.ids` already exists (registry.cr:32) — the matrix
  generator uses it; no registry change needed.
- VERIFIED exact live model ids present: `openai:gpt-4o-mini`,
  `anthropic:claude-3-5-haiku-20241022`, `google:gemini-2.0-flash`.
- STILL INSPECT: confirm `crystal spec --tag live` / `pending!` behavior on the
  installed Crystal (1.20.2) at impl time (codex confirmed against 1.20 docs);
  `install-crystal@v1` accepts `crystal: "1.20.2"` (confirmed by its README).

## Execution

Subagent-driven development: one fresh subagent per unit (PU1→PU3), with a
`superpowers:code-reviewer` pass between units (CI correctness, live-gating
safety, README accuracy). Final whole-phase review, then
`finishing-a-development-branch` (merge to master locally). Subagents must NOT
modify `req_llm/` (vendored) or `docs/plans/`, and must NOT push to the remote.
