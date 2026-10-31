# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "shellwords"
require "open3"

module Freentonic
  # The `author` subcommand of docker-run-freentonic.sh refuses a workspace
  # dir that lives inside a git work tree, so a recording.jsonl full of live
  # session data can't be `git add`ed by reflex. That guard is shell (`git
  # rev-parse --is-inside-work-tree`); exercise the shipped code by sourcing
  # the wrapper and calling the factored-out function directly — the wrapper's
  # dispatch is behind a `BASH_SOURCE == $0` guard, so sourcing has no side
  # effects. No Docker, no Chrome, no network (AGENTS.md invariant 10) — just
  # bash + local git.
  class DockerAuthorGuardTest < Minitest::Test
    WRAPPER = File.expand_path("../docker-run-freentonic.sh", __dir__)

    def run_guard(dir)
      script = "source #{WRAPPER.shellescape}; refuse_if_in_git_worktree #{dir.shellescape}"
      Open3.capture3("bash", "-c", script)
    end

    def git_init(dir)
      _out, _err, status = Open3.capture3("git", "-C", dir, "init", "--quiet")
      skip "git unavailable" unless status.success?
    end

    def test_author_dir_inside_git_worktree_is_refused
      Dir.mktmpdir do |repo|
        git_init(repo)
        sub = File.join(repo, "providers", "acme")
        FileUtils.mkdir_p(sub)

        _out, err, status = run_guard(sub)

        refute status.success?, "expected a non-zero exit for a dir inside a git work tree"
        assert_equal 2, status.exitstatus
        assert_match(/inside a git work tree/, err)
      end
    end

    def test_author_dir_outside_git_worktree_is_allowed
      Dir.mktmpdir do |plain|
        # A bare temp dir is not under version control; the guard must pass it.
        _out, _err, status = run_guard(plain)

        assert status.success?, "expected a dir outside any git repo to pass the guard"
      end
    end

    def test_sourcing_wrapper_has_no_dispatch_side_effects
      # Sourcing must not fall into the subcommand `case` (it would print usage
      # and exit 1). The BASH_SOURCE guard keeps sourcing inert.
      out, _err, status = Open3.capture3("bash", "-c", "source #{WRAPPER.shellescape}; echo READY")

      assert status.success?
      assert_match(/READY/, out)
      refute_match(/Subcommands:/, out)
    end
  end
end
