module ReqLLM
  # Token usage for a single model exchange, plus cost derivation.
  #
  # Mirrors the canonical token shape ReqLLM.Usage normalizes to (usage.ex) and
  # the per-token cost math in ReqLLM.Usage.Cost / ReqLLM.Billing
  # (usage/cost.ex). Pricing is expressed in USD per 1,000,000 tokens, matching
  # the models.dev catalog convention.
  struct Usage
    getter input_tokens : Int32
    getter output_tokens : Int32
    getter reasoning_tokens : Int32
    getter cached_tokens : Int32

    # The computed dollar cost for this exchange, attached by `Steps.usage`
    # after decode (nil until the usage step runs with a priced model). The
    # zero-arg `cost` reader returns this stored value; the `cost(pricing)` /
    # `cost(input:, output:)` overloads COMPUTE a cost from a pricing pair and
    # leave this field untouched — the step computes, then assigns the result
    # back via `usage.cost = ...`.
    property cost : Float64? = nil

    def initialize(@input_tokens : Int32 = 0, @output_tokens : Int32 = 0,
                   @reasoning_tokens : Int32 = 0, @cached_tokens : Int32 = 0,
                   @cost : Float64? = nil)
    end

    # Input plus output tokens.
    def total_tokens : Int32
      input_tokens + output_tokens
    end

    # Dollar cost given a pricing pair in USD per 1,000,000 tokens, e.g.
    # `usage.cost({input: 0.15, output: 0.60})`. Use
    # `LLMDB::Model::Cost#to_pricing` to feed a catalog `Cost` struct here.
    def cost(pricing) : Float64
      cost(input: pricing[:input], output: pricing[:output])
    end

    # Dollar cost from explicit input/output per-1M-token prices.
    def cost(*, input : Float64, output : Float64) : Float64
      (input_tokens.to_f / 1_000_000.0) * input +
        (output_tokens.to_f / 1_000_000.0) * output
    end

    # Human-readable dollar string for the stored `cost`, e.g. "$0.0000027"
    # (trailing zeros trimmed). Avoids Float64#to_s scientific-notation noise
    # like "2.6999999999999996e-6". Returns nil when no cost is computed.
    def cost_str : String?
      c = @cost
      return nil unless c
      formatted = ("%.8f" % c).sub(/(\.\d*?)0+$/, "\\1").sub(/\.$/, "")
      "$#{formatted}"
    end
  end
end
