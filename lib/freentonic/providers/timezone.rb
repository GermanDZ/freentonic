# frozen_string_literal: true

require "date"
require "time"

module Freentonic
  module Providers
    # Timezone resolution for date extraction. The canonical model stores a
    # calendar Date, not an instant, so the only question a timezone answers
    # here is: *which zone's calendar day does this instant fall on?*
    #
    # Two operations:
    #   - to_date_in(time, zone): the calendar Date `time` falls on in `zone`
    #     (the "output"/bucketing zone for any input that is an absolute
    #     instant — a Unix timestamp or an offset-bearing datetime).
    #   - wall_to_time(y,mo,d,h,mi,s, zone): interpret naive wall-clock
    #     components as local time in `zone`, returning the UTC instant (the
    #     "input" zone for an offset-*naive* datetime string).
    #
    # Zone grammar (deliberately small; DST-correctness is opt-in):
    #   - nil / "" / "UTC" (any case) → UTC. Pure stdlib. The default
    #     everywhere, so absent config is deterministic and machine-
    #     independent (never the process's local TZ).
    #   - "+01:00" / "-0500" — a fixed numeric offset. Pure stdlib. Exact,
    #     but does NOT track DST (an offset is a constant).
    #   - anything else — an IANA named zone ("Europe/Madrid"), DST-correct,
    #     but requires the optional `tzinfo` gem. If tzinfo isn't installed,
    #     a named zone raises a clear UserError pointing at the fix rather
    #     than failing obscurely mid-sync.
    module Timezone
      module_function

      OFFSET = /\A[+-]\d{2}:?\d{2}\z/

      def utc?(zone)
        z = zone.to_s.strip
        z.empty? || z.casecmp?("UTC")
      end

      # The calendar Date `time` (any Time) falls on in `zone`.
      def to_date_in(time, zone)
        localize(time, zone).to_date
      end

      # Shift an absolute Time into `zone` (as a Time carrying that zone's
      # offset). UTC and fixed offsets are stdlib; named zones use tzinfo.
      def localize(time, zone)
        return time.getutc if utc?(zone)

        z = zone.to_s.strip
        return time.getlocal(z) if z.match?(OFFSET)

        named_zone(z).to_local(time.getutc)
      end

      # Interpret naive wall-clock components as local time in `zone`,
      # returning the corresponding UTC instant. Used only for offset-naive
      # datetime strings (a bank that sends "2024-03-15 23:30:00" in its own
      # clock with no offset).
      def wall_to_utc(year, month, day, hour, min, sec, zone)
        return Time.utc(year, month, day, hour, min, sec) if utc?(zone)

        z = zone.to_s.strip
        return Time.new(year, month, day, hour, min, sec, z).getutc if z.match?(OFFSET)

        # tzinfo treats the passed Time's components as the local wall time.
        named_zone(z).local_to_utc(Time.utc(year, month, day, hour, min, sec))
      end

      # Lazily load tzinfo for named IANA zones. Kept out of the stdlib paths
      # so a workflow that only uses UTC / fixed offsets never needs the gem.
      def named_zone(zone)
        require "tzinfo"
        TZInfo::Timezone.get(zone)
      rescue LoadError
        raise UserError,
              "timezone #{zone.inspect} is a named IANA zone, which needs the " \
              "tzinfo gem (add it to your Gemfile, or use \"UTC\" / a fixed " \
              "offset like \"+01:00\")"
      rescue TZInfo::InvalidTimezoneIdentifier
        raise UserError, "unknown timezone #{zone.inspect}"
      end
    end
  end
end
