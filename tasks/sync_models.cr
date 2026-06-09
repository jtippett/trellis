# sync_models — regenerates the vendored `src/llmdb/data/models.json` catalog
# from models.dev.
#
# Usage:
#   crystal run tasks/sync_models.cr                      # fetch live api.json
#   crystal run tasks/sync_models.cr -- --source FILE     # offline: read FILE
#
# Behavior:
#   * Primary source: https://models.dev/api.json via stdlib HTTP::Client.
#   * Offline fallback: --source <path> reads + normalizes a local JSON file in
#     the models.dev shape (so this runs in restricted/CI/offline environments).
#   * Normalizes models.dev's provider-keyed shape into OUR flat catalog shape
#     (keyed "provider:id"), the same shape `LLMDB::Model` deserializes.
#   * Writes the catalog with DETERMINISTIC ordering (top-level keys sorted by
#     "provider:id", fixed per-model field order) so diffs are clean.
#   * Bumps `LLMDB::VERSION` (the date constant in src/llmdb.cr) to today.
#
# models.dev api.json shape (assumed; documented at models.dev and in
# req_llm/guides/model-metadata.md — verified offline against a fixture here):
#
#   {
#     "<provider_id>": {
#       "id": "<provider_id>",
#       "name": "...",
#       "models": {
#         "<model_id>": {
#           "id": "<model_id>", "name": "...", "type": "chat",
#           "attachment": bool, "reasoning": bool, "temperature": bool,
#           "tool_call": bool,
#           "cost":  {"input": f, "output": f, "cache_read": f},
#           "limit": {"context": i, "output": i},
#           "modalities": {"input": [..], "output": [..]}
#         }, ...
#       }
#     }, ...
#   }
#
# Note: models.dev's per-model objects do NOT carry a "provider" field — it is
# the top-level key, which we fold into each normalized record.

require "http/client"
require "json"

module SyncModels
  extend self

  MODELS_DEV_URL = "https://models.dev/api.json"
  DATA_PATH      = File.expand_path("../src/llmdb/data/models.json", __DIR__)
  LLMDB_PATH     = File.expand_path("../src/llmdb.cr", __DIR__)

  def run(argv : Array(String)) : Nil
    source = parse_source(argv)
    raw =
      if source
        read_source(source)
      else
        fetch_remote
      end

    api = JSON.parse(raw)
    entries = normalize(api)

    if entries.empty?
      STDERR.puts "error: no models found in source (unexpected shape?)"
      exit 1
    end

    # Only bump VERSION when the catalog content actually changed, so the
    # weekly CI job opens a PR on real drift rather than on every date change.
    if write_catalog(entries)
      version = bump_version
      puts "wrote #{entries.size} models to #{DATA_PATH} (catalog changed)"
      puts "LLMDB::VERSION = #{version.inspect}"
    else
      puts "catalog unchanged (#{entries.size} models); VERSION left at #{current_version.inspect}"
    end
  end

  # --- argument parsing ----------------------------------------------------

  private def parse_source(argv : Array(String)) : String?
    idx = argv.index("--source")
    return nil unless idx
    path = argv[idx + 1]?
    unless path
      STDERR.puts "error: --source requires a path argument"
      exit 1
    end
    path
  end

  # --- sources -------------------------------------------------------------

  private def read_source(path : String) : String
    unless File.exists?(path)
      STDERR.puts "error: --source file not found: #{path}"
      exit 1
    end
    File.read(path)
  end

  private def fetch_remote : String
    response = HTTP::Client.get(MODELS_DEV_URL)
    unless response.success?
      STDERR.puts "error: GET #{MODELS_DEV_URL} returned #{response.status_code}"
      exit 1
    end
    response.body
  rescue ex : Socket::Error | IO::Error | OpenSSL::Error
    STDERR.puts "error: could not reach #{MODELS_DEV_URL}: #{ex.message}"
    STDERR.puts "       pass --source <path> to normalize from a local file instead."
    exit 1
  end

  # --- normalization -------------------------------------------------------

  # Normalize models.dev's provider-keyed shape into a sorted array of
  # {catalog_key, model_object} tuples in OUR flat shape.
  def normalize(api : JSON::Any) : Array({String, JSON::Any})
    entries = [] of {String, JSON::Any}

    api.as_h.each do |provider_id, provider_data|
      provider_h = provider_data.as_h?
      next unless provider_h
      models = provider_h["models"]?.try(&.as_h?)
      next unless models

      models.each do |model_id, m|
        next unless m.as_h?
        id = m["id"]?.try(&.as_s) || model_id
        entries << {"#{provider_id}:#{id}", build_model(provider_id, id, m)}
      end
    end

    entries.sort_by! { |entry| entry[0] }
  end

  # Build one normalized model object with a FIXED field order (Crystal Hash
  # preserves insertion order, so output is deterministic).
  private def build_model(provider_id : String, id : String, m : JSON::Any) : JSON::Any
    h = {} of String => JSON::Any
    h["id"] = JSON::Any.new(id)
    if name = m["name"]?.try(&.as_s?)
      h["name"] = JSON::Any.new(name)
    end
    h["provider"] = JSON::Any.new(provider_id)
    h["type"] = JSON::Any.new(m["type"]?.try(&.as_s?) || "chat")
    h["attachment"] = JSON::Any.new(bool(m, "attachment"))
    h["reasoning"] = JSON::Any.new(bool(m, "reasoning"))
    h["temperature"] = JSON::Any.new(bool(m, "temperature"))
    h["tool_call"] = JSON::Any.new(bool(m, "tool_call"))
    h["cost"] = build_cost(m["cost"]?)
    h["limit"] = build_limit(m["limit"]?)
    h["modalities"] = build_modalities(m["modalities"]?)
    JSON::Any.new(h)
  end

  private def build_cost(cost : JSON::Any?) : JSON::Any
    h = {} of String => JSON::Any
    h["input"] = JSON::Any.new(num(cost, "input"))
    h["output"] = JSON::Any.new(num(cost, "output"))
    if cost && (cr = cost["cache_read"]?) && coerce_float(cr)
      h["cache_read"] = JSON::Any.new(coerce_float(cr).not_nil!)
    end
    JSON::Any.new(h)
  end

  private def build_limit(limit : JSON::Any?) : JSON::Any
    h = {} of String => JSON::Any
    h["context"] = JSON::Any.new(int(limit, "context"))
    h["output"] = JSON::Any.new(int(limit, "output"))
    JSON::Any.new(h)
  end

  private def build_modalities(mod : JSON::Any?) : JSON::Any
    h = {} of String => JSON::Any
    h["input"] = JSON::Any.new(string_array(mod, "input"))
    h["output"] = JSON::Any.new(string_array(mod, "output"))
    JSON::Any.new(h)
  end

  # --- coercion helpers ----------------------------------------------------

  private def bool(obj : JSON::Any, key : String) : Bool
    obj[key]?.try(&.as_bool?) || false
  end

  private def num(obj : JSON::Any?, key : String) : Float64
    return 0.0 unless obj
    coerce_float(obj[key]?) || 0.0
  end

  private def int(obj : JSON::Any?, key : String) : Int64
    return 0_i64 unless obj
    v = obj[key]?
    return 0_i64 unless v
    v.as_i64? || v.as_i?.try(&.to_i64) || v.as_f?.try(&.to_i64) || 0_i64
  end

  private def coerce_float(v : JSON::Any?) : Float64?
    return nil unless v
    v.as_f? || v.as_i64?.try(&.to_f) || v.as_i?.try(&.to_f)
  end

  private def string_array(obj : JSON::Any?, key : String) : Array(JSON::Any)
    return [] of JSON::Any unless obj
    arr = obj[key]?.try(&.as_a?)
    return [] of JSON::Any unless arr
    arr.compact_map { |e| e.as_s?.try { |s| JSON::Any.new(s) } }
  end

  # --- output --------------------------------------------------------------

  # Returns true if the catalog file content changed (and was rewritten).
  private def write_catalog(entries : Array({String, JSON::Any})) : Bool
    top = {} of String => JSON::Any
    entries.each { |(key, model)| top[key] = model }
    new_content = JSON::Any.new(top).to_pretty_json + "\n"
    old_content = File.exists?(DATA_PATH) ? File.read(DATA_PATH) : nil
    return false if old_content == new_content
    File.write(DATA_PATH, new_content)
    true
  end

  # Rewrite the LLMDB::VERSION date constant to today (UTC). Returns the value.
  private def bump_version : String
    today = Time.utc.to_s("%Y-%m-%d")
    content = File.read(LLMDB_PATH)
    updated = content.sub(/VERSION = "\d{4}-\d{2}-\d{2}"/, %(VERSION = "#{today}"))
    File.write(LLMDB_PATH, updated) if updated != content
    today
  end

  private def current_version : String
    if m = File.read(LLMDB_PATH).match(/VERSION = "(\d{4}-\d{2}-\d{2})"/)
      m[1]
    else
      "unknown"
    end
  end
end

SyncModels.run(ARGV)
