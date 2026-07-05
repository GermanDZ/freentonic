# frozen_string_literal: true

require_relative "../timestamp_ms"

module Freentonic
  class ApiClient
    # Declarative cursor pagination driven by a YAML `pagination:` spec.
    # Mixed into ApiClient as private instance methods; depends on
    # Interpolation (ep_interpolate_*, ep_dig_path, ep_symbolize_keys) and
    # the instance's `pagination_sleep`.
    module CursorPagination
      # Declarative cursor pagination driven by a YAML spec. Each iteration:
      #
      #   1. Merge initial_kwargs (first call only) or continue_kwargs
      #      (subsequent calls) into the caller's kwargs, plus any cursor
      #      values extracted from the previous response.
      #   2. Interpolate the request_template and dispatch.
      #   3. Extract the batch and accumulate; an empty batch stops the
      #      loop unconditionally.
      #   4. Evaluate continue_when against the raw response (envelope
      #      flavor) or the new cursor value (cursor_gt flavor) — if it
      #      doesn't hold, stop.
      #   5. Extract the next cursor field values via dotted paths into
      #      the response (cursor_from_response) and/or alias chains on
      #      the last batch row (cursor_from_last_row). Any required
      #      field coming back nil stops the loop. A cycle (new cursor
      #      == previous cursor) also stops, matching paginate_by_cursor.
      #
      # Safety cap defaults to 10_000 rows; YAML may override via `max:`.
      def ep_paginate_by_cursor(spec:, kwargs:, request_template:, dispatch:, extract_batch:)
        cap             = (spec["max"] || spec[:max] || 10_000).to_i
        initial_kwargs  = ep_symbolize_keys(spec["initial_kwargs"] || spec[:initial_kwargs] || {})
        cont_kwargs     = ep_symbolize_keys(spec["continue_kwargs"] || spec[:continue_kwargs] || {})
        env_decls       = spec["cursor_from_response"] || spec[:cursor_from_response] || {}
        row_decls       = spec["cursor_from_last_row"] || spec[:cursor_from_last_row] || {}
        cont_when       = spec["continue_when"] || spec[:continue_when]
        initial_kwargs  = ep_resolve_runtime_tokens(initial_kwargs, kwargs)

        all           = []
        iteration     = 0
        cursor_kwargs = {}
        loop do
          merged = kwargs.dup
          merged.merge!(initial_kwargs) if iteration.zero?
          merged.merge!(cont_kwargs)    if iteration.positive?
          merged.merge!(cursor_kwargs)

          resolved = ep_interpolate_hash(request_template, merged)
          response = dispatch.call(resolved)
          batch    = extract_batch.call(response)

          break if !batch.is_a?(Array) || batch.empty?
          all.concat(batch)
          break if all.size >= cap

          next_cursor = {}
          next_cursor.merge!(ep_extract_cursor_fields(env_decls, response))
          next_cursor.merge!(ep_extract_cursor_fields_from_row(row_decls, batch.last))

          # Any required cursor field that came back nil → stop. Mirrors
          # the defensive nil-checks providers were writing by hand
          # ("masMovimientos cursor incomplete; stopping").
          break if !next_cursor.empty? && next_cursor.values.any?(&:nil?)

          # Cycle detection: if the cursor didn't move forward, stop.
          # Catches both server-side bugs (same cursor twice) and
          # legitimate end-of-feed signals (the timestamp-cursor case
          # where the last row's timestamp >= the cursor we just sent).
          break if !next_cursor.empty? && next_cursor == cursor_kwargs

          if cont_when && !ep_cursor_continue_when?(cont_when, response, next_cursor, kwargs)
            break
          end

          cursor_kwargs = next_cursor
          iteration += 1
          pagination_sleep
        end
        all
      end

      # Evaluate the continue_when block. Two supported shapes:
      #
      #   1. Envelope path equality (envelope-cursor flavor):
      #        { "response_path" => "a.b.c", "equals" => "S" }
      #      Compared as strings so YAML scalars round-trip cleanly.
      #
      #   2. Cursor-value lower bound (row-cursor flavor):
      #        { "cursor_gt" => { "field" => "to", "value" => "{from_ms}" } }
      #      Continues as long as the new cursor's value (Numeric) is
      #      strictly greater than the kwarg value the caller supplied
      #      (also Numeric). Equality stops — once the cursor would
      #      walk past the lookback boundary, the loop terminates.
      def ep_cursor_continue_when?(spec, response, next_cursor = {}, kwargs = {})
        if (gt = spec["cursor_gt"] || spec[:cursor_gt])
          field  = gt["field"] || gt[:field]
          token  = gt["value"] || gt[:value]
          new_v  = next_cursor[field.to_sym]
          bound  = ep_interpolate_val(token, kwargs)
          return true if new_v.nil? || bound.nil?
          return new_v.to_f > bound.to_f
        end

        path  = spec["response_path"] || spec[:response_path]
        value = spec["equals"]        || spec[:equals]
        return true if path.nil? || value.nil?
        ep_dig_path(response, path).to_s == value.to_s
      end

      def ep_extract_cursor_fields(decls, response)
        decls.each_with_object({}) do |(kwarg_name, source), h|
          path = case source
                 when Hash then source["from_response"] || source[:from_response]
                 else           source
                 end
          h[kwarg_name.to_sym] = ep_dig_path(response, path)
        end
      end

      # Last-row cursor extraction with an alias chain + coercion. Each
      # decl looks like:
      #
      #   { "fields" => [a, b, c], "coerce" => "timestamp_ms" }
      #
      # `fields` is walked in order; the first non-nil value wins.
      # `coerce` is optional — currently only "timestamp_ms" is
      # supported (Numeric passthrough, String parsed via TimestampMs).
      def ep_extract_cursor_fields_from_row(decls, last_row)
        return {} if decls.nil? || decls.empty? || !last_row.is_a?(Hash)
        decls.each_with_object({}) do |(kwarg_name, source), h|
          fields = source["fields"] || source[:fields] || []
          coerce = source["coerce"] || source[:coerce]
          raw    = Array(fields).lazy.map { |f| last_row[f.to_s] }.find { |v| !v.nil? }
          h[kwarg_name.to_sym] = case coerce.to_s
                                 when "timestamp_ms" then TimestampMs.parse(raw)
                                 else                     raw
                                 end
        end
      end

      # Resolve runtime-only tokens in a kwargs hash. Currently:
      #   {now_ms} — current Unix time in milliseconds (Integer).
      # All other token shapes are resolved by the normal interpolation
      # pipeline (ep_interpolate_val) against the caller's kwargs, so
      # initial_kwargs: { to: "{from_ms}" } also Just Works when
      # from_ms is a caller kwarg.
      def ep_resolve_runtime_tokens(kwargs_hash, caller_kwargs)
        kwargs_hash.each_with_object({}) do |(k, v), h|
          h[k] = if v.is_a?(String) && v == "{now_ms}"
                   (Time.now.to_f * 1000).to_i
                 elsif v.is_a?(String) && v =~ /\A\{[^}]+\}\z/
                   ep_interpolate_val(v, caller_kwargs)
                 else
                   v
                 end
        end
      end
    end
  end
end
