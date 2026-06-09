require "./request"
require "./response"
require "./adapter"

module ReqLLM::HTTP
  module Pipeline
    extend self

    def run(req : Request, adapter : Adapter) : ReqLLM::Response
      http_resp : Response? = nil

      req.request_steps.each do |(_name, step)|
        case result = step.call(req)
        when Response then http_resp = result; break
        when Request  then req = result
        end
      end

      begin
        http_resp ||= perform(req, adapter) # Task 14 swaps in retry-aware perform
        req.response_steps.each do |(_name, step)|
          req, http_resp = step.call(req, http_resp.not_nil!)
        end
      rescue ex
        req.error_steps.each { |(_n, s)| ex = s.call(req, ex) }
        raise ex
      end

      http_resp.not_nil!.decoded ||
        raise ReqLLM::Error::API::Response.new("decode produced no response")
    end

    # Plain transport; Task 14 replaces with retry-aware version.
    def perform(req : Request, adapter : Adapter) : Response
      adapter.call(req)
    end
  end
end
