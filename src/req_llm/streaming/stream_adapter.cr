require "http/client"
require "./sse"
require "../fixture"
require "../provider"
require "../stream_chunk"
require "../http/request"

module ReqLLM
  # Drives a prepared streaming request to completion, emitting decoded
  # `StreamChunk`s through the `emit` proc supplied by the `StreamResponse`
  # producer fiber. The pipeline (`Steps.error`/`decode`/`usage`) is NOT used
  # for streaming; this adapter is the streaming analogue, handling transport,
  # the SSE -> `decode_stream_event` -> `emit` pipeline, and non-2xx errors.
  #
  # Two modes, chosen by `Fixture.will_replay?` (same predicate `attach` uses
  # for auth-skip):
  #
  #   * REPLAY — fully offline: read the fixture's recorded SSE frames and feed
  #     them through the SAME `SSE.each_event` + `decode_stream_event` path as a
  #     live stream. No network, no key.
  #   * LIVE — open an `HTTP::Client` (instance + BLOCK form, so the response
  #     body streams incrementally; the class-method `HTTP::Client.exec`
  #     BUFFERS and would defeat streaming) and pump `resp.body_io` through the
  #     same decode path. A non-2xx status is read fully and raised as
  #     `Error::API::Request` (mirroring `Steps.error`).
  #
  # Record mode for streaming is intentionally NOT implemented in this unit:
  # the replay path is the tested contract, and capturing live SSE frames mid
  # block-stream is non-trivial. The live path is validated separately (it
  # cannot be exercised offline).
  module StreamAdapter
    extend self

    # Drive `req` (already prepared by `provider.attach_stream`), emitting every
    # decoded chunk via `emit`. Picks replay vs live by fixture availability.
    def drive(req : HTTP::Request, provider : ReqLLM::Provider,
              emit : ReqLLM::StreamChunk ->) : Nil
      if Fixture.will_replay?(req, provider.id)
        replay(req, provider, emit)
      else
        live(req, provider, emit)
      end
    end

    # Offline replay: concatenate the recorded SSE frames and feed them through
    # the real parser, so the recorded stream exercises the exact decode path a
    # live stream would.
    private def replay(req : HTTP::Request, provider : ReqLLM::Provider,
                       emit : ReqLLM::StreamChunk ->) : Nil
      name = req.fixture.not_nil!
      frames = Fixture.load_stream(Fixture.path(provider.id, name))
      io = IO::Memory.new(frames.join)
      pump(io, provider, emit)
    end

    # Live transport: instance + block form gives a streaming `body_io`.
    private def live(req : HTTP::Request, provider : ReqLLM::Provider,
                     emit : ReqLLM::StreamChunk ->) : Nil
      uri = req.url
      body = case b = req.body
             when IO    then b.gets_to_end
             when Bytes then String.new(b)
             else            b
             end

      client = ::HTTP::Client.new(uri)
      begin
        client.post(uri.request_target, headers: req.headers, body: body) do |resp|
          if resp.status_code >= 400
            # The transport status is an error; Steps.error never runs on the
            # streaming path, so surface it here exactly as the non-streaming
            # pipeline would. Drain the body for the error message.
            error_body = resp.body_io?.try(&.gets_to_end) || ""
            raise Error::API::Request.new(
              error_body, status: resp.status_code, body: error_body)
          end
          pump(resp.body_io, provider, emit)
        end
      ensure
        client.close
      end
    end

    # The shared SSE -> decode -> emit pipeline used by both modes.
    private def pump(io : IO, provider : ReqLLM::Provider,
                     emit : ReqLLM::StreamChunk ->) : Nil
      ReqLLM::SSE.each_event(io) do |event|
        provider.decode_stream_event(event).each { |chunk| emit.call(chunk) }
      end
    end
  end
end
