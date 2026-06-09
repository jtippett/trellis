require "../spec_helper"

describe ReqLLM::Context do
  it "wraps a list of messages" do
    ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "hi")])
    ctx.messages.size.should eq(1)
    ctx.to_a.size.should eq(1)
  end

  it "defaults to an empty message list and empty tools" do
    ctx = ReqLLM::Context.new
    ctx.messages.should be_empty
    ctx.tools.should be_empty
  end

  it "appends a message with << and append" do
    ctx = ReqLLM::Context.new
    ctx << ReqLLM::Message.new(ReqLLM::Role::User, "a")
    ctx.append(ReqLLM::Message.new(ReqLLM::Role::Assistant, "b"))
    ctx.messages.size.should eq(2)
  end

  it "prepends a message" do
    ctx = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "second")])
    ctx.prepend(ReqLLM::Message.new(ReqLLM::Role::System, "first"))
    ctx.messages.first.role.should eq(ReqLLM::Role::System)
  end

  it "concatenates another context" do
    a = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "a")])
    b = ReqLLM::Context.new([ReqLLM::Message.new(ReqLLM::Role::User, "b")])
    a.concat(b)
    a.messages.size.should eq(2)
  end

  it "builds role-tagged messages via class helpers" do
    ReqLLM::Context.user("hi").role.should eq(ReqLLM::Role::User)
    ReqLLM::Context.assistant("ok").role.should eq(ReqLLM::Role::Assistant)
    ReqLLM::Context.system("be terse").role.should eq(ReqLLM::Role::System)
    ReqLLM::Context.user("hi").content.first.text.should eq("hi")
  end

  it "exposes tools passed to the constructor" do
    tools = [ReqLLM::Tool.new("get_weather", "Get the current weather")]
    ctx = ReqLLM::Context.new([] of ReqLLM::Message, tools)
    ctx.tools.size.should eq(1)
  end
end
