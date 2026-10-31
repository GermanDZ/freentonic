require_relative "test_helper"
require "tmpdir"
require "open3"
require "freentonic/providers/scaffold"

module Freentonic
  module Providers
    # The scaffold is where a provider starts, so it must start green: the
    # generated workflow lints clean, carries no provider Ruby (a
    # declarative-only server refuses `ruby:` stages), and its generated
    # tests pass as written.
    class ScaffoldTest < Minitest::Test
      LIB = File.expand_path("../lib", __dir__)

      def with_scaffold(name = "my_bank")
        Dir.mktmpdir do |tmp|
          Dir.chdir(tmp) do
            scaffold = Scaffold.new(name)
            scaffold.generate!
            yield scaffold, tmp
          end
        end
      end

      def test_generates_exactly_the_listed_files
        with_scaffold do |scaffold, tmp|
          generated = Dir.glob("**/*", base: tmp).select { |f| File.file?(File.join(tmp, f)) }
          assert_equal scaffold.files.sort, generated.sort
        end
      end

      def test_generated_workflow_is_declarative
        with_scaffold do |scaffold|
          workflow = WorkflowSchema.load(File.join(scaffold.dir, "workflow.yml"))
          assert workflow.raw.dig("extract", "plan"), "extract: must be a plan"
          assert workflow.raw.dig("normalize", "plan"), "normalize: must be a plan"
          assert_empty Dir.glob("*.rb", base: scaffold.dir), "no provider Ruby outside test/"
        end
      end

      def test_generated_workflow_lints_clean
        with_scaffold do |scaffold|
          out = StringIO.new
          code = Linter.new(workflow_path: File.join(scaffold.dir, "workflow.yml"),
                            stdout: out, stderr: StringIO.new).run
          assert_equal 0, code, out.string
        end
      end

      # In a subprocess, as `rake test:<provider>` runs them — the generated
      # files are real test files, not strings this test evaluates.
      def test_generated_tests_pass
        with_scaffold("acme_bank") do |scaffold|
          scaffold.files.grep(/_test\.rb\z/).each do |file|
            output, status = Open3.capture2e(RbConfig.ruby, "-I", LIB, file)
            assert status.success?, "#{file} failed:\n#{output}"
            assert_match(/0 failures, 0 errors/, output, file)
          end
        end
      end

      def test_normalizes_the_name
        scaffold = Scaffold.new("My-Bank")
        assert_equal "my_bank", scaffold.name
        assert_equal "MyBank", scaffold.camel_name
      end
    end
  end
end
