# frozen_string_literal: true

require "json"
require "uri"

module Freentonic
  # Compiles a `recording.jsonl` (the artifact `--recording` mode writes)
  # into a *draft* `connect:` pipeline as YAML. Deterministic, no Chrome,
  # no network — a pure data transform.
  #
  # The output is explicitly a DRAFT, never a finished provider: selectors
  # come straight off a single hand-walk of the bank UI, credentials are
  # masked into `secret(...)` by construction, and everything the author
  # must review is flagged with an inline `# REVIEW:` comment. Render it,
  # read it, edit it, then `--lint` it.
  #
  # Mapping (recording event -> emitted step), per the plan:
  #   * first  navigate      -> navigate(url:)
  #   * later  navigate      -> wait_url(includes: <url path>)
  #   * click / submit       -> wait_for_selector(selector:) THEN click(selector:)
  #   * fill + mask:true     -> fill(selector, value: secret(NAME)) + secrets: entry
  #   * fill (unmasked)      -> fill(selector, value: "<literal>") + # REVIEW comment
  #   * needs_review:true    -> emitted step + # REVIEW: nth-child selector...
  #   * empty selector       -> emitted step + # REVIEW: no selector captured
  #   * probe_ready/recorder_*/anything else -> dropped
  #
  # Only ever emits five registry actions: navigate / wait_url /
  # wait_for_selector / click / fill. A drift-guard test locks that.
  class RecordingCompiler
    # The single connect phase the draft emits. There is no reserved phase
    # name in the schema; "login" is a convention (Scaffold uses "connect").
    PHASE_NAME = "login"

    # Event kinds that carry an interaction we map to a step. Everything
    # else (probe_ready, recorder_started/stopped/error, ...) is dropped.
    INTERACTION_KINDS = %w[navigate click submit fill].freeze

    # Keyword fragments that name a masked field, used to derive a stable,
    # human-readable secret name from input_type/selector. Ordered so the
    # most specific/common wins first.
    SECRET_KEYWORDS = %w[password otp pin cvv cvc sms 2fa token pwd secret].freeze

    # Input types whose value is text the user typed. A click on one of these
    # with no fill for its selector means the value wasn't captured (a managed
    # / custom-element input) — the compiler scaffolds a fill so the secret
    # isn't silently missing.
    TEXTLIKE_INPUT_TYPES = %w[text email tel number password search url
                              date datetime-local month week time].freeze

    # A run of this many consecutive single-digit-key clicks is treated as a
    # numeric keypad: the per-key clicks are DROPPED (they won't replay — key
    # positions shuffle each load — and they encode the secret) and a scaffold
    # for the dedicated keypad action is left in their place.
    KEYPAD_MIN_RUN = 3

    # A single emitted YAML step: an action name, ordered scalar pairs, and
    # any leading `# REVIEW:` comment lines the renderer places above it.
    Step = Struct.new(:action, :pairs, :comments, keyword_init: true)

    def initialize(recording_path:, workflow_path: nil, stdout: $stdout, stderr: $stderr)
      @recording_path = recording_path
      @workflow_path = workflow_path
      @stdout = stdout
      @stderr = stderr
      @secret_by_selector = {}
      @used_secret_names = []
      @declared_secrets = [] # ordered list of secret names to declare
      @literal_count = 0
    end

    # Returns the draft workflow YAML as a String.
    def compile
      if @workflow_path
        # Graft mode (splicing steps into an existing workflow) is a
        # deliberate fast-follow — the fresh-draft path delivers the value.
        raise UserError,
              "--compile-recording graft mode (--workflow) is not implemented yet; " \
              "compile to a fresh draft and merge by hand"
      end

      events = collapse_keypad_runs(coalesce_navigates(last_session(read_events)))
      steps = build_steps(events)
      warn_on_literals
      render(steps)
    end

    private

    # Read the JSONL sink line by line. Tolerate a blank/truncated/malformed
    # line (the recorder flushes per line, so the last line can be partial)
    # by warning to stderr and skipping it — never crash the compile.
    def read_events
      events = []
      File.foreach(@recording_path).with_index(1) do |line, lineno|
        stripped = line.strip
        next if stripped.empty?
        begin
          events << JSON.parse(stripped)
        rescue JSON::ParserError
          @stderr.puts "[compile-recording] skipping malformed JSON on line #{lineno}"
        end
      end
      events
    end

    # recording.jsonl is appended to, so a re-recorded login leaves every
    # attempt in one file, each opened by a `recorder_started` line. Only the
    # last attempt describes the login to compile; merging them would replay
    # the failed tries too.
    def last_session(events)
      starts = events.each_index.select { |i| events[i]["kind"] == "recorder_started" }
      return events if starts.length < 2

      @stderr.puts "[compile-recording] #{starts.length} recording sessions in the file; " \
                   "compiling only the last one"
      events[starts.last..]
    end

    # Collapse runs of consecutive `navigate` events with the same URL into
    # one — a single click frequently emits several identical frameNavigated
    # frames.
    def coalesce_navigates(events)
      events.each_with_object([]) do |ev, acc|
        prev = acc.last
        if ev["kind"] == "navigate" && prev &&
           prev["kind"] == "navigate" && prev["url"] == ev["url"]
          next
        end
        acc << ev
      end
    end

    # A click on a single-digit key (a numeric keypad button). The probe
    # records one as a bare `keypad_digit: true` click — no text, label or
    # selector, so the digit never reaches recording.jsonl; older recordings
    # carry the digit as the click's visible text.
    def keypad_key?(ev)
      ev["kind"] == "click" &&
        (ev["keypad_digit"] == true || ev["text"].to_s.strip.match?(/\A\d\z/))
    end

    # Replace each run of >= KEYPAD_MIN_RUN consecutive single-digit-key clicks
    # with one synthetic `keypad` event. This DROPS the per-key clicks (which
    # leak the entered digits into the draft and won't replay against a
    # scrambled pad) before they ever become steps.
    def collapse_keypad_runs(events)
      out = []
      i = 0
      while i < events.length
        if keypad_key?(events[i])
          j = i
          j += 1 while j < events.length && keypad_key?(events[j])
          # A flagged key has no selector to replay, so any run of them is a
          # keypad; an old-format short run may be ordinary "1"/"2" buttons.
          if (j - i) >= KEYPAD_MIN_RUN || events[i...j].any? { |e| e["keypad_digit"] == true }
            out << { "kind" => "keypad", "count" => j - i }
            i = j
            next
          end
        end
        out << events[i]
        i += 1
      end
      out
    end

    def build_steps(events)
      fill_selectors = events.select { |e| e["kind"] == "fill" }
                             .map { |e| e["selector"].to_s }
      steps = []
      seen_navigate = false
      events.each do |ev|
        kind = ev["kind"]
        next unless INTERACTION_KINDS.include?(kind) || kind == "keypad"

        case kind
        when "navigate"
          if seen_navigate
            steps.concat(navigate_expectation(ev))
          else
            seen_navigate = true
            steps << navigate_entry(ev)
          end
        when "click", "submit"
          steps.concat(click_steps(ev))
          steps << unfilled_input_scaffold(ev) if unfilled_text_input?(ev, fill_selectors)
        when "fill"
          steps << fill_step(ev)
        when "keypad"
          steps << keypad_scaffold(ev)
        end
      end
      steps
    end

    # True when a click landed on a text-entry input that never received a
    # fill — the value was typed but not observable (a managed / custom-element
    # input). We scaffold a fill so the secret isn't silently dropped.
    def unfilled_text_input?(ev, fill_selectors)
      return false unless ev["kind"] == "click"
      return false unless TEXTLIKE_INPUT_TYPES.include?(ev["input_type"].to_s.downcase)
      !fill_selectors.include?(ev["selector"].to_s)
    end

    # Comment-only scaffold (action: nil renders just the comment lines) for a
    # clicked-but-unfilled text field. Invisible to YAML parsing, so it never
    # affects lint or the step list — pure guidance the author pastes in.
    def unfilled_input_scaffold(ev)
      Step.new(action: nil, pairs: [], comments: [
        "# REVIEW: this input was clicked but no typed value was captured — a",
        "# managed / custom-element input can hide its value from the recorder.",
        "# If it takes typed input, add a fill (and a matching secrets: entry):",
        "#   - action: fill",
        "#     selector: #{yq(ev["selector"].to_s)}",
        '#     value: "secret(REPLACE_ME)"'
      ])
    end

    # Comment-only scaffold replacing a dropped keypad run. Names the count of
    # dropped keys but never the digits themselves.
    def keypad_scaffold(ev)
      Step.new(action: nil, pairs: [], comments: [
        "# REVIEW: #{ev["count"]} single-digit key presses were recorded here and DROPPED.",
        "# They look like a numeric keypad: the per-key clicks won't replay (key",
        "# positions shuffle each load) AND they encode the secret. Replace with the",
        "# keypad action for this pad (see docs/workflow-action-enter-pin-pad.md):",
        "#   - action: enter_pin_pad",
        '#     selector: "REPLACE_ME: the pad container selector"',
        '#     pin: "secret(USER_PIN)"'
      ])
    end

    # First navigate -> the workflow entry URL.
    def navigate_entry(ev)
      Step.new(
        action: "navigate",
        pairs: [["url", yq(ev["url"].to_s)]],
        comments: []
      )
    end

    # Subsequent navigate -> model the redirect as an expectation. Use the
    # URL path (not the full URL) as the `includes:` substring. Navigation
    # events carry no selector, so they never earn a selector REVIEW.
    def navigate_expectation(ev)
      [Step.new(
        action: "wait_url",
        pairs: [["includes", yq(url_tail(ev["url"].to_s))]],
        comments: []
      )]
    end

    # click / submit -> wait for the target to exist, then click it. The
    # review comments ride on the leading wait_for_selector step so a fragile
    # or missing selector is flagged once, above the pair.
    def click_steps(ev)
      selector = yq(ev["selector"].to_s)
      [
        Step.new(
          action: "wait_for_selector",
          pairs: [["selector", selector]],
          comments: review_comments(ev)
        ),
        Step.new(
          action: "click",
          pairs: [["selector", selector]],
          comments: []
        )
      ]
    end

    def fill_step(ev)
      comments = review_comments(ev)
      value =
        if ev["mask"] == true
          name = secret_name_for(ev)
          yq("secret(#{name})")
        else
          @literal_count += 1
          comments = comments + ["# REVIEW: literal from recording"]
          yq(ev["value"].to_s)
        end

      Step.new(
        action: "fill",
        pairs: [["selector", yq(ev["selector"].to_s)], ["value", value]],
        comments: comments
      )
    end

    # `# REVIEW:` lines an interaction event earns from its selector quality.
    # A `shadow` event also gets an informational NOTE: the selector is
    # root-scoped, so it won't match in a browser console's plain
    # querySelector — but freentonic's actions pierce shadow roots at
    # runtime, so the step replays fine.
    def review_comments(ev)
      comments = []
      if ev["selector"].to_s.empty? || ev["selector_strategy"] == "none"
        comments << "# REVIEW: no selector captured"
      elsif ev["selector_strategy"] == "id-volatile"
        comments << "# REVIEW: auto-generated id — regenerates each load; replace with a stable attribute (name/placeholder/aria-label)"
      elsif ev["needs_review"] == true
        comments << "# REVIEW: nth-child selector, may be fragile"
      end
      if ev["shadow"] == true
        comments << "# NOTE: element is inside shadow DOM (freentonic actions pierce it; a browser-console querySelector won't match)"
      end
      comments
    end

    # Deterministic, collision-safe secret name. The same selector always
    # maps to the same name (so a re-typed field reuses one secret); a new
    # field whose derived base collides gets a numeric suffix. Recompiling
    # the same recording is therefore stable.
    def secret_name_for(ev)
      selector = ev["selector"].to_s
      return @secret_by_selector[selector] if !selector.empty? && @secret_by_selector.key?(selector)

      base = derive_secret_base(ev)
      name = base
      counter = 2
      while @used_secret_names.include?(name)
        name = "#{base}_#{counter}"
        counter += 1
      end

      @used_secret_names << name
      @declared_secrets << name
      @secret_by_selector[selector] = name unless selector.empty?
      name
    end

    def derive_secret_base(ev)
      input_type = ev["input_type"].to_s.downcase
      return "PASSWORD" if input_type == "password"

      haystack = "#{input_type} #{ev["selector"]}".downcase
      keyword = SECRET_KEYWORDS.find { |kw| haystack.include?(kw) }
      keyword ? keyword.upcase : "SECRET"
    end

    def url_tail(url)
      parsed = URI.parse(url)
      tail = parsed.path.to_s
      tail = parsed.host.to_s if tail.empty? || tail == "/"
      tail.empty? ? url : tail
    rescue URI::InvalidURIError
      url
    end

    def warn_on_literals
      return if @literal_count.zero?

      @stderr.puts "[compile-recording] wrote #{@literal_count} literal value(s) " \
                   "from the recording — review before committing (these can be usernames/PII)"
    end

    # ---- Rendering (hand-rolled heredoc templating, Scaffold style) ------
    #
    # We render by hand rather than through Psych so the inline `# REVIEW:`
    # comments survive — a YAML emitter would drop every comment.

    def render(steps)
      out = +""
      out << "version: 1\n\n"
      out << "# DRAFT compiled from #{File.basename(@recording_path)} by --compile-recording.\n"
      out << "# This is a starting point, NOT a finished provider: review every\n"
      out << "# selector and REVIEW comment, then run `freentonic --lint` on it.\n\n"
      out << "config:\n"
      out << "  key: REPLACE_ME\n\n"
      out << render_secrets
      out << "pipeline:\n"
      out << "  - #{PHASE_NAME}\n\n"
      out << "phases:\n"
      out << "  #{PHASE_NAME}:\n"
      out << render_steps(steps)
      out
    end

    def render_secrets
      return "" if @declared_secrets.empty?

      lines = +"secrets:\n"
      @declared_secrets.each do |name|
        lines << "  #{name}:\n"
        lines << "    prompt: #{yq("REPLACE_ME: describe the #{name} secret")}\n"
      end
      lines << "\n"
      lines
    end

    def render_steps(steps)
      return "    []\n" if steps.empty?

      out = +""
      steps.each do |step|
        step.comments.each do |comment|
          out << "    #{comment}\n"
        end
        # A comment-only scaffold (action: nil) renders just its comments —
        # no `- action:` line, so it is invisible to YAML parsing.
        next if step.action.nil?

        first_key, first_value = step.pairs.first
        out << "    - action: #{step.action}\n"
        out << "      #{first_key}: #{first_value}\n" if first_key
        step.pairs.drop(1).each do |key, value|
          out << "      #{key}: #{value}\n"
        end
      end
      out
    end

    # Double-quoted YAML scalar with the two escapes a double-quoted YAML
    # scalar needs. Keeps selectors (which carry `>` and quotes) and literal
    # values intact and unambiguous.
    def yq(value)
      escaped = value.gsub(/[\\"]/) { |char| "\\#{char}" }
      %("#{escaped}")
    end
  end
end
