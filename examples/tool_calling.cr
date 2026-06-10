# Tool calling against the live OpenAI API.
#
# Gives the model a `get_weather` tool and prints the tool call it chooses.
# Requires an OpenAI key (see basic_text.cr for how to provide it).
#
#   crystal run examples/tool_calling.cr
require "../src/cr_llm"

ReqLLM::Keys.load_env_file("#{__DIR__}/../.env")

# A tool is a name + description + JSON-Schema parameters.
weather = ReqLLM::Tool.new(
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

begin
  resp = ReqLLM.generate_text(
    "openai:gpt-4o-mini",
    "What's the weather in Paris? Use the get_weather tool.",
    tools: [weather],
    max_tokens: 64,
    temperature: 0.0,
  )

  puts "finish_reason: #{resp.finish_reason}"
  puts "tool calls:    #{resp.tool_calls.size}"
  resp.tool_calls.each do |call|
    puts "  -> #{call.name}(#{call.args_map})"
  end
  puts "cost:          #{resp.usage.try(&.cost_str) || "n/a"}"
rescue ex : ReqLLM::Error
  STDERR.puts "cr_llm error: #{ex.message}"
  exit 1
end
