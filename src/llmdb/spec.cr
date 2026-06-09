module LLMDB
  # A parsed model spec of the form `"provider:model"` or
  # `"provider:model@tag"`. Mirrors `LLMDB.Spec.parse`.
  #
  # The provider is kept as the raw provider id `String` (the models.dev /
  # engine key). Crystal cannot intern an arbitrary runtime String as a Symbol,
  # so the catalog and engine key providers by String throughout. `parse`
  # validates only structural rules (colon present, provider and model both
  # non-empty); any provider string parses, which also enables future
  # inline/custom models.
  struct Spec
    getter provider : String
    getter model : String
    getter tag : String?

    def initialize(@provider : String, @model : String, @tag : String? = nil)
    end

    def self.parse(spec : String) : Spec
      unless spec.includes?(':')
        raise ReqLLM::Error::Invalid::Parameter.new(
          "Invalid model spec #{spec.inspect}: expected \"provider:model\"")
      end

      provider_id, _, rest = spec.partition(':')
      model, _, tag = rest.partition('@')

      if provider_id.empty? || model.empty?
        raise ReqLLM::Error::Invalid::Parameter.new(
          "Invalid model spec #{spec.inspect}: provider and model must be non-empty")
      end

      new(provider_id, model, tag.empty? ? nil : tag)
    end

    # The catalog key for this spec, `"provider:model"` (tag excluded).
    def key : String
      "#{provider}:#{model}"
    end

    def to_s(io : IO) : Nil
      io << provider << ':' << model
      if t = tag
        io << '@' << t
      end
    end
  end
end
