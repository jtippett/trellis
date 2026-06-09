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

    def initialize(@input_tokens : Int32 = 0, @output_tokens : Int32 = 0,
                   @reasoning_tokens : Int32 = 0, @cached_tokens : Int32 = 0)
    end

    # Input plus output tokens.
    def total_tokens : Int32
      input_tokens + output_tokens
    end

    # Dollar cost given a pricing pair in USD per 1,000,000 tokens, e.g.
    # `usage.cost({input: 0.15, output: 0.60})`.
    def cost(pricing) : Float64
      cost(input: pricing[:input], output: pricing[:output])
    end

    # Dollar cost from explicit input/output per-1M-token prices.
    def cost(*, input : Float64, output : Float64) : Float64
      (input_tokens.to_f / 1_000_000.0) * input +
        (output_tokens.to_f / 1_000_000.0) * output
    end
  end
end
