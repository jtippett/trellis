require "../spec_helper"

describe Trellis::Context do
  it "wraps a list of messages" do
    ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "hi")])
    ctx.messages.size.should eq(1)
    ctx.to_a.size.should eq(1)
  end

  it "defaults to an empty message list and empty tools" do
    ctx = Trellis::Context.new
    ctx.messages.should be_empty
    ctx.tools.should be_empty
  end

  it "appends a message with << and append" do
    ctx = Trellis::Context.new
    ctx << Trellis::Message.new(Trellis::Role::User, "a")
    ctx.append(Trellis::Message.new(Trellis::Role::Assistant, "b"))
    ctx.messages.size.should eq(2)
  end

  it "prepends a message" do
    ctx = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "second")])
    ctx.prepend(Trellis::Message.new(Trellis::Role::System, "first"))
    ctx.messages.first.role.should eq(Trellis::Role::System)
  end

  it "concatenates another context" do
    a = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "a")])
    b = Trellis::Context.new([Trellis::Message.new(Trellis::Role::User, "b")])
    a.concat(b)
    a.messages.size.should eq(2)
  end

  it "builds role-tagged messages via class helpers" do
    Trellis::Context.user("hi").role.should eq(Trellis::Role::User)
    Trellis::Context.assistant("ok").role.should eq(Trellis::Role::Assistant)
    Trellis::Context.system("be terse").role.should eq(Trellis::Role::System)
    Trellis::Context.user("hi").content.first.text.should eq("hi")
  end

  it "exposes tools passed to the constructor" do
    tools = [Trellis::Tool.new("get_weather", "Get the current weather")]
    ctx = Trellis::Context.new([] of Trellis::Message, tools)
    ctx.tools.size.should eq(1)
  end
end
