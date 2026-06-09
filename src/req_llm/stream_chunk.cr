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

    # A metadata chunk (finish reasons, usage, etc.). `extra_metadata` is merged
    # over `data`, matching upstream `meta/2`.
    def self.meta(data : Hash(String, JSON::Any),
                  extra_metadata = {} of String => JSON::Any) : StreamChunk
      new(ChunkType::Meta, metadata: data.merge(extra_metadata))
    end
  end
end
