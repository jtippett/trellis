module Trellis
  # Provider-agnostic Server-Sent Events (SSE) parser.
  #
  # This is a pure, synchronous parser: it turns a byte/text `IO` into a
  # sequence of `Event`s by applying the SSE framing rules. It performs NO
  # concurrency and NO HTTP — later streaming units feed it socket IO or
  # recorded fixture frames.
  #
  # ## Framing rules
  #
  # - Lines are separated by `\n`; a trailing `\r` (i.e. `\r\n`) is tolerated
  #   and stripped.
  # - A line of the form `field: value` (or `field:value`) sets a field. The
  #   recognized fields are `event`, `data`, `id`, and `retry`; any other field
  #   name is ignored. A single leading space after the colon is stripped.
  # - Multiple `data:` lines within one event are joined with `\n`.
  # - A blank line dispatches the accumulated event and resets the buffer. An
  #   event is only dispatched when it carries data or an event name (a stray
  #   blank line therefore emits nothing).
  # - A line beginning with `:` is a comment and is ignored.
  #
  # ## Judgment calls
  #
  # - **Default event name.** A dispatched event with no explicit `event:` field
  #   has `event == nil`. Per the SSE spec this means the logical event type is
  #   `"message"`; we leave the field `nil` and let the decode layer treat `nil`
  #   as `"message"` rather than fabricating a default here.
  # - **EOF behavior.** An incomplete event at end-of-input (data accumulated
  #   but no terminating blank line) is NOT dispatched. The SSE spec discards a
  #   trailing event that is not blank-line terminated, and OpenAI/Anthropic
  #   always terminate frames with a blank line, so this is safe.
  # - **`[DONE]` boundary.** This parser does NOT special-case the `[DONE]`
  #   sentinel. `data: [DONE]` is emitted as an ordinary `Event` whose `data` is
  #   the string `"[DONE]"`. Interpreting the sentinel is the job of the
  #   provider decode layer, not the framer.
  module SSE
    extend self

    # A single parsed SSE event.
    #
    # - `event` is the `event:` field name, or `nil` when absent (logically
    #   `"message"`).
    # - `data` is the payload, with multiple `data:` lines joined by `\n`.
    # - `id` and `retry` carry the corresponding fields verbatim, or `nil`.
    record Event,
      data : String,
      event : String? = nil,
      id : String? = nil,
      retry : String? = nil

    # Reads *io* to end and returns all framed `Event`s in order.
    def parse(io : IO) : Array(Event)
      events = [] of Event
      each_event(io) { |event| events << event }
      events
    end

    # Reads *io* to end, yielding each framed `Event` as it is dispatched.
    # This is the incremental-friendly form; `parse` is built on top of it.
    def each_event(io : IO, & : Event ->) : Nil
      builder = EventBuilder.new

      io.each_line(chomp: false) do |raw|
        line = raw.chomp('\n').chomp('\r')

        if line.empty?
          if event = builder.build
            yield event
          end
          builder = EventBuilder.new
          next
        end

        # Comment line: ignore.
        next if line.starts_with?(':')

        field, sep, value = line.partition(':')
        # A line with no colon names a field whose value is the empty string.
        value = "" unless sep == ":"
        # Strip a single leading space after the colon.
        value = value.lchop(' ') if value.starts_with?(' ')

        builder.set(field, value)
      end

      # EOF: an unterminated trailing event is intentionally discarded.
    end

    # Accumulates fields for the event currently being parsed.
    private struct EventBuilder
      def initialize
        @data = [] of String
        @event = nil.as(String?)
        @id = nil.as(String?)
        @retry = nil.as(String?)
        @has_field = false
      end

      def set(field : String, value : String) : Nil
        case field
        when "data"
          @data << value
          @has_field = true
        when "event"
          @event = value
          @has_field = true
        when "id"
          @id = value
          @has_field = true
        when "retry"
          @retry = value
          @has_field = true
        else
          # Unknown field: ignore per the SSE spec.
        end
      end

      # Returns the dispatchable `Event`, or `nil` when nothing was accumulated.
      def build : Event?
        return nil unless @has_field
        Event.new(data: @data.join('\n'), event: @event, id: @id, retry: @retry)
      end
    end
  end
end
