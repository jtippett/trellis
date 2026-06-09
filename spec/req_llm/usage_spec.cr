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
end
