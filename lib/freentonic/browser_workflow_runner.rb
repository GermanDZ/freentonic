# frozen_string_literal: true

require "json"
require "timeout"
require "io/console"
require "base64"

module Freentonic
    class BrowserWorkflowRunner
      WAIT_STEP_SECONDS = 0.2

      # Injected into deep-query expressions so selectors cross shadow roots
      # AND same-origin iframes. Cross-origin iframes (where contentDocument
      # access throws a SecurityError) are skipped silently.
      DEEP_QUERY_FN = <<~'JS'.freeze
        function deepQuery(root, sel) {
          const el = root && root.querySelector ? root.querySelector(sel) : null;
          if (el) return el;
          const all = root && root.querySelectorAll ? root.querySelectorAll('*') : [];
          for (const child of all) {
            if (child.shadowRoot) {
              const r = deepQuery(child.shadowRoot, sel);
              if (r) return r;
            }
            if (child.tagName === 'IFRAME' || child.tagName === 'FRAME') {
              let doc = null;
              try { doc = child.contentDocument; } catch (_) { doc = null; }
              if (doc) {
                const r = deepQuery(doc, sel);
                if (r) return r;
              }
            }
          }
          return null;
        }
      JS

      def initialize(source:, session:, schema:, context:, secret_resolver:, session_drainer:, stdout:, stderr:, stdin: $stdin, runtime_context: {})
        @source = source
        @session = session
        @schema = schema
        @context = context
        @secret_resolver = secret_resolver
        @session_drainer = session_drainer
        @stdout = stdout
        @stderr = stderr
        @stdin = stdin
        @runtime_context = runtime_context
        @error_signals = schema.error_signals
      end

      def execute_phase(name)
        steps = @schema.phase(name)
        return @context if steps.empty?

        @stdout.puts "  Running #{name} phase..."
        steps.each do |step|
          execute_step(step)
        end
        @context
      end

      private

      def execute_step(step)
        drain_network_events if @recording_installed

        action = step.fetch("action")

        unless step_condition_met?(step)
          @stdout.puts "    [yml] skipped (when_context): #{action}"
          return
        end

        case action
        when "note"
          @stdout.puts "    #{resolved(step.fetch("message"))}"
        when "note_if_selector"
          selector = step.fetch("selector")
          present = runtime_deep_call(<<~JS, selector)
            (selector) => deepQuery(document, selector) !== null
          JS
          if present
            @stdout.puts "    #{resolved(step.fetch("message"))}"
          end
        when "navigate"
          url = resolved(step.fetch("url"))
          @stdout.puts "    [yml] navigate: #{url}"
          @session.send_command("Page.navigate", { url: url })
        when "reload"
          @stdout.puts "    [yml] reload"
          @session.send_command("Page.reload")
        when "wait"
          seconds = step.fetch("seconds")
          @stdout.puts "    [yml] wait: #{seconds}s"
          sleep Float(seconds)
        when "wait_url"
          includes = step.fetch("includes")
          timeout = Integer(step.fetch("timeout", 30))
          @stdout.print "    [yml] wait_url: includes \"#{includes}\" (timeout: #{timeout}s)"
          wait_for_url(includes, timeout: timeout)
          @stdout.puts " ✓"
        when "wait_network_idle"
          seconds = Integer(step.fetch("seconds", 3))
          @stdout.puts "    [yml] wait_network_idle: #{seconds}s"
          @session_drainer.call(@session, iterations: seconds, sleep_seconds: 1)
        when "capture_header"
          name = step.fetch("name")
          as = step.fetch("as")
          @stdout.puts "    [yml] capture_header: \"#{name}\" → ctx.#{as}"
          capture_header(
            name: name,
            as: as,
            retries: Integer(step.fetch("retries", 0)),
            interval_seconds: Float(step.fetch("interval_seconds", 1)),
            required: step.fetch("required", true)
          )
        when "capture_cookie_header"
          host = step.fetch("host")
          path = step.fetch("path")
          as = step.fetch("as")
          @stdout.puts "    [yml] capture_cookie_header: #{host}#{path} → ctx.#{as}"
          capture_cookie_header(
            host: host,
            path: path,
            as: as,
            required: step.fetch("required", true)
          )
        when "capture_response_json"
          url_includes = step.fetch("url_includes")
          field = step.fetch("field")
          as_key = step.fetch("as")
          exclude_url = step.fetch("exclude_url", nil)
          @stdout.puts "    [yml] capture_response_json: #{url_includes} .#{field} → ctx.#{as_key}"
          capture_response_json(
            url_includes: url_includes,
            exclude_url: exclude_url,
            field: field,
            as: as_key,
            retries: Integer(step.fetch("retries", 0)),
            interval_seconds: Float(step.fetch("interval_seconds", 1)),
            required: step.fetch("required", true)
          )
        when "wait_for_selector"
          selector = step.fetch("selector")
          timeout  = Integer(step.fetch("timeout", 15))
          @stdout.print "    [yml] wait_for_selector: #{selector} (timeout: #{timeout}s)"
          wait_for_selector(selector, timeout: timeout)
          @stdout.puts " ✓"
        when "wait_for_first_of"
          selectors = Array(step.fetch("selectors"))
          timeout   = Integer(step.fetch("timeout", 30))
          @stdout.print "    [yml] wait_for_first_of: [#{selectors.join(", ")}] (timeout: #{timeout}s)"
          wait_for_first_of(selectors, timeout: timeout)
          @stdout.puts " ✓"
        when "wait_for_shadow_selector"
          host     = step.fetch("host")
          selector = step.fetch("selector")
          timeout  = Integer(step.fetch("timeout", 30))
          @stdout.print "    [yml] wait_for_shadow_selector: #{host} >>> #{selector} (timeout: #{timeout}s)"
          wait_for_shadow_selector(host, selector, timeout: timeout)
          @stdout.puts " ✓"
        when "enter_pin_pad"
          @stdout.puts "    [yml] enter_pin_pad: #{step.fetch("selector")}"
          enter_pin_pad(step.fetch("selector"), step.fetch("pin"))
        when "click"
          @stdout.puts "    [yml] click: #{step.fetch("selector")}"
          click_selector(step.fetch("selector"), optional: false)
        when "click_if_present"
          @stdout.puts "    [yml] click_if_present: #{step.fetch("selector")}"
          click_selector(step.fetch("selector"), optional: true)
        when "click_text"
          text    = step.fetch("text")
          role    = step.fetch("role", "button")
          within  = step["within"]
          match   = step.fetch("match", "exact")
          timeout = Integer(step.fetch("timeout", 10))
          @stdout.print "    [yml] click_text: #{role} #{text.inspect} (timeout: #{timeout}s)"
          click_text(text: text, role: role, within: within, match: match, timeout: timeout)
          @stdout.puts " ✓"
        when "fill"
          @stdout.puts "    [yml] fill: #{step.fetch("selector")}"
          fill_selector(step.fetch("selector"), step.fetch("value"), optional: false, clear: step["clear"] == true)
        when "fill_if_present"
          @stdout.puts "    [yml] fill_if_present: #{step.fetch("selector")}"
          fill_selector(step.fetch("selector"), step.fetch("value"), optional: true, clear: step["clear"] == true)
        when "enter_digits"
          count = Array(step.fetch("digits")).size
          @stdout.puts "    [yml] enter_digits: #{count} digit(s) in #{step.fetch("keypad")}"
          enter_digits(step.fetch("digits"), keypad: step.fetch("keypad"))
        when "prompt_stdin_and_fill"
          prompt_stdin_and_fill(step)
        when "record_requests"
          start_recording(step)
        when "dump_requests"
          dump_recorded_requests(step)
        when "pause"
          pause_for_user(step)
        when "capture_url"
          capture_current_url(step)
        when "simulate_human"
          duration = Float(step.fetch("duration", 2))
          @stdout.puts "    [yml] simulate_human: #{duration}s"
          simulate_human_behavior(duration)
        when "screenshot"
          label = step.fetch("label", "manual")
          @stdout.puts "    [yml] screenshot: #{label}"
          save_screenshot(label)
        else
          raise UserError, "unknown workflow action #{action.inspect} for #{@source.key}"
        end
      end

      def wait_for_url(expected_fragment, timeout:)
        deadline = Time.now + timeout
        last_dot = Time.now
        while Time.now < deadline
          current_url = current_url_value
          return if current_url.include?(resolved(expected_fragment))
          check_error_signals!

          if Time.now - last_dot >= 2
            @stdout.print "."
            @stdout.flush if @stdout.respond_to?(:flush)
            last_dot = Time.now
          end
          sleep WAIT_STEP_SECONDS
        end

        @stdout.puts
        save_timeout_screenshot("wait_url #{expected_fragment.inspect}")
        raise UserError, "workflow wait_url timed out waiting for #{expected_fragment.inspect}"
      end

      CLICK_TEXT_JS = <<~'JS'.freeze
        (text, role, within, match) => {
          const roots = [];
          if (within) {
            const scope = deepQuery(document, within);
            if (!scope) return false;
            roots.push(scope);
          } else {
            roots.push(document);
          }

          const tagSet = role === "button" ? ["BUTTON"] :
                         role === "link"   ? ["A"]      :
                         null;
          const roleFallback = role === "button" ? 'button' :
                               role === "link"   ? 'link'   : null;

          const cmp = match === "contains" ? (a, b) => a.includes(b) :
                      match === "prefix"   ? (a, b) => a.startsWith(b) :
                                             (a, b) => a === b;

          function visit(root) {
            const stack = [root];
            const seen = [];
            while (stack.length) {
              const node = stack.shift();
              if (!node) continue;

              if (node.nodeType === 1) {
                const matchesRole =
                  tagSet === null ||
                  tagSet.includes(node.tagName) ||
                  (roleFallback && node.getAttribute && node.getAttribute('role') === roleFallback);
                if (matchesRole) {
                  const nodeText = (node.textContent || "").trim().replace(/\s+/g, " ");
                  if (cmp(nodeText, text)) {
                    if (node.focus) node.focus();
                    node.click();
                    return true;
                  }
                }
              }

              const children = node.children
                ? Array.from(node.children)
                : (node.childNodes ? Array.from(node.childNodes).filter(c => c.nodeType === 1) : []);
              for (let i = children.length - 1; i >= 0; i--) stack.unshift(children[i]);
              if (node.shadowRoot) stack.unshift(node.shadowRoot);
              if (node.tagName === 'IFRAME' || node.tagName === 'FRAME') {
                let doc = null;
                try { doc = node.contentDocument; } catch (_) { doc = null; }
                if (doc) stack.unshift(doc);
              }
            }
            return false;
          }

          for (const r of roots) {
            if (visit(r)) return true;
          }
          return false;
        }
      JS

      def click_text(text:, role:, within:, match:, timeout:)
        deadline = Time.now + timeout
        loop do
          found = runtime_deep_call(CLICK_TEXT_JS, text, role, within || "", match)
          return if found
          if Time.now >= deadline
            scope = within ? " within #{within.inspect}" : ""
            save_timeout_screenshot("click_text #{role} #{text.inspect}")
            raise UserError, "click_text timed out: #{role} #{text.inspect}#{scope}"
          end
          sleep WAIT_STEP_SECONDS
        end
      end

      def click_selector(selector, optional:)
        result = runtime_deep_call(<<~JS, selector)
          (selector) => {
            if (document.activeElement) document.activeElement.blur();
            const element = deepQuery(document, selector);
            if (!element) return false;
            element.click();
            return true;
          }
        JS

        return if result
        return if optional

        raise UserError, "workflow click could not find selector #{selector.inspect}"
      end

      def capture_header(name:, as:, retries:, interval_seconds:, required:)
        value = SourceHelpers.find_header(@session.pending_events, name)

        retries.times do
          break if value && !value.empty?

          sleep interval_seconds
          @session.send_command("Runtime.evaluate", { expression: "1" }) rescue nil
          value = SourceHelpers.find_header(@session.pending_events, name)
        end

        if value.nil? || value.empty?
          raise UserError, "workflow capture_header could not find #{name.inspect}" if required
          return nil
        end

        @context[as.to_s] = value
        @stdout.puts "      ✓ #{name}: captured"
      end

      def capture_cookie_header(host:, path:, as:, required:)
        filtered, header = SourceHelpers.cookie_header_for(@session, host: host, path: path)

        if header.empty?
          raise UserError, "workflow capture_cookie_header found no cookies for #{host}#{path}" if required
          return nil
        end

        @context[as.to_s] = header
        @context["#{as}_cookie_count"] = filtered.size
        @stdout.puts "      ✓ #{filtered.size} cookies captured"
      end

      def capture_response_json(url_includes:, exclude_url:, field:, as:, retries:, interval_seconds:, required:)
        value = find_response_json_field(url_includes, exclude_url, field)

        retries.times do
          break unless value.nil?

          sleep interval_seconds
          @session.send_command("Runtime.evaluate", { expression: "1" }) rescue nil
          value = find_response_json_field(url_includes, exclude_url, field)
        end

        if value.nil?
          raise UserError, "workflow capture_response_json could not find #{field.inspect} in response matching #{url_includes.inspect}" if required
          return nil
        end

        @context[as.to_s] = value
        @stdout.puts "      ✓ #{field}: captured"
      end

      def find_response_json_field(url_includes, exclude_url, field)
        responses = @session.pending_events.select do |event|
          event["method"] == "Network.responseReceived" &&
            event.dig("params", "response", "url").to_s.include?(url_includes) &&
            (exclude_url.nil? || !event.dig("params", "response", "url").to_s.include?(exclude_url))
        end
        return nil if responses.empty?

        responses.reverse_each do |event|
          request_id = event.dig("params", "requestId")
          next unless request_id

          begin
            result = @session.send_command("Network.getResponseBody", { requestId: request_id })
            body = result["body"]
            next if body.nil? || body.empty?

            parsed = JSON.parse(body) rescue nil
            return parsed[field] if parsed.is_a?(Hash) && !parsed[field].nil?
          rescue StandardError
            next
          end
        end

        nil
      end

      def fill_selector(selector, value, optional: false, resolve: true, clear: false)
        js = clear ? fill_lookup_with_clear_js : fill_lookup_js
        found = runtime_deep_call(js, selector)

        case found
        when true
          :ok
        when false
          return if optional
          raise UserError, "workflow fill could not find selector #{selector.inspect}"
        when "not-a-text-input"
          raise UserError, "workflow fill clear: true requires <input> or <textarea>, got a different element for #{selector.inspect}"
        else
          raise UserError, "workflow fill: unexpected runtime return #{found.inspect}"
        end

        text = resolve ? resolved(value) : value
        # Simulate human typing: dispatch each character individually via CDP
        # with a variable inter-keystroke delay so it looks organic to the page.
        text.each_char do |char|
          @session.send_command("Input.dispatchKeyEvent", { type: "char", text: char })
          sleep(rand(40..130) / 1000.0)
        end

        # Simulate Tab to move focus away — more human than calling .blur()
        # directly, and reliably triggers component validation on focus loss.
        sleep(rand(50..150) / 1000.0)
        tab = { key: "Tab", code: "Tab", windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9 }
        @session.send_command("Input.dispatchKeyEvent", tab.merge(type: "keyDown"))
        @session.send_command("Input.dispatchKeyEvent", tab.merge(type: "keyUp"))
      end

      def prompt_stdin_and_fill(step)
        selector = step.fetch("selector")
        prompt = step.fetch("prompt")
        timeout_seconds = Integer(step.fetch("timeout"))
        submit_selector = step["submit_selector"]
        mask = step["mask"] == true
        if_present = step["if_present"] == true

        if if_present
          present = runtime_deep_call(<<~JS, selector)
            (selector) => deepQuery(document, selector) !== null
          JS
          unless present
            @stdout.puts "    [yml] prompt_stdin_and_fill: skipped (#{selector} not present)"
            return
          end
        end

        unless @stdin.respond_to?(:tty?) && @stdin.tty?
          raise UserError, "prompt_stdin_and_fill: refusing to read from non-tty stdin"
        end

        value =
          begin
            Timeout.timeout(timeout_seconds) do
              if mask
                IO.console.getpass(prompt)
              else
                @stderr.print(prompt)
                @stderr.flush if @stderr.respond_to?(:flush)
                @stdin.gets&.chomp
              end
            end
          rescue Timeout::Error
            raise UserError, "prompt_stdin_and_fill: timed out waiting for user input on #{selector}"
          end

        if value.nil? || value.empty?
          raise UserError, "prompt_stdin_and_fill: empty input for #{selector}"
        end

        fill_selector(selector, value, optional: false, resolve: false)
        click_selector(submit_selector, optional: false) if submit_selector
        @stdout.puts "    [yml] prompt_stdin_and_fill: filled #{selector}"
      end

      def wait_for_selector(selector, timeout:)
        deadline = Time.now + timeout
        last_dot = Time.now
        while Time.now < deadline
          return if runtime_deep_call(<<~JS, selector)
            (selector) => deepQuery(document, selector) !== null
          JS
          check_error_signals!

          if Time.now - last_dot >= 2
            @stdout.print "."
            @stdout.flush if @stdout.respond_to?(:flush)
            last_dot = Time.now
          end
          sleep WAIT_STEP_SECONDS
        end

        @stdout.puts
        save_timeout_screenshot("wait_for_selector #{selector.inspect}")
        raise UserError, "workflow wait_for_selector timed out waiting for #{selector.inspect}"
      end

      def wait_for_first_of(selectors, timeout:)
        deadline = Time.now + timeout
        last_dot = Time.now
        while Time.now < deadline
          selectors.each do |sel|
            return if runtime_deep_call(<<~JS, sel)
              (selector) => deepQuery(document, selector) !== null
            JS
          end
          check_error_signals!

          if Time.now - last_dot >= 2
            @stdout.print "."
            @stdout.flush if @stdout.respond_to?(:flush)
            last_dot = Time.now
          end
          sleep WAIT_STEP_SECONDS
        end

        @stdout.puts
        save_timeout_screenshot("wait_for_first_of #{selectors.inspect}")
        raise UserError, "workflow wait_for_first_of timed out waiting for any of #{selectors.inspect}"
      end

      def wait_for_shadow_selector(host_selector, selector, timeout:)
        deadline = Time.now + timeout
        last_dot = Time.now
        while Time.now < deadline
          return if runtime_shadow_eval(host_selector, <<~JS, selector)
            (shadowRoot, sel) => shadowRoot.querySelector(sel) !== null
          JS
          check_error_signals!

          if Time.now - last_dot >= 2
            @stdout.print "."
            @stdout.flush if @stdout.respond_to?(:flush)
            last_dot = Time.now
          end
          sleep WAIT_STEP_SECONDS
        end

        @stdout.puts
        save_timeout_screenshot("wait_for_shadow_selector #{host_selector} >>> #{selector}")
        raise UserError, "workflow wait_for_shadow_selector timed out waiting for #{selector.inspect} in #{host_selector.inspect}"
      end

      def enter_pin_pad(selector, pin)
        full_pin = resolved(pin).gsub(/\D/, "")

        # findInTree / findAllInTree recurse into nested shadow roots.
        # Must use <<~'JS' (non-interpolating heredoc) so Ruby doesn't drop
        # backslashes — \d in a <<~JS heredoc becomes d (unknown escape silently
        # stripped), which turns JS digit-regexes into letter-d matchers.
        tree_helpers = <<~'JS'
          function _iframeDoc(el) {
            if (el.tagName !== 'IFRAME' && el.tagName !== 'FRAME') return null;
            try { return el.contentDocument; } catch (_) { return null; }
          }
          function findInTree(root, predicate) {
            for (const el of root.querySelectorAll('*')) {
              if (predicate(el)) return el;
              if (el.shadowRoot) {
                const found = findInTree(el.shadowRoot, predicate);
                if (found) return found;
              }
              const doc = _iframeDoc(el);
              if (doc) {
                const found = findInTree(doc, predicate);
                if (found) return found;
              }
            }
            return null;
          }
          function findAllInTree(root, predicate) {
            const out = [];
            for (const el of root.querySelectorAll('*')) {
              if (predicate(el)) out.push(el);
              if (el.shadowRoot) out.push(...findAllInTree(el.shadowRoot, predicate));
              const doc = _iframeDoc(el);
              if (doc) out.push(...findAllInTree(doc, predicate));
            }
            return out;
          }
        JS

        # Poll until .dots-indicator reports non-zero PIN positions.
        # Uses .container-pinpad as the entry point (found via deepQuery) then
        # findInTree to reach .dots-indicator through any nested shadow roots.
        # Falls back to counting unfilled .dot elements if aria-label is absent.
        raw = nil
        30.times do
          raw = runtime_deep_call(<<~JS, full_pin)
            (fullPin) => {
              #{tree_helpers}
              const pad = deepQuery(document, '.container-pinpad');
              if (!pad) return 'ERR:no-pad';

              const ind = findInTree(pad, function(el) { return el.matches && el.matches('.dots-indicator'); });
              let ariaLabel = ind ? (ind.getAttribute('aria-label') || '') : '';
              let positions = [];
              const m = ariaLabel.match(/\\d+/g);
              if (m) positions = m.map(function(s) { return parseInt(s, 10); }).filter(function(n) { return n > 0; });

              if (!positions.length) {
                const dots = findAllInTree(pad, function(el) { return el.matches && el.matches('.dot'); });
                dots.forEach(function(d, i) {
                  if (!d.classList.contains('filled')) positions.push(i + 1);
                });
              }

              if (!positions.length) return null;

              const digits = positions.map(function(pos) {
                return pos <= fullPin.length ? fullPin[pos - 1] : '?';
              });
              return positions.join(',') + '|' + digits.join(',');
            }
          JS
          break if raw
          sleep 0.3
        end

        raise UserError, "enter_pin_pad: could not read PIN positions from #{selector.inspect}" unless raw

        pos_part, digit_part = raw.split("|", 2)
        positions = pos_part.split(",").map(&:to_i)
        digits    = digit_part.split(",")

        if (bad_idx = digits.index("?"))
          pos = positions[bad_idx]
          raise UserError,
                "enter_pin_pad: position #{pos} exceeds PIN length #{full_pin.length} — " \
                "update the USER_PIN secret to include at least #{pos} digits"
        end

        digits.each do |digit|
          clicked = runtime_deep_call(<<~JS, digit.to_s)
            (digit) => {
              #{tree_helpers}
              const pad = deepQuery(document, '.container-pinpad');
              if (!pad) return false;
              const keys = findAllInTree(pad, function(el) { return el.matches && el.matches('.container-key'); });
              for (const k of keys) {
                const label = k.getAttribute('aria-label') || (k.textContent || '').trim();
                if (label === digit) { k.click(); return true; }
              }
              return false;
            }
          JS

          raise UserError, "enter_pin_pad: digit #{digit.inspect} button not found in #{selector.inspect}" unless clicked
          sleep(rand(300..700) / 1000.0)
        end
      end

      # Evaluates a function inside a custom element's shadow root.
      # function_source receives (shadowRoot, ...args) and returns a value.
      def runtime_shadow_eval(host_selector, function_source, *args)
        extra = args.map { |a| ", #{JSON.generate(a)}" }.join
        expression = <<~JS.strip
          (() => {
            #{DEEP_QUERY_FN}
            const host = deepQuery(document, #{JSON.generate(host_selector)});
            if (!host || !host.shadowRoot) return null;
            return (#{function_source.strip})(host.shadowRoot#{extra});
          })()
        JS
        result = @session.send_command(
          "Runtime.evaluate",
          { expression: expression, returnByValue: true, awaitPromise: true },
          timeout: 10
        )
        handle_runtime_exception!(expression, result)
        result.dig("result", "value")
      end

      def enter_digits(digits, keypad:)
        resolved(digits).each do |digit|
          found = runtime_call(<<~JS, keypad, digit.to_s)
            (keypadSelector, digit) => {
              const root = document.querySelector(keypadSelector) || document;
              const candidates = Array.from(
                root.querySelectorAll("button, [role='button'], a, input[type='button'], input[type='submit'], [data-digit]")
              );

              const match = candidates.find((element) => {
                const values = [
                  element.getAttribute("data-digit"),
                  element.value,
                  element.innerText,
                  element.textContent
                ].filter(Boolean).map((item) => String(item).trim());

                return values.includes(digit);
              });

              if (!match) {
                return false;
              }

              match.click();
              return true;
            }
          JS

          raise UserError, "workflow enter_digits could not find digit #{digit.inspect} inside #{keypad.inspect}" unless found
          sleep WAIT_STEP_SECONDS
        end
      end

      # Simulate organic mouse movement, scrolling, and pauses so behavioral
      # captchas (ThreatMetrix, PerimeterX, etc.) see a real user pattern.
      # Uses CDP Input domain directly — no JS injection.
      def simulate_human_behavior(duration)
        deadline = Time.now + duration
        x = rand(200..600)
        y = rand(150..400)

        while Time.now < deadline
          # Pick a random target and move toward it in small steps (bezier-ish).
          target_x = rand(80..900)
          target_y = rand(80..600)
          steps = rand(10..25)
          steps.times do |i|
            break if Time.now >= deadline
            t = (i + 1).to_f / steps
            # Ease-out curve with jitter
            ease = 1 - (1 - t)**2
            cx = (x + (target_x - x) * ease + rand(-5..5)).round
            cy = (y + (target_y - y) * ease + rand(-5..5)).round
            @session.send_command("Input.dispatchMouseEvent", {
              type: "mouseMoved", x: cx, y: cy
            })
            sleep(rand(8..30) / 1000.0)
          end
          x, y = target_x, target_y

          # Pause like a human reading the page
          sleep(rand(150..500) / 1000.0)

          # Occasionally scroll
          if rand < 0.3
            delta = rand(-80..80)
            @session.send_command("Input.dispatchMouseEvent", {
              type: "mouseWheel", x: x, y: y, deltaX: 0, deltaY: delta
            })
            sleep(rand(100..300) / 1000.0)
          end
        end
      end

      def save_screenshot(label)
        result = @session.send_command("Page.captureScreenshot", { format: "png" }, timeout: 10)
        data = result&.dig("data")
        raise UserError, "screenshot: empty response from Chrome" unless data

        run_dir = ENV["FREENTONIC_RUN_DIR"]
        run_id  = ENV["FREENTONIC_RUN_ID"]

        now = Time.now
        timestamp = now.strftime("%Y%m%d-%H%M%S-") + format("%03d", (now.usec / 1000))

        if run_dir && File.directory?(run_dir) && File.writable?(run_dir)
          prefix = run_id && !run_id.empty? ? "#{run_id}-" : ""
          filename = "#{prefix}freentonic-#{label}-#{timestamp}.png"
          path = File.join(run_dir, filename)
        else
          filename = "freentonic-#{label}-#{timestamp}.png"
          dir = ["/workspace", Dir.pwd].find { |d| File.directory?(d) && File.writable?(d) } || Dir.pwd
          path = File.join(dir, filename)
        end

        # Explicit 0600 so screenshots of bank pages (balances, transactions,
        # 2FA codes mid-flow) aren't group/world-readable even when the
        # umask hasn't been tightened (e.g. outside the container).
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC | File::BINARY, 0o600) do |f|
          f.write(Base64.decode64(data))
        end
        @stderr.puts "    screenshot saved: #{path}"
      end

      # Best-effort screenshot on timeout — never raises.
      def save_timeout_screenshot(description)
        save_screenshot("timeout")
      rescue StandardError => e
        @stderr.puts "    (screenshot failed: #{e.message})"
      end

      def check_error_signals!
        return if @error_signals.empty?

        now = Time.now
        @last_error_signal_check ||= Time.at(0)
        return if (now - @last_error_signal_check) < 2
        @last_error_signal_check = now

        @error_signals.each do |signal|
          matched = if signal["text"]
            runtime_call(<<~JS, signal["text"])
              (text) => document.body && document.body.innerText.includes(text)
            JS
          elsif signal["title"]
            runtime_call(<<~JS, signal["title"])
              (text) => document.title.includes(text)
            JS
          elsif signal["selector"]
            runtime_deep_call(<<~JS, signal["selector"])
              (selector) => deepQuery(document, selector) !== null
            JS
          end

          next unless matched

          message = signal["message"] || signal["text"] || signal["title"] || "element #{signal["selector"]} found"
          save_screenshot("error-signal")
          raise UserError, "Screen error detected: #{message}"
        end
      rescue UserError
        raise
      rescue StandardError
        # Don't let a failed error-signal check break the workflow
      end

      def current_url_value
        result = @session.send_command(
          "Runtime.evaluate",
          { expression: "window.location.href", returnByValue: true, awaitPromise: true },
          timeout: 5
        )
        handle_runtime_exception!("window.location.href", result)
        result.dig("result", "value").to_s
      end

      def runtime_call(function_source, *args)
        expression = "(#{function_source.strip})(#{args.map { |arg| JSON.generate(arg) }.join(', ')})"
        result = @session.send_command(
          "Runtime.evaluate",
          { expression: expression, returnByValue: true, awaitPromise: true },
          timeout: 10
        )
        handle_runtime_exception!(expression, result)
        result.dig("result", "value")
      end

      # Like runtime_call but injects DEEP_QUERY_FN so the function body can
      # call deepQuery(document, selector) to pierce nested shadow roots.
      def runtime_deep_call(function_source, *args)
        expression = <<~JS.strip
          (() => {
            #{DEEP_QUERY_FN}
            return (#{function_source.strip})(#{args.map { |a| JSON.generate(a) }.join(", ")});
          })()
        JS
        result = @session.send_command(
          "Runtime.evaluate",
          { expression: expression, returnByValue: true, awaitPromise: true },
          timeout: 10
        )
        handle_runtime_exception!(expression, result)
        result.dig("result", "value")
      end

      def handle_runtime_exception!(expression, result)
        return unless result["exceptionDetails"]

        description = result.dig("exceptionDetails", "exception", "description") ||
                      result.dig("exceptionDetails", "text") ||
                      "unknown error"
        raise UserError, "workflow JS failed for #{@source.key}: #{description} (expression=#{expression})"
      end

      # ─── Debug request recording ───

      MAX_ENTRIES_CAP    = 10_000
      MAX_BODY_BYTES_CAP = 4 * 1024 * 1024  # 4 MB

      DEFAULT_MAX_ENTRIES    = 200
      DEFAULT_MAX_BODY_BYTES = 64 * 1024  # 64 KB

      def start_recording(step)
        url_matches = Array(step.fetch("url_matches"))
        include_body = step.fetch("include_response_body", false)
        max_body = Integer(step.fetch("max_body_bytes", DEFAULT_MAX_BODY_BYTES))
        max_entries = Integer(step.fetch("max_entries", DEFAULT_MAX_ENTRIES))

        @stdout.puts "    [yml] record_requests: #{url_matches.size} pattern(s)"

        @context[:debug_request_log] ||= []
        @context[:debug_recording] ||= { url_patterns: [], include_body: false, max_body_bytes: max_body, max_entries: max_entries }

        rec = @context[:debug_recording]
        rec[:url_patterns].concat(url_matches)
        rec[:include_body] = true if include_body
        rec[:max_body_bytes] = [rec[:max_body_bytes], max_body].max
        rec[:max_entries] = [rec[:max_entries], max_entries].max

        install_network_listener!
        drain_network_events
      end

      def install_network_listener!
        return if @recording_installed
        @recording_installed = true
        @recording_event_idx = 0

        # Enable Network domain events (idempotent if already enabled).
        @session.send_command("Network.enable")
      end

      def drain_network_events
        rec = @context[:debug_recording]
        return unless rec

        events = @session.pending_events
        while @recording_event_idx < events.size
          event = events[@recording_event_idx]
          @recording_event_idx += 1
          method = event["method"]
          params = event["params"] || {}

          case method
          when "Network.requestWillBeSent"
            url = params.dig("request", "url").to_s
            request_id = params["requestId"]
            if rec[:url_patterns].any? { |pat| url.include?(pat) }
              record_request(request_id, params)
            end
          when "Network.responseReceived"
            url = params.dig("response", "url").to_s
            request_id = params["requestId"]
            if rec[:url_patterns].any? { |pat| url.include?(pat) }
              record_response(request_id, params)
            end
          when "Network.loadingFinished"
            request_id = params["requestId"]
            finalize_response_body(request_id)
          end
        end
      end

      def record_request(request_id, params)
        req = params["request"] || {}
        entry = {
          "request" => {
            "method" => req["method"],
            "url" => req["url"],
            "headers" => req["headers"],
            "body" => req["postData"]
          },
          "response" => nil,
          "timings" => {
            "started_at" => Time.now.iso8601
          },
          "_request_id" => request_id,
          "_needs_body" => false
        }

        log = @context[:debug_request_log]
        rec = @context[:debug_recording]
        log << entry

        # Ring buffer: drop oldest when over max_entries
        while log.size > rec[:max_entries]
          log.shift
        end
      end

      def record_response(request_id, params)
        log = @context[:debug_request_log]
        rec = @context[:debug_recording]
        entry = log.reverse_each.find { |e| e["_request_id"] == request_id }
        return unless entry

        resp = params["response"] || {}
        entry["response"] = {
          "status" => resp["status"],
          "headers" => resp["headers"]
        }

        if rec[:include_body]
          entry["_needs_body"] = true
        end
      end

      def finalize_response_body(request_id)
        rec = @context[:debug_recording]
        return unless rec&.dig(:include_body)

        log = @context[:debug_request_log]
        entry = log.reverse_each.find { |e| e["_request_id"] == request_id && e["_needs_body"] }
        return unless entry

        entry["_needs_body"] = false

        begin
          result = @session.send_command("Network.getResponseBody", { requestId: request_id }, timeout: 5)
          body = result["body"].to_s
          is_base64 = result["base64Encoded"] == true

          body = Base64.decode64(body) if is_base64

          max = rec[:max_body_bytes]
          if body.bytesize > max
            body = body.byteslice(0, max)
            entry["response"]["truncated"] = true
          end

          entry["response"]["body"] = body.force_encoding("UTF-8")
        rescue StandardError
          # CDP may fail to retrieve body (e.g. redirects) — skip silently
        end
      end

      def dump_recorded_requests(step)
        drain_network_events

        path = step.fetch("path")
        format = step.fetch("format", "ndjson")
        reset = step.fetch("reset", false)

        log = @context[:debug_request_log] || []

        # Strip internal tracking keys before writing
        clean_entries = log.map do |entry|
          entry.reject { |k, _| k.start_with?("_") }
        end

        require_relative "debug_request_writer"
        writer = DebugRequestWriter.new(path: path, format: format)
        writer.write(clean_entries)

        @stdout.puts "    [yml] dump_requests: wrote #{clean_entries.size} entries to #{path}"

        if reset
          @context[:debug_request_log] = []
        end
      end

      # ─── Interactive debug actions ───

      def pause_for_user(step)
        message = step.fetch("message")
        timeout_seconds = Integer(step.fetch("timeout"))

        unless @stdin.respond_to?(:tty?) && @stdin.tty?
          raise UserError, "pause: refusing to block on non-tty stdin"
        end

        @stderr.print(message)
        @stderr.print(" [press Enter to continue] ")
        @stderr.flush if @stderr.respond_to?(:flush)

        started = Time.now
        begin
          Timeout.timeout(timeout_seconds) { @stdin.gets }
        rescue Timeout::Error
          raise UserError, "pause: timed out after #{timeout_seconds}s"
        end

        elapsed = (Time.now - started).round(1)
        @stdout.puts "    [yml] pause: resumed after #{elapsed}s"
      end

      def capture_current_url(step)
        as_key = step.fetch("as")
        url = current_url_value
        @context[as_key.to_s] = url
        @stdout.puts "    [yml] capture_url: → ctx.#{as_key}"
      end

      def resolved(value)
        @secret_resolver.resolve_value(source: @source, schema: @schema, value: value)
      end

      FILL_LOOKUP_JS = <<~'JS'.freeze
        (selector) => {
          const el = deepQuery(document, selector);
          if (!el) return false;
          el.focus();
          el.click();
          return true;
        }
      JS

      FILL_LOOKUP_WITH_CLEAR_JS = <<~'JS'.freeze
        (selector) => {
          const el = deepQuery(document, selector);
          if (!el) return false;
          if (!(el instanceof HTMLInputElement) && !(el instanceof HTMLTextAreaElement)) {
            return 'not-a-text-input';
          }
          const proto = el instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, '');
          el.dispatchEvent(new Event('input',  { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          el.focus();
          el.click();
          return true;
        }
      JS

      def fill_lookup_js
        FILL_LOOKUP_JS
      end

      def fill_lookup_with_clear_js
        FILL_LOOKUP_WITH_CLEAR_JS
      end

      def step_condition_met?(step)
        gate = step["when_context"]
        return true if gate.nil? || gate.empty?

        gate.all? do |key, ops|
          actual = resolve_context_value(key)
          ops.all? { |op, operand| compare_context(actual, op, operand, key) }
        end
      end

      def resolve_context_value(key)
        if @runtime_context.key?(key.to_sym)
          @runtime_context[key.to_sym]
        elsif @runtime_context.key?(key.to_s)
          @runtime_context[key.to_s]
        else
          @context[key.to_s] || @context[key.to_sym]
        end
      end

      def compare_context(actual, op, operand, key)
        case op
        when "gt"      then numeric!(actual, key) >  numeric!(operand, key)
        when "gte"     then numeric!(actual, key) >= numeric!(operand, key)
        when "lt"      then numeric!(actual, key) <  numeric!(operand, key)
        when "lte"     then numeric!(actual, key) <= numeric!(operand, key)
        when "eq"      then actual == operand
        when "neq"     then actual != operand
        when "present" then operand == true ? !actual.nil? : actual.nil?
        when "absent"  then operand == true ? actual.nil? : !actual.nil?
        else
          raise UserError, "when_context: unknown operator #{op.inspect} on key #{key.inspect}"
        end
      end

      def numeric!(val, key)
        return val if val.is_a?(Numeric)
        raise UserError, "when_context: key #{key.inspect} requires a numeric value, got #{val.inspect}"
      end
    end
  end
