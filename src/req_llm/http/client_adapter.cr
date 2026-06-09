require "http/client"
require "./adapter"

module ReqLLM::HTTP
  class ClientAdapter
    include Adapter

    def call(request : Request) : Response
      body = case b = request.body
             when IO    then b.gets_to_end
             when Bytes then String.new(b)
             else            b # String? | Nil
             end
      raw = ::HTTP::Client.exec(request.method, request.url.to_s,
        headers: request.headers, body: body)
      Response.new(raw.status_code, raw.headers, raw.body)
    end
  end
end
