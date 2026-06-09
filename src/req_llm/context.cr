module ReqLLM
  # A conversation history: a collection of messages plus the tools available
  # for the exchange. Upstream ReqLLM.Context carries both (context.ex:36).
  class Context
    getter messages : Array(Message)
    getter tools : Array(Tool)

    def initialize(@messages : Array(Message) = [] of Message,
                   @tools : Array(Tool) = [] of Tool)
    end

    # Append a message in place.
    def append(message : Message) : self
      @messages << message
      self
    end

    # Alias for append, enabling `ctx << message`.
    def <<(message : Message) : self
      append(message)
    end

    # Prepend a message in place.
    def prepend(message : Message) : self
      @messages.unshift(message)
      self
    end

    # Concatenate another context's messages onto this one in place.
    def concat(other : Context) : self
      @messages.concat(other.messages)
      self
    end

    # Return the underlying message list.
    def to_a : Array(Message)
      @messages
    end

    # Role builder helpers.

    def self.user(content : String) : Message
      Message.new(Role::User, content)
    end

    def self.assistant(content : String) : Message
      Message.new(Role::Assistant, content)
    end

    def self.system(content : String) : Message
      Message.new(Role::System, content)
    end
  end
end
