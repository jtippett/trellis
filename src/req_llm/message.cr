module ReqLLM
  # A single conversation message with multi-modal content.
  #
  # Content is always an Array(ContentPart), never a bare string. The String
  # constructor overload wraps the text into a single text part to mirror
  # upstream ReqLLM.Message behaviour.
  #
  # The metadata / provider_data / reasoning_details fields exist for lossless
  # round-tripping of provider-specific data across conversation turns.
  struct Message
    getter role : Role
    getter content : Array(ContentPart)
    getter name : String?
    getter tool_call_id : String?
    getter tool_calls : Array(ToolCall)?
    getter metadata : Hash(String, JSON::Any)
    getter provider_data : Hash(String, JSON::Any)?
    getter reasoning_details : Array(JSON::Any)?

    def initialize(@role : Role, @content : Array(ContentPart), *,
                   @name = nil, @tool_call_id = nil, @tool_calls = nil,
                   @metadata = {} of String => JSON::Any,
                   @provider_data = nil, @reasoning_details = nil)
    end

    # String convenience overload: wrap into a single text content part.
    def initialize(role : Role, text : String, *,
                   name = nil, tool_call_id = nil, tool_calls = nil,
                   metadata = {} of String => JSON::Any,
                   provider_data = nil, reasoning_details = nil)
      initialize(role, [ContentPart.text(text)],
        name: name, tool_call_id: tool_call_id, tool_calls: tool_calls,
        metadata: metadata, provider_data: provider_data,
        reasoning_details: reasoning_details)
    end

    # A message is valid when it carries content, or otherwise stands in for a
    # tool call / tool result (tool_calls present, or a tool_call_id set).
    def valid? : Bool
      return true unless @content.empty?
      return true if (tc = @tool_calls) && !tc.empty?
      return true unless @tool_call_id.nil?
      false
    end
  end
end
