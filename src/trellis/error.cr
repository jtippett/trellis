module Trellis
  class Error < Exception
    module Invalid
      class Parameter < Error; end

      class Schema < Error; end

      class Role < Error; end
    end

    module API
      class Request < Error
        getter status : Int32?
        getter body : String?

        def initialize(message : String, @status : Int32? = nil, @body : String? = nil)
          super(message)
        end
      end

      class Response < Error; end
    end

    class Validation < Error; end
  end
end
