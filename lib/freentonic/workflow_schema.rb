# frozen_string_literal: true

require "yaml"

module Freentonic
  class WorkflowSchema
    CONFIG_KEY = "config"
    CREDENTIALS_KEY = "credentials"
    PHASES_KEY = "phases"
    PIPELINE_KEY = "pipeline"
    SECRETS_KEY = "secrets"

    def self.load(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      new(path: path, raw: raw)
    end

    attr_reader :path

    def initialize(path:, raw:)
      @path = path
      @raw = raw
      validate!
    end

    def config
      @raw.fetch(CONFIG_KEY, {})
    end

    def credentials
      @raw[CREDENTIALS_KEY]
    end

    def pipeline
      @raw.fetch(PIPELINE_KEY, [])
    end

    def phases
      @raw.fetch(PHASES_KEY, {})
    end

    def phase(name)
      Array(phases[name.to_s])
    end

    def secrets
      @raw.fetch(SECRETS_KEY, {})
    end

    def secret_config(name)
      secrets.fetch(name.to_s, {})
    end

    def error_signals
      Array(config["error_signals"])
    end

    # Declarative Normalizer spec: normalize: { ruby: "./normalizer.rb", class: "My::Normalizer" }
    def normalizer
      @raw["normalize"]
    end

    def build_api_client(credentials)
      return nil unless @raw["api_client"]
      require_relative "api_client"
      @_api_client_class ||= build_api_client_class(@raw["api_client"])
      @_api_client_class.new(credentials)
    end

    private

    def build_api_client_class(ac)
      klass = Class.new(Freentonic::ApiClient)
      klass.yaml_config(ac)

      klass.base_url(ac["base_url"]) if ac["base_url"]
      klass.api_root(ac["api_root"]) if ac["api_root"]

      apply_credentials(klass, ac["credentials"])
      klass.batch_keys(*Array(ac["batch_keys"]).map(&:to_s)) if ac["batch_keys"]
      klass.date_format(ac["date_format"])                   if ac["date_format"]

      if ac["derived_credentials"]
        specs = ac["derived_credentials"].transform_values do |v|
          { from: v["from"], regex: v["regex"], capture: (v["capture"] || 1) }
        end
        klass.derived_credentials(specs)
      end

      if ac["expected_code"] || ac["expected_content_type"]
        klass.expected_response(code: ac["expected_code"],
                                content_type: ac["expected_content_type"])
      end

      (ac["auth_headers"] || {}).each do |name, val|
        if (m = val.to_s.match(/\A\{(\w+)\}\z/))
          klass.auth_header(name, from: m[1].to_sym)
        else
          klass.auth_header(name, val.to_s)
        end
      end

      Array(ac["endpoints"]).each do |ep|
        name       = ep["name"].to_sym
        path       = ep["path"]
        base       = ep["base"]
        method     = ep["method"]&.upcase
        pagination = ep["pagination"]
        limit      = ep["limit"] || 100
        rk         = Array(ep.dig("response", "extract_batch")).map(&:to_s)
        rk         = nil if rk.empty?

        case method
        when "GET"
          params = ep["params"] || {}
          klass.define_get(name, path, base: base, params: params,
                           pagination: pagination, limit: limit,
                           response_extract_batch: rk)
        when "POST"
          form = ep["form"] || {}
          klass.define_post(name, path, base: base, form: form,
                            pagination: pagination, limit: limit,
                            response_extract_batch: rk)
        end
      end

      load_client_ext(klass, ac["ext"]) if ac["ext"]
      klass
    end

    def apply_credentials(klass, cred_config)
      return unless cred_config
      if cred_config.is_a?(Array)
        klass.credentials(*cred_config.map(&:to_sym))
      elsif cred_config.is_a?(Hash)
        names    = Array(cred_config["keys"]).map(&:to_sym)
        required = cred_config["required"] || false
        klass.credentials(*names, required: required)
      end
    end

    # ext_spec must be a Hash with explicit "file" and "module" keys.
    # The module name is resolved via a strict nested const_get(name, false)
    # walk, so YAML authors cannot influence which Ruby constant gets
    # resolved beyond what they type explicitly. Prevents a dynamic
    # constant lookup security wart.
    def load_client_ext(klass, ext_spec)
      unless ext_spec.is_a?(Hash) && ext_spec["file"] && ext_spec["module"]
        raise UserError, "workflow #{@path}: api_client.ext must be a hash with file: and module: keys"
      end
      ext_path = File.expand_path(ext_spec["file"], File.dirname(@path))
      require ext_path
      mod = ext_spec["module"].to_s.split("::").inject(Object) do |ns, name|
        ns.const_get(name, false)
      end
      klass.include(mod)
    end

    def validate!
      version = @raw["version"]
      raise UserError, "workflow #{@path} must declare version: 1" unless version == 1

      unless phases.is_a?(Hash)
        raise UserError, "workflow #{@path} phases must be a hash"
      end

      phases.each do |phase_name, steps|
        next if steps.nil?
        unless steps.is_a?(Array)
          raise UserError, "workflow #{@path} phase #{phase_name.inspect} must be an array or null"
        end
        steps.each_with_index do |step, i|
          validate_step!(phase_name, step, i)
        end
      end

      unless pipeline.is_a?(Array) && pipeline.all? { |p| p.is_a?(String) }
        raise UserError, "workflow #{@path} pipeline must be a list of phase names"
      end

      unknown = pipeline - phases.keys
      unless unknown.empty?
        raise UserError, "workflow #{@path} pipeline references undefined phases: #{unknown.join(", ")}"
      end

      unless secrets.is_a?(Hash)
        raise UserError, "workflow #{@path} secrets must be a hash"
      end

      validate_error_signals!
    end

    def validate_error_signals!
      signals = config["error_signals"]
      return if signals.nil?

      unless signals.is_a?(Array)
        raise UserError, "workflow #{@path} config.error_signals must be an array"
      end

      signals.each_with_index do |sig, i|
        unless sig.is_a?(Hash)
          raise UserError, "workflow #{@path} config.error_signals[#{i}] must be a hash"
        end
        unless sig.key?("text") || sig.key?("selector") || sig.key?("title")
          raise UserError, "workflow #{@path} config.error_signals[#{i}] must have text:, selector:, or title:"
        end
      end
    end

    WHEN_CONTEXT_NUMERIC_OPS = %w[gt gte lt lte].freeze
    WHEN_CONTEXT_EQUALITY_OPS = %w[eq neq].freeze
    WHEN_CONTEXT_PRESENCE_OPS = %w[present absent].freeze
    WHEN_CONTEXT_OPS = (WHEN_CONTEXT_NUMERIC_OPS + WHEN_CONTEXT_EQUALITY_OPS + WHEN_CONTEXT_PRESENCE_OPS).freeze

    def validate_step!(phase_name, step, index)
      unless step.is_a?(Hash) && step["action"].is_a?(String)
        raise UserError, "workflow #{@path} phase #{phase_name.inspect} step #{index}: must be a hash with an action: key"
      end

      validate_when_context!(phase_name, step, index) if step.key?("when_context")

      case step["action"]
      when "click_text"
        loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: click_text"
        unless step["text"].is_a?(String) && !step["text"].empty?
          raise UserError, "#{loc} requires a non-empty text:"
        end
        if step.key?("role") && !%w[button link any].include?(step["role"])
          raise UserError, "#{loc} role: must be one of button, link, any (got #{step["role"].inspect})"
        end
        if step.key?("within") && !step["within"].is_a?(String)
          raise UserError, "#{loc} within: must be a string"
        end
        if step.key?("match") && !%w[exact contains prefix].include?(step["match"])
          raise UserError, "#{loc} match: must be one of exact, contains, prefix (got #{step["match"].inspect})"
        end
        if step.key?("timeout") && !(step["timeout"].is_a?(Integer) && step["timeout"] >= 1)
          raise UserError, "#{loc} timeout: must be a positive integer"
        end
      when "fill", "fill_if_present"
        if step.key?("clear") && ![true, false].include?(step["clear"])
          raise UserError, "workflow #{@path} phase #{phase_name.inspect} step #{index}: #{step["action"]} clear: must be true or false"
        end
      when "record_requests"
        validate_record_requests!(phase_name, step, index)
      when "dump_requests"
        validate_dump_requests!(phase_name, step, index)
      when "pause"
        validate_pause!(phase_name, step, index)
      when "capture_url"
        validate_capture_url!(phase_name, step, index)
      when "prompt_stdin_and_fill"
        loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: prompt_stdin_and_fill"
        unless step["selector"].is_a?(String) && !step["selector"].empty?
          raise UserError, "#{loc} requires a non-empty selector:"
        end
        unless step["prompt"].is_a?(String) && !step["prompt"].empty?
          raise UserError, "#{loc} requires a non-empty prompt:"
        end
        unless step["timeout"].is_a?(Integer) && step["timeout"] >= 1
          raise UserError, "#{loc} requires a positive integer timeout: in seconds"
        end
        if step.key?("submit_selector") && !step["submit_selector"].is_a?(String)
          raise UserError, "#{loc} submit_selector: must be a string"
        end
        if step.key?("mask") && ![true, false].include?(step["mask"])
          raise UserError, "#{loc} mask: must be true or false"
        end
        if step.key?("if_present") && ![true, false].include?(step["if_present"])
          raise UserError, "#{loc} if_present: must be true or false"
        end
      end
    end

    MAX_ENTRIES_CAP    = 10_000
    MAX_BODY_BYTES_CAP = 4 * 1024 * 1024  # 4 MB

    def validate_record_requests!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: record_requests"

      url_matches = step["url_matches"]
      unless url_matches.is_a?(Array) && !url_matches.empty? && url_matches.all? { |u| u.is_a?(String) && !u.empty? }
        raise UserError, "#{loc} requires a non-empty url_matches: array of strings"
      end

      if step.key?("include_response_body") && ![true, false].include?(step["include_response_body"])
        raise UserError, "#{loc} include_response_body: must be true or false"
      end

      if step.key?("max_body_bytes")
        v = step["max_body_bytes"]
        unless v.is_a?(Integer) && v >= 1 && v <= MAX_BODY_BYTES_CAP
          raise UserError, "#{loc} max_body_bytes: must be an integer between 1 and #{MAX_BODY_BYTES_CAP}"
        end
      end

      if step.key?("max_entries")
        v = step["max_entries"]
        unless v.is_a?(Integer) && v >= 1 && v <= MAX_ENTRIES_CAP
          raise UserError, "#{loc} max_entries: must be an integer between 1 and #{MAX_ENTRIES_CAP}"
        end
      end
    end

    def validate_dump_requests!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: dump_requests"

      unless step["path"].is_a?(String) && !step["path"].empty?
        raise UserError, "#{loc} requires a non-empty path:"
      end

      if step.key?("format") && !%w[ndjson har].include?(step["format"])
        raise UserError, "#{loc} format: must be ndjson or har (got #{step["format"].inspect})"
      end

      if step.key?("reset") && ![true, false].include?(step["reset"])
        raise UserError, "#{loc} reset: must be true or false"
      end
    end

    def validate_pause!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: pause"

      unless step["message"].is_a?(String) && !step["message"].empty?
        raise UserError, "#{loc} requires a non-empty message:"
      end

      unless step["timeout"].is_a?(Integer) && step["timeout"] >= 1
        raise UserError, "#{loc} requires a positive integer timeout: in seconds"
      end
    end

    def validate_capture_url!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: capture_url"

      unless step["as"].is_a?(String) && !step["as"].empty?
        raise UserError, "#{loc} requires a non-empty as:"
      end
    end

    def validate_when_context!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: when_context"
      gate = step["when_context"]

      unless gate.is_a?(Hash)
        raise UserError, "#{loc} must be a hash"
      end

      gate.each do |key, ops|
        unless ops.is_a?(Hash) && !ops.empty?
          raise UserError, "#{loc} key #{key.inspect} must map to a non-empty hash of operators"
        end

        ops.each do |op, operand|
          unless WHEN_CONTEXT_OPS.include?(op)
            raise UserError, "#{loc} key #{key.inspect}: unknown operator #{op.inspect} (allowed: #{WHEN_CONTEXT_OPS.join(", ")})"
          end

          if WHEN_CONTEXT_NUMERIC_OPS.include?(op) && !operand.is_a?(Numeric)
            raise UserError, "#{loc} key #{key.inspect}: operator #{op.inspect} requires a numeric operand, got #{operand.inspect}"
          end

          if WHEN_CONTEXT_PRESENCE_OPS.include?(op) && ![true, false].include?(operand)
            raise UserError, "#{loc} key #{key.inspect}: operator #{op.inspect} requires a boolean operand, got #{operand.inspect}"
          end
        end
      end
    end
  end
end
