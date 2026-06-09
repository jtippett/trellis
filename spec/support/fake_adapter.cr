require "../../src/cr_llm"
require "../../src/req_llm/http/adapter"

# A test adapter that records whether transport was invoked. When constructed
# with a status/body it returns that HTTP::Response; when constructed with no
# body it raises if `call` is invoked (proving short-circuit skips transport).
class FakeAdapter
  include ReqLLM::HTTP::Adapter

  getter? called : Bool = false

  def initialize(@status : Int32? = nil, @body : String? = nil)
  end

  def call(request : ReqLLM::HTTP::Request) : ReqLLM::HTTP::Response
    @called = true
    body = @body
    raise "FakeAdapter called without a configured response" if body.nil?
    ReqLLM::HTTP::Response.new(@status || 200, HTTP::Headers.new, body)
  end
end
