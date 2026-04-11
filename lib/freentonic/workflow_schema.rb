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
        next if steps.nil? || steps.is_a?(Array)

        raise UserError, "workflow #{@path} phase #{phase_name.inspect} must be an array or null"
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
    end
  end
end
