# frozen_string_literal: true

module Freentonic
  # Resolves `secret(name)` references in workflow YAML values through a
  # pluggable Secrets::Store backend.
  #
  # Walks strings, arrays, and hashes recursively so you can freely nest
  # secrets inside step params. Results are cached per (source_key, name)
  # so a single run won't prompt twice for the same secret.
  #
  # The `secret(NAME[INDEX])` form looks up the *bare* secret `NAME` and
  # returns the character at position `INDEX` (0-based). Useful for
  # PIN-pad workflows where a single stored secret like "1234" needs to
  # be replayed per-digit ("1", "2", "3", "4") into separate input
  # fields. The bare-name lookup honors the normal stored / prompt /
  # cache rules; the slice itself is cached on the full reference so
  # multiple `secret(USER_PIN[0])` references reuse one cached char.
  class SecretResolver
    SECRET_PATTERN = /\Asecret\(([^)]+)\)\z/
    # `NAME` matches the underlying secret name allowed by the store's
    # write rules (alphanumeric + dot + underscore). `[N]` is a 0-based
    # integer index.
    INDEXED_NAME_PATTERN = /\A(?<name>[A-Za-z_][A-Za-z0-9_.]*)\[(?<index>\d+)\]\z/

    def initialize(secret_store: nil, stdout: $stdout, stderr: $stderr)
      @secret_store = secret_store || Secrets.build(Secrets.default_name)
      @stdout = stdout
      @stderr = stderr
      @cache = {}
    end

    def resolve_value(source:, schema:, value:)
      case value
      when String then resolve_string(source: source, schema: schema, value: value)
      when Array  then value.map { |item| resolve_value(source: source, schema: schema, value: item) }
      when Hash   then value.transform_values { |item| resolve_value(source: source, schema: schema, value: item) }
      else value
      end
    end

    private

    def resolve_string(source:, schema:, value:)
      match = SECRET_PATTERN.match(value)
      return value unless match

      reference = match[1]
      cache_key = [source.key, reference]
      return @cache[cache_key] if @cache.key?(cache_key)

      idx_match = INDEXED_NAME_PATTERN.match(reference)
      if idx_match
        bare = fetch_or_prompt(source: source, schema: schema, secret_name: idx_match[:name])
        index = idx_match[:index].to_i
        unless bare.is_a?(String) && index < bare.length
          raise UserError,
                "secret(#{reference}): index #{index} out of range for " \
                "#{idx_match[:name]} (length #{bare.to_s.length})"
        end
        return @cache[cache_key] = bare[index]
      end

      @cache[cache_key] = fetch_or_prompt(source: source, schema: schema, secret_name: reference)
    end

    def fetch_or_prompt(source:, schema:, secret_name:)
      bare_cache_key = [source.key, secret_name]
      return @cache[bare_cache_key] if @cache.key?(bare_cache_key)

      stored = @secret_store.fetch(source_key: source.key, secret_name: secret_name)
      return @cache[bare_cache_key] = stored unless stored.nil? || stored.empty?

      config = schema.secret_config(secret_name)
      prompt = config["prompt"] || "Enter #{secret_name} for #{source.key}"
      @cache[bare_cache_key] = @secret_store.prompt_and_store(
        source_key: source.key,
        secret_name: secret_name,
        prompt: prompt,
        stdout: @stdout,
        stderr: @stderr
      )
    end
  end
end
