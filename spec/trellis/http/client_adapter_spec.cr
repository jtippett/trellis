require "../../spec_helper"
require "http/server"
require "socket"

describe Trellis::HTTP::ClientAdapter do
  it "performs a real POST and returns status + body" do
    server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || ""
      ctx.response.status_code = 201
      ctx.response.print %({"echo":#{body}})
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }

    begin
      wait_until_accepting(address)

      req = Trellis::HTTP::Request.new("POST",
        URI.parse("http://#{address.address}:#{address.port}/v1/chat"))
      req.body = %({"q":"hi"})
      resp = Trellis::HTTP::ClientAdapter.new.call(req)
      resp.status.should eq(201)
      resp.body.should contain("echo")
      resp.body.should contain("hi")
    ensure
      server.close
    end
  end
end

# Poll the listening socket until it accepts a connection, rather than sleeping
# on a fixed timer (condition-based waiting). bind_tcp reserves the port
# synchronously, but the spawned `listen` may not be accepting yet on a slow
# machine; this bounds the wait without racing.
private def wait_until_accepting(address, attempts = 100)
  attempts.times do
    begin
      socket = TCPSocket.new(address.address, address.port)
      socket.close
      return
    rescue Socket::ConnectError
      Fiber.yield
    end
  end
end
