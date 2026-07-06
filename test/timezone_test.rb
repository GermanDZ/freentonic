# frozen_string_literal: true

require_relative "test_helper"
require "date"

module Freentonic
  module Providers
    class TimezoneTest < Minitest::Test
      # 2024-03-14 23:00:00 UTC — straddles midnight for any positive offset.
      INSTANT = Time.utc(2024, 3, 14, 23, 0, 0)

      def test_to_date_in_utc_by_default_and_explicit
        assert_equal Date.new(2024, 3, 14), Timezone.to_date_in(INSTANT, nil)
        assert_equal Date.new(2024, 3, 14), Timezone.to_date_in(INSTANT, "")
        assert_equal Date.new(2024, 3, 14), Timezone.to_date_in(INSTANT, "UTC")
        assert_equal Date.new(2024, 3, 14), Timezone.to_date_in(INSTANT, "utc")
      end

      def test_to_date_in_fixed_offset_can_flip_the_day
        assert_equal Date.new(2024, 3, 15), Timezone.to_date_in(INSTANT, "+01:00")
        assert_equal Date.new(2024, 3, 15), Timezone.to_date_in(INSTANT, "+0100")
        assert_equal Date.new(2024, 3, 14), Timezone.to_date_in(INSTANT, "-05:00")
      end

      def test_to_date_in_named_zone_is_dst_correct
        # tzinfo is available in this environment. Madrid is CET (+01:00) in
        # March, so 23:00 UTC → 00:00 next day.
        assert_equal Date.new(2024, 3, 15), Timezone.to_date_in(INSTANT, "Europe/Madrid")
        # July is CEST (+02:00); a 22:30 UTC instant → 00:30 next day.
        july = Time.utc(2024, 7, 1, 22, 30, 0)
        assert_equal Date.new(2024, 7, 2), Timezone.to_date_in(july, "Europe/Madrid")
      end

      def test_unknown_named_zone_raises_user_error
        err = assert_raises(UserError) { Timezone.to_date_in(INSTANT, "Nowhere/Fake") }
        assert_includes err.message, "unknown timezone"
      end

      def test_wall_to_utc_utc_and_offset
        assert_equal Time.utc(2024, 3, 15, 23, 30, 0),
                     Timezone.wall_to_utc(2024, 3, 15, 23, 30, 0, "UTC")
        # 23:30 at -05:00 is 04:30 next day UTC.
        assert_equal Time.utc(2024, 3, 16, 4, 30, 0),
                     Timezone.wall_to_utc(2024, 3, 15, 23, 30, 0, "-05:00")
      end

      def test_wall_to_utc_named_zone
        # 00:30 local Madrid CET (+01:00) → 23:30 UTC previous day.
        assert_equal Time.utc(2024, 3, 14, 23, 30, 0),
                     Timezone.wall_to_utc(2024, 3, 15, 0, 30, 0, "Europe/Madrid")
      end
    end
  end
end
