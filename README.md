# Trellis

A faithful Crystal port of Elixir's [`req_llm`](https://github.com/agentjido/req_llm) —
a struct/pipeline LLM client for **OpenAI**, **Anthropic**, and **Google**, covering
text generation, streaming, tool calls, and structured output.

The name nods to the **LL** of LLM (tre**ll**is) and to its structured, woven-together
pipeline. Licensed under **Apache-2.0**.

## Install

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  trellis:
    github: jtippett/trellis
```

Then `shards install` and require it:

```crystal
require "trellis"
```

## Quick start

```crystal
require "trellis"

# Reads the key from OPENAI_API_KEY in the environment (or load a .env first —
# see below). The spec string is "provider:model".
resp = Trellis.generate_text("openai:gpt-4o-mini", "Hello!")

puts resp.text
puts resp.usage.try(&.cost_str) # e.g. "$0.0000027" (nil when unpriced)
```

The API key is read from the provider's env var (`OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`). You can load a project-root `.env` file
first, or pass `api_key:` out-of-band:

```crystal
Trellis::Keys.load_env_file        # loads ./.env if present (ENV wins)
Trellis::Keys.load_env_file(".env.local")

Trellis.generate_text("openai:gpt-4o-mini", "Hi", api_key: "sk-...")
```

## Streaming

`Trellis.stream_text` returns a `StreamResponse` you can consume lazily. Each of
`text_stream`, `each`, and `join` drains the stream once (single-consume):

```crystal
stream = Trellis.stream_text("openai:gpt-4o-mini", "Write a haiku about Crystal.")

# Lazy Iterator(String) over the content text:
stream.text_stream.each { |chunk| print chunk }

# Or collapse the whole stream into a final Response (like generate_text):
resp = stream.join
puts resp.text
```

`each` yields raw `StreamChunk`s if you need finer control; `join` accumulates
the chunks into a `Response` (with usage/cost attached from the catalog).

## Structured output

Give `generate_object` a JSON Schema as a `Hash(String, JSON::Any)`; the model
must emit data matching it (validated before return). `response.object` holds the
parsed `JSON::Any`, or use `generate_object!` to get just the object:

```crystal
schema = {
  "type"       => JSON::Any.new("object"),
  "properties" => JSON::Any.new({
    "name" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
    "age"  => JSON::Any.new({"type" => JSON::Any.new("integer")} of String => JSON::Any),
  } of String => JSON::Any),
  "required" => JSON::Any.new([JSON::Any.new("name"), JSON::Any.new("age")]),
} of String => JSON::Any

resp = Trellis.generate_object("openai:gpt-4o-mini", "A person named Alice, age 30", schema)
puts resp.object # => {"name" => "Alice", "age" => 30}

# Or get the object directly:
obj = Trellis.generate_object!("openai:gpt-4o-mini", "A person named Alice, age 30", schema)
puts obj["name"].as_s
```

## Tool calling

Define a `Trellis::Tool` (name + description + JSON-Schema parameters), pass it via
the `tools:` option, and read the model's chosen calls off `response.tool_calls`:

```crystal
weather = Trellis::Tool.new(
  "get_weather",
  "Get the current weather for a location",
  {
    "type"       => JSON::Any.new("object"),
    "properties" => JSON::Any.new({
      "location" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
    } of String => JSON::Any),
    "required" => JSON::Any.new([JSON::Any.new("location")]),
  } of String => JSON::Any,
)

resp = Trellis.generate_text("openai:gpt-4o-mini",
  "What's the weather in Paris?", tools: [weather])

resp.tool_calls.each do |call|
  puts "#{call.name}(#{call.args_map})" # => get_weather({"location" => "Paris"})
end
```

## Provider-support matrix

All implemented providers support chat, streaming, tools, and structured output.
Model counts come from the embedded `LLMDB` catalog (a models.dev snapshot).

<!-- PROVIDER_MATRIX:START -->
Catalog: 5142 models across 140 providers (models.dev snapshot 2026-06-10). Trellis implements 3.

| Provider  | id          | Models | Chat | Streaming | Tools | Structured |
|-----------|-------------|-------:|:----:|:---------:|:-----:|:----------:|
| Anthropic | `anthropic` |     25 |  ✓   |     ✓     |   ✓   |     ✓      |
| Google    | `google`    |     22 |  ✓   |     ✓     |   ✓   |     ✓      |
| OpenAI    | `openai`    |     50 |  ✓   |     ✓     |   ✓   |     ✓      |
<!-- PROVIDER_MATRIX:END -->

Regenerate with `crystal run tasks/provider_matrix.cr` (paste the output between
the markers above).

## Offline testing / fixtures

Every entry point accepts a `fixture:` parameter that replays a recorded response
from disk — fully offline, no API key required (auth is skipped on replay). It is
the same record/replay mechanism the test suite uses:

```crystal
# Point the loader at a fixtures tree (default is spec/fixtures):
Trellis::Fixture.base_dir = "examples/fixtures"

resp = Trellis.generate_text("openai:gpt-4o-mini", "Say hello.", fixture: "hello")
puts resp.text
```

See `examples/offline_text.cr` (runnable with no key) and the recorded fixtures
under `examples/fixtures/` and `spec/fixtures/`.

## Options

The generation entry points accept these keyword options (validated against
`Trellis::Options::BASE_SCHEMA`):

| Option              | Type                       | Notes                          |
|---------------------|----------------------------|--------------------------------|
| `temperature`       | Float                      | 0.0–2.0                        |
| `max_tokens`        | Int                        | cap on output tokens           |
| `top_p`             | Float                      | 0.0–1.0                        |
| `frequency_penalty` | Float                      | -2.0–2.0                       |
| `presence_penalty`  | Float                      | -2.0–2.0                       |
| `seed`              | Int                        | deterministic sampling         |
| `stop`              | String \| Array(String)    | stop sequence(s)               |
| `tools`             | Array(Trellis::Tool)       | function-calling tools         |
| `stream`            | Bool                       | (set internally by `stream_text`) |

An unknown option, a type mismatch, or an out-of-range value raises
`Trellis::Error::Invalid::Parameter`.

```crystal
Trellis.generate_text("openai:gpt-4o-mini", "Hi",
  max_tokens: 60, temperature: 0.2, stop: ["\n\n"])
```

## Response

`Trellis.generate_text` / `generate_object` return a `Trellis::Response`:

- `resp.text` — the assistant's text content (`String`).
- `resp.tool_calls` — `Array(ToolCall)` (each has `name`, `arguments`, `args_map`).
- `resp.usage` — `Trellis::Usage?` with `input_tokens` / `output_tokens` /
  `total_tokens` and the computed `cost` / `cost_str` (cost lives on `Usage`,
  not on `Response`).
- `resp.object` — the structured `JSON::Any?` (set by `generate_object`).
- `resp.finish_reason` — a `Trellis::FinishReason?`.

## Errors

Trellis raises a typed error tree rooted at `Trellis::Error`:

- `Trellis::Error::Invalid::Parameter` — bad option, unknown model/provider,
  missing API key.
- `Trellis::Error::API::Request` (carries `status` / `body`) and
  `Trellis::Error::API::Response` — transport / upstream failures.
- `Trellis::Error::Validation` — structured output missing or schema mismatch.

```crystal
begin
  resp = Trellis.generate_text("openai:gpt-4o-mini", "Hi")
rescue ex : Trellis::Error
  STDERR.puts "trellis error: #{ex.message}"
end
```

## How it works

Trellis is a faithful Crystal port of Elixir's `req_llm`. Two layers:

- **`LLMDB`** — a models.dev-driven catalog embedded at build time. `LLMDB.model("provider:id")`
  resolves a spec; `LLMDB.models` / `LLMDB.providers` enumerate it. Refresh it with
  `crystal run tasks/sync_models.cr`.
- **A named-step HTTP pipeline** — each request flows through composable steps
  (encode body, attach auth, decode response, attach usage/cost, or replay a
  fixture), mirroring `req_llm`'s Req-pipeline design. Providers plug in by
  registering with `Trellis::Registry` and implementing encode/decode.
