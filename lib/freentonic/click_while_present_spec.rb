# frozen_string_literal: true

require_relative "errors"

module Freentonic
  # Validation + normalization for the `click_while_present` step, shared by
  # WorkflowSchema (at load, so a bad option fails before login/2FA instead
  # of mid-run) and BrowserWorkflowRunner (at run, for workflows built in
  # code). One definition, so the two can't drift.
  #
  #   - action: click_while_present
  #     selector: "button[data-testid='load-more']"
  #     max_clicks: 100              # required, 1..1000
  #     settle_seconds: 2            # 1..60
  #     on_max_clicks: fail          # fail (default) | warn
  #     wait_for_response:           # optional: what each click fetches
  #       url_includes: ["op=getPage"]
  #       timeout_seconds: 20        # 1..120
  #     stop_when_older_than_lookback:
  #       url_includes: ["op=getFirstPage", "op=getPage"]
  #       items_paths: ["data.page.items", "data.first.modules.*.items"]
  #       timestamp_field: timestamp
  #       timestamp_unit: ms         # ms (default) | s
  #       items_where: { type: TRANSACTION }
  #       margin_hours: 0            # 0..168
  module ClickWhilePresentSpec
    MAX_CLICKS_LIMIT = 1000
    SETTLE_RANGE = (1..60)
    RESPONSE_TIMEOUT_RANGE = (1..120)
    MARGIN_HOURS_RANGE = (0..168)

    STEP_KEYS = %w[selector max_clicks settle_seconds on_max_clicks wait_for_response stop_when_older_than_lookback].freeze
    RESPONSE_KEYS = %w[url_includes timeout_seconds].freeze
    STOP_KEYS = %w[url_includes items_paths timestamp_field timestamp_unit items_where margin_hours].freeze

    module_function

    # Returns the normalized spec or raises UserError naming `loc`.
    def validate!(step, loc)
      unknown = step.keys - STEP_KEYS - WorkflowActions::UNIVERSAL_KEYS
      fail!(loc, "unknown option(s) #{unknown.join(", ")}") unless unknown.empty?

      selector = step["selector"]
      fail!(loc, "selector: must be a non-empty string") unless selector.is_a?(String) && !selector.empty?

      {
        selector: selector,
        max_clicks: int!(step["max_clicks"], 1..MAX_CLICKS_LIMIT, "#{loc}.max_clicks"),
        settle_seconds: step.key?("settle_seconds") ? int!(step["settle_seconds"], SETTLE_RANGE, "#{loc}.settle_seconds") : 2,
        on_max_clicks: on_max_clicks!(step.fetch("on_max_clicks", "fail"), loc),
        wait_for_response: step["wait_for_response"] && response!(step["wait_for_response"], "#{loc}.wait_for_response"),
        stop: step["stop_when_older_than_lookback"] && stop!(step["stop_when_older_than_lookback"], "#{loc}.stop_when_older_than_lookback")
      }
    end

    def response!(spec, loc)
      fail!(loc, "must be a hash") unless spec.is_a?(Hash)
      extra = spec.keys - RESPONSE_KEYS
      fail!(loc, "unknown key(s) #{extra.join(", ")}") unless extra.empty?

      {
        url_includes: strings!(spec["url_includes"], "#{loc}.url_includes"),
        timeout_seconds: spec.key?("timeout_seconds") ? int!(spec["timeout_seconds"], RESPONSE_TIMEOUT_RANGE, "#{loc}.timeout_seconds") : 20
      }
    end

    def stop!(spec, loc)
      fail!(loc, "must be a hash") unless spec.is_a?(Hash)
      extra = spec.keys - STOP_KEYS
      fail!(loc, "unknown key(s) #{extra.join(", ")}") unless extra.empty?

      unit = spec.fetch("timestamp_unit", "ms")
      fail!("#{loc}.timestamp_unit", "must be ms or s (got #{unit.inspect})") unless %w[ms s].include?(unit)
      where = spec.fetch("items_where", {})
      unless where.is_a?(Hash) && where.all? { |k, v| k.is_a?(String) && (v.is_a?(String) || v.is_a?(Numeric) || [true, false].include?(v)) }
        fail!("#{loc}.items_where", "must map field names to literal values")
      end
      field = spec.fetch("timestamp_field", "timestamp")
      fail!("#{loc}.timestamp_field", "must be a non-empty string") unless field.is_a?(String) && !field.empty?

      {
        url_includes: strings!(spec["url_includes"], "#{loc}.url_includes"),
        items_paths: strings!(spec["items_paths"], "#{loc}.items_paths"),
        timestamp_field: field,
        timestamp_unit: unit,
        items_where: where,
        margin_hours: spec.key?("margin_hours") ? int!(spec["margin_hours"], MARGIN_HOURS_RANGE, "#{loc}.margin_hours") : 0
      }
    end

    def on_max_clicks!(value, loc)
      fail!("#{loc}.on_max_clicks", "must be fail or warn (got #{value.inspect})") unless %w[fail warn].include?(value)
      value
    end

    def int!(value, range, loc)
      unless value.is_a?(Integer) && range.cover?(value)
        fail!(loc, "must be an integer between #{range.min} and #{range.max} (got #{value.inspect})")
      end
      value
    end

    def strings!(value, loc)
      unless value.is_a?(Array) && !value.empty? && value.all? { |v| v.is_a?(String) && !v.empty? }
        fail!(loc, "must be a non-empty list of strings")
      end
      value
    end

    def fail!(loc, message)
      raise UserError, "#{loc}: #{message}"
    end
  end
end
