module ReqLLM
  module Keys
    extend self

    def resolve(env_key : String, explicit : String? = nil) : String
      return explicit if explicit && !explicit.empty?
      if value = ENV[env_key]?
        return value unless value.empty?
      end
      raise Error::Invalid::Parameter.new(
        "Missing API key: set #{env_key} in the environment or pass api_key:")
    end

    def parse_env(contents : String) : Hash(String, String)
      result = {} of String => String
      contents.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        # Strip a leading `export ` so `export FOO=bar` yields key FOO.
        if line.starts_with?("export ")
          line = line.lchop("export ").lstrip
        end
        key, _, raw = line.partition('=')
        next if key.empty?
        value = raw.strip
        if value.starts_with?('"') || value.starts_with?('\'')
          # Quoted value: take the content up to the matching closing quote
          # and ignore anything after it (e.g. a trailing comment). A `#`
          # inside the quotes is preserved verbatim.
          quote = value[0]
          if (closing = value.index(quote, 1))
            value = value[1...closing]
          end
        elsif (comment = inline_comment_index(value))
          # Unquoted value: a `#` at the start or preceded by whitespace
          # begins an inline comment, which is stripped.
          value = value[0...comment].rstrip
        end
        result[key.strip] = value
      end
      result
    end

    # Returns the index where an inline comment begins in an unquoted value,
    # or nil if there is none. A `#` only starts a comment when it is at the
    # start of the value or is preceded by whitespace; a `#` adjacent to a
    # non-whitespace character (e.g. `a#b`) is part of the value.
    private def inline_comment_index(value : String) : Int32?
      value.each_char_with_index do |char, index|
        if char == '#' && (index == 0 || value[index - 1].whitespace?)
          return index
        end
      end
      nil
    end

    def load_env_file(path : String = ".env") : Nil
      return unless File.exists?(path)
      parse_env(File.read(path)).each { |k, v| ENV[k] ||= v }
    end
  end
end
