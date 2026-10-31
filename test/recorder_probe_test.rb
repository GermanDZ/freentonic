# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "json"
require "open3"
require "fileutils"

module Freentonic
  # Coverage for the recording probe's assembled source — the JS injected
  # via Page.addScriptToEvaluateOnNewDocument. Tests are string-level (the
  # same style page_observer_test uses for its injected expression): no
  # Chrome executes here (invariant 10), so what we pin is the assembly
  # contract and the presence of the shadow-DOM machinery — events from
  # inside an open shadow root are retargeted to the host, and only
  # composedPath() recovers the real target.
  class RecorderProbeTest < Minitest::Test
    class CapturingSession
      attr_reader :commands

      def initialize
        @commands = []
      end

      def send_command(method, params = {})
        @commands << { method: method, params: params }
        true
      end
    end

    # The assembled probe source as install() ships it — proves injection and
    # returns the exact bytes for content assertions.
    def probe_source(record_dom: false)
      Dir.mktmpdir do |dir|
        recorder = Recorder.new(
          path: File.join(dir, "recording.jsonl"),
          stdout: StringIO.new,
          record_dom: record_dom
        )
        session = CapturingSession.new
        recorder.install(session)
        inject = session.commands.find { |c| c[:method] == "Page.addScriptToEvaluateOnNewDocument" }
        refute_nil inject, "install must inject the probe script"
        return inject[:params][:source]
      end
    end

    def test_probe_embeds_shared_selector_heuristics
      src = probe_source
      # The marker must be replaced by the shared source, so the probe and
      # the page observer derive selectors from identical code.
      refute_includes src, "__FREENTONIC_SHARED_SELECTORS__"
      assert_includes src, "function selectorFor"
      assert_includes src, "function describeInputValue"
      assert_includes src, "function elementSummary"
    end

    def test_probe_recovers_deep_targets_through_open_shadow_roots
      src = probe_source
      # Without composedPath, an in-shadow click records as a click on the
      # web-component host and in-shadow fills are dropped entirely (the
      # retargeted ev.target is not an <input>).
      assert_includes src, "composedPath"
      assert_includes src, "function deepTarget"
    end

    def test_probe_click_walks_composed_path_for_interactive_ancestor
      src = probe_source
      # The interactive-ancestor search walks the composed path, so it can
      # cross shadow boundaries (a parentElement walk stops at the root).
      assert_includes src, "function isInteractiveNode"
    end

    def test_shared_selectors_scope_uniqueness_to_the_root_node
      src = probe_source
      # Uniqueness checks must run against el.getRootNode() (the ShadowRoot
      # for in-shadow elements) — ownerDocument can't see into shadow roots,
      # so every in-shadow element used to fall through to nth-child.
      assert_includes src, "getRootNode"
      assert_includes src, "function selectorRoot"
    end

    def test_shared_selectors_have_placeholder_strategy
      src = probe_source
      # Some inputs have no id/name but a stable placeholder — that must be a
      # selector strategy of its own.
      assert_includes src, 'strategy: "placeholder"'
    end

    def test_shared_selectors_demote_generated_ids
      src = probe_source
      # The id-randomness detector must be present and wired: a generated id
      # is skipped at strategy-1 and returns flagged as "id-volatile", so
      # stable name/placeholder/aria win. (Logic itself is verified out of
      # band with node — a JS engine isn't available in the Ruby suite.)
      assert_includes src, "function looksGeneratedId"
      assert_includes src, "function looksRandomToken"
      assert_includes src, '!looksGeneratedId(id)'
      assert_includes src, 'strategy: "id-volatile"'
    end

    def test_shared_selectors_flag_shadow_elements
      src = probe_source
      assert_includes src, "summary.shadow = true"
    end

    def test_fill_capture_uses_composed_events
      src = probe_source
      # `change` is composed:false — inside a shadow root it never reaches a
      # document-level listener AT ALL, so an in-shadow fill is silently
      # dropped. Fills must therefore ride composed events: `input` marks the
      # field dirty, `focusout`/Enter emits the final value; `change` stays
      # for light-DOM commits, deduped by the dirty flag.
      assert_includes src, '"input"'
      assert_includes src, '"focusout"'
      assert_includes src, '"keydown"'
      assert_includes src, "dirtyFills"
      assert_includes src, "function emitFill"
    end

    def test_fill_capture_emits_value_holding_inputs
      src = probe_source
      # Form-associated custom elements manage the inner <input> value
      # programmatically, so the composed `input` event never sets dirty.
      # focusout must ALSO emit a text-like input that holds a value, deduped
      # by emittedFills so light-DOM fields don't double-fire.
      assert_includes src, "function holdsEnteredValue"
      assert_includes src, "TEXTLIKE_TYPES"
      assert_includes src, "emittedFills"
      assert_includes src, "dirtyFills.has(el) || holdsEnteredValue(el)"
    end

    def test_fill_capture_excludes_non_text_controls
      src = probe_source
      # A fill is only for text entry: radio/checkbox/button are click-driven.
      # emitFill gates on fillableControl so a radio never records a fill (and
      # a radio whose name matches a sensitive pattern never masks as a bogus
      # secret).
      assert_includes src, "function fillableControl"
      assert_includes src, "if (!fillableControl(el)) return;"
    end

    # ─── per-step DOM snapshots ───

    def test_record_dom_gate_reflects_flag
      assert_includes probe_source(record_dom: true),  "var RECORD_DOM = true;"
      assert_includes probe_source(record_dom: false), "var RECORD_DOM = false;"
      # The marker must always be substituted — a bare token would be a
      # ReferenceError at eval time.
      refute_includes probe_source(record_dom: true), "__FREENTONIC_RECORD_DOM__"
    end

    def test_dom_serializer_present_and_strips_values
      src = probe_source(record_dom: true)
      assert_includes src, "function serializeDeep"
      # Open shadow roots are emitted as declarative templates.
      assert_includes src, 'shadowrootmode="open"'
      # Attributes pass an allowlist on EVERY element, so a value a custom
      # element reflects onto its host (value=, aria-valuetext, data-*) never
      # reaches the snapshot file.
      assert_includes src, "SNAPSHOT_ATTRS.hasOwnProperty(name)"
      refute_includes src, "isControl", "a control-only strip-list misses custom elements"
    end

    def test_dom_snapshot_allowlist_keeps_selector_hooks_and_no_value_attrs
      block = probe_source(record_dom: true)[/var SNAPSHOT_ATTRS = \{(.*?)\};/m, 1]
      refute_nil block, "SNAPSHOT_ATTRS allowlist missing"
      allowed = block.scan(/"?([a-z][a-z-]*)"?\s*:\s*1/).flatten

      # Everything the shared selector heuristics read must survive, or the
      # snapshot stops being useful for offline selector mining.
      %w[id name class type role placeholder aria-label href
         data-testid data-test-id data-test].each do |attr|
        assert_includes allowed, attr
      end
      # Nothing that carries entered/selected state.
      %w[value checked selected aria-valuetext aria-valuenow aria-checked
         aria-selected data-value].each do |attr|
        refute_includes allowed, attr
      end
      # href keeps its path only — query/fragment can carry session tokens.
      assert_includes probe_source(record_dom: true),
                      'if (name === "href") value = String(value).split(/[?#]/)[0];'
    end

    # ─── offload: inline dom -> dom/<session>/NNNN.html + dom_ref ───

    def new_recorder(dir)
      rec = Recorder.new(path: File.join(dir, "recording.jsonl"), stdout: StringIO.new, record_dom: true)
      rec.install(CapturingSession.new)
      rec
    end

    def test_offload_dom_writes_file_and_rewrites_ref
      Dir.mktmpdir do |dir|
        rec = new_recorder(dir)
        payload = { "kind" => "click", "selector" => "#x", "dom" => "<html><body>hi</body></html>" }
        rec.send(:offload_dom!, payload)

        refute payload.key?("dom"), "inline dom must be peeled off the event line"
        assert_match %r{\Adom/\d+/0001\.html\z}, payload["dom_ref"]
        written = File.join(dir, payload["dom_ref"])
        assert_equal "<html><body>hi</body></html>", File.read(written)
        assert_equal "600", format("%o", File.stat(written).mode & 0o777)
      end
    end

    def test_offload_dom_sequences_files
      Dir.mktmpdir do |dir|
        rec = new_recorder(dir)
        p1 = { "kind" => "click", "dom" => "<a>" }
        p2 = { "kind" => "fill",  "dom" => "<b>" }
        rec.send(:offload_dom!, p1)
        rec.send(:offload_dom!, p2)
        assert_equal File.dirname(p1["dom_ref"]), File.dirname(p2["dom_ref"])
        assert_equal %w[0001.html 0002.html], [p1, p2].map { |p| File.basename(p["dom_ref"]) }
      end
    end

    # recording.jsonl is appended to across recordings into the same run
    # dir, so each session's snapshots get their own folder — a re-record
    # must not overwrite the files an earlier session's dom_ref points at.
    def test_a_second_recording_session_does_not_overwrite_snapshots
      Dir.mktmpdir do |dir|
        first = { "kind" => "click", "dom" => "<first>" }
        new_recorder(dir).send(:offload_dom!, first)
        sleep 0.01 # sessions are named by start time in ms
        second = { "kind" => "click", "dom" => "<second>" }
        new_recorder(dir).send(:offload_dom!, second)

        refute_equal first["dom_ref"], second["dom_ref"]
        assert_equal "<first>", File.read(File.join(dir, first["dom_ref"]))
      end
    end

    def test_offload_dom_never_writes_through_a_symlink
      Dir.mktmpdir do |dir|
        rec = new_recorder(dir)
        session_dir = rec.instance_variable_get(:@dom_dir)
        FileUtils.mkdir_p(session_dir)
        target = File.join(dir, "elsewhere.txt")
        File.write(target, "untouched")
        File.symlink(target, File.join(session_dir, "0001.html"))

        payload = { "kind" => "click", "dom" => "<page>" }
        rec.send(:offload_dom!, payload)

        refute payload.key?("dom_ref"), "a refused write leaves no dom_ref"
        assert_equal "untouched", File.read(target)
      end
    end

    def test_offload_dom_noop_without_dom
      Dir.mktmpdir do |dir|
        rec = new_recorder(dir)
        payload = { "kind" => "click", "selector" => "#x" }
        rec.send(:offload_dom!, payload)
        refute payload.key?("dom_ref")
        refute File.directory?(File.join(dir, "dom")), "no dom dir when nothing to write"
      end
    end

    # ─── secret hygiene in what the probe records ───

    def test_keypad_digit_clicks_record_no_digit_and_no_snapshot
      src = probe_source(record_dom: true)
      # A single-digit key emits a bare flagged click — no text, label or
      # selector that could carry the digit — and skips the DOM snapshot.
      assert_includes src, 'emit({ kind: "click", keypad_digit: true, url: location.href });'
      assert_includes src, "!payload.keypad_digit"
    end

    # Runs the shared masking function itself (needs node; the Ruby suite
    # otherwise has no JS engine), so the name patterns are tested as
    # behavior, not as regex text.
    def test_masking_covers_compound_spanish_and_labelled_fields
      skip "node not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

      script = <<~JS
        const src = require("fs").readFileSync(#{JSON.generate(Recorder::SHARED_SELECTORS_PATH)}, "utf8");
        eval(src.slice(src.indexOf("var SENSITIVE_HINT"), src.indexOf("function elementSummary")));
        const el = (name, attrs = {}) => ({ type: "text", name, value: "typed", getAttribute: (n) => attrs[n] || null });
        const out = {};
        for (const n of ["dni_number", "dninumber", "user_dni", "documentnumber", "document_id",
                         "usuario", "clave", "username", "email", "company", "postcode", "search"]) {
          out[n] = describeInputValue(el(n)).mask;
        }
        out.placeholder = describeInputValue(el("f1", { placeholder: "DNI / NIE" })).mask;
        out.aria = describeInputValue(el("f2", { "aria-label": "Contraseña" })).mask;
        console.log(JSON.stringify(out));
      JS
      out, status = Open3.capture2("node", "-e", script)
      assert status.success?, out
      masked = JSON.parse(out)

      %w[dni_number dninumber user_dni documentnumber document_id usuario clave username placeholder aria].each do |k|
        assert masked[k], "#{k} must be masked"
      end
      %w[email company postcode search].each { |k| refute masked[k], "#{k} must not be masked" }
    end
  end
end
