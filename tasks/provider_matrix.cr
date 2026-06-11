# provider_matrix — prints a markdown provider-support matrix of the providers
# Trellis IMPLEMENTS, with their model counts drawn from the embedded `LLMDB`
# catalog (the models.dev snapshot).
#
# Usage:
#   crystal run tasks/provider_matrix.cr
#
# The output is deterministic (ids sorted; counts from the embedded catalog), so
# it can be pasted into README.md between the
# `<!-- PROVIDER_MATRIX:START -->` / `<!-- PROVIDER_MATRIX:END -->` markers.
#
# `require` resolves the same way `tasks/sync_models.cr` does: from `tasks/`,
# `../src/trellis` loads the library (which self-registers the providers).
require "../src/trellis"

module ProviderMatrix
  extend self

  # Friendly display names for the implemented provider ids; falls back to the
  # capitalized id for anything not listed.
  DISPLAY_NAMES = {
    "openai"    => "OpenAI",
    "anthropic" => "Anthropic",
    "google"    => "Google",
  }

  def display_name(id : String) : String
    DISPLAY_NAMES[id]? || id.capitalize
  end

  def run : Nil
    ids = Trellis::Registry.ids.sort

    puts "Catalog: #{LLMDB.models.size} models across #{LLMDB.providers.size} " \
         "providers (models.dev snapshot #{LLMDB::VERSION}). " \
         "Trellis implements #{ids.size}."
    puts
    puts "| Provider  | id          | Models | Chat | Streaming | Tools | Structured |"
    puts "|-----------|-------------|-------:|:----:|:---------:|:-----:|:----------:|"

    ids.each do |id|
      count = LLMDB.models.count { |m| m.provider == id }
      name = display_name(id)
      puts "| #{name.ljust(9)} | `#{id}`#{" " * (9 - id.size)} | " \
           "#{count.to_s.rjust(6)} |  ✓   |     ✓     |   ✓   |     ✓      |"
    end
  end
end

ProviderMatrix.run
