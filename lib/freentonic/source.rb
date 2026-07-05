# frozen_string_literal: true

module Freentonic
  # A Source is a thin wrapper around a workflow YAML file. In v1 all
  # provider logic lives in the YAML (plus sibling Ruby files for the
  # extractor and normalizer), so the framework never needs to subclass
  # Source — you construct one directly:
  #
  #   source = Freentonic::Source.new(workflow_path: "providers/ing/workflow.yml")
  #
  # Source knows how to:
  #   - load + memoize the workflow schema
  #   - pull out the `extract:` spec for the Extract stage
  #   - validate captured workflow_context against `credentials:` spec and
  #     return the resulting credentials hash (used by the Connect stage)
  class Source
    def initialize(workflow_path:)
      @workflow_path = workflow_path
    end

    def key
      workflow.config.fetch("key")
    end

    def default_lookback_days
      workflow.config.fetch("default_lookback_days", 14)
    end

    def workflow?
      !@workflow_path.nil?
    end

    def workflow
      return nil unless workflow?
      @workflow ||= WorkflowSchema.load(@workflow_path)
    end

    # The raw YAML extract: block. Exposed so the Extract stage can load it
    # without reaching through `workflow.config`. Accepts `extract:` either
    # nested under `config:` (legacy) or at the document root.
    def extract_spec
      workflow.config["extract"] || workflow.raw["extract"]
    end

    def extract_credentials(_session, workflow_context: {}, stdout:, stderr:)
      cred_schema = workflow&.credentials
      unless cred_schema
        raise UserError, "workflow #{@workflow_path} must declare a top-level credentials: block"
      end

      Array(cred_schema["require"]).each do |k|
        raise UserError, "capture_credentials phase did not capture #{k}" unless workflow_context[k.to_s]
      end

      stdout.puts "  [yml] credentials captured by declarative phase"

      Array(cred_schema["validate"]).each do |rule|
        k = rule.fetch("key")
        value = workflow_context[k.to_s]
        if rule["not_empty"] && (value.nil? || value.to_s.empty?)
          raise UserError, "captured #{k} is empty — was login completed?"
        end
        if rule["contains"] && !value.to_s.include?(rule["contains"])
          raise UserError, "captured #{k} does not contain #{rule["contains"].inspect}"
        end
      end

      result = {}
      Array(cred_schema["map"]).each do |mapping|
        from = mapping.fetch("from")
        as_key = mapping.fetch("as")
        value = workflow_context[from.to_s]

        if mapping["derive"] == "time_plus_seconds"
          value = value ? (Time.now + value.to_i) : nil
        end

        result[as_key.to_sym] = value

        next if mapping["log"] == false

        presence = value ? "✓" : "✗"
        extra = mapping["log_extra"]
        if extra && value
          formatted = extra.gsub(/\{(\w+)\}/) { |_| workflow_context[$1].to_s }
          presence = "#{presence} (#{formatted})"
        end
        stdout.puts "  #{as_key}:".ljust(32) + presence
      end

      result
    end
  end
end
