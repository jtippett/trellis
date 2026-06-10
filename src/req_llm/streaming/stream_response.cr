require "../stream_chunk"
require "../response"
require "../context"
require "./accumulator"

module ReqLLM
  # A lazily-consumable stream of `StreamChunk`s backed by a bounded `Channel`,
  # fed by a PRODUCER FIBER, that collapses to a `ReqLLM::Response` via `join`.
  #
  # This is the Crystal expression of Elixir's `ReqLLM.StreamServer` +
  # `ReqLLM.StreamResponse`: instead of a GenServer with a queue, a single
  # `spawn`ed fiber pushes decoded chunks onto a bounded `Channel`, and the
  # consumer pulls them with `receive?`. The bounded channel provides
  # backpressure (a fast producer blocks once the buffer fills, until the
  # consumer drains it).
  #
  # ## Construction
  #
  # The producer is supplied as a block that receives an `emit` proc; calling
  # `emit.call(chunk)` sends the chunk to the channel (blocking when the buffer
  # is full):
  #
  # ```
  # stream = ReqLLM::StreamResponse.new("anthropic:claude-...", context) do |emit|
  #   emit.call(StreamChunk.text("Hello"))
  #   emit.call(StreamChunk.text(" world"))
  #   emit.call(StreamChunk.meta(finish_data))
  # end
  # ```
  #
  # SU5 supplies a producer that reads a socket -> SSE -> `decode_stream_event`
  # -> `emit.call(chunk)`. The fiber is spawned eagerly in the constructor.
  #
  # ## Consumption (single-consume contract)
  #
  # The channel is a one-shot pipe: each chunk can be observed by exactly one
  # consumer, once. `each`, `join`, and `text_stream` all DRAIN the channel and
  # therefore consume the stream. They may be called only ONCE per
  # `StreamResponse`; a second consumption raises `AlreadyConsumed`. A single
  # consumer is assumed — concurrent consumers from multiple fibers are NOT
  # supported.
  #
  # ## Lifecycle
  #
  # * Producer fiber: runs the block, `emit` -> `@channel.send(chunk)`. On normal
  #   return, `Channel::ClosedError` (consumer cancelled), or any other
  #   exception, an `ensure` block ALWAYS closes the channel. A non-cancel
  #   exception is stored in `@error` BEFORE the channel is closed.
  # * Consumer: `receive?` yields each chunk and returns `nil` once the channel
  #   is closed and drained. Seeing `nil`, the consumer checks `@error` and
  #   re-raises it, so a producer failure surfaces to the consumer rather than
  #   dying silently in the fiber.
  #
  # Because `@error` is set before `close` and the consumer reads it only after
  # `receive?` returns `nil` (i.e. after observing the close), the write
  # happens-before the read — the error is always visible (the channel
  # close/receive pair establishes the ordering even under `-Dpreview_mt`).
  #
  # ## Cancellation / early abandon
  #
  # A consumer that stops early should call `cancel`, which closes the channel.
  # The producer's next `emit.call` then raises `Channel::ClosedError`, which the
  # fiber treats as clean cancellation (NOT stored in `@error`) and terminates.
  # Without `cancel`, a producer that outpaces an abandoned consumer simply parks
  # blocked on a full channel until the process exits — it never deadlocks the
  # consumer.
  class StreamResponse
    include Enumerable(StreamChunk)

    # Raised when a `StreamResponse` is consumed more than once.
    class AlreadyConsumed < Exception
    end

    DEFAULT_CAPACITY = 16

    getter model : String
    getter context : Context?

    # The exception raised by the producer fiber, if any. `nil` while the
    # producer is still running or after a clean completion/cancellation.
    getter error : Exception?

    # `model` is the model id string; `context` is the input context threaded
    # into the joined `Response`. `capacity` bounds the channel buffer. `cost`
    # is the model's catalog pricing: the streaming path does NOT run
    # `Steps.usage`, so `join` applies cost from this pricing to the final
    # `Response`'s usage (mirroring `Steps.usage`). Nil leaves cost unset (an
    # unknown cost, not a misleading $0). The producer block receives an `emit`
    # proc (`StreamChunk ->`).
    def initialize(@model : String, @context : Context? = nil,
                   *, capacity : Int32 = DEFAULT_CAPACITY,
                   cost : LLMDB::Model::Cost? = nil,
                   &producer : (StreamChunk ->) ->)
      @cost = cost
      @channel = Channel(StreamChunk).new(capacity)
      @error = nil
      @consumed = false
      start_producer(producer)
    end

    # Yields each chunk in arrival order until the producer closes the channel.
    # Consumes the stream (single-consume). Re-raises a producer error after the
    # last buffered chunk has been yielded.
    def each(& : StreamChunk ->) : Nil
      claim_consumption!
      while chunk = @channel.receive?
        yield chunk
      end
      raise_producer_error!
    end

    # Drains the stream through a `ChunkAccumulator` and returns the final
    # `Response` (model + context threaded in), equivalent to the non-streaming
    # decode. Consumes the stream (single-consume). Re-raises a producer error.
    def join : Response
      acc = ChunkAccumulator.new
      each { |chunk| acc << chunk }
      response = acc.finish(@model, @context)

      # Thread cost the way Steps.usage does for the non-streaming path: the
      # accumulator only sets token counts, so compute per-token cost from the
      # model's catalog pricing here. Usage is a value type — mutate the local
      # copy and write it back. A nil pricing (or unpriced model) leaves cost
      # nil (unknown, not free).
      if cost = @cost
        if usage = response.usage
          usage.cost = usage.cost(cost)
          response.usage = usage
        end
      end

      response
    end

    # A lazy `Iterator(String)` over just the `:content` chunk text, in order.
    # Pulling from it consumes the stream (single-consume). Re-raises a producer
    # error once the stream is exhausted.
    def text_stream : Iterator(String)
      claim_consumption!
      TextIterator.new(@channel, self)
    end

    # Closes the channel from the consumer side so an outpacing producer stops
    # (its next `emit` raises `Channel::ClosedError`, treated as clean
    # cancellation). Idempotent.
    def cancel : Nil
      @channel.close
    end

    # :nodoc:
    # Re-raises the producer's stored exception, if any. Called by consumers
    # after the channel has drained.
    protected def raise_producer_error! : Nil
      if err = @error
        raise err
      end
    end

    private def claim_consumption! : Nil
      raise AlreadyConsumed.new("StreamResponse stream already consumed") if @consumed
      @consumed = true
    end

    private def start_producer(producer : (StreamChunk ->) ->) : Nil
      channel = @channel
      emit = ->(chunk : StreamChunk) { channel.send(chunk) }
      spawn(name: "stream-response-producer") do
        begin
          producer.call(emit)
        rescue Channel::ClosedError
          # Consumer cancelled (closed the channel); stop quietly — not an error.
        rescue ex
          # Store BEFORE closing so the consumer observes it after `receive?` nil.
          @error = ex
        ensure
          channel.close
        end
      end
    end

    # Lazy iterator over content-chunk text. Skips non-content chunks. Re-raises
    # the producer error (via the owner) when the channel is exhausted.
    private class TextIterator
      include Iterator(String)

      def initialize(@channel : Channel(StreamChunk), @owner : StreamResponse)
      end

      def next
        while chunk = @channel.receive?
          if chunk.type.content? && (text = chunk.text)
            return text
          end
        end
        @owner.raise_producer_error!
        stop
      end
    end
  end
end
