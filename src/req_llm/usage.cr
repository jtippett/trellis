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

    # Cache-aware dollar cost from a catalog `Cost` struct (USD per 1M tokens),
    # the faithful per-exchange cost. Mirrors `ReqLLM.Billing` (billing.ex):
    # OpenAI-style `cached_tokens` are a SUBSET of `input_tokens`, so the
    # non-cached portion `(input_tokens - cached_tokens)` bills at the input
    # rate while the cached portion bills at the cheaper `cache_read` rate;
    # `output_tokens` bill at the output rate. When the catalog has no
    # `cache_read` rate the cached portion falls back to the input rate, which
    # collapses the formula to `input_tokens * input_rate` (no carve-out).
    #
    # `reasoning_tokens` are already counted inside `output_tokens` for OpenAI
    # and there is no separate reasoning price in the models.dev `Cost` shape,
    # so they are NOT priced separately (matching billing.ex, which only adds
    # reasoning to output when an explicit `add_reasoning_to_cost` flag is set
    # and no reasoning component exists). `cache_write` prices cache CREATION,
    # which is metered by `cache_creation_tokens` — a field this `Usage` does
    # not carry — so it never contributes to this exchange's cost.
    #
    # Returns nil when the model is unpriced (see `Cost#priced?`), so an unknown
    # cost stays nil rather than reading as a misleading `0.0` (free).
    def cost(cost : LLMDB::Model::Cost) : Float64?
      return nil unless cost.priced?

      input_rate = cost.input
      cache_read_rate = cost.cached || input_rate
      billed_input = {input_tokens - cached_tokens, 0}.max

      (billed_input.to_f / 1_000_000.0) * input_rate +
        (cached_tokens.to_f / 1_000_000.0) * cache_read_rate +
        (output_tokens.to_f / 1_000_000.0) * cost.output
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
