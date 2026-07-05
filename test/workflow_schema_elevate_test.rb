# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

module Freentonic
  class WorkflowSchemaElevateTest < Minitest::Test
    # Load a workflow with the given elevate: block against a fixed
    # api_client declaring the three SCA endpoints. Returns the UserError
    # message, or nil when it validates clean.
    def load_error(elevate_yaml)
      yaml = <<~YAML
        version: 1
        pipeline: []
        phases: {}
        api_client:
          base_url: https://api.example
          endpoints:
            - name: sca_challenge
              method: GET
              path: /sca
              headers: { x-ing-reset-validations: "1" }
            - name: sca_commit
              method: PUT
              path: /sca
              json: { processId: "{process_id}" }
            - name: refresh_access_token
              method: GET
              path: /token
        #{elevate_yaml}
      YAML
      Dir.mktmpdir do |d|
        path = File.join(d, "workflow.yml")
        File.write(path, yaml)
        begin
          WorkflowSchema.load(path)
          nil
        rescue UserError => e
          e.message
        end
      end
    end

    def test_valid_elevate_block_loads_clean
      assert_nil load_error(<<~YAML)
        elevate:
          when: { lookback_days: { gt: 90 } }
          on_failure: degrade
          steps:
            - fetch: sca_challenge
              as: challenge
            - await_operator_approval:
                message: "approve {challenge.acceptanceMethods.0.code} on your phone"
                timeout: 180
            - fetch: sca_commit
              args: { process_id: "{challenge.acceptanceMethods.0.securityProcessId}" }
            - fetch: refresh_access_token
              as: refreshed
            - rebind_credential:
                header: Authorization
                host: api.ing.ingdirect.es
                value: "Bearer {refreshed.accessTokens.0.accessToken}"
      YAML
    end

    def test_elevate_must_be_a_hash
      assert_includes load_error("elevate: [1, 2]"), "must be a hash"
    end

    def test_on_failure_must_be_degrade_or_abort
      err = load_error(<<~YAML)
        elevate:
          on_failure: retry
          steps:
            - fetch: sca_challenge
              as: c
      YAML
      assert_includes err, "on_failure"
      assert_includes err, "degrade"
    end

    def test_steps_must_be_non_empty
      assert_includes load_error("elevate: { steps: [] }"), "non-empty array"
    end

    def test_unknown_step_verb_is_rejected
      err = load_error(<<~YAML)
        elevate:
          steps:
            - frobnicate: yes
      YAML
      assert_includes err, "unknown step"
    end

    def test_await_requires_message
      err = load_error(<<~YAML)
        elevate:
          steps:
            - await_operator_approval: { timeout: 30 }
      YAML
      assert_includes err, "message"
    end

    def test_await_timeout_must_be_positive_integer
      err = load_error(<<~YAML)
        elevate:
          steps:
            - await_operator_approval: { message: "hi", timeout: -5 }
      YAML
      assert_includes err, "timeout"
    end

    def test_rebind_requires_header
      err = load_error(<<~YAML)
        elevate:
          steps:
            - fetch: refresh_access_token
              as: refreshed
            - rebind_credential: { value: "{refreshed.t}" }
      YAML
      assert_includes err, "header"
    end

    def test_rebind_requires_value
      err = load_error(<<~YAML)
        elevate:
          steps:
            - rebind_credential: { header: Authorization }
      YAML
      assert_includes err, "value"
    end

    def test_embedded_ref_to_unbound_name_is_rejected
      err = load_error(<<~YAML)
        elevate:
          steps:
            - rebind_credential:
                header: Authorization
                value: "Bearer {refreshed.accessTokens.0.accessToken}"
      YAML
      assert_includes err, "unbound name"
      assert_includes err, "refreshed"
    end

    def test_fetch_to_undeclared_endpoint_is_rejected
      err = load_error(<<~YAML)
        elevate:
          steps:
            - fetch: not_a_real_endpoint
              as: x
      YAML
      assert_includes err, "not a declared api_client endpoint"
    end

    def test_block_when_referencing_unbound_name_is_rejected
      err = load_error(<<~YAML)
        elevate:
          when: { made_up_binding: { gt: 1 } }
          steps:
            - fetch: sca_challenge
              as: c
      YAML
      assert_includes err, "made_up_binding"
    end

    def test_seed_bindings_are_available_to_when_and_messages
      # lookback_days (seed) in a gate + from_date (seed) embedded in a
      # message both validate without an explicit binding step.
      assert_nil load_error(<<~YAML)
        elevate:
          when: { lookback_days: { gte: 1 } }
          steps:
            - await_operator_approval:
                message: "since {from_date}, approve please"
      YAML
    end

    def test_multiple_verbs_in_one_step_rejected
      err = load_error(<<~YAML)
        elevate:
          steps:
            - fetch: sca_challenge
              rebind_credential: { header: X, value: "y" }
      YAML
      assert_includes err, "exactly one verb"
    end
  end
end
