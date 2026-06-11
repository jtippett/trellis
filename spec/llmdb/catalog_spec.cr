require "../spec_helper"

describe LLMDB do
  it "looks up a model by spec string" do
    model = LLMDB.model("openai:gpt-4o-mini")
    model.provider.should eq("openai")
    model.id.should eq("gpt-4o-mini")
    model.context_limit.should eq(128_000)
    model.cost.input.should eq(0.15)
    model.cost.output.should eq(0.6)
    model.supports?(:tools).should be_true
  end

  it "looks up the other seeded flagship models" do
    LLMDB.model("anthropic:claude-sonnet-4-5").provider.should eq("anthropic")
    LLMDB.model("google:gemini-2.5-flash").provider.should eq("google")
  end

  it "ignores a tag when looking up" do
    LLMDB.model("openai:gpt-4o-mini@preview").id.should eq("gpt-4o-mini")
  end

  it "accepts a pre-parsed Spec" do
    LLMDB.model(LLMDB::Spec.parse("openai:gpt-4o-mini")).id.should eq("gpt-4o-mini")
  end

  it "raises for an unknown model" do
    expect_raises(Trellis::Error::Invalid::Parameter) { LLMDB.model("openai:does-not-exist") }
  end

  it "exposes all models and providers" do
    LLMDB.models.size.should be >= 3
    LLMDB.providers.should contain("openai")
    LLMDB.providers.should contain("anthropic")
    LLMDB.providers.should contain("google")
  end

  it "loaded the full real catalog (thousands of models)" do
    LLMDB.models.size.should be > 1000
  end

  it "resolves a non-flagship model from the full catalog" do
    model = LLMDB.model("openai:gpt-4o")
    model.provider.should eq("openai")
    model.id.should eq("gpt-4o")
    model.context_limit.should be > 0
  end

  it "exposes structured_output for a model that advertises it" do
    LLMDB.model("openai:gpt-4o").supports?(:structured_output).should be_true
  end

  it "loads a model with tiered/non-scalar cost without crashing" do
    # 302ai:gpt-5.4 carries non-scalar `tiers` (list) and `context_over_200k`
    # (dict) pricing in models.dev; the sync skips those, keeping only scalar
    # cost keys, so the model still deserializes with sane numeric costs.
    model = LLMDB.model("302ai:gpt-5.4")
    model.cost.input.should be >= 0.0
    model.cost.output.should be >= 0.0
  end

  it "has a catalog version" do
    LLMDB::VERSION.should match(/\d{4}-\d{2}-\d{2}/)
  end
end
