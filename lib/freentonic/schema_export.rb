# frozen_string_literal: true

require "json"

module Freentonic
  # Assembles the machine-readable workflow dialect — action names +
  # required/optional keys + one-line summaries, universal keys, the
  # `when_context` operator set, and the extract/normalize/elevate plan-verb
  # names — into a single version-locked JSON document. This is the
  # system-prompt payload for any authoring agent: it is always in lockstep
  # with the installed gem because it reads the live registries
  # (WorkflowActions::SPECS, WhenContext::OPERATORS, WorkflowSchema's frozen
  # verb/binding arrays), never a hand-maintained copy.
  #
  # Pure assembly over stdlib `json`; no Chrome, no network, no new gem.
  module SchemaExport
    module_function

    def document
      {
        "freentonic_version" => Freentonic::VERSION,
        "workflow_schema_version" => WorkflowSchema::DIALECT_VERSION,
        "actions" => WorkflowActions::SPECS.transform_values { |spec|
          {
            "required" => Array(spec[:required]),
            "optional" => Array(spec[:optional]),
            "summary"  => spec.fetch(:summary)
          }.tap { |h| h["doc"] = spec[:doc] if spec[:doc] }
        },
        "universal_keys" => WorkflowActions::UNIVERSAL_KEYS,
        "when_context_operators" => WhenContext::OPERATORS,
        "extract_plan_verbs"   => WorkflowSchema::PLAN_STEP_VERBS,
        "normalize_plan_verbs" => WorkflowSchema::NORMALIZE_PLAN_VERBS,
        "elevate_plan_verbs"   => WorkflowSchema::ELEVATE_STEP_VERBS,
        "plan_seed_bindings"      => WorkflowSchema::PLAN_SEED_BINDINGS,
        "normalize_seed_bindings" => WorkflowSchema::NORMALIZE_SEED_BINDINGS,
        "normalize_output_keys"   => WorkflowSchema::NORMALIZE_OUTPUT_KEYS
      }
    end

    def to_json(*)
      JSON.pretty_generate(document)
    end
  end
end
