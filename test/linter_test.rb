# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "tempfile"

module Freentonic
  class LinterTest < Minitest::Test
    EXTRACTOR_RB = <<~RUBY
      class LintTestExtractor
        def call(**); {}; end
      end
    RUBY

    NORMALIZER_RB = <<~RUBY
      class LintTestNormalizer
        def call(raw, context:); raw; end
      end
    RUBY

    # Writes a workflow YAML (plus sibling extractor/normalizer ruby) into a
    # fresh tmpdir and yields its path. Overrides let each test mutate one
    # slice of the workflow to exercise a single check.
    def with_workflow(yaml, extractor: EXTRACTOR_RB, normalizer: NORMALIZER_RB)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "extractor.rb"), extractor) if extractor
        File.write(File.join(dir, "normalizer.rb"), normalizer) if normalizer
        path = File.join(dir, "workflow.yml")
        File.write(path, yaml)
        yield path
      end
    end

    def lint(path)
      out = StringIO.new
      code = Linter.new(workflow_path: path, stdout: out, stderr: StringIO.new).run
      [code, out.string]
    end

    CLEAN = <<~YAML
      version: 1
      config:
        key: test
        default_lookback_days: 30
      secrets:
        USER_PIN: {}
      credentials:
        require: [cookie]
        map:
          - { from: cookie, as: cookie }
      phases:
        login:
          - { action: navigate, url: "https://bank.example/login" }
          - { action: fill, selector: "#pin", value: "secret(USER_PIN)" }
          - { action: capture_cookie_header, host: bank.example, path: /, as: cookie }
      pipeline: [login]
      extract:
        ruby: ./extractor.rb
        class: LintTestExtractor
      normalize:
        ruby: ./normalizer.rb
        class: LintTestNormalizer
    YAML

    def test_clean_workflow_lints_ok
      with_workflow(CLEAN) do |path|
        code, out = lint(path)
        assert_equal 0, code, out
        assert_includes out, "lints clean"
      end
    end

    def test_unknown_action_fails
      yaml = CLEAN.sub("action: navigate", "action: navigat")
      with_workflow(yaml) do |path|
        code, out = lint(path)
        assert_equal 1, code
        assert_includes out, "unknown action"
      end
    end

    def test_missing_extractor_file_fails
      yaml = CLEAN.sub("ruby: ./extractor.rb", "ruby: ./nope.rb")
      with_workflow(yaml, extractor: nil) do |path|
        code, out = lint(path)
        assert_equal 1, code
        assert_includes out, "file not found"
      end
    end

    def test_unresolvable_extractor_class_fails
      yaml = CLEAN.sub("class: LintTestExtractor", "class: NoSuchExtractor")
      with_workflow(yaml) do |path|
        code, out = lint(path)
        assert_equal 1, code
        assert_includes out, "is not defined"
      end
    end

    def test_credentials_require_not_captured_fails
      yaml = CLEAN.sub("require: [cookie]", "require: [cookie, missing_token]")
      with_workflow(yaml) do |path|
        code, out = lint(path)
        assert_equal 1, code
        assert_includes out, "missing_token"
        assert_includes out, "never captured"
      end
    end

    def test_undeclared_secret_is_a_warning_not_an_error
      # secret(USER_PIN) stays declared; add an undeclared secret reference.
      yaml = CLEAN.sub('value: "secret(USER_PIN)"', 'value: "secret(UNDECLARED)"')
      with_workflow(yaml) do |path|
        code, out = lint(path)
        assert_equal 0, code, out
        assert_includes out, "UNDECLARED"
        assert_includes out, "warning"
      end
    end

    def test_extractor_outside_workflow_subtree_is_rejected
      Dir.mktmpdir do |root|
        # extractor lives ABOVE the workflow's own directory → escape.
        File.write(File.join(root, "shared_extractor.rb"), EXTRACTOR_RB)
        subdir = File.join(root, "provider")
        FileUtils.mkdir_p(subdir)
        File.write(File.join(subdir, "normalizer.rb"), NORMALIZER_RB)
        yaml = CLEAN.sub("ruby: ./extractor.rb", "ruby: ../shared_extractor.rb")
        path = File.join(subdir, "workflow.yml")
        File.write(path, yaml)
        code, out = lint(path)
        assert_equal 1, code
        assert_includes out, "resolves outside"
      end
    end

    def test_path_confinement_resolves_sibling_and_rejects_escape
      Dir.mktmpdir do |dir|
        inside = File.join(dir, "ok.rb")
        File.write(inside, "# ok\n")
        assert_equal File.realpath(inside),
          PathConfinement.resolve_within!(inside, dir, label: "x")

        outside = Tempfile.new("pc-outside")
        outside.write("# nope\n"); outside.flush
        err = assert_raises(UserError) do
          PathConfinement.resolve_within!(outside.path, dir, label: "x")
        end
        assert_includes err.message, "resolves outside"
      ensure
        outside&.close!
      end
    end

    def test_api_client_build_failure_fails
      yaml = CLEAN + <<~YAML
        api_client:
          base_url: https://api.bank.example
          endpoints:
            - name: txns
              path: /txns
              method: POST
              form: { a: 1 }
              json: { b: 2 }
      YAML
      with_workflow(yaml) do |path|
        code, out = lint(path)
        assert_equal 1, code
        assert_includes out, "form"
      end
    end

    # ── extract: plan: (declarative form) ───────────────────────────────

    # Same as CLEAN but the extract: block is a plan over a declared
    # endpoint — no sibling extractor.rb needed.
    PLAN_WORKFLOW = <<~YAML
      version: 1
      config: { key: test, default_lookback_days: 30 }
      secrets: { USER_PIN: {} }
      credentials:
        require: [cookie]
        map:
          - { from: cookie, as: cookie }
      phases:
        login:
          - { action: navigate, url: "https://bank.example/login" }
          - { action: fill, selector: "#pin", value: "secret(USER_PIN)" }
          - { action: capture_cookie_header, host: bank.example, path: /, as: cookie }
      pipeline: [login]
      api_client:
        base_url: https://api.bank.example
        endpoints:
          - name: fetch_accounts
            method: GET
            path: /accounts
      extract:
        plan:
          steps:
            - fetch: fetch_accounts
              as: accounts
          output:
            accounts: "{accounts}"
      normalize:
        ruby: ./normalizer.rb
        class: LintTestNormalizer
    YAML

    def test_plan_workflow_lints_clean_without_extractor_ruby
      with_workflow(PLAN_WORKFLOW, extractor: nil) do |path|
        code, out = lint(path)
        assert_equal 0, code, out
        assert_includes out, "lints clean"
      end
    end

    def test_plan_fetch_unknown_endpoint_fails_lint
      yaml = PLAN_WORKFLOW.sub("fetch: fetch_accounts", "fetch: fetch_missing")
      with_workflow(yaml, extractor: nil) do |path|
        code, out = lint(path)
        assert_equal 1, code
        assert_includes out, "fetch_missing"
        assert_includes out, "not a declared api_client endpoint"
      end
    end

    # ── normalize: plan: (declarative form) ─────────────────────────────

    # Both stages declarative: a plan extractor and a plan normalizer, no
    # sibling ruby at all.
    NORMALIZE_PLAN_WORKFLOW = PLAN_WORKFLOW.sub(<<~RUBY, <<~PLAN)
      normalize:
        ruby: ./normalizer.rb
        class: LintTestNormalizer
    RUBY
      normalize:
        plan:
          steps:
            - select: { from: raw, path: accounts, default: [] }
              as: accounts
            - let: transactions
              value: []
          output:
            accounts: "{accounts}"
            transactions: "{transactions}"
    PLAN

    def test_normalize_plan_lints_clean_without_normalizer_ruby
      with_workflow(NORMALIZE_PLAN_WORKFLOW, extractor: nil, normalizer: nil) do |path|
        code, out = lint(path)
        assert_equal 0, code, out
        assert_includes out, "lints clean"
      end
    end

    def test_normalize_plan_unbound_ref_fails_lint
      yaml = NORMALIZE_PLAN_WORKFLOW.sub("value: []", 'value: "{nope}"')
      with_workflow(yaml, extractor: nil, normalizer: nil) do |path|
        code, out = lint(path)
        assert_equal 1, code
        assert_includes out, "unbound name"
      end
    end

    # ── config.yml timezone knobs ───────────────────────────────────────

    # Writes a workflow + a config.yml with the given timezone lines, lints,
    # and returns [code, output]. Config caches by dir basename; mktmpdir
    # names are unique, so each call gets a fresh config.
    def lint_with_config(tz_yaml)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "config.yml"), "institution: tztest\n#{tz_yaml}")
        path = File.join(dir, "workflow.yml")
        File.write(path, NORMALIZE_PLAN_WORKFLOW)
        Providers::Config.__reset_for_tests!
        lint(path)
      end
    end

    def test_utc_and_fixed_offset_timezones_lint_clean
      code, out = lint_with_config("output_timezone: \"+01:00\"\ninput_timezone: UTC\n")
      assert_equal 0, code, out
    end

    def test_valid_named_zone_lints_clean_when_tzinfo_available
      skip "tzinfo not installed" unless tzinfo_available?
      code, out = lint_with_config("output_timezone: Europe/Madrid\n")
      assert_equal 0, code, out
    end

    def test_unknown_named_zone_fails_lint
      skip "tzinfo not installed" unless tzinfo_available?
      code, out = lint_with_config("output_timezone: Europe/Madird\n")
      assert_equal 1, code
      assert_includes out, "config.output_timezone"
      assert_includes out, "unknown timezone"
    end

    def tzinfo_available?
      require "tzinfo"
      true
    rescue LoadError
      false
    end
  end
end
