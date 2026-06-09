module LLMDB
  # The vendored models.dev catalog, embedded at compile time and parsed once.
  #
  # The JSON lives at `src/llmdb/data/models.json` and is read via the
  # `read_file` macro relative to this file's directory (`__DIR__` == the llmdb
  # source dir), so there is no runtime file I/O and the data ships in the
  # binary. It is a JSON object keyed by `"provider:id"`; each value is a model
  # in the models.dev shape `LLMDB::Model` deserializes.
  module Catalog
    extend self

    DATA = {{ read_file("#{__DIR__}/data/models.json") }}

    @@models : Hash(String, Model)?

    # The full catalog, keyed by `"provider:id"`. Memoized on first access.
    def all : Hash(String, Model)
      @@models ||= Hash(String, Model).from_json(DATA)
    end

    # Look up a model by its `"provider:id"` key, or nil when absent.
    def fetch?(key : String) : Model?
      all[key]?
    end
  end
end
