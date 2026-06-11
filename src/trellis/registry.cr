require "./error"
require "./provider"

module Trellis
  # Maps a provider id (a String, e.g. "openai") to a registered provider
  # instance. Mirrors the dispatch role of `Trellis.provider_registry`.
  #
  # The registry starts empty; concrete providers (Unit N) register themselves
  # at load time. `fetch` raises `Error::Invalid::Parameter` for an unknown id.
  module Registry
    extend self

    @@providers = {} of String => Provider

    # Register (or replace) a provider under its own `#id`.
    def register(provider : Provider) : Provider
      @@providers[provider.id] = provider
    end

    # Return the provider registered under `provider_id`, raising
    # `Error::Invalid::Parameter` when none is registered.
    def fetch(provider_id : String) : Provider
      @@providers[provider_id]? ||
        raise Error::Invalid::Parameter.new("unsupported provider: #{provider_id}")
    end

    # Whether a provider is registered under `provider_id`.
    def registered?(provider_id : String) : Bool
      @@providers.has_key?(provider_id)
    end

    # All registered provider ids.
    def ids : Array(String)
      @@providers.keys
    end
  end
end
