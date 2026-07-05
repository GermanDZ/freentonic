require_relative "test_helper"

# TimestampMs is the shared "coerce to Unix ms" util that both ApiClient
# cursor pagination and Providers::Helpers#parse_timestamp_ms delegate to.
class TimestampMsTest < Minitest::Test
  T = Freentonic::TimestampMs

  def test_numeric_already_ms_passthrough
    assert_equal 1_710_504_000_000, T.parse(1_710_504_000_000)
  end

  def test_numeric_seconds_scaled_to_ms
    assert_equal 1_710_504_000_000, T.parse(1_710_504_000)
  end

  def test_numeric_float_seconds
    assert_equal 1_500, T.parse(1.5)
  end

  def test_string_digits_ms_passthrough
    assert_equal 1_710_504_000_000, T.parse("1710504000000")
  end

  def test_string_digits_seconds_scaled
    assert_equal 1_710_504_000_000, T.parse("1710504000")
  end

  def test_string_iso8601_parsed
    assert_equal 1_710_496_800_000, T.parse("2024-03-15T10:00:00.000Z")
  end

  def test_nil_returns_nil
    assert_nil T.parse(nil)
  end

  def test_unparseable_string_returns_nil
    assert_nil T.parse("not a date")
  end

  # The provider Helpers mixin must stay byte-equivalent to the shared util
  # after the dedupe — pin it so a future divergence is caught.
  def test_helpers_mixin_delegates_identically
    helper = Class.new { include Freentonic::Providers::Helpers }.new
    ["2024-03-15T10:00:00.000Z", "1710504000000", 1_710_504_000, nil, "!!! unparseable"].each do |v|
      expected = T.parse(v)
      actual   = helper.parse_timestamp_ms(v)
      if expected.nil?
        assert_nil actual, "expected nil for #{v.inspect}"
      else
        assert_equal expected, actual, "mismatch for #{v.inspect}"
      end
    end
  end
end
