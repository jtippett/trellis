require "./error"
require "./tool"

module Trellis
  # Schema-based validation of request options — the Crystal replacement for
  # the `nimble_options` schemas used in `req_llm/lib/req_llm/provider/options.ex`.
  #
  # Crystal is statically typed, so a runtime keyword schema cannot map 1:1 to
  # NimbleOptions. The shape here is:
  #
  #   * `FieldSpec`  — one option's spec: an expected `type` tag, an optional
  #     numeric `range`, an optional `default`, and a `required` flag.
  #   * `Schema`     — a `Hash(Symbol, FieldSpec)` plus `#validate` and `#merge`.
  #   * `Validated`  — the typed result, a `Hash(Symbol, Value)` with typed
  #     accessor helpers. Forward-declared as a `struct` in
  #     `http/request.cr` and reopened (NOT redefined as a class) here.
  #
  # Declare a schema with the `schema` macro (a NamedTuple literal of specs):
  #
  #     Options.schema({
  #       temperature: {type: :float, range: 0.0..2.0},
  #       max_tokens:  {type: :int, default: nil},
  #       stream:      {type: :bool, default: false},
  #     })
  #
  # Validate user options (a NamedTuple) against it:
  #
  #     validated = Options.validate({temperature: 0.7})   # base schema
  #     validated.fetch_float?(:temperature) # => 0.7
  #     validated.fetch_bool(:stream)        # => false (default applied)
  #
  # Providers EXTEND the base schema by merging their own keys (e.g. Anthropic's
  # `anthropic_version`, reasoning models' `reasoning_effort`):
  #
  #     schema = Options.base_schema.merge(
  #       Options.schema({reasoning_effort: {type: :symbol, default: :medium}})
  #     )
  #     opts = schema.validate({temperature: 0.2, reasoning_effort: :high})
  #
  # Units M/N/O (provider encode/decode, generate_text) read validated values
  # off the `Validated` stored in `HTTP::Request#options` via the typed
  # accessors (`fetch_float?`, `fetch_int?`, `fetch_bool`, `fetch_tools`, ...)
  # or the generic `#[]` / `#get`.
  module Options
    extend self

    # Union of every value type a validated option may hold. Add to this when a
    # new `FieldSpec` type tag is introduced.
    alias Value = Float64 | Int32 | Bool | String | Symbol | Array(String) | Array(Tool) | Nil

    # Specification for a single option key.
    #
    # `type` is a tag in `{:float, :int, :bool, :string, :symbol, :tools,
    # :string_or_string_array}`.
    # `range` (numeric) is checked for `:float`/`:int`. `default` is applied when
    # the key is absent (a `nil` default means "no value"). `required` raises
    # when the key is absent.
    struct FieldSpec
      getter type : Symbol
      getter range : Range(Float64, Float64)?
      getter default : Value
      getter required : Bool

      def initialize(@type : Symbol, @range : Range(Float64, Float64)? = nil,
                     @default : Value = nil, @required : Bool = false)
      end
    end

    # A validated set of option keys. Reopens the `struct` forward-declared in
    # `http/request.cr`.
    struct Validated
      getter values : Hash(Symbol, Value)

      def initialize(@values : Hash(Symbol, Value) = {} of Symbol => Value)
      end

      # Generic accessors — return the raw `Value` (may be nil).
      def [](key : Symbol) : Value
        @values[key]?
      end

      def get(key : Symbol) : Value
        @values[key]?
      end

      def has?(key : Symbol) : Bool
        @values.has_key?(key)
      end

      def to_h : Hash(Symbol, Value)
        @values
      end

      # Typed accessors for the known value shapes.
      def fetch_float?(key : Symbol) : Float64?
        @values[key]?.as?(Float64)
      end

      def fetch_int?(key : Symbol) : Int32?
        @values[key]?.as?(Int32)
      end

      def fetch_string?(key : Symbol) : String?
        @values[key]?.as?(String)
      end

      def fetch_symbol?(key : Symbol) : Symbol?
        @values[key]?.as?(Symbol)
      end

      # Returns the bool value, or `false` when absent.
      def fetch_bool(key : Symbol) : Bool
        v = @values[key]?
        v.is_a?(Bool) ? v : false
      end

      # Returns the tools array, or an empty array when absent.
      def fetch_tools(key : Symbol = :tools) : Array(Tool)
        v = @values[key]?
        v.is_a?(Array(Tool)) ? v : [] of Tool
      end

      # Returns the raw String-array value, or nil when absent/other-typed.
      def fetch_string_array?(key : Symbol) : Array(String)?
        @values[key]?.as?(Array(String))
      end

      # Returns a `stop` value that may be a single `String` or an
      # `Array(String)` (OpenAI accepts both), or nil when absent.
      def fetch_stop(key : Symbol = :stop) : String | Array(String) | Nil
        v = @values[key]?
        case v
        when String        then v
        when Array(String) then v
        else                    nil
        end
      end
    end

    # A composed set of `FieldSpec`s.
    class Schema
      getter fields : Hash(Symbol, FieldSpec)

      def initialize(@fields : Hash(Symbol, FieldSpec) = {} of Symbol => FieldSpec)
      end

      # Returns a new schema with `other`'s fields layered on top (provider
      # extension). Later keys win on collision.
      def merge(other : Schema) : Schema
        Schema.new(@fields.merge(other.fields))
      end

      # Validate a NamedTuple of user options, returning a typed `Validated`.
      # Raises `Error::Invalid::Parameter` on an unknown key, a type mismatch,
      # a range violation, or a missing required key.
      def validate(opts : NamedTuple) : Validated
        values = {} of Symbol => Value

        # Seed defaults (a nil default contributes nothing).
        @fields.each do |name, spec|
          d = spec.default
          values[name] = d unless d.nil?
        end

        opts.each do |key, value|
          spec = @fields[key]?
          unless spec
            raise Error::Invalid::Parameter.new(
              "unknown option #{key.inspect}; valid options: #{@fields.keys.join(", ")}")
          end
          values[key] = Schema.coerce(key, spec, value)
        end

        @fields.each do |name, spec|
          if spec.required && !values.has_key?(name)
            raise Error::Invalid::Parameter.new("missing required option #{name.inspect}")
          end
        end

        Validated.new(values)
      end

      # Coerce/validate a single user value against its spec. Generic over the
      # incoming value's static type.
      def self.coerce(key : Symbol, spec : FieldSpec, value) : Value
        case spec.type
        when :float
          f = to_float(key, value)
          if r = spec.range
            unless r.includes?(f)
              raise Error::Invalid::Parameter.new(
                "option #{key.inspect} must be within #{r}, got #{f}")
            end
          end
          f
        when :int
          i = to_int(key, value)
          if r = spec.range
            unless r.includes?(i.to_f64)
              raise Error::Invalid::Parameter.new(
                "option #{key.inspect} must be within #{r}, got #{i}")
            end
          end
          i
        when :bool
          value.is_a?(Bool) ? value : raise(type_error(key, "bool", value))
        when :string
          value.is_a?(String) ? value : raise(type_error(key, "string", value))
        when :symbol
          value.is_a?(Symbol) ? value : raise(type_error(key, "symbol", value))
        when :tools
          value.is_a?(Array(Tool)) ? value : raise(type_error(key, "Array(Tool)", value))
        when :string_or_string_array
          case value
          when String        then value
          when Array(String) then value
          else                    raise type_error(key, "String or Array(String)", value)
          end
        else
          raise Error::Invalid::Parameter.new(
            "unknown option type #{spec.type.inspect} for #{key.inspect}")
        end
      end

      private def self.to_float(key, value) : Float64
        case value
        when Float64 then value
        when Int     then value.to_f64
        else              raise type_error(key, "float", value)
        end
      end

      private def self.to_int(key, value) : Int32
        case value
        when Int32 then value
        when Int   then value.to_i32
        else            raise type_error(key, "int", value)
        end
      end

      private def self.type_error(key, expected, value) : Error::Invalid::Parameter
        Error::Invalid::Parameter.new(
          "option #{key.inspect} expected #{expected}, got #{value.class}: #{value.inspect}")
      end
    end

    # Build a `Schema` from a NamedTuple literal mapping keys to spec literals.
    # Each spec is a NamedTuple `{type:, range?:, default?:, required?:}`.
    macro schema(spec)
      ::Trellis::Options::Schema.new(
        {
          {% for key, field in spec %}
          :"{{ key.id }}" => ::Trellis::Options::FieldSpec.new(
            type: {{ field[:type] }},
            {% if field[:range] %}range: {{ field[:range] }},{% end %}
            {% if field[:default] != nil %}default: {{ field[:default] }},{% end %}
            {% if field[:required] != nil %}required: {{ field[:required] }},{% end %}
          ),
          {% end %}
        } of Symbol => ::Trellis::Options::FieldSpec
      )
    end

    # The universal core generation schema (the subset relevant to Phase 1).
    # Providers extend this via `base_schema.merge(...)`.
    BASE_SCHEMA = schema({
      temperature:       {type: :float, range: 0.0..2.0},
      max_tokens:        {type: :int, default: nil},
      top_p:             {type: :float, range: 0.0..1.0},
      frequency_penalty: {type: :float, range: -2.0..2.0},
      presence_penalty:  {type: :float, range: -2.0..2.0},
      seed:              {type: :int},
      stop:              {type: :string_or_string_array},
      tools:             {type: :tools, default: [] of Trellis::Tool},
      stream:            {type: :bool, default: false},
    })

    # Returns the base generation schema.
    def base_schema : Schema
      BASE_SCHEMA
    end

    # Validate user options against the base schema.
    def validate(opts : NamedTuple) : Validated
      BASE_SCHEMA.validate(opts)
    end
  end
end
