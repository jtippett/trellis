module Trellis
  enum FinishReason
    Stop
    Length
    ToolCalls
    ContentFilter
    Error
    Other

    def self.from_wire(value : String?) : FinishReason
      case value
      when "stop", "end_turn", "stop_sequence", "STOP", "completed" then Stop
      when "length", "max_tokens", "max_output_tokens",
           "model_context_window_exceeded", "MAX_TOKENS" then Length
      when "tool_calls", "tool_use"                            then ToolCalls
      when "content_filter", "refusal", "RECITATION", "SAFETY" then ContentFilter
      when nil                                                 then Other
        # Unknown wire reasons map to Other (deliberate: upstream is itself
        # inconsistent here, using :error in chat decode but :unknown in classify).
      else Other
      end
    end
  end

  class Response
    getter model : String
    getter context : Context?
    getter message : Message?
    # usage and object are written by later pipeline steps (Steps.usage attaches
    # cost; structured-output decode sets object), so they must be settable.
    property usage : Usage?
    getter finish_reason : FinishReason?
    property object : JSON::Any?
    property error : Exception?

    def initialize(@model : String, *, @context = nil, @message = nil,
                   @usage = nil, @finish_reason = nil, @object = nil, @error = nil)
    end

    def text : String
      msg = @message
      return "" unless msg
      String.build do |io|
        msg.content.each { |p| io << p.text if p.type.text? && p.text }
      end
    end

    def tool_calls : Array(ToolCall)
      @message.try(&.tool_calls) || [] of ToolCall
    end

    def ok? : Bool
      @error.nil?
    end

    # Extract the structured object from a completed Response, regardless of mode:
    #   * tool_strict mode (Anthropic): the `structured_output` tool call's args.
    #   * json_schema mode (OpenAI/Google): the assistant text parsed as JSON.
    # Returns the object as JSON::Any, or raises Error::Validation when neither
    # yields a JSON object/array.
    def unwrap_object : JSON::Any
      if tc = tool_calls.find { |c| c.name == "structured_output" }
        # Parse the RAW arguments JSON, NOT tc.args_map: args_map returns
        # Hash(String, JSON::Any) and rescues a non-object to `{}`, which would
        # silently drop a top-level ARRAY structured output. Anthropic decode keeps
        # the raw tool_use input in `tc.arguments` (a JSON string), so parse it
        # directly and accept either a Hash or an Array.
        parsed = (JSON.parse(tc.arguments) rescue nil)
        case parsed.try(&.raw)
        when Hash, Array then return parsed.not_nil!
        end
      end
      txt = text
      unless txt.empty?
        parsed = (JSON.parse(txt) rescue nil)
        case parsed.try(&.raw)
        when Hash, Array then return parsed.not_nil!
        end
      end
      raise Error::Validation.new("no structured output found in response")
    end
  end
end
