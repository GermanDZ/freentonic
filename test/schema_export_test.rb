# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "json"
require "tmpdir"

module Freentonic
  # Covers the `--schema-json` dialect export: the SchemaExport document, its
  # drift guards against the live registries, and the CLI short-circuit. All
  # stdlib-only — no Chrome, no network (invariant 10).
  class SchemaExportTest < Minitest::Test
    def document
      SchemaExport.document
    end

    def test_schema_json_lists_every_registered_action
      assert_equal WorkflowActions.names.sort,
                   document["actions"].keys.sort,
                   "exported actions must match the registry exactly (no omissions, no inventions)"
    end

    def test_schema_json_required_keys_match_registry
      document["actions"].each do |name, spec|
        assert_equal WorkflowActions.required_keys(name), spec["required"],
                     "required keys drifted for #{name}"
        assert_equal WorkflowActions.optional_keys(name), spec["optional"],
                     "optional keys drifted for #{name}"
      end
    end

    def test_every_action_has_a_summary
      WorkflowActions::SPECS.each do |name, spec|
        summary = spec[:summary]
        assert_kind_of String, summary, "#{name} is missing a :summary"
        refute summary.strip.empty?, "#{name} has an empty :summary"
      end
      # And the exported document carries it through for every action.
      document["actions"].each do |name, spec|
        refute spec["summary"].to_s.strip.empty?, "#{name} exported an empty summary"
      end
    end

    def test_doc_emitted_only_when_present
      # note has a dedicated doc; simulate_human does not.
      assert_equal "workflow-action-note.md", document["actions"]["note"]["doc"]
      refute document["actions"]["simulate_human"].key?("doc"),
             "actions without a doc file must not emit a doc key"
    end

    def test_schema_json_includes_plan_verbs_and_operators
      %w[extract_plan_verbs normalize_plan_verbs when_context_operators].each do |key|
        assert_kind_of Array, document[key], "#{key} must be an array"
        refute_empty document[key], "#{key} must be non-empty"
      end
      assert_includes document["extract_plan_verbs"], "fetch"
      refute_includes document["normalize_plan_verbs"], "fetch",
                      "normalize plans have no api_client, so fetch must be excluded"
    end

    def test_when_context_operators_match_dispatch
      runner_src = File.read(
        File.expand_path("../lib/freentonic/browser_workflow_runner.rb", __dir__)
      )
      compare = runner_src[/def compare_context.*?\n      end\n/m]
      refute_nil compare, "could not locate compare_context in the runner"
      dispatched = compare.scan(/when "([a-z]+)"/).flatten

      assert_equal WhenContext::OPERATORS.sort, dispatched.sort,
                   "compare_context case arms must match WhenContext::OPERATORS"

      # The plan gate must stay in lockstep too.
      gate_src = File.read(
        File.expand_path("../lib/freentonic/extract_plan/when_gate.rb", __dir__)
      )
      gate_arms = gate_src[/def compare.*?\n      end\n/m].scan(/when "([a-z]+)"/).flatten
      assert_equal WhenContext::OPERATORS.sort, gate_arms.sort,
                   "WhenGate#compare case arms must match WhenContext::OPERATORS"
    end

    def test_schema_json_is_valid_json_and_exits_zero
      stdout = StringIO.new
      stderr = StringIO.new
      status = Cli.new(stdout: stdout, stderr: stderr).run(["--schema-json"])

      assert_equal 0, status, stderr.string
      assert_equal "", stderr.string
      parsed = JSON.parse(stdout.string)
      assert_equal WorkflowActions.names.sort, parsed["actions"].keys.sort
      assert_equal Freentonic::VERSION, parsed["freentonic_version"]
    end

    def test_schema_json_needs_no_workflow
      # It short-circuits before validate!, so it must not error on a missing
      # --workflow (unlike --lint).
      stdout = StringIO.new
      stderr = StringIO.new
      status = Cli.new(stdout: stdout, stderr: stderr).run(["--schema-json"])
      assert_equal 0, status, stderr.string
    end

    def test_dialect_version_constant_matches_validate
      assert_equal 1, WorkflowSchema::DIALECT_VERSION
      assert_equal WorkflowSchema::DIALECT_VERSION,
                   document["workflow_schema_version"]

      # A workflow declaring a different dialect version still raises.
      Dir.mktmpdir("freentonic-schema") do |dir|
        path = File.join(dir, "workflow.yml")
        File.write(path, <<~YAML)
          version: 2
          config:
            key: fixture
          pipeline: []
          phases: {}
          secrets: {}
          credentials:
            map: []
        YAML
        err = assert_raises(UserError) { WorkflowSchema.load(path) }
        assert_includes err.message, "version: 1"
      end
    end
  end
end
