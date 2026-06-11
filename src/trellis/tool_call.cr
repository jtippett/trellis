require "json"
require "uuid"

module Trellis
  # A single tool call emitted by an assistant message.
  #
  # Upstream ReqLLM.ToolCall keeps the nested OpenAI Chat Completions wire shape
  # (`{id, type: "function", function: {name, arguments}}`). We flatten that into
  # an idiomatic `id`/`name`/`arguments` struct while preserving the provider
  # round-trip via `from_wire`/`to_wire`, including the `builtin?` and `metadata`
  # markers that upstream carries inside the nested `function` map
  # (tool_call.ex:39, :116, :158).
  #
  # `arguments` is the raw JSON-encoded argument string exactly as the provider
  # sent it; `args_map` decodes it on demand.
  struct ToolCall
    getter id : String
    getter name : String
    getter arguments : String
    getter? builtin : Bool
    getter metadata : Hash(String, JSON::Any)

    def initialize(@id : String, @name : String, @arguments : String, *,
                   @builtin : Bool = false,
                   @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any)
    end

    # Decode the raw `arguments` JSON string into a map. Returns an empty map
    # when the arguments are absent or not a JSON object.
    def args_map : Hash(String, JSON::Any)
      parsed = JSON.parse(@arguments)
      parsed.as_h
    rescue
      {} of String => JSON::Any
    end

    # Build a ToolCall from the provider wire shape
    # `{"id", "type", "function": {"name", "arguments", "builtin?"?, "metadata"?}}`.
    def self.from_wire(json : JSON::Any) : ToolCall
      h = json.as_h
      function = h["function"]?.try(&.as_h?) || {} of String => JSON::Any

      id = h["id"]?.try(&.as_s?) || generate_id
      name = function["name"]?.try(&.as_s?) || ""
      arguments = function["arguments"]?.try(&.as_s?) || "{}"
      builtin = flagged_builtin?(function) || flagged_builtin?(h)
      metadata = function["metadata"]?.try(&.as_h?) || {} of String => JSON::Any

      new(id, name, arguments, builtin: builtin, metadata: metadata)
    end

    # Render this ToolCall back into the nested provider wire shape, preserving
    # the `builtin?` and `metadata` markers when present.
    def to_wire : JSON::Any
      function = {
        "name"      => JSON::Any.new(@name),
        "arguments" => JSON::Any.new(@arguments),
      } of String => JSON::Any
      function["builtin?"] = JSON::Any.new(true) if @builtin
      function["metadata"] = JSON::Any.new(@metadata) unless @metadata.empty?

      JSON::Any.new({
        "id"       => JSON::Any.new(@id),
        "type"     => JSON::Any.new("function"),
        "function" => JSON::Any.new(function),
      } of String => JSON::Any)
    end

    def self.generate_id : String
      "call_#{UUID.random}"
    end

    private def self.flagged_builtin?(map : Hash(String, JSON::Any)) : Bool
      map["builtin?"]?.try(&.as_bool?) == true
    end
  end
end
