require "../spec_helper"

describe ReqLLM::Keys do
  it "prefers an explicit key over the environment" do
    ReqLLM::Keys.resolve("OPENAI_API_KEY", explicit: "sk-explicit").should eq("sk-explicit")
  end

  it "falls back to the environment" do
    ENV["OPENAI_API_KEY"] = "sk-env"
    ReqLLM::Keys.resolve("OPENAI_API_KEY").should eq("sk-env")
  ensure
    ENV.delete("OPENAI_API_KEY")
  end

  it "raises a clear error when missing" do
    expect_raises(ReqLLM::Error::Invalid::Parameter, /OPENAI_API_KEY/) do
      ReqLLM::Keys.resolve("OPENAI_API_KEY")
    end
  end

  it "parses a .env string into pairs" do
    pairs = ReqLLM::Keys.parse_env("# comment\nFOO=bar\nBAZ=\"qux\"\n")
    pairs["FOO"].should eq("bar")
    pairs["BAZ"].should eq("qux")
  end
end
