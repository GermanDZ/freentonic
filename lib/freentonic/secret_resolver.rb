# frozen_string_literal: true

module Freentonic
  # Resolves `secret(name)` references in workflow YAML values through a
  # pluggable Secrets::Store backend.
  #
  # Walks strings, arrays, and hashes recursively so you can freely nest
  # secrets inside step params. Results are cached per (source_key, name)
  # so a single run won't prompt twice for the same secret.
  class SecretResolver
    SECRET_PATTERN = /\Asecret\(([^)]+)\)\z/

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

      secret_name = match[1]
      cache_key = [source.key, secret_name]
      return @cache[cache_key] if @cache.key?(cache_key)

      stored = @secret_store.fetch(source_key: source.key, secret_name: secret_name)
      return @cache[cache_key] = stored unless stored.nil? || stored.empty?

      config = schema.secret_config(secret_name)
      prompt = config["prompt"] || "Enter #{secret_name} for #{source.key}"
      @cache[cache_key] = @secret_store.prompt_and_store(
        source_key: source.key,
        secret_name: secret_name,
        prompt: prompt,
        stdout: @stdout,
        stderr: @stderr
      )
    end
  end
end
