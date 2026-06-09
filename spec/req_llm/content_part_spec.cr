require "../spec_helper"

describe ReqLLM::ContentPart do
  it "builds a text part" do
    part = ReqLLM::ContentPart.text("hello")
    part.type.should eq(ReqLLM::PartType::Text)
    part.text.should eq("hello")
  end

  it "builds an image_url part" do
    part = ReqLLM::ContentPart.image_url("https://x/y.png")
    part.type.should eq(ReqLLM::PartType::ImageUrl)
    part.url.should eq("https://x/y.png")
  end

  it "builds a binary image part with media type" do
    part = ReqLLM::ContentPart.image(Bytes[1, 2, 3], "image/png")
    part.type.should eq(ReqLLM::PartType::Image)
    part.media_type.should eq("image/png")
    part.data.should eq(Bytes[1, 2, 3])
  end

  it "builds a thinking part" do
    ReqLLM::ContentPart.thinking("reasoning").type.should eq(ReqLLM::PartType::Thinking)
  end
end
