require "json"

module ReqLLM
  # A callback executed when a model invokes a tool. It receives the decoded
  # argument map and returns an arbitrary JSON-able result. Optional in Phase 1
  # (tool execution is not yet wired), so it defaults to nil.
  alias ToolCallback = Hash(String, JSON::Any) -> JSON::Any

  # Tool definition for model function calling.
  #
  # Mirrors ReqLLM.Tool (tool.ex). Holds a `name`, human-readable `description`,
  # a `parameter_schema` expressed as a JSON Schema map, and an optional
  # `callback`. `to_json_schema` normalizes the schema to the OpenAI-style
  # object shape `{"type" => "object", "properties" => {...}, "required" => [...]}`.
  #
  # Kept as a `struct`: the `callback` Proc is a reference, so storing it in a
  # value type is fine.
  struct Tool
    getter name : String
    getter description : String
    getter parameter_schema : Hash(String, JSON::Any)
    getter callback : ToolCallback?
    # When true, providers that support it (e.g. OpenAI structured outputs) emit
    # a per-tool `"strict": true` flag. Mirrors ReqLLM.Tool's optional `strict`
    # field (tool.ex), which defaults to false.
    getter strict : Bool

    def initialize(@name : String, @description : String,
                   @parameter_schema : Hash(String, JSON::Any) = {} of String => JSON::Any,
                   @callback : ToolCallback? = nil, *, @strict : Bool = false)
      unless Tool.valid_name?(@name)
        raise Error::Invalid::Parameter.new(
          "Invalid tool name: #{@name.inspect}. Must be a valid identifier " \
          "(alphanumeric, underscore, or hyphen, start with a letter or " \
          "underscore, max 64 chars)")
      end
    end

    # Convert this Tool's parameter schema to the JSON Schema object format used
    # by LLM function-calling APIs. Preserves ALL top-level keys of
    # `parameter_schema` (e.g. `additionalProperties`, `$defs`/`definitions`,
    # top-level `description`, `$schema`) and only fills in `type`/`properties`/
    # `required` defaults when absent — mirroring how upstream builds an object
    # schema while never clobbering an explicit `type`.
    def to_json_schema : Hash(String, JSON::Any)
      schema = @parameter_schema.dup
      schema["type"] ||= JSON::Any.new("object")
      schema["properties"] ||= JSON::Any.new({} of String => JSON::Any)
      schema["required"] ||= JSON::Any.new([] of JSON::Any)
      schema
    end

    # Tool names must be valid identifiers: alphanumerics, underscores, or
    # hyphen-joined segments, starting with a letter or underscore, max 64 chars
    # (mirrors tool.ex valid_name?/1).
    def self.valid_name?(name : String) : Bool
      return false if name.size > 64
      !!(name =~ /\A[a-zA-Z_][a-zA-Z0-9_]*(-[a-zA-Z0-9_]+)*\z/)
    end
  end
end
