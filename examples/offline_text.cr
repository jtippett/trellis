# Offline quickstart — runs with NO API key and NO network.
#
# It replays a recorded fixture (examples/fixtures/openai/hello.json) through the
# real generate_text pipeline, so you can try cr_llm end-to-end before wiring up
# a key. This is the same mechanism the test suite uses.
#
#   crystal run examples/offline_text.cr
#
# `require` and the fixture path are resolved relative to THIS file, so it works
# from any working directory.
require "../src/cr_llm"

# Point the fixture loader at this examples/ tree (default is spec/fixtures).
ReqLLM::Fixture.base_dir = "#{__DIR__}/fixtures"

resp = ReqLLM.generate_text(
  "openai:gpt-4o-mini",
  "Say hello.",
  fixture: "hello",
)

puts resp.text
puts "---"
puts "finish_reason: #{resp.finish_reason}"
if u = resp.usage
  puts "tokens:        in=#{u.input_tokens} out=#{u.output_tokens}"
  puts "cost:          #{u.cost_str || "n/a (unpriced)"}"
end
