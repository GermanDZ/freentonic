# frozen_string_literal: true

module Freentonic
  # Static, side-effect-free validation of a workflow — everything that can
  # be checked without launching Chrome or hitting the bank. Today the
  # earliest full check of a workflow is a live login; `--lint` moves the
  # cheap failures (typos, missing files, unresolvable classes, dangling
  # credential/secret references) to the front of the loop.
  #
  # Checks, in order:
  #   1. Schema loads + validates (version, phases, actions, required keys).
  #   2. `extract:` / `normalize:` ruby files exist, `require`, and their
  #      classes resolve and expose `#call`.
  #   3. `api_client:` YAML builds into a class (endpoints, auth headers,
  #      derived credentials, ext module) without a live request.
  #   4. Every `credentials.require` key is produced by a capture action's
  #      `as:` output (a missing one hard-fails at connect time).
  #   5. Every `secret(NAME)` reference has a matching `secrets:` entry
  #      (warning — the runtime falls back to prompting, but it usually
  #      signals a typo).
  #
  # Loads no Chrome and performs no network I/O. It DOES `require` the
  # provider's extractor/normalizer/ext ruby (same trust model as a run —
  # "YAML is code"), so only lint workflows you would run.
  class Linter
    def initialize(workflow_path:, stdout:, stderr:)
      @workflow_path = File.expand_path(workflow_path)
      @stdout = stdout
      @stderr = stderr
      @errors = []
      @warnings = []
    end

    # Returns a process exit code: 0 = clean (warnings allowed), 1 = errors.
    def run
      schema = load_schema
      if schema
        check_provider_ruby(schema, "extract",   schema.raw["extract"])
        check_provider_ruby(schema, "normalize", schema.normalizer)
        check_api_client(schema)
        check_credentials(schema)
        check_secrets(schema)
      end
      report
      @errors.empty? ? 0 : 1
    end

    private

    def load_schema
      WorkflowSchema.load(@workflow_path)
    rescue UserError => e
      error(e.message)
      nil
    rescue Errno::ENOENT
      error("workflow not found: #{@workflow_path}")
      nil
    end

    # extract: / normalize: → { ruby:, class: }. Resolves the file and class
    # exactly as the stage does, so a bad path or renamed class fails here
    # instead of after login.
    def check_provider_ruby(schema, label, spec)
      return if spec.nil?

      unless spec.is_a?(Hash) && spec["ruby"] && spec["class"]
        return error("#{label}: must be a hash with ruby: and class: keys")
      end

      ruby_path = File.expand_path(spec["ruby"], File.dirname(schema.path))
      unless File.file?(ruby_path)
        return error("#{label}.ruby: file not found: #{ruby_path}")
      end

      begin
        require ruby_path
      rescue ScriptError, StandardError => e
        return error("#{label}.ruby: failed to load #{ruby_path}: #{e.message}")
      end

      klass = resolve_const(spec["class"])
      return error("#{label}.class: #{spec["class"]} is not defined after loading #{ruby_path}") unless klass

      unless klass.is_a?(Class) && klass.method_defined?(:call)
        error("#{label}.class: #{spec["class"]} must be a class exposing #call")
      end
    end

    def check_api_client(schema)
      return unless schema.raw["api_client"]
      schema.api_client_class
    rescue UserError => e
      error(e.message)
    rescue ScriptError, StandardError => e
      error("api_client: failed to build client class: #{e.message}")
    end

    # credentials.require lists context keys that MUST exist after connect;
    # they can only come from a capture action's as:. A require key nothing
    # captures is a guaranteed connect-time failure.
    def check_credentials(schema)
      cred = schema.credentials
      return unless cred.is_a?(Hash)

      captured = captured_context_keys(schema)

      Array(cred["require"]).each do |key|
        next if captured.include?(key.to_s)
        error("credentials.require: #{key.inspect} is never captured " \
              "(no capture action writes as: #{key})")
      end

      Array(cred["map"]).each do |mapping|
        from = mapping.is_a?(Hash) ? mapping["from"] : nil
        next if from.nil? || captured.include?(from.to_s)
        warning("credentials.map: from: #{from.inspect} is never captured")
      end
    end

    def check_secrets(schema)
      declared = schema.secrets.keys.map(&:to_s)
      secret_names(schema.raw).each do |name|
        next if declared.include?(name)
        warning("secret(#{name}): no secrets: entry declared for #{name.inspect} " \
                "(falls back to prompting — check for a typo)")
      end
    end

    # Every as: written by a capture_* action across all phases.
    def captured_context_keys(schema)
      keys = []
      schema.phases.each_value do |steps|
        Array(steps).each do |step|
          next unless step.is_a?(Hash)
          action = step["action"].to_s
          next unless action.start_with?("capture")
          keys << step["as"].to_s if step["as"]
        end
      end
      keys
    end

    # Recursively collect every bare secret NAME referenced anywhere in the
    # workflow (secret(NAME) and secret(NAME[i])).
    def secret_names(node, acc = [])
      case node
      when String
        if (m = SecretResolver::SECRET_PATTERN.match(node))
          ref = m[1]
          idx = SecretResolver::INDEXED_NAME_PATTERN.match(ref)
          acc << (idx ? idx[:name] : ref)
        end
      when Array then node.each { |v| secret_names(v, acc) }
      when Hash  then node.each_value { |v| secret_names(v, acc) }
      end
      acc.uniq
    end

    def resolve_const(name)
      name.to_s.split("::").inject(Object) { |ns, part| ns.const_get(part, false) }
    rescue NameError
      nil
    end

    def error(msg)
      @errors << msg
      nil
    end

    def warning(msg)
      @warnings << msg
      nil
    end

    def report
      rel = @workflow_path
      @warnings.each { |w| @stdout.puts "  ⚠ #{w}" }
      @errors.each   { |e| @stdout.puts "  ✗ #{e}" }

      if @errors.empty?
        suffix = @warnings.empty? ? "" : " (#{@warnings.size} warning(s))"
        @stdout.puts "✓ #{rel} lints clean#{suffix}"
      else
        @stdout.puts "✗ #{rel}: #{@errors.size} error(s), #{@warnings.size} warning(s)"
      end
    end
  end
end
