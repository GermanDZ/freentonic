# frozen_string_literal: true

require "json"

module Freentonic
  # On-demand structured page observation — text, not pixels.
  #
  # Runs `page_observer/observe.js` (concatenated after DEEP_QUERY_FN and the
  # shared selector heuristics) through a single `Runtime.evaluate`, parses
  # the returned JSON, and hands back a plain Hash:
  #
  #   { "url" => ..., "title" => ..., "interactive" => [ {tag, selector, ...}, ... ] }
  #
  # SECURITY: the observer NEVER surfaces an element's value. observe.js only
  # emits a `masked` flag for inputs, and #normalize additionally whitelists
  # element keys as defense in depth so a value could not leak even if the
  # injected source were tampered with. Selectors and labels are metadata,
  # safe to persist next to run logs (that is what `inspect_page` and
  # failures.ndjson rely on).
  module PageObserver
    SHARED_SELECTORS_PATH = File.expand_path("recorder/selectors.js", __dir__)
    OBSERVE_JS_PATH       = File.expand_path("page_observer/observe.js", __dir__)

    SHARED_SELECTORS_JS = File.read(SHARED_SELECTORS_PATH).freeze
    OBSERVE_JS          = File.read(OBSERVE_JS_PATH).freeze

    # The only element keys allowed to leave the page. Notably absent:
    # anything that could carry a field's value.
    ALLOWED_ELEMENT_KEYS = %w[
      tag selector selector_strategy needs_review text role href type label masked
    ].freeze

    module_function

    # Observe `session` (a CDP session duck-type responding to
    # #send_command). Returns the normalized Hash described above. Raises
    # only on a JSON parse failure of a genuinely malformed response — the
    # caller (failures.ndjson) wraps this in its own rescue.
    def observe(session)
      raw = evaluate(session)
      parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
      normalize(parsed)
    end

    def evaluate(session)
      result = session.send_command(
        "Runtime.evaluate",
        { expression: expression, returnByValue: true, awaitPromise: true },
        timeout: 10
      )
      result && result.dig("result", "value")
    end

    # Injected exactly like runtime_deep_call (invariant 2): DEEP_QUERY_FN is
    # concatenated in, the whole thing is a self-invoking arrow, and there
    # are no runtime arguments to interpolate. observe.js returns a JSON
    # string.
    def expression
      <<~JS.strip
        (() => {
          #{Freentonic::BrowserWorkflowRunner::DEEP_QUERY_FN}
          #{SHARED_SELECTORS_JS}
          return #{OBSERVE_JS.strip};
        })()
      JS
    end

    def normalize(parsed)
      return empty unless parsed.is_a?(Hash)

      interactive = parsed["interactive"] || parsed[:interactive] || []
      {
        "url"         => parsed["url"] || parsed[:url],
        "title"       => parsed["title"] || parsed[:title],
        "interactive" => Array(interactive).filter_map { |el| sanitize_element(el) }
      }
    end

    # Whitelist element keys — anything not in ALLOWED_ELEMENT_KEYS (a stray
    # `value`, say) is dropped before it can reach a log or a file.
    def sanitize_element(el)
      return nil unless el.is_a?(Hash)

      el.each_with_object({}) do |(k, v), out|
        key = k.to_s
        out[key] = v if ALLOWED_ELEMENT_KEYS.include?(key)
      end
    end

    def empty
      { "url" => nil, "title" => nil, "interactive" => [] }
    end
  end
end
