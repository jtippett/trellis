require "http/headers"

module Trellis::HTTP
  class Response
    property status : Int32
    property headers : ::HTTP::Headers
    property body : String
    property decoded : Trellis::Response?
    property private : Hash(Symbol, String)

    def initialize(@status, @headers, @body)
      @decoded = nil
      @private = {} of Symbol => String
    end
  end
end
