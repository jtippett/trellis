require "./llmdb/spec"
require "./llmdb/model"
require "./llmdb/catalog"

# The models.dev-driven catalog layer. `LLMDB.model("provider:id")` resolves a
# spec string against the embedded catalog; `LLMDB.models` / `LLMDB.providers`
# enumerate it.
module LLMDB
  # Catalog snapshot version (models.dev sync date). Bumped by the Task 19 sync
  # task whenever the vendored data changes.
  VERSION = "2026-06-09"

  # Resolve a model spec (a `"provider:model[@tag]"` string or a `Spec`) against
  # the embedded catalog. Raises `ReqLLM::Error::Invalid::Parameter` when the
  # spec is malformed or the model is not in the catalog.
  def self.model(spec : String | Spec) : Model
    parsed = spec.is_a?(Spec) ? spec : Spec.parse(spec)
    Catalog.fetch?(parsed.key) ||
      raise ReqLLM::Error::Invalid::Parameter.new("Unknown model: #{parsed.key}")
  end

  # All models in the catalog.
  def self.models : Array(Model)
    Catalog.all.values
  end

  # The distinct providers present in the catalog.
  def self.providers : Array(Symbol)
    models.map(&.provider).uniq
  end
end
