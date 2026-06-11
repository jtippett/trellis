require "./request"
require "./response"

module Trellis::HTTP
  module Adapter
    abstract def call(request : Request) : Response
  end
end
