require "json"
require "./error"

module ReqLLM
  # JSON-Schema helpers for the structured-output (`generate_object`) path.
  #
  # NOTE: distinct from `ReqLLM::Options::Schema` (which validates GENERATION
  # OPTIONS). This module operates on the OUTPUT JSON Schema the caller supplies
  # to `generate_object`: `enforce_strict` prepares it for a provider's strict
  # mode, and `validate` checks a decoded object against it.
  #
  # Both are a DELIBERATE SUBSET of JSON Schema (see method docs). Phase 5
  # schemas are flat object/array/scalar; `$defs`/`anyOf`/`oneOf` are DEFERRED.
  module Schema
    extend self

    # Port of upstream `enforce_strict_recursive`
    # (`openai/adapter_helpers.ex`). For an object node (`type == "object"` with
    # a `properties` map) set `required` to ALL property keys and
    # `additionalProperties: false`, recursing into each property value. For an
    # array node with an object `items` schema, recurse `items`. All other nodes
    # pass through unchanged.
    #
    # SCOPE: recurse `properties` + array `items` ONLY. `$defs`/`anyOf`/`oneOf`
    # enforcement is DEFERRED (upstream recurses those too, but Phase 5 schemas
    # are flat). PURE: returns a new Hash; never mutates the input.
    def enforce_strict(schema : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      type = schema["type"]?.try(&.as_s?)

      if type == "object" && (props = schema["properties"]?.try(&.as_h?))
        updated_props = {} of String => JSON::Any
        props.each do |k, v|
          updated_props[k] = if h = v.as_h?
                               JSON::Any.new(enforce_strict(h))
                             else
                               v
                             end
        end

        out = schema.dup
        out["properties"] = JSON::Any.new(updated_props)
        out["required"] = JSON::Any.new(props.keys.map { |k| JSON::Any.new(k) })
        out["additionalProperties"] = JSON::Any.new(false)
        out
      elsif type == "array" && (items = schema["items"]?.try(&.as_h?))
        out = schema.dup
        out["items"] = JSON::Any.new(enforce_strict(items))
        out
      else
        schema.dup
      end
    end

    # A MINIMAL JSON Schema validator. Raises `Error::Validation` with a precise
    # `path` + expected/got message on the FIRST mismatch; returns nil on
    # success.
    #
    # Supported subset (DELIBERATE — not full JSON Schema):
    #   * `"type"`: object/string/integer/number/boolean/array/null — type-check.
    #   * object: every key in `"required"` must be present; each present
    #     property whose name is in `"properties"` recurses against its
    #     subschema; an extra (non-property) key is rejected ONLY when
    #     `additionalProperties == false`.
    #   * array: each element recurses against `"items"` (when `items` is an
    #     object schema).
    #   * a node with no recognized `"type"` (or only unsupported keywords)
    #     PASSES (permissive — we validate only what we understand).
    def validate(data : JSON::Any, schema : Hash(String, JSON::Any)) : Nil
      validate_node(data, schema, "$")
    end

    private def validate_node(data : JSON::Any, schema : Hash(String, JSON::Any),
                              path : String) : Nil
      type = schema["type"]?.try(&.as_s?)
      return unless type # typeless/unknown node — permissive pass

      case type
      when "object"
        h = data.as_h? || raise mismatch(path, "object", data)
        validate_object(h, schema, path)
      when "array"
        a = data.as_a? || raise mismatch(path, "array", data)
        validate_array(a, schema, path)
      when "string"
        data.as_s? || raise mismatch(path, "string", data)
      when "integer"
        # JSON has no integer type; require a whole number with no fractional part.
        unless data.as_i64? || data.as_i?
          raise mismatch(path, "integer", data)
        end
      when "number"
        unless data.as_f? || data.as_i64? || data.as_i?
          raise mismatch(path, "number", data)
        end
      when "boolean"
        data.as_bool?.nil? && raise(mismatch(path, "boolean", data))
      when "null"
        raise mismatch(path, "null", data) unless data.raw.nil?
      else
        # Unsupported type keyword — permissive pass (documented subset).
      end
    end

    private def validate_object(h : Hash(String, JSON::Any),
                                schema : Hash(String, JSON::Any), path : String) : Nil
      props = schema["properties"]?.try(&.as_h?)

      if required = schema["required"]?.try(&.as_a?)
        required.each do |key_any|
          if key = key_any.as_s?
            unless h.has_key?(key)
              raise Error::Validation.new(
                "#{path}: missing required property #{key.inspect}")
            end
          end
        end
      end

      additional = schema["additionalProperties"]?
      reject_extra = additional.try(&.as_bool?) == false

      h.each do |key, value|
        sub = props.try(&.[key]?)
        if sub && (sub_h = sub.as_h?)
          validate_node(value, sub_h, "#{path}.#{key}")
        elsif reject_extra && !(props.try(&.has_key?(key)))
          raise Error::Validation.new(
            "#{path}: additional property #{key.inspect} is not allowed")
        end
      end
    end

    private def validate_array(a : Array(JSON::Any),
                               schema : Hash(String, JSON::Any), path : String) : Nil
      items = schema["items"]?.try(&.as_h?)
      return unless items

      a.each_with_index do |element, i|
        validate_node(element, items, "#{path}[#{i}]")
      end
    end

    private def mismatch(path : String, expected : String, data : JSON::Any) : Error::Validation
      Error::Validation.new(
        "#{path}: expected #{expected}, got #{describe(data)}")
    end

    private def describe(data : JSON::Any) : String
      case raw = data.raw
      when Hash   then "object"
      when Array  then "array"
      when String then "string"
      when Bool   then "boolean"
      when Nil    then "null"
      when Int    then "integer"
      when Float  then "number"
      else             raw.class.to_s
      end
    end
  end
end
