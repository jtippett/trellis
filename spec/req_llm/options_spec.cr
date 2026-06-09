require "../spec_helper"

describe ReqLLM::Options do
  describe ".validate (base schema)" do
    it "applies defaults for omitted options" do
      v = ReqLLM::Options.validate({temperature: 0.7})
      v.fetch_float?(:temperature).should eq(0.7)
      v.fetch_bool(:stream).should be_false
      v.fetch_int?(:max_tokens).should be_nil
      v.fetch_tools.should eq([] of ReqLLM::Tool)
    end

    it "keeps user-provided values over defaults" do
      v = ReqLLM::Options.validate({temperature: 1.0, max_tokens: 256, stream: true})
      v.fetch_int?(:max_tokens).should eq(256)
      v.fetch_bool(:stream).should be_true
    end

    it "raises Invalid::Parameter on a range violation" do
      expect_raises(ReqLLM::Error::Invalid::Parameter, /temperature/) do
        ReqLLM::Options.validate({temperature: 3.0})
      end
    end

    it "raises Invalid::Parameter on a type mismatch" do
      expect_raises(ReqLLM::Error::Invalid::Parameter, /max_tokens/) do
        ReqLLM::Options.validate({max_tokens: "lots"})
      end
    end

    it "raises Invalid::Parameter on an unknown key" do
      expect_raises(ReqLLM::Error::Invalid::Parameter, /unknown/) do
        ReqLLM::Options.validate({not_a_real_option: 1})
      end
    end

    it "coerces an integer where a float is expected" do
      v = ReqLLM::Options.validate({temperature: 1})
      v.fetch_float?(:temperature).should eq(1.0)
    end

    it "exposes validated values via [] and get" do
      v = ReqLLM::Options.validate({temperature: 0.5})
      v[:temperature].should eq(0.5)
      v.get(:stream).should eq(false)
    end
  end

  describe "schema extension" do
    it "merges provider-specific keys onto the base schema" do
      schema = ReqLLM::Options.base_schema.merge(
        ReqLLM::Options.schema({
          reasoning_effort:  {type: :symbol, default: :medium},
          anthropic_version: {type: :string},
        })
      )

      v = schema.validate({
        temperature:       0.2,
        reasoning_effort:  :high,
        anthropic_version: "2023-06-01",
      })
      v.fetch_symbol?(:reasoning_effort).should eq(:high)
      v.fetch_string?(:anthropic_version).should eq("2023-06-01")
      v.fetch_float?(:temperature).should eq(0.2)
    end

    it "applies a provider default when the key is omitted" do
      schema = ReqLLM::Options.base_schema.merge(
        ReqLLM::Options.schema({reasoning_effort: {type: :symbol, default: :medium}})
      )
      schema.validate({temperature: 0.1}).fetch_symbol?(:reasoning_effort).should eq(:medium)
    end

    it "still rejects unknown keys after extension" do
      schema = ReqLLM::Options.base_schema.merge(
        ReqLLM::Options.schema({reasoning_effort: {type: :symbol}})
      )
      expect_raises(ReqLLM::Error::Invalid::Parameter) do
        schema.validate({totally_unknown: 1})
      end
    end
  end
end
