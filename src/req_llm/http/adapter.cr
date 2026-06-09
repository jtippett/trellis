require "./request"
require "./response"

module ReqLLM::HTTP
  module Adapter
    abstract def call(request : Request) : Response
  end
end
