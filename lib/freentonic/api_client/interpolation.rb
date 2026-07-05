# frozen_string_literal: true

require "date"

module Freentonic
  class ApiClient
    # Template interpolation for path templates and request-parameter
    # hashes. Mixed into ApiClient as private instance methods so that
    # `{name|date}` can reach the instance's `format_date` (declared via
    # the `date_format` macro).
    #
    # Token grammar (a value is a token only if it is a String matching
    # `\A\{…\}\z` exactly — everything else is a literal):
    #   {offset}     → the pagination offset integer
    #   {name}       → kwargs[:name]
    #   {name|date}  → format_date(kwargs[:name])  (workflow's date_format)
    #   {name|iso}   → kwargs[:name] as yyyy-mm-dd, regardless of date_format
    module Interpolation
      # Replace {name} tokens in a path template with values from kwargs.
      def ep_interpolate_path(template, kwargs)
        template.gsub(/\{(\w+)\}/) do
          kwargs.fetch($1.to_sym) { raise ArgumentError, "missing :#{$1} for path #{template}" }
        end
      end

      # Resolve a hash whose values may contain {name} / {name|date} / {offset} tokens.
      def ep_interpolate_hash(template_hash, kwargs, offset: nil)
        template_hash.each_with_object({}) do |(k, v), h|
          resolved = ep_interpolate_val(v, kwargs, offset: offset)
          h[k.to_sym] = resolved unless resolved.nil?
        end
      end

      # Resolve a single template value. See the module doc for the grammar.
      def ep_interpolate_val(val, kwargs, offset: nil)
        return val unless val.is_a?(String) && val.match?(/\A\{[^}]+\}\z/)
        inner = val[1..-2]
        return offset if inner == "offset"
        name, filter = inner.split("|", 2)
        raw = kwargs[name.to_sym]
        case filter
        when "date" then format_date(raw)
        when "iso"  then ep_format_iso(raw)
        else raw
        end
      end

      def ep_format_iso(raw)
        return nil if raw.nil?
        d = raw.is_a?(Date) ? raw : Date.parse(raw.to_s)
        d.strftime("%Y-%m-%d")
      end

      def ep_dig_path(source, path)
        return nil if path.nil? || source.nil?
        path.to_s.split(".").inject(source) do |acc, key|
          next nil unless acc.is_a?(Hash)
          acc[key]
        end
      end

      def ep_symbolize_keys(h)
        h.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
      end
    end
  end
end
