require "date"
require "time"
require_relative "../timestamp_ms"
require_relative "timezone"

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
      # misses, falls through to the generic parse path.
      #
      #   parse_date("05/06/2024", preferred_formats: ["%d/%m/%Y"])
      #   #=> Date.new(2024, 6, 5)
      #
      # Timezone handling. The canonical model stores a calendar Date, so
      # the only question a timezone answers is which zone's calendar day an
      # *instant* falls on. Both zones default to UTC — so absent config the
      # result is deterministic and machine-independent (never the process's
      # local TZ, which the old Time.at(ts).to_date silently used):
      #   - output_timezone: buckets any absolute instant (a Unix timestamp,
      #     or an offset-bearing datetime like "…Z" / "…-05:00") into its
      #     calendar day. This is the display/booking zone.
      #   - input_timezone: interprets an offset-*naive* datetime string
      #     ("2024-03-15 23:30:00", no offset) as local time in that zone
      #     before bucketing. Irrelevant to date-only strings and to inputs
      #     that already carry an instant.
      # Date-only inputs (a Date, "2024-03-15", a %d/%m/%Y match) have no
      # time component, so no zone applies — they pass through as written.
      #
      #   parse_date(1710457200000, output_timezone: "+01:00") #=> 2024-03-15
      #   parse_date(1710457200000)                            #=> 2024-03-14 (UTC)
      #
      def parse_date(value, preferred_formats: nil, input_timezone: nil, output_timezone: nil)
        return nil if value.nil?

        case value
        when Date
          value
        when Numeric
          Timezone.to_date_in(Time.at(unix_seconds(value)), output_timezone)
        when String
          parse_date_string(value, preferred_formats, input_timezone, output_timezone)
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
        TimestampMs.parse(value)
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

      # Resolve a logical field name to its first non-nil value in a
      # source Hash, walking an alias chain declared in the provider's
      # config.yml `field_aliases:` block. The mapping auto-binds to
      # the class constant FIELD_ALIASES via Configurable.
      #
      #   # config.yml
      #   field_aliases:
      #     iban:    [iban, IBAN]
      #     date:    [fechaOperacion, fechaoper, fechaValor, fechavalor, fecha]
      #     balance: [saldo, saldoActual, saldoDisponible, balance]
      #
      #   # normalizer.rb
      #   pick(:iban, account_row)          #=> first non-nil of iban / IBAN
      #   pick(:date, movement_row)         #=> first non-nil of the 5 keys
      #
      # `aliases:` lets callers pass an explicit list when they don't
      # want to rely on the class constant (mostly useful in tests).
      # Nil semantics match the `||` chains this helper replaces: only
      # nil is treated as "missing" — empty strings pass through, so
      # provider knowledge about empty-string handling stays at the
      # call site.
      #
      # Returns nil when FIELD_ALIASES isn't defined, the logical key
      # isn't in the map, or no aliased key has a non-nil value.
      def pick(logical_key, source, aliases: nil)
        return nil unless source.is_a?(Hash)
        map = aliases
        if map.nil?
          klass = self.class
          map = klass.const_get(:FIELD_ALIASES, true) if klass.const_defined?(:FIELD_ALIASES, true)
        end
        return nil unless map.is_a?(Hash)
        list = map[logical_key.to_s]
        return nil if list.nil?
        Array(list).each do |k|
          v = source[k.to_s]
          return v unless v.nil?
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
      # Also reachable as Freentonic::Providers::Helpers.pan_last4 so the
      # Builder (a module_function-style namespace) can defer to a single
      # implementation instead of duplicating the regex.
      module_function :pan_last4

      private

      # Unix timestamp → seconds (Float). Detect seconds vs milliseconds:
      # timestamps after year 3000 in seconds (~32_503_680_000) are
      # implausible, so anything above 10^12 is milliseconds.
      def unix_seconds(value)
        n = value.to_f
        n > 1_000_000_000_000 ? n / 1000.0 : n
      end

      # Parse a String date, applying timezone rules only to the shapes that
      # carry an instant. Order: Unix numeric string → preferred strptime
      # formats (date-only) → generic, classified by Date._parse.
      def parse_date_string(value, preferred_formats, input_tz, output_tz)
        if value =~ /\A\d{10,13}\z/
          return Timezone.to_date_in(Time.at(unix_seconds(value)), output_tz)
        end

        Array(preferred_formats).each do |fmt|
          begin
            return Date.strptime(value, fmt) # date-only pattern → no zone
          rescue Date::Error, ArgumentError
            next
          end
        end

        parse_generic_date(value, input_tz, output_tz)
      end

      # Classify an ISO-ish string by what Date._parse recovers:
      #   - no hour            → date-only; the calendar day as written.
      #   - hour + offset      → an absolute instant; bucket in output_tz.
      #   - hour, no offset    → a naive datetime; interpret the wall clock
      #                          in input_tz, then bucket in output_tz.
      # A string Date._parse can't place (no year) falls back to Date.parse,
      # which the outer rescue turns into the DD/MM/YYYY / nil fallback.
      def parse_generic_date(value, input_tz, output_tz)
        parts = Date._parse(value)
        return Date.parse(value) if parts[:year].nil?
        return Date.new(parts[:year], parts[:mon], parts[:mday]) if parts[:hour].nil?

        y, mo, d = parts[:year], parts[:mon], parts[:mday]
        h  = parts[:hour] || 0
        mi = parts[:min]  || 0
        s  = parts[:sec]  || 0

        instant =
          if parts[:offset]
            Time.new(y, mo, d, h, mi, s, format_offset(parts[:offset]))
          else
            Timezone.wall_to_utc(y, mo, d, h, mi, s, input_tz)
          end
        Timezone.to_date_in(instant, output_tz)
      end

      # Date._parse gives the offset in seconds; Time.new wants a "+hh:mm"
      # string (or a Numeric offset — but the string form is unambiguous).
      def format_offset(seconds)
        sign = seconds.negative? ? "-" : "+"
        abs  = seconds.abs
        format("%s%02d:%02d", sign, abs / 3600, (abs % 3600) / 60)
      end

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
