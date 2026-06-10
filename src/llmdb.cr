require "./llmdb/spec"
require "./llmdb/model"
require "./llmdb/catalog"

# The models.dev-driven catalog layer. `LLMDB.model("provider:id")` resolves a
# spec string against the embedded catalog; `LLMDB.models` / `LLMDB.providers`
# enumerate it.
module LLMDB
  # Catalog snapshot version (models.dev sync date). Bumped by the Task 19 sync
  # task whenever the vendored data changes.
  VERSION = "2026-06-10"

  # Resolve a model spec (a `"provider:model[@tag]"` string or a `Spec`) against
  # the embedded catalog. Raises `ReqLLM::Error::Invalid::Parameter` when the
  # spec is malformed or the model is not in the catalog.
  def self.model(spec : String | Spec) : Model
    if spec.is_a?(Spec)
      return Catalog.fetch?(spec.key) ||
        raise ReqLLM::Error::Invalid::Parameter.new("Unknown model: #{spec.key}")
    end

    # Try the literal "provider:id" first. Model ids may legitimately contain
    # '@' (e.g. Cloudflare "workers-ai/@cf/..." or versioned ids like
    # "claude-sonnet-4-5@20250929"), so we must not eagerly treat '@' as a
    # version-tag separator and mis-split a real id.
    if model = Catalog.fetch?(spec)
      return model
    end

    # Fall back to tag-aware parsing ("provider:model@tag" -> base "provider:model").
    # This also validates structure and raises on a malformed/unknown spec.
    parsed = Spec.parse(spec)
    Catalog.fetch?(parsed.key) ||
      raise ReqLLM::Error::Invalid::Parameter.new("Unknown model: #{parsed.key}")
  end

  # All models in the catalog.
  def self.models : Array(Model)
    Catalog.all.values
  end

  # The distinct provider ids present in the catalog.
  def self.providers : Array(String)
    models.map(&.provider).uniq
  end
end
