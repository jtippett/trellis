require "json"

module ReqLLM
  # The kind of content carried by a StreamChunk.
  #
  # Mirrors the upstream atom set `:content | :thinking | :tool_call | :meta`
  # (stream_chunk.ex). Named ChunkType to avoid clashing with PartType.
  enum ChunkType
    Content
    Thinking
    ToolCall
    Meta
  end

  # A single chunk in a streaming response.
  #
  # Mirrors ReqLLM.StreamChunk (stream_chunk.ex): a unified shape across
  # providers for text content, reasoning/thinking tokens, tool-call fragments,
  # and trailing metadata (usage, finish reasons). Use the constructor helpers
  # rather than `new` directly.
  struct StreamChunk
    getter type : ChunkType
    getter text : String?
    getter name : String?
    getter arguments : Hash(String, JSON::Any)?
    getter metadata : Hash(String, JSON::Any)

    def initialize(@type : ChunkType, *, @text : String? = nil,
                   @name : String? = nil,
                   @arguments : Hash(String, JSON::Any)? = nil,
                   @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any)
    end

    # A content chunk containing response text.
    def self.text(content : String, metadata = {} of String => JSON::Any) : StreamChunk
      new(ChunkType::Content, text: content, metadata: metadata)
    end

    # A thinking/reasoning chunk containing reasoning text.
    def self.thinking(content : String, metadata = {} of String => JSON::Any) : StreamChunk
      new(ChunkType::Thinking, text: content, metadata: metadata)
    end

    # A tool-call chunk with a function name and (possibly partial) arguments.
    def self.tool_call(name : String, arguments : Hash(String, JSON::Any),
                       metadata = {} of String => JSON::Any) : StreamChunk
      new(ChunkType::ToolCall, name: name, arguments: arguments, metadata: metadata)
    end

    # A streaming tool-call DELTA chunk, the shape `ChunkAccumulator` reassembles
    # by index. Unlike `.tool_call` (pre-assembled arguments), providers stream
    # tool calls as fragments: the first fragment for an `index` carries the
    # `id` and `name`; subsequent fragments carry partial `arguments_fragment`
    # JSON pieces that the accumulator concatenates in arrival order.
    #
    # Sets exactly the metadata keys the accumulator reads, so SU4 (and any later
    # provider decoder) never hand-types the `"index"`/`"id"`/`"arguments_fragment"`
    # strings:
    #   * `metadata["index"]` — always set (groups fragments; REQUIRED).
    #   * `name` (struct field) — set when present (usually the first fragment).
    #   * `metadata["id"]` — set when present (usually the first fragment).
    #   * `metadata["arguments_fragment"]` — set when present (a partial JSON piece).
    def self.tool_call_delta(index : Int32, id : String? = nil, name : String? = nil,
                             arguments_fragment : String? = nil) : StreamChunk
      metadata = {"index" => JSON::Any.new(index.to_i64)} of String => JSON::Any
      metadata["id"] = JSON::Any.new(id) if id
      metadata["arguments_fragment"] = JSON::Any.new(arguments_fragment) if arguments_fragment
      new(ChunkType::ToolCall, name: name, metadata: metadata)
    end

    # A metadata chunk (finish reasons, usage, etc.). `extra_metadata` is merged
    # over `data`, matching upstream `meta/2`.
    def self.meta(data : Hash(String, JSON::Any),
                  extra_metadata = {} of String => JSON::Any) : StreamChunk
      new(ChunkType::Meta, metadata: data.merge(extra_metadata))
    end
  end
end
