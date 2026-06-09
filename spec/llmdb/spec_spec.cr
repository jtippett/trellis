require "../spec_helper"

describe LLMDB::Spec do
  it "parses provider and model" do
    parsed = LLMDB::Spec.parse("openai:gpt-4o-mini")
    parsed.provider.should eq(:openai)
    parsed.model.should eq("gpt-4o-mini")
    parsed.tag.should be_nil
  end

  it "parses and tracks a tag" do
    parsed = LLMDB::Spec.parse("anthropic:claude-sonnet-4-5@20250929")
    parsed.provider.should eq(:anthropic)
    parsed.model.should eq("claude-sonnet-4-5")
    parsed.tag.should eq("20250929")
  end

  it "round-trips to its string form" do
    LLMDB::Spec.parse("google:gemini-2.5-flash").to_s.should eq("google:gemini-2.5-flash")
    LLMDB::Spec.parse("openai:gpt-4o-mini@preview").to_s.should eq("openai:gpt-4o-mini@preview")
  end

  it "rejects a spec without a colon" do
    expect_raises(ReqLLM::Error::Invalid::Parameter) { LLMDB::Spec.parse("gpt-4o") }
  end

  it "rejects a spec with an empty model" do
    expect_raises(ReqLLM::Error::Invalid::Parameter) { LLMDB::Spec.parse("openai:") }
  end

  it "rejects an unknown provider" do
    expect_raises(ReqLLM::Error::Invalid::Parameter, /provider/) { LLMDB::Spec.parse("nope:model") }
  end
end
