# frozen_string_literal: true

require "json"

module Freentonic
    class BrowserWorkflowRunner
      WAIT_STEP_SECONDS = 0.2

      # Injected into deep-query expressions so selectors cross shadow roots.
      DEEP_QUERY_FN = <<~'JS'.freeze
        function deepQuery(root, sel) {
          const el = root.querySelector(sel);
          if (el) return el;
          for (const child of root.querySelectorAll('*')) {
            if (child.shadowRoot) {
              const r = deepQuery(child.shadowRoot, sel);
              if (r) return r;
            }
          }
          return null;
        }
      JS

      def initialize(source:, session:, schema:, context:, secret_resolver:, session_drainer:, stdout:, stderr:)
        @source = source
        @session = session
        @schema = schema
        @context = context
        @secret_resolver = secret_resolver
        @session_drainer = session_drainer
        @stdout = stdout
        @stderr = stderr
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
        action = step.fetch("action")

        case action
        when "note"
          @stdout.puts "    #{resolved(step.fetch("message"))}"
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
        when "fill"
          @stdout.puts "    [yml] fill: #{step.fetch("selector")}"
          fill_selector(step.fetch("selector"), step.fetch("value"), optional: false)
        when "fill_if_present"
          @stdout.puts "    [yml] fill_if_present: #{step.fetch("selector")}"
          fill_selector(step.fetch("selector"), step.fetch("value"), optional: true)
        when "enter_digits"
          count = Array(step.fetch("digits")).size
          @stdout.puts "    [yml] enter_digits: #{count} digit(s) in #{step.fetch("keypad")}"
          enter_digits(step.fetch("digits"), keypad: step.fetch("keypad"))
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

          if Time.now - last_dot >= 2
            @stdout.print "."
            @stdout.flush if @stdout.respond_to?(:flush)
            last_dot = Time.now
          end
          sleep WAIT_STEP_SECONDS
        end

        @stdout.puts
        raise UserError, "workflow wait_url timed out waiting for #{expected_fragment.inspect}"
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

      def fill_selector(selector, value, optional: false)
        found = runtime_deep_call(<<~JS, selector)
          (selector) => {
            const el = deepQuery(document, selector);
            if (!el) return false;
            el.focus();
            el.click();
            return true;
          }
        JS
        unless found
          return if optional
          raise UserError, "workflow fill could not find selector #{selector.inspect}"
        end

        # Simulate human typing: dispatch each character individually via CDP
        # with a variable inter-keystroke delay so it looks organic to the page.
        resolved(value).each_char do |char|
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

      def wait_for_selector(selector, timeout:)
        deadline = Time.now + timeout
        last_dot = Time.now
        while Time.now < deadline
          return if runtime_deep_call(<<~JS, selector)
            (selector) => deepQuery(document, selector) !== null
          JS

          if Time.now - last_dot >= 2
            @stdout.print "."
            @stdout.flush if @stdout.respond_to?(:flush)
            last_dot = Time.now
          end
          sleep WAIT_STEP_SECONDS
        end

        @stdout.puts
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

          if Time.now - last_dot >= 2
            @stdout.print "."
            @stdout.flush if @stdout.respond_to?(:flush)
            last_dot = Time.now
          end
          sleep WAIT_STEP_SECONDS
        end

        @stdout.puts
        raise UserError, "workflow wait_for_first_of timed out waiting for any of #{selectors.inspect}"
      end

      def wait_for_shadow_selector(host_selector, selector, timeout:)
        deadline = Time.now + timeout
        last_dot = Time.now
        while Time.now < deadline
          return if runtime_shadow_eval(host_selector, <<~JS, selector)
            (shadowRoot, sel) => shadowRoot.querySelector(sel) !== null
          JS

          if Time.now - last_dot >= 2
            @stdout.print "."
            @stdout.flush if @stdout.respond_to?(:flush)
            last_dot = Time.now
          end
          sleep WAIT_STEP_SECONDS
        end

        @stdout.puts
        raise UserError, "workflow wait_for_shadow_selector timed out waiting for #{selector.inspect} in #{host_selector.inspect}"
      end

      def enter_pin_pad(selector, pin)
        full_pin = resolved(pin).gsub(/\D/, "")

        # findInTree / findAllInTree recurse into nested shadow roots.
        # Must use <<~'JS' (non-interpolating heredoc) so Ruby doesn't drop
        # backslashes — \d in a <<~JS heredoc becomes d (unknown escape silently
        # stripped), which turns JS digit-regexes into letter-d matchers.
        tree_helpers = <<~'JS'
          function findInTree(root, predicate) {
            for (const el of root.querySelectorAll('*')) {
              if (predicate(el)) return el;
              if (el.shadowRoot) {
                const found = findInTree(el.shadowRoot, predicate);
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

      def resolved(value)
        @secret_resolver.resolve_value(source: @source, schema: @schema, value: value)
      end
    end
  end
