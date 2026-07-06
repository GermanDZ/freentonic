# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

module Freentonic
  # Ask 10: the runtime gate that makes provider Ruby opt-in
  # (FREENTONIC_ALLOW_PROVIDER_RUBY) and declarative-only the default.
  class RubyCapabilityTest < Minitest::Test
    def with_env(value)
      prev = ENV[RubyCapability::ENV_VAR]
      value.nil? ? ENV.delete(RubyCapability::ENV_VAR) : ENV[RubyCapability::ENV_VAR] = value
      yield
    ensure
      prev.nil? ? ENV.delete(RubyCapability::ENV_VAR) : ENV[RubyCapability::ENV_VAR] = prev
    end

    # --- module: enabled? ------------------------------------------------
    def test_disabled_by_default_and_for_falsey_values
      [nil, "", "0", "false", "no", "off", "nope"].each do |v|
        with_env(v) { refute RubyCapability.enabled?, "#{v.inspect} should be declarative-only" }
      end
    end

    def test_enabled_for_truthy_values_case_insensitively
      %w[1 true TRUE yes On].each do |v|
        with_env(v) { assert RubyCapability.enabled?, "#{v.inspect} should enable provider Ruby" }
      end
    end

    # --- module: ensure_enabled! -----------------------------------------
    def test_ensure_raises_when_disabled_with_features
      with_env(nil) do
        err = assert_raises(UserError) { RubyCapability.ensure_enabled!(["normalize: ruby:"]) }
        assert_includes err.message, "normalize: ruby:"
        assert_includes err.message, RubyCapability::ENV_VAR
      end
    end

    def test_ensure_is_noop_with_no_features_even_when_disabled
      with_env(nil) do
        RubyCapability.ensure_enabled!([])
        RubyCapability.ensure_enabled!([""])
        RubyCapability.ensure_enabled!(nil)
      end
      pass
    end

    def test_ensure_is_noop_when_enabled
      with_env("1") { RubyCapability.ensure_enabled!(["normalize: ruby:", "extract: ruby:"]) }
      pass
    end

    # --- schema predicates -----------------------------------------------
    def schema_for(block_yaml)
      Dir.mktmpdir do |d|
        path = File.join(d, "workflow.yml")
        File.write(path, "version: 1\npipeline: []\nphases: {}\n#{block_yaml}")
        return WorkflowSchema.load(path)
      end
    end

    def test_predicates_detect_ruby_vs_plan
      ruby_nm  = schema_for("normalize:\n  ruby: ./normalizer.rb\n  class: Foo::Bar")
      assert ruby_nm.normalize_uses_ruby?
      refute ruby_nm.extract_uses_ruby?
      assert ruby_nm.uses_provider_ruby?

      ruby_ex  = schema_for("extract:\n  ruby: ./extractor.rb\n  class: Foo::Ex")
      assert ruby_ex.extract_uses_ruby?
      refute ruby_ex.normalize_uses_ruby?

      plan_yaml = <<~YAML
        normalize:
          plan:
            steps:
              - select: { from: raw, path: accounts, default: [] }
                as: accounts
              - select: { from: raw, path: transactions, default: [] }
                as: transactions
            output:
              accounts: "{accounts}"
              transactions: "{transactions}"
      YAML
      plan_nm = schema_for(plan_yaml)
      refute plan_nm.normalize_uses_ruby?
      refute plan_nm.uses_provider_ruby?
    end

    # --- Engine gate (precise to planned stages) --------------------------
    FakeSchema = Struct.new(:extract_ruby, :normalize_ruby, :api_client_ruby) do
      def extract_uses_ruby?    = extract_ruby
      def normalize_uses_ruby?  = normalize_ruby
      def api_client_uses_ruby? = api_client_ruby
    end

    FakeSource = Struct.new(:schema) do
      def workflow? = true
      def workflow  = schema
    end

    def gate(source, planned)
      Engine.new(context: { source: source }).send(:ensure_ruby_capability!, planned)
    end

    def test_engine_gate_blocks_a_ruby_normalize_run_when_disabled
      source = FakeSource.new(FakeSchema.new(false, true, false))
      with_env(nil) do
        assert_raises(UserError) { gate(source, %i[connect extract normalize export]) }
      end
    end

    def test_engine_gate_allows_when_enabled
      source = FakeSource.new(FakeSchema.new(false, true, false))
      with_env("1") { gate(source, %i[normalize export]) } # no raise
      pass
    end

    def test_engine_gate_is_precise_to_planned_stages
      # normalize: ruby: but this run skips normalize (--from-normalized) →
      # no provider Ruby executes → allowed even declarative-only.
      source = FakeSource.new(FakeSchema.new(false, true, false))
      with_env(nil) { gate(source, %i[export]) }
      pass
    end

    def test_engine_gate_noop_without_a_workflow_source
      with_env(nil) { Engine.new(context: {}).send(:ensure_ruby_capability!, %i[normalize]) }
      pass
    end
  end
end
