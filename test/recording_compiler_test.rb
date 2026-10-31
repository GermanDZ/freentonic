# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "tempfile"
require "yaml"

module Freentonic
  # Covers `--compile-recording`: the recording.jsonl -> draft connect:
  # pipeline transform, its mapping table, the lint-clean guarantee, and the
  # CLI wiring + git-worktree write refusal. All stdlib-only — no Chrome, no
  # network (invariant 10).
  class RecordingCompilerTest < Minitest::Test
    FIXTURE = File.expand_path("fixtures/recording.jsonl", __dir__)

    def compile(recording_path: FIXTURE, stderr: StringIO.new)
      RecordingCompiler.new(
        recording_path: recording_path,
        stdout: StringIO.new,
        stderr: stderr
      ).compile
    end

    # Parse the emitted YAML back into steps for the `login` phase. Comments
    # are validated separately against the raw text — YAML drops them.
    def login_steps(yaml)
      YAML.safe_load(yaml).fetch("phases").fetch("login")
    end

    # Write a recording.jsonl into `dir` from an array of event hashes.
    def write_recording(dir, events)
      path = File.join(dir, "recording.jsonl")
      File.write(path, events.map { |e| JSON.generate(e) }.join("\n") + "\n")
      path
    end

    def test_compile_maps_each_event_kind
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "navigate", "url" => "https://bank.example/dashboard" },
          { "kind" => "click", "selector" => "#go", "selector_strategy" => "id", "needs_review" => false },
          { "kind" => "submit", "selector" => "form#f", "selector_strategy" => "id", "needs_review" => false },
          { "kind" => "fill", "selector" => "input[name='user']", "selector_strategy" => "name",
            "needs_review" => false, "input_type" => "text", "value" => "alice" },
          { "kind" => "fill", "selector" => "input[type='password']", "selector_strategy" => "name",
            "needs_review" => false, "input_type" => "password", "mask" => true }
        ])
        steps = login_steps(compile(recording_path: path))

        assert_equal(
          %w[navigate wait_url wait_for_selector click wait_for_selector click fill fill],
          steps.map { |s| s["action"] }
        )
        assert_equal "https://bank.example/login", steps[0]["url"]
        assert_equal "/dashboard", steps[1]["includes"]
        assert_equal "#go", steps[2]["selector"]
        assert_equal "#go", steps[3]["selector"]
        assert_equal "form#f", steps[4]["selector"]
        assert_equal "alice", steps[6]["value"]
        assert_equal "secret(PASSWORD)", steps[7]["value"]
      end
    end

    def test_masked_fill_becomes_secret_and_declares_it
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "fill", "selector" => "input[type='password']", "selector_strategy" => "name",
            "needs_review" => false, "input_type" => "password", "mask" => true }
        ])
        yaml = compile(recording_path: path)
        doc = YAML.safe_load(yaml)

        fill = doc["phases"]["login"].find { |s| s["action"] == "fill" }
        assert_equal "secret(PASSWORD)", fill["value"]
        # secret(NAME) is anchored — the whole value must match.
        assert SecretResolver::SECRET_PATTERN.match?(fill["value"])
        # ... and it is declared under secrets: with a matching entry.
        assert doc["secrets"].key?("PASSWORD"), "masked fill must declare its secret"
        assert doc["secrets"]["PASSWORD"].key?("prompt")
      end
    end

    def test_masked_fill_collision_gets_stable_suffix
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "fill", "selector" => "input#p1", "input_type" => "password", "mask" => true },
          { "kind" => "fill", "selector" => "input#p2", "input_type" => "password", "mask" => true }
        ])
        doc = YAML.safe_load(compile(recording_path: path))
        names = doc["phases"]["login"].map { |s| s["value"] }
        assert_equal ["secret(PASSWORD)", "secret(PASSWORD_2)"], names
        assert_equal %w[PASSWORD PASSWORD_2], doc["secrets"].keys
      end
    end

    def test_no_secrets_block_without_masked_fill
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "fill", "selector" => "input[name='user']", "input_type" => "text", "value" => "alice" }
        ])
        doc = YAML.safe_load(compile(recording_path: path))
        refute doc.key?("secrets"), "no masked fill means no secrets: block"
      end
    end

    def test_output_is_lint_clean
      require "freentonic/linter"
      yaml = compile
      Tempfile.create(["compiled", ".yml"]) do |f|
        f.write(yaml)
        f.flush
        code = Linter.new(
          workflow_path: f.path,
          stdout: StringIO.new,
          stderr: StringIO.new
        ).run
        assert_equal 0, code, "compiled draft must lint clean (exit 0)"
      end
    end

    def test_needs_review_selectors_are_flagged
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "click", "selector" => "div > a:nth-of-type(3)",
            "selector_strategy" => "nth-child", "needs_review" => true },
          { "kind" => "submit", "selector" => "", "selector_strategy" => "none", "needs_review" => true }
        ])
        yaml = compile(recording_path: path)
        assert_includes yaml, "# REVIEW: nth-child selector, may be fragile"
        assert_includes yaml, "# REVIEW: no selector captured"
      end
    end

    # A machine-generated id (strategy id-volatile) the recorder fell back to
    # gets its own REVIEW line, distinct from the nth-child one, telling the
    # author to swap in a stable attribute.
    def test_id_volatile_selector_flagged_distinctly
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "click", "selector" => "#widget-a1b2c3d4e5",
            "selector_strategy" => "id-volatile", "needs_review" => true }
        ])
        yaml = compile(recording_path: path)
        assert_includes yaml, "# REVIEW: auto-generated id"
        refute_includes yaml, "# REVIEW: nth-child selector, may be fragile"
      end
    end

    # Shadow-sourced events (probe sets "shadow": true when the element
    # lives inside an open shadow root) compile to the SAME steps as light-
    # DOM events — the runner's deepQuery pierces shadow roots at replay,
    # so no special action is needed. The only difference is an
    # informational NOTE comment so a reviewer isn't confused when the
    # selector doesn't match in a browser console.
    def test_shadow_events_compile_to_ordinary_steps_with_note
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "click", "selector" => "button[name='submit']",
            "selector_strategy" => "name", "needs_review" => false, "shadow" => true },
          { "kind" => "fill", "selector" => "input[name='secret']",
            "selector_strategy" => "name", "needs_review" => false,
            "input_type" => "password", "mask" => true, "shadow" => true }
        ])
        yaml = compile(recording_path: path)
        steps = login_steps(yaml)

        # Same step shapes as a light-DOM recording.
        assert_equal %w[wait_for_selector click fill], steps.map { |s| s["action"] }
        assert_equal "button[name='submit']", steps[0]["selector"]
        # Masking still routes through secret(...) for shadow fills.
        assert_match(/\Asecret\(.+\)\z/, steps[2]["value"])
        # The NOTE rides above the wait step and the fill.
        assert_includes yaml, "# NOTE: element is inside shadow DOM"
        assert_equal 2, yaml.scan("# NOTE: element is inside shadow DOM").size
      end
    end

    # A run of single-digit-key clicks (a numeric keypad) is DROPPED — the
    # digits never reach the draft — and a scaffold for the keypad action is
    # left in their place. This is both a security fix (no leaked PIN) and
    # guidance (the per-key clicks would never replay against a scrambled pad).
    def test_keypad_digit_clicks_are_dropped_and_scaffolded
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "click", "selector" => "span.k7", "text" => "7", "needs_review" => false },
          { "kind" => "click", "selector" => "span.k4", "text" => "4", "needs_review" => false },
          { "kind" => "click", "selector" => "span.k9", "text" => "9", "needs_review" => false },
          { "kind" => "click", "selector" => "span.k1", "text" => "1", "needs_review" => false }
        ])
        yaml = compile(recording_path: path)

        # No digit-bearing selector survives — the keys are gone.
        %w[k7 k4 k9 k1].each { |k| refute_includes yaml, k, "keypad key #{k} leaked into the draft" }
        # The scaffold names the count but not the digits, and points at the action.
        assert_includes yaml, "4 single-digit key presses"
        assert_includes yaml, "action: enter_pin_pad"
        assert_includes yaml, "secret(USER_PIN)"
        # Only the navigate is a real step; the keypad scaffold is comment-only.
        assert_equal %w[navigate], login_steps(yaml).map { |s| s["action"] }
      end
    end

    def test_short_digit_run_is_not_treated_as_keypad
      Dir.mktmpdir do |dir|
        # Two digit clicks is below the keypad threshold — kept as clicks.
        path = write_recording(dir, [
          { "kind" => "click", "selector" => "#a", "text" => "1", "needs_review" => false },
          { "kind" => "click", "selector" => "#b", "text" => "2", "needs_review" => false }
        ])
        actions = login_steps(compile(recording_path: path)).map { |s| s["action"] }
        assert_equal %w[wait_for_selector click wait_for_selector click], actions
      end
    end

    # The probe records a digit key as a bare flagged click (no text or
    # selector), so even a short run of them can't be replayed as clicks —
    # it's always a keypad scaffold.
    def test_flagged_keypad_clicks_always_collapse
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "click", "keypad_digit" => true },
          { "kind" => "click", "keypad_digit" => true }
        ])
        yaml = compile(recording_path: path)

        assert_includes yaml, "2 single-digit key presses"
        assert_equal %w[navigate], login_steps(yaml).map { |s| s["action"] }
      end
    end

    # recording.jsonl is appended to, so a re-recorded login leaves the
    # failed attempt in the file too; only the last session is compiled.
    def test_only_the_last_recording_session_is_compiled
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "recorder_started", "t" => 1 },
          { "kind" => "navigate", "url" => "https://bank.example/old-attempt" },
          { "kind" => "recorder_started", "t" => 2 },
          { "kind" => "navigate", "url" => "https://bank.example/login" }
        ])
        stderr = StringIO.new
        yaml = compile(recording_path: path, stderr: stderr)

        refute_includes yaml, "old-attempt"
        assert_includes yaml, "https://bank.example/login"
        assert_includes stderr.string, "2 recording sessions"
      end
    end

    # A click on a text-entry input with no fill for it (a managed/custom
    # input whose value the recorder couldn't see) scaffolds a fill so the
    # secret isn't silently missing.
    def test_clicked_unfilled_text_input_is_scaffolded
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "click", "selector" => "input[name='userid']",
            "input_type" => "text", "needs_review" => false }
        ])
        yaml = compile(recording_path: path)
        assert_includes yaml, "clicked but no typed value was captured"
        assert_includes yaml, "secret(REPLACE_ME)"
        # The scaffold is a comment; the only real steps are the click pair.
        assert_equal %w[wait_for_selector click], login_steps(yaml).map { |s| s["action"] }
      end
    end

    def test_clicked_text_input_with_fill_is_not_scaffolded
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "click", "selector" => "input[name='userid']",
            "input_type" => "text", "needs_review" => false },
          { "kind" => "fill", "selector" => "input[name='userid']",
            "input_type" => "text", "value" => "abc", "needs_review" => false }
        ])
        yaml = compile(recording_path: path)
        refute_includes yaml, "no typed value was captured"
      end
    end

    def test_clicked_checkbox_is_not_scaffolded_as_fill
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "click", "selector" => "#remember",
            "input_type" => "checkbox", "needs_review" => false }
        ])
        refute_includes compile(recording_path: path), "no typed value was captured"
      end
    end

    def test_unmasked_fill_is_flagged_and_kept_literal
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "fill", "selector" => "input[name='user']", "input_type" => "text", "value" => "alice" }
        ])
        stderr = StringIO.new
        yaml = compile(recording_path: path, stderr: stderr)
        assert_includes yaml, "# REVIEW: literal from recording"
        fill = YAML.safe_load(yaml)["phases"]["login"].first
        assert_equal "alice", fill["value"]
        # A literal value can be a username/PII — one stderr warning fires.
        assert_includes stderr.string, "literal value(s)"
      end
    end

    def test_bookkeeping_events_dropped
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "recorder_started", "t" => 1 },
          { "kind" => "probe_ready", "url" => "https://bank.example/login" },
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "recorder_error", "error" => "boom" },
          { "kind" => "recorder_stopped", "t" => 2 }
        ])
        steps = login_steps(compile(recording_path: path))
        assert_equal %w[navigate], steps.map { |s| s["action"] },
                     "only the navigate maps to a step; bookkeeping events drop"
      end
    end

    def test_subsequent_navigate_becomes_wait_url
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "navigate", "url" => "https://bank.example/accounts/summary" }
        ])
        steps = login_steps(compile(recording_path: path))
        assert_equal "navigate", steps[0]["action"]
        assert_equal "https://bank.example/login", steps[0]["url"]
        assert_equal "wait_url", steps[1]["action"]
        assert_equal "/accounts/summary", steps[1]["includes"]
      end
    end

    def test_consecutive_duplicate_navigates_coalesced
      Dir.mktmpdir do |dir|
        path = write_recording(dir, [
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "navigate", "url" => "https://bank.example/login" },
          { "kind" => "navigate", "url" => "https://bank.example/login" }
        ])
        steps = login_steps(compile(recording_path: path))
        assert_equal %w[navigate], steps.map { |s| s["action"] }
      end
    end

    def test_malformed_last_line_is_tolerated
      Dir.mktmpdir do |dir|
        path = File.join(dir, "recording.jsonl")
        File.write(path, <<~JSONL)
          {"kind":"navigate","url":"https://bank.example/login"}
          {"kind":"fill","selector":"input#u","input_type":"text","value":"x"}
          {"kind":"click","selector":"#go
        JSONL
        stderr = StringIO.new
        steps = login_steps(compile(recording_path: path, stderr: stderr))
        # The valid lines still compile; the truncated last line is skipped.
        assert_equal %w[navigate fill], steps.map { |s| s["action"] }
        assert_includes stderr.string, "malformed JSON"
      end
    end

    def test_blank_lines_ignored
      Dir.mktmpdir do |dir|
        path = File.join(dir, "recording.jsonl")
        File.write(path, "\n{\"kind\":\"navigate\",\"url\":\"https://bank.example/login\"}\n\n")
        steps = login_steps(compile(recording_path: path))
        assert_equal %w[navigate], steps.map { |s| s["action"] }
      end
    end

    def test_only_registry_actions_emitted
      # Drift guard: every action the compiler can ever emit must be a known
      # WorkflowActions name (and one of the five the plan allows).
      allowed = %w[navigate wait_url wait_for_selector click fill]
      steps = login_steps(compile)
      steps.each do |step|
        action = step["action"]
        assert WorkflowActions.known?(action), "#{action} is not a registered action"
        assert_includes allowed, action, "#{action} is outside the compiler's five-action allowlist"
        # Every required key for the action is present.
        WorkflowActions.required_keys(action).each do |key|
          assert step.key?(key), "#{action} missing required key #{key}"
        end
      end
    end

    def test_graft_mode_is_refused
      err = assert_raises(UserError) do
        RecordingCompiler.new(
          recording_path: FIXTURE,
          workflow_path: "/some/existing.yml",
          stdout: StringIO.new,
          stderr: StringIO.new
        ).compile
      end
      assert_includes err.message, "graft"
    end

    # ---- CLI wiring -----------------------------------------------------

    def test_cli_compile_recording_writes_yaml_to_stdout
      stdout = StringIO.new
      stderr = StringIO.new
      code = Cli.new(stdout: stdout, stderr: stderr).run(["--compile-recording", FIXTURE])
      assert_equal 0, code, stderr.string
      doc = YAML.safe_load(stdout.string)
      assert_equal 1, doc["version"]
      assert doc["phases"].key?("login")
    end

    def test_cli_needs_no_workflow
      # Short-circuits before validate!, so a missing --workflow is fine.
      stdout = StringIO.new
      stderr = StringIO.new
      code = Cli.new(stdout: stdout, stderr: stderr).run(["--compile-recording", FIXTURE])
      assert_equal 0, code, stderr.string
    end

    def test_cli_missing_recording_is_a_clean_user_error
      # A typo'd path must exit 1 with a friendly message, not crash with an
      # uncaught Errno::ENOENT backtrace.
      stdout = StringIO.new
      stderr = StringIO.new
      missing = File.join(Dir.tmpdir, "no_such_recording_#{Process.pid}.jsonl")
      refute File.exist?(missing)
      code = Cli.new(stdout: stdout, stderr: stderr).run(["--compile-recording", missing])
      assert_equal 1, code
      assert_includes stderr.string, "no such file"
    end

    def test_out_path_inside_git_repo_is_refused
      # We run inside the freentonic git work tree, so an --out under it is
      # refused (the draft can carry a username literal).
      stdout = StringIO.new
      stderr = StringIO.new
      target = File.join(Dir.pwd, "compiled_draft_should_not_write.yml")
      code = Cli.new(stdout: stdout, stderr: stderr).run(
        ["--compile-recording", FIXTURE, "--out", target]
      )
      assert_equal 1, code
      assert_includes stderr.string, "git work tree"
      refute File.exist?(target), "must not write inside the repo"
    end

    def test_out_path_outside_repo_is_written
      Dir.mktmpdir do |dir|
        target = File.join(dir, "draft.yml")
        stdout = StringIO.new
        stderr = StringIO.new
        code = Cli.new(stdout: stdout, stderr: stderr).run(
          ["--compile-recording", FIXTURE, "--out", target]
        )
        # mktmpdir lives under /tmp or /var — outside any git work tree —
        # unless the runner's TMPDIR is itself inside a repo. Guard for that.
        skip "TMPDIR is inside a git work tree" if code != 0 && stderr.string.include?("git work tree")
        assert_equal 0, code, stderr.string
        assert File.exist?(target)
        assert_equal 1, YAML.safe_load(File.read(target))["version"]
        assert_equal 0o600, File.stat(target).mode & 0o777
      end
    end
  end
end
