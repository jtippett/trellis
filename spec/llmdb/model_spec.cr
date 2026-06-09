require "../spec_helper"

private MODEL_JSON = <<-JSON
{
  "id": "gpt-4o-mini",
  "name": "GPT-4o mini",
  "provider": "openai",
  "type": "chat",
  "tool_call": true,
  "reasoning": false,
  "temperature": true,
  "attachment": true,
  "cost": {"input": 0.15, "output": 0.6, "cache_read": 0.075},
  "limit": {"context": 128000, "output": 16384},
  "modalities": {"input": ["text", "image"], "output": ["text"]}
}
JSON

describe LLMDB::Model do
  it "loads the models.dev JSON shape" do
    model = LLMDB::Model.from_json(MODEL_JSON)
    model.id.should eq("gpt-4o-mini")
    model.name.should eq("GPT-4o mini")
    model.provider.should eq(:openai)
    model.type.should eq("chat")
  end

  it "exposes capabilities via supports?" do
    model = LLMDB::Model.from_json(MODEL_JSON)
    model.supports?(:tools).should be_true
    model.supports?(:temperature).should be_true
    model.supports?(:attachment).should be_true
    model.supports?(:reasoning).should be_false
  end

  it "exposes context and output limits" do
    model = LLMDB::Model.from_json(MODEL_JSON)
    model.context_limit.should eq(128000)
    model.output_limit.should eq(16384)
  end

  it "exposes input/output/cached pricing for cost wiring" do
    model = LLMDB::Model.from_json(MODEL_JSON)
    model.cost.input.should eq(0.15)
    model.cost.output.should eq(0.6)
    model.cost.cached.should eq(0.075)
  end

  it "exposes modalities" do
    model = LLMDB::Model.from_json(MODEL_JSON)
    model.modalities.input.should eq(["text", "image"])
    model.modalities.output.should eq(["text"])
  end

  it "defaults missing optional fields" do
    model = LLMDB::Model.from_json(%({"id": "x", "provider": "openai"}))
    model.cost.input.should eq(0.0)
    model.context_limit.should eq(0)
    model.supports?(:tools).should be_false
    model.modalities.input.should be_empty
  end
end
