# Basic text generation against the live OpenAI API.
#
# Requires an OpenAI key. Provide it either way:
#   * a .env file in the project root containing  OPENAI_API_KEY=sk-...
#   * or export OPENAI_API_KEY in your shell
#
#   crystal run examples/basic_text.cr
require "../src/cr_llm"

# Load OPENAI_API_KEY from a project-root .env if present (no-op otherwise).
ReqLLM::Keys.load_env_file("#{__DIR__}/../.env")

begin
  resp = ReqLLM.generate_text(
    "openai:gpt-4o-mini",
    "In one short sentence, what is Crystal (the programming language)?",
    max_tokens: 60,
    temperature: 0.2,
  )

  puts resp.text
  puts "---"
  puts "finish_reason: #{resp.finish_reason}"
  if u = resp.usage
    puts "tokens:        in=#{u.input_tokens} out=#{u.output_tokens}"
    puts "cost:          #{u.cost_str || "n/a"}"
  end
rescue ex : ReqLLM::Error
  # cr_llm raises typed errors; surface them cleanly instead of a stack trace.
  STDERR.puts "cr_llm error: #{ex.message}"
  exit 1
end
