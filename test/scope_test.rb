# frozen_string_literal: true

require_relative "test_helper"

module Freentonic
  module ExtractPlan
    class ScopeTest < Minitest::Test
      def scope(bindings = {})
        Scope.new(bindings)
      end

      # ── whole-token resolve: array indices in dotted paths ──────────────

      def test_resolve_digs_array_index
        s = scope("refreshed" => { "accessTokens" => [{ "accessToken" => "tok-0" },
                                                       { "accessToken" => "tok-1" }] })
        assert_equal "tok-0", s.resolve("{refreshed.accessTokens.0.accessToken}")
        assert_equal "tok-1", s.resolve("{refreshed.accessTokens.1.accessToken}")
      end

      def test_resolve_array_index_out_of_range_is_nil
        s = scope("xs" => [1])
        assert_nil s.resolve("{xs.5}")
      end

      def test_resolve_non_integer_segment_on_array_is_nil
        s = scope("xs" => [1, 2])
        assert_nil s.resolve("{xs.foo}")
      end

      def test_resolve_whole_token_still_literal_when_not_a_token
        assert_equal "Bearer {x}", scope("x" => "y").resolve("Bearer {x}")
      end

      # ── embedded interpolate ────────────────────────────────────────────

      def test_interpolate_embeds_token_in_surrounding_text
        s = scope("challenge" => { "acceptanceMethods" => [{ "code" => "AC-9" }] })
        assert_equal "approve AC-9 now",
                     s.interpolate("approve {challenge.acceptanceMethods.0.code} now")
      end

      def test_interpolate_multiple_tokens
        s = scope("a" => "1", "b" => "2")
        assert_equal "1-2", s.interpolate("{a}-{b}")
      end

      def test_interpolate_lenient_nil_becomes_empty_string
        assert_equal "x=", scope.interpolate("x={missing}")
      end

      def test_interpolate_strict_nil_raises
        err = assert_raises(ArgumentError) { scope.interpolate("x={missing}", strict: true) }
        assert_includes err.message, "missing"
      end

      def test_interpolate_strict_ok_when_all_resolve
        s = scope("t" => "abc")
        assert_equal "Bearer abc", s.interpolate("Bearer {t}", strict: true)
      end

      def test_interpolate_passes_through_non_string
        assert_equal 42, scope.interpolate(42)
      end
    end
  end
end
