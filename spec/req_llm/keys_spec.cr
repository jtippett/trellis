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

  it "strips a leading export prefix" do
    pairs = ReqLLM::Keys.parse_env("export FOO=bar\n")
    pairs["FOO"].should eq("bar")
  end

  it "strips a leading export prefix on quoted values" do
    pairs = ReqLLM::Keys.parse_env("export BAR=\"baz\"\n")
    pairs["BAR"].should eq("baz")
  end

  it "strips an inline comment from an unquoted value" do
    pairs = ReqLLM::Keys.parse_env("FOO=bar # comment\n")
    pairs["FOO"].should eq("bar")
  end

  it "preserves a # inside a double-quoted value" do
    pairs = ReqLLM::Keys.parse_env("Q=\"bar # baz\"\n")
    pairs["Q"].should eq("bar # baz")
  end

  it "preserves a # inside a single-quoted value" do
    pairs = ReqLLM::Keys.parse_env("S='a#b'\n")
    pairs["S"].should eq("a#b")
  end

  it "treats an unquoted value that is only a comment as empty" do
    pairs = ReqLLM::Keys.parse_env("FOO= # comment\n")
    pairs["FOO"].should eq("")
  end
end
