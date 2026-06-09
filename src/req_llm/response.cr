module ReqLLM
  enum FinishReason
    Stop
    Length
    ToolCalls
    ContentFilter
    Error
    Other

    def self.from_wire(value : String?) : FinishReason
      case value
      when "stop", "end_turn", "STOP", "completed"                   then Stop
      when "length", "max_tokens", "max_output_tokens", "MAX_TOKENS" then Length
      when "tool_calls", "tool_use"                                  then ToolCalls
      when "content_filter", "SAFETY"                                then ContentFilter
      when nil                                                       then Other
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
  end
end
