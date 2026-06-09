require "http/headers"
require "uri"
require "./response" # HTTP::Response, referenced by the step alias return types

# Minimal forward-declared types so this file compiles standalone. Each is
# reopened with real fields/methods by a later unit. Crystal collects type
# definitions whole-program and MERGES reopened ones regardless of require
# order, so the safety invariant is NOT require ordering — it is that each
# reopening MUST use the same kind declared here:
#   - Options::Validated => reopen as `struct` (Task 20)
#   - RetryPolicy        => reopen as `struct` (Task 14)
#   - LLMDB::Model       => reopen as `class`  (Task 17)
# A `class` vs `struct` mismatch on reopening is a hard compile error.
module ReqLLM
  module Options
    struct Validated
    end
  end

  struct RetryPolicy
  end
end

module LLMDB
  class Model
  end
end

module ReqLLM::HTTP
  # A request step returns a Request (continue) or an HTTP::Response (short-circuit
  # into the response phase — e.g. fixture replay). Response/error steps fold pairs.
  alias RequestStepProc = Request -> (Request | Response)
  alias ResponseStepProc = (Request, Response) -> {Request, Response}
  alias ErrorStepProc = (Request, Exception) -> Exception

  class Request
    property method : String
    property url : URI
    property headers : ::HTTP::Headers
    property body : (IO | String | Bytes | Nil)

    # Typed pipeline state (codex blocker 1: never JSON::Any for these).
    property model : LLMDB::Model?
    property context : ReqLLM::Context?
    property operation : Symbol
    property options : ReqLLM::Options::Validated?
    property retry : ReqLLM::RetryPolicy?
    property fixture : String? # fixture name; attach wires the fixture step when set
    # Out-of-band API key (NOT a generation option — the options schema has no
    # :api_key and would reject it). `generate_text` sets this from the user's
    # `api_key:` arg; `BaseProvider` reads it when resolving auth.
    property api_key : String?

    getter request_steps : Array({Symbol, RequestStepProc})
    getter response_steps : Array({Symbol, ResponseStepProc})
    getter error_steps : Array({Symbol, ErrorStepProc})

    def initialize(@method, @url, @headers = ::HTTP::Headers.new, @body = nil)
      @operation = :chat
      @model = nil
      @context = nil
      @options = nil
      @fixture = nil
      @api_key = nil
      @retry = nil
      @request_steps = [] of {Symbol, RequestStepProc}
      @response_steps = [] of {Symbol, ResponseStepProc}
      @error_steps = [] of {Symbol, ErrorStepProc}
    end

    def append_request_step(name : Symbol, &block : RequestStepProc)
      @request_steps << {name, block}; self
    end

    def prepend_request_step(name : Symbol, &block : RequestStepProc)
      @request_steps.unshift({name, block}); self
    end

    def replace_request_step(name : Symbol, &block : RequestStepProc)
      idx = @request_steps.index { |(n, _)| n == name }
      idx ? (@request_steps[idx] = {name, block}) : (@request_steps << {name, block})
      self
    end

    def append_response_step(name : Symbol, &block : ResponseStepProc)
      @response_steps << {name, block}; self
    end

    def append_error_step(name : Symbol, &block : ErrorStepProc)
      @error_steps << {name, block}; self
    end

    def request_step_names : Array(Symbol)
      @request_steps.map { |(n, _)| n }
    end
  end
end
