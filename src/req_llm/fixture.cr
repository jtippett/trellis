require "json"
require "http/headers"
require "./http/request"
require "./http/response"

module ReqLLM
  # Record/replay test harness, built on the pipeline's
  # short-circuit-then-still-fold-response-steps behaviour.
  #
  # A fixture has TWO halves (see the Pipeline contract):
  #
  #   * Replay half (a REQUEST step): when the fixture file exists and we are
  #     not recording, parse it into a raw `HTTP::Response` and RETURN it from a
  #     request step. That short-circuits transport, but the pipeline still runs
  #     the response steps (error / decode / usage) so `decoded` gets populated.
  #
  #   * Record half (a RESPONSE step): in record mode, append a response step
  #     LAST (named `:fixture_capture`) that serializes `{status, headers, body}`
  #     to the fixture path, then passes the pair through unchanged.
  #
  # `attach` wires exactly one half based on `record?` — replay in replay mode,
  # capture in record mode. Providers call `Fixture.attach` last in their own
  # `attach`, so the wired step lands last among its kind.
  #
  # Fixture JSON schema:
  #
  #   { "status": 200, "headers": {"content-type": "..."}, "body": "<raw>" }
  #
  # Headers round-trip: `HTTP::Headers` may hold multiple values per key; on
  # capture we join them with ", " (RFC 7230 combined-field-value form) into a
  # single JSON string, and on replay set that single string back as one value.
  module Fixture
    extend self

    DEFAULT_BASE_DIR = "spec/fixtures"

    # Overridable so specs can point at a temp dir and stay hermetic.
    @@base_dir : String = DEFAULT_BASE_DIR

    def base_dir : String
      @@base_dir
    end

    def base_dir=(dir : String) : String
      @@base_dir = dir
    end

    # Fixture file path: <base>/<provider>/<name>.json.
    def path(provider : Symbol | String, name : String, base : String = base_dir) : String
      File.join(base, provider.to_s, "#{name}.json")
    end

    # Record mode is opt-in via the environment; the default is replay.
    def record? : Bool
      ENV["CR_LLM_FIXTURES"]? == "record"
    end

    # Whether this request will be served entirely from a recorded fixture: a
    # fixture name is set, we are NOT recording, and the fixture file exists on
    # disk. When true, the replay step short-circuits transport, so no real
    # request is made and NO API key is required — `BaseProvider#attach` uses
    # this to skip auth resolution on replay.
    def will_replay?(req : HTTP::Request, provider : Symbol | String) : Bool
      name = req.fixture
      return false unless name
      return false if record?
      File.exists?(path(provider, name))
    end

    # The replay half: a named REQUEST step. When the file exists (and we are
    # not recording) it reads + parses the fixture into an `HTTP::Response` and
    # returns it, short-circuiting transport. When the file is missing it passes
    # the request through so real transport happens (matching upstream: replay
    # only short-circuits when the file exists).
    def replay_step(provider : Symbol | String, name : String) : {Symbol, HTTP::RequestStepProc}
      file = path(provider, name)
      proc = HTTP::RequestStepProc.new do |req|
        if !record? && File.exists?(file)
          load_response(file).as(HTTP::Request | HTTP::Response)
        else
          req.as(HTTP::Request | HTTP::Response)
        end
      end
      {:fixture, proc}
    end

    # The record half: a named RESPONSE step that writes the raw response to the
    # fixture path, then passes the (req, resp) pair through unchanged.
    def capture_step(provider : Symbol | String, name : String) : {Symbol, HTTP::ResponseStepProc}
      file = path(provider, name)
      proc = HTTP::ResponseStepProc.new do |req, resp|
        write_response(file, resp)
        {req, resp}
      end
      {:fixture_capture, proc}
    end

    # Wire the correct half onto `req` based on `record?`:
    #   * record mode  -> capture step appended LAST among response steps
    #   * replay mode  -> replay step appended LAST among request steps
    def attach(req : HTTP::Request, provider : Symbol | String, name : String) : HTTP::Request
      if record?
        step_name, proc = capture_step(provider, name)
        req.append_response_step(step_name, &proc)
      else
        step_name, proc = replay_step(provider, name)
        req.append_request_step(step_name, &proc)
      end
      req
    end

    # Serialize a raw HTTP::Response to the fixture file as pretty JSON.
    def write_response(file : String, resp : HTTP::Response) : Nil
      Dir.mkdir_p(File.dirname(file))
      headers = {} of String => String
      resp.headers.each do |key, values|
        headers[key] = values.join(", ")
      end
      data = {status: resp.status, headers: headers, body: resp.body}
      File.write(file, data.to_pretty_json)
    end

    # Parse a fixture file into a raw HTTP::Response (decoded == nil).
    def load_response(file : String) : HTTP::Response
      parsed = JSON.parse(File.read(file))
      status = parsed["status"].as_i
      headers = ::HTTP::Headers.new
      parsed["headers"].as_h.each do |key, value|
        headers[key] = value.as_s
      end
      body = parsed["body"].as_s
      HTTP::Response.new(status, headers, body)
    end
  end
end
