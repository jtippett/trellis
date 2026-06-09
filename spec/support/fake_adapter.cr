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

# A test adapter that returns a preconfigured sequence of status codes (one per
# call) and counts how many times `call` was invoked. Drives retry-loop specs
# without any wall-clock waiting: assert on `#calls`, not on elapsed time.
class CountingAdapter
  include ReqLLM::HTTP::Adapter

  getter calls : Int32 = 0

  def initialize(@statuses : Array(Int32), @headers : ::HTTP::Headers = ::HTTP::Headers.new)
  end

  def call(request : ReqLLM::HTTP::Request) : ReqLLM::HTTP::Response
    status = @statuses[@calls]? || @statuses.last
    @calls += 1
    ReqLLM::HTTP::Response.new(status, @headers, %({"ok":true}))
  end
end
