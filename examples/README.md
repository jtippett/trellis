# trellis examples

Runnable examples for the `trellis` library. Each is a standalone Crystal program;
`require` paths resolve relative to the file, so you can run them from any directory.

## Start here — no key needed

```sh
crystal run examples/offline_text.cr
```

`offline_text.cr` replays a recorded fixture (`examples/fixtures/openai/hello.json`)
through the real `generate_text` pipeline. No network, no API key — the fastest way
to see trellis work end-to-end. It's the same record/replay mechanism the test suite
uses.

## Live examples — require an OpenAI key

Provide a key in either way:

- a `.env` file in the **project root** with `OPENAI_API_KEY=sk-...` (gitignored), or
- `export OPENAI_API_KEY=sk-...` in your shell.

```sh
crystal run examples/basic_text.cr     # one-shot text generation
crystal run examples/tool_calling.cr   # model picks a get_weather tool call
```

Both load the project-root `.env` automatically via `Trellis::Keys.load_env_file`.

## What they demonstrate

| Example             | Key? | Shows                                                            |
|---------------------|------|-----------------------------------------------------------------|
| `offline_text.cr`   | no   | fixture replay, `Response#text`/`finish_reason`/`usage`         |
| `basic_text.cr`     | yes  | live generation, token usage + `Usage#cost_str`, error handling |
| `tool_calling.cr`   | yes  | passing a `Tool`, decoding `Response#tool_calls`                |

## Error handling

trellis raises typed `Trellis::Error` exceptions (e.g. a missing key is
`Trellis::Error::Invalid::Parameter` with a clear message). The live examples
`rescue Trellis::Error` and print a one-line message instead of a stack trace —
the pattern an app or CLI should follow.
