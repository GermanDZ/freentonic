require "date"
require "time"

module Freentonic
  module Providers
    module Helpers
      # Wrap a non-critical fetch so one failing product doesn't sink
      # the whole run. Returns nil on error.
      #
      #   bank_details = safe_fetch(stderr, "bank details") { client.fetch_bank_details }
      #
      def safe_fetch(stderr, label)
        yield
      rescue StandardError => error
        stderr.puts "    ✗ #{label}: #{error.class}: #{error.message}"
        nil
      end

      # Convert an amount to integer cents. Handles the formats seen
      # across providers:
      #
      #   cents(12.34)                              #=> 1234   (major units → cents)
      #   cents(1234, already_minor: true)          #=> 1234   (already cents)
      #   cents({"amount" => 12.34})                #=> 1234   (Hash with amount key)
      #   cents("12,34")                            #=> 1234   (String with comma)
      #   cents(nil)                                #=> nil
      #
      def cents(amount, already_minor: false)
        return nil if amount.nil?

        case amount
        when Hash
          value = (amount["amount"] || amount["value"] || amount["cantidad"] || amount["importe"])&.to_f
          value ? (value * 100).round : nil
        when Numeric
          already_minor ? amount.to_i : (amount.to_f * 100).round
        when String
          (amount.tr(",", ".").to_f * 100).round
        end
      end

      # Parse a date from various formats seen across providers.
      # Returns a Date or nil.
      #
      #   parse_date(1710504000000)                  #=> Date (Unix ms)
      #   parse_date("2024-03-15T10:00:00.000Z")    #=> Date (ISO 8601)
      #   parse_date("15/03/2024")                   #=> Date (DD/MM/YYYY)
      #   parse_date("2024-03-15")                   #=> Date (YYYY-MM-DD)
      #   parse_date(nil)                            #=> nil
      #
      # `preferred_formats:` is a list of strptime patterns to try first
      # (in order) when the input is a String that isn't a Unix timestamp.
      # Useful when the provider's dominant date format would otherwise
      # be mis-parsed — e.g. Spanish-locale "05/06/2024" means 5 June,
      # not the ISO-ish 6 May that Date.parse would infer without a hint.
      # Non-matching patterns are skipped silently; if every pattern
      # misses, falls through to the generic Date.parse path.
      #
      #   parse_date("05/06/2024", preferred_formats: ["%d/%m/%Y"])
      #   #=> Date.new(2024, 6, 5)
      #
      def parse_date(value, preferred_formats: nil)
        return nil if value.nil?

        case value
        when Date
          value
        when Numeric
          # Unix timestamp — detect seconds vs milliseconds.
          # Timestamps after year 3000 in seconds (~32503680000) are
          # implausible, so anything above 10^12 is milliseconds.
          ts = value > 1_000_000_000_000 ? value / 1000.0 : value.to_f
          Time.at(ts).to_date
        when String
          if value =~ /\A\d{10,13}\z/
            # Numeric string (Unix timestamp)
            ts = value.to_i
            ts = ts / 1000 if ts > 1_000_000_000_000
            Time.at(ts).to_date
          else
            Array(preferred_formats).each do |fmt|
              begin
                return Date.strptime(value, fmt)
              rescue Date::Error, ArgumentError
                next
              end
            end
            Date.parse(value)
          end
        end
      rescue ArgumentError, TypeError
        # Back-compat fallback for callers that don't pass preferred_formats
        # but hit a DD/MM/YYYY input.
        begin
          Date.strptime(value.to_s, "%d/%m/%Y")
        rescue Date::Error, ArgumentError
          nil
        end
      end

      # Pluck and rename fields from a source hash according to a
      # declarative mapping. Each mapping entry's value is one of:
      #
      #   "fieldname"               — copy `source["fieldname"]` as-is.
      #   "outer.inner"             — dotted-path nested lookup; equivalent
      #                               to source.dig("outer", "inner").
      #   ["a", "b", "c"]           — fallback chain, returns the first
      #                               non-nil dotted-path lookup.
      #
      # Output values are whatever the lookup returned (no type coercion).
      # Missing paths produce nil entries (NOT dropped — the output hash
      # always has every mapping key, with nil where the source didn't
      # provide a value). That matches what providers want for raw_payload
      # / metadata allowlists, where stable column-set is more useful than
      # compact-but-variable shapes.
      #
      # Intended usage from a provider's normalizer:
      #
      #   metadata: { "ing" => extract_fields(mv, RAW_FIELDS_MOVEMENT) }
      #
      # …with RAW_FIELDS_MOVEMENT auto-defined by NormalizerBase from
      # `raw_fields_movement` in <provider>/config.yml.
      #
      def extract_fields(source, mapping)
        return {} unless source.is_a?(Hash)

        mapping.each_with_object({}) do |(out_key, spec), acc|
          acc[out_key.to_s] = case spec
                              when String
                                dig_path(source, spec)
                              when Array
                                spec.lazy.map { |p| dig_path(source, p) }.find { |v| !v.nil? }
                              else
                                nil
                              end
        end
      end

      # Parse a value to a Unix millisecond timestamp. Useful for
      # cursor-based pagination where the API expects ms timestamps.
      #
      #   parse_timestamp_ms(1710504000000)                  #=> 1710504000000
      #   parse_timestamp_ms("2024-03-15T10:00:00.000Z")    #=> 1710504000000
      #
      def parse_timestamp_ms(value)
        case value
        when Numeric
          value > 1_000_000_000_000 ? value.to_i : (value * 1000).to_i
        when String
          if value =~ /\A\d+\z/
            v = value.to_i
            v > 1_000_000_000_000 ? v : v * 1000
          else
            (Time.parse(value).to_f * 1000).to_i
          end
        end
      rescue ArgumentError, TypeError
        nil
      end

      # Return the first candidate that is a non-empty stripped string;
      # nil if none qualify. Common provider pattern for picking a
      # display name out of (alias, name, description, fallback).
      #
      #   first_present(account["alias"], account["name"], "Bank")
      #   #=> "Cuenta Naranja"  (or "Bank" if both alias and name are blank)
      #
      def first_present(*candidates)
        candidates.each do |c|
          s = c.to_s.strip
          return s unless s.empty?
        end
        nil
      end

      # Extract the last 4 digits of a card number for use in a card-account
      # portable_ref ("BANKID:LAST4"). Tolerates the masking patterns banks
      # actually emit:
      #
      #   pan_last4("**** **** **** 8619")   #=> "8619"
      #   pan_last4("XXXX-XXXX-XXXX-8619")   #=> "8619"
      #   pan_last4("4123 56** **** 8619")   #=> "8619"
      #   pan_last4("5234567890128619")      #=> "8619"   (full PAN)
      #   pan_last4("8619")                  #=> "8619"   (already last-4)
      #   pan_last4(nil)                     #=> nil
      #   pan_last4("****")                  #=> nil      (no digits)
      #   pan_last4("123")                   #=> nil      (<4 digits)
      #
      # Strategy: strip everything non-digit, take the last 4 if at least 4
      # digits remain. Caller is responsible for passing a PAN-shaped
      # string — this helper does not validate that the digits *are* a PAN
      # (e.g. passing "2026-04-27" would return "0427"). When the upstream
      # field for a given card is nil/blank/opaque, the helper returns nil
      # and the normalizer should fall back to the source_id-based id
      # rather than emit a portable_ref derived from garbage.
      def pan_last4(value)
        return nil if value.nil?
        digits = value.to_s.gsub(/\D/, "")
        return nil if digits.length < 4
        digits[-4, 4]
      end

      private

      # Walk a dotted path into a nested hash, returning nil at the first
      # missing segment. "a.b.c" → source["a"]["b"]["c"], with bail-out
      # if any intermediate is not a Hash.
      def dig_path(source, path)
        path.to_s.split(".").inject(source) do |acc, key|
          acc.is_a?(Hash) ? acc[key] : nil
        end
      end
    end
  end
end
