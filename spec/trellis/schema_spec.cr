require "../spec_helper"

# Helpers to build JSON Schema maps concisely.
private def jany(v) : JSON::Any
  JSON::Any.new(v)
end

private def obj(props : Hash(String, JSON::Any), required : Array(String) = [] of String,
                additional : Bool? = nil) : Hash(String, JSON::Any)
  h = {
    "type"       => jany("object"),
    "properties" => jany(props),
    "required"   => jany(required.map { |k| jany(k) }),
  } of String => JSON::Any
  h["additionalProperties"] = jany(additional) unless additional.nil?
  h
end

describe Trellis::Schema do
  describe ".validate" do
    it "passes a conforming object" do
      schema = obj({
        "name" => jany({"type" => jany("string")}),
        "age"  => jany({"type" => jany("integer")}),
      } of String => JSON::Any, required: ["name"])
      data = JSON.parse(%({"name":"Alice","age":30}))

      Trellis::Schema.validate(data, schema).should be_nil
    end

    it "raises on a missing required key" do
      schema = obj({
        "name" => jany({"type" => jany("string")}),
      } of String => JSON::Any, required: ["name"])
      data = JSON.parse(%({}))

      expect_raises(Trellis::Error::Validation, /name/) do
        Trellis::Schema.validate(data, schema)
      end
    end

    it "raises on a wrong-typed property" do
      schema = obj({
        "age" => jany({"type" => jany("integer")}),
      } of String => JSON::Any, required: ["age"])
      data = JSON.parse(%({"age":"thirty"}))

      expect_raises(Trellis::Error::Validation, /age/) do
        Trellis::Schema.validate(data, schema)
      end
    end

    it "accepts a whole-valued float for an integer field but rejects a fractional one" do
      schema = obj({
        "age" => jany({"type" => jany("integer")}),
      } of String => JSON::Any, required: ["age"])

      # 30.0 is a valid integer value (JSON has no int/float distinction).
      Trellis::Schema.validate(JSON.parse(%({"age":30.0})), schema)

      expect_raises(Trellis::Error::Validation, /age/) do
        Trellis::Schema.validate(JSON.parse(%({"age":30.5})), schema)
      end
    end

    it "raises on a nested object property mismatch" do
      schema = obj({
        "user" => jany(obj({
          "name" => jany({"type" => jany("string")}),
        } of String => JSON::Any, required: ["name"])),
      } of String => JSON::Any, required: ["user"])
      data = JSON.parse(%({"user":{"name":42}}))

      expect_raises(Trellis::Error::Validation, /user.*name|name/) do
        Trellis::Schema.validate(data, schema)
      end
    end

    it "raises on an array element type mismatch" do
      schema = {
        "type"  => jany("array"),
        "items" => jany({"type" => jany("integer")}),
      } of String => JSON::Any
      data = JSON.parse(%([1, "two", 3]))

      expect_raises(Trellis::Error::Validation) do
        Trellis::Schema.validate(data, schema)
      end
    end

    it "raises on an extra key when additionalProperties is false" do
      schema = obj({
        "name" => jany({"type" => jany("string")}),
      } of String => JSON::Any, required: ["name"], additional: false)
      data = JSON.parse(%({"name":"Alice","extra":1}))

      expect_raises(Trellis::Error::Validation, /extra/) do
        Trellis::Schema.validate(data, schema)
      end
    end

    it "passes a typeless/unknown node (documented permissive subset)" do
      schema = {"description" => jany("anything goes")} of String => JSON::Any
      data = JSON.parse(%({"whatever":[1,2,3]}))

      Trellis::Schema.validate(data, schema).should be_nil
    end
  end

  describe ".enforce_strict" do
    it "marks all properties required and adds additionalProperties:false" do
      schema = {
        "type"       => jany("object"),
        "properties" => jany({
          "name" => jany({"type" => jany("string")}),
          "age"  => jany({"type" => jany("integer")}),
        } of String => JSON::Any),
        "required" => jany([jany("name")]),
      } of String => JSON::Any

      out = Trellis::Schema.enforce_strict(schema)

      out["additionalProperties"].should eq(jany(false))
      required = out["required"].as_a.map(&.as_s).sort!
      required.should eq(["age", "name"])
    end

    it "recurses into a nested object property" do
      schema = {
        "type"       => jany("object"),
        "properties" => jany({
          "user" => jany({
            "type"       => jany("object"),
            "properties" => jany({
              "name" => jany({"type" => jany("string")}),
            } of String => JSON::Any),
          } of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any

      out = Trellis::Schema.enforce_strict(schema)
      nested = out["properties"].as_h["user"].as_h

      nested["additionalProperties"].should eq(jany(false))
      nested["required"].as_a.map(&.as_s).should eq(["name"])
    end

    it "recurses into array items that are objects" do
      schema = {
        "type"  => jany("array"),
        "items" => jany({
          "type"       => jany("object"),
          "properties" => jany({
            "id" => jany({"type" => jany("integer")}),
          } of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any

      out = Trellis::Schema.enforce_strict(schema)
      items = out["items"].as_h

      items["additionalProperties"].should eq(jany(false))
      items["required"].as_a.map(&.as_s).should eq(["id"])
    end

    it "does not mutate the input schema" do
      schema = {
        "type"       => jany("object"),
        "properties" => jany({
          "name" => jany({"type" => jany("string")}),
        } of String => JSON::Any),
      } of String => JSON::Any

      Trellis::Schema.enforce_strict(schema)

      schema.has_key?("additionalProperties").should be_false
    end
  end
end
