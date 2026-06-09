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
        key, _, raw = line.partition('=')
        next if key.empty?
        value = raw.strip
        if (value.starts_with?('"') && value.ends_with?('"')) ||
           (value.starts_with?('\'') && value.ends_with?('\''))
          value = value[1..-2]
        end
        result[key.strip] = value
      end
      result
    end

    def load_env_file(path : String = ".env") : Nil
      return unless File.exists?(path)
      parse_env(File.read(path)).each { |k, v| ENV[k] ||= v }
    end
  end
end
