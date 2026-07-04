# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

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
  end
end
