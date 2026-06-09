module LLMDB
  # A single catalog entry, mirroring the models.dev model shape consumed by the
  # `llm_db` registry. Reopens the empty `class LLMDB::Model` forward-declared in
  # `src/req_llm/http/request.cr` (MUST remain a `class`, never a `struct`).
  #
  # Field mapping to the models.dev JSON shape (see req_llm/guides/model-metadata.md):
  #   provider   <- "provider"   (string id; exposed as a String via #provider)
  #   id         <- "id"
  #   name       <- "name"
  #   type       <- "type"       (default "chat")
  #   capabilities are derived from the flat boolean flags models.dev emits:
  #     :tools       <- "tool_call"
  #     :reasoning   <- "reasoning"
  #     :temperature <- "temperature"
  #     :attachment  <- "attachment"
  #   cost       <- "cost"       ({input, output, cache_read}, USD per 1M tokens)
  #   limit      <- "limit"      ({context, output})
  #   modalities <- "modalities" ({input: [...], output: [...]})
  class Model
    include JSON::Serializable

    # Pricing in USD per 1,000,000 tokens (matching Usage#cost convention).
    struct Cost
      include JSON::Serializable

      getter input : Float64 = 0.0
      getter output : Float64 = 0.0
      @[JSON::Field(key: "cache_read")]
      getter cached : Float64? = nil

      def initialize(@input = 0.0, @output = 0.0, @cached = nil)
      end

      # The input/output pair as a NamedTuple, so this catalog `Cost` struct can
      # be passed straight to `ReqLLM::Usage#cost(pricing)` (which indexes
      # `pricing[:input]` / `pricing[:output]`).
      def to_pricing : NamedTuple(input: Float64, output: Float64)
        {input: input, output: output}
      end
    end

    # Token limits for the model.
    struct Limit
      include JSON::Serializable

      getter context : Int32 = 0
      getter output : Int32 = 0

      def initialize(@context = 0, @output = 0)
      end
    end

    # Supported input/output modalities (e.g. "text", "image", "audio").
    struct Modalities
      include JSON::Serializable

      getter input : Array(String) = [] of String
      getter output : Array(String) = [] of String

      def initialize(@input = [] of String, @output = [] of String)
      end
    end

    # The raw provider id (e.g. "openai"), the engine/catalog key. Exposed as
    # `#provider` for parity with the rest of the engine.
    @[JSON::Field(key: "provider")]
    getter provider : String
    getter id : String
    getter name : String? = nil
    getter type : String = "chat"

    getter? tool_call : Bool = false
    getter? reasoning : Bool = false
    getter? temperature : Bool = false
    getter? attachment : Bool = false

    getter cost : Cost = Cost.new
    getter limit : Limit = Limit.new
    getter modalities : Modalities = Modalities.new

    def initialize(@provider : String, @id : String, *, @name : String? = nil,
                   @type : String = "chat", @tool_call : Bool = false,
                   @reasoning : Bool = false, @temperature : Bool = false,
                   @attachment : Bool = false, @cost : Cost = Cost.new,
                   @limit : Limit = Limit.new, @modalities : Modalities = Modalities.new)
    end

    # The set of capability flags this model supports.
    def capabilities : Set(Symbol)
      caps = Set(Symbol).new
      caps << :tools if tool_call?
      caps << :reasoning if reasoning?
      caps << :temperature if temperature?
      caps << :attachment if attachment?
      caps
    end

    # Whether the model supports the given capability flag (e.g. `:tools`).
    def supports?(capability : Symbol) : Bool
      capabilities.includes?(capability)
    end

    # Maximum context window in tokens.
    def context_limit : Int32
      limit.context
    end

    # Maximum output length in tokens.
    def output_limit : Int32
      limit.output
    end

    # The catalog key for this model, `"provider:id"`.
    def key : String
      "#{@provider}:#{@id}"
    end
  end
end
