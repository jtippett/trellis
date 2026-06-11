require "../../spec_helper"

private def parse(input : String) : Array(Trellis::SSE::Event)
  Trellis::SSE.parse(IO::Memory.new(input))
end

describe Trellis::SSE do
  it "parses a single data-only event" do
    events = parse("data: {\"a\":1}\n\n")
    events.size.should eq(1)
    events[0].event.should be_nil
    events[0].data.should eq("{\"a\":1}")
  end

  it "parses a named event" do
    events = parse("event: delta\ndata: x\n\n")
    events.size.should eq(1)
    events[0].event.should eq("delta")
    events[0].data.should eq("x")
  end

  it "joins multiple data lines with a newline" do
    events = parse("data: a\ndata: b\n\n")
    events.size.should eq(1)
    events[0].data.should eq("a\nb")
  end

  it "does not filter the [DONE] sentinel" do
    events = parse("data: [DONE]\n\n")
    events.size.should eq(1)
    events[0].data.should eq("[DONE]")
  end

  it "ignores comment lines" do
    events = parse(": ping\n\n")
    events.should be_empty
  end

  it "ignores comments but still dispatches a real event" do
    events = parse(": ping\ndata: x\n\n")
    events.size.should eq(1)
    events[0].data.should eq("x")
  end

  it "tolerates CRLF line endings" do
    events = parse("event: delta\r\ndata: x\r\n\r\n")
    events.size.should eq(1)
    events[0].event.should eq("delta")
    events[0].data.should eq("x")
  end

  it "parses multiple events in order" do
    events = parse("data: one\n\ndata: two\n\ndata: three\n\n")
    events.map(&.data).should eq(["one", "two", "three"])
  end

  it "strips a single leading space after the colon" do
    events = parse("data:  two-spaces\n\n")
    events[0].data.should eq(" two-spaces")
  end

  it "handles a field with no space after the colon" do
    events = parse("data:x\n\n")
    events[0].data.should eq("x")
  end

  it "captures id and retry fields" do
    events = parse("id: 42\nretry: 1000\ndata: x\n\n")
    events[0].id.should eq("42")
    events[0].retry.should eq("1000")
    events[0].data.should eq("x")
  end

  it "does NOT dispatch an incomplete trailing event at EOF" do
    events = parse("data: complete\n\ndata: dangling")
    events.map(&.data).should eq(["complete"])
  end

  it "yields events incrementally via each_event" do
    collected = [] of String
    Trellis::SSE.each_event(IO::Memory.new("data: a\n\ndata: b\n\n")) do |event|
      collected << event.data
    end
    collected.should eq(["a", "b"])
  end

  it "does not dispatch a blank-line-only stream" do
    parse("\n\n\n").should be_empty
  end
end
