require "../spec_helper"

describe ReqLLM::Usage do
  it "defaults all token counts to zero" do
    usage = ReqLLM::Usage.new
    usage.input_tokens.should eq(0)
    usage.output_tokens.should eq(0)
    usage.reasoning_tokens.should eq(0)
    usage.cached_tokens.should eq(0)
    usage.total_tokens.should eq(0)
  end

  it "sums input and output into total_tokens" do
    usage = ReqLLM::Usage.new(input_tokens: 1000, output_tokens: 500)
    usage.total_tokens.should eq(1500)
  end

  it "computes dollar cost from per-1M-token pricing" do
    usage = ReqLLM::Usage.new(input_tokens: 1_000_000, output_tokens: 500_000)
    usage.cost({input: 0.15, output: 0.60}).should be_close(0.45, 1e-9)
  end

  it "scales cost with token counts" do
    usage = ReqLLM::Usage.new(input_tokens: 200_000, output_tokens: 100_000)
    usage.cost({input: 0.15, output: 0.60}).should be_close(0.09, 1e-9)
  end

  describe "#cost(LLMDB::Model::Cost)" do
    it "applies the cache_read discount to cached tokens (subset of input)" do
      # cached_tokens are a subset of input_tokens: the non-cached portion
      # bills at the input rate, the cached portion at the cheaper cache_read
      # rate, output at the output rate. Mirrors ReqLLM.Billing (billing.ex).
      usage = ReqLLM::Usage.new(input_tokens: 1000, output_tokens: 500, cached_tokens: 400)
      cost = LLMDB::Model::Cost.new(input: 0.15, output: 0.60, cached: 0.075)
      expected = (600 * 0.15 + 400 * 0.075 + 500 * 0.60) / 1_000_000.0
      usage.cost(cost).not_nil!.should be_close(expected, 1e-12)
    end

    it "bills cached tokens at the input rate when no cache_read rate is set" do
      # No cache_read rate -> no carve-out; cached tokens fall back to the
      # input rate, so the result equals input_tokens * input_rate + output.
      usage = ReqLLM::Usage.new(input_tokens: 1000, output_tokens: 500, cached_tokens: 400)
      cost = LLMDB::Model::Cost.new(input: 0.15, output: 0.60)
      expected = (1000 * 0.15 + 500 * 0.60) / 1_000_000.0
      usage.cost(cost).not_nil!.should be_close(expected, 1e-12)
    end

    it "reduces to plain input/output cost when there are no cached tokens" do
      usage = ReqLLM::Usage.new(input_tokens: 11, output_tokens: 7)
      cost = LLMDB::Model::Cost.new(input: 0.15, output: 0.60)
      usage.cost(cost).not_nil!.should be_close(5.85e-6, 1e-12)
    end

    it "returns nil for an unpriced model (no input/output/cache rates)" do
      usage = ReqLLM::Usage.new(input_tokens: 1000, output_tokens: 500)
      usage.cost(LLMDB::Model::Cost.new).should be_nil
    end
  end

  describe "#cost_str" do
    it "is nil when no cost is computed" do
      ReqLLM::Usage.new.cost_str.should be_nil
    end

    it "formats a tiny cost without scientific notation, trimming trailing zeros" do
      ReqLLM::Usage.new(cost: 2.6999999999999996e-6).cost_str.should eq("$0.0000027")
    end

    it "trims a whole-ish dollar cost to its significant decimals" do
      ReqLLM::Usage.new(cost: 1.5).cost_str.should eq("$1.5")
    end
  end
end
