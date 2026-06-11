module Trellis
  enum Role
    User
    Assistant
    System
    Tool
  end

  enum PartType
    Text
    ImageUrl
    VideoUrl
    Image
    File
    Thinking
  end

  struct ContentPart
    getter type : PartType
    getter text : String?
    getter url : String?
    getter data : Bytes?
    getter file_id : String?
    getter media_type : String?
    getter filename : String?
    getter metadata : Hash(String, JSON::Any)

    def initialize(@type, *, @text = nil, @url = nil, @data = nil,
                   @file_id = nil, @media_type = nil, @filename = nil,
                   @metadata = {} of String => JSON::Any)
    end

    def self.text(text : String, metadata = {} of String => JSON::Any)
      new(PartType::Text, text: text, metadata: metadata)
    end

    def self.thinking(text : String, metadata = {} of String => JSON::Any)
      new(PartType::Thinking, text: text, metadata: metadata)
    end

    def self.image_url(url : String, metadata = {} of String => JSON::Any)
      new(PartType::ImageUrl, url: url, metadata: metadata)
    end

    def self.video_url(url : String, metadata = {} of String => JSON::Any)
      new(PartType::VideoUrl, url: url, metadata: metadata)
    end

    def self.image(data : Bytes, media_type : String, metadata = {} of String => JSON::Any)
      new(PartType::Image, data: data, media_type: media_type, metadata: metadata)
    end

    def self.file(data : Bytes, filename : String, media_type : String)
      new(PartType::File, data: data, filename: filename, media_type: media_type)
    end

    def self.file_id(id : String, media_type : String? = nil)
      new(PartType::File, file_id: id, media_type: media_type)
    end
  end
end
