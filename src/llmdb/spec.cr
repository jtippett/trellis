module LLMDB
  # Known models.dev provider ids mapped to their canonical Symbol. Crystal
  # symbols are interned at compile time, so an arbitrary runtime String cannot
  # become a Symbol; this curated converter is the single source of truth that
  # turns a parsed provider id into the Symbol the rest of the engine keys on.
  def self.provider_symbol(id : String) : Symbol
    case id
    when "openai"                  then :openai
    when "anthropic"               then :anthropic
    when "google"                  then :google
    when "amazon_bedrock"          then :amazon_bedrock
    when "azure"                   then :azure
    when "cerebras"                then :cerebras
    when "google-vertex-anthropic" then :"google-vertex-anthropic"
    when "google_vertex_anthropic" then :google_vertex_anthropic
    when "groq"                    then :groq
    when "minimax"                 then :minimax
    when "openrouter"              then :openrouter
    when "xai"                     then :xai
    when "zai"                     then :zai
    when "zai_coder"               then :zai_coder
    else
      raise ReqLLM::Error::Invalid::Parameter.new("Unknown provider: #{id.inspect}")
    end
  end

  # A parsed model spec of the form `"provider:model"` or
  # `"provider:model@tag"`. Mirrors `LLMDB.Spec.parse`.
  struct Spec
    getter provider : Symbol
    getter model : String
    getter tag : String?

    def initialize(@provider : Symbol, @model : String, @tag : String? = nil)
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

      new(LLMDB.provider_symbol(provider_id), model, tag.empty? ? nil : tag)
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
