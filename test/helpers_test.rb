require_relative "test_helper"
require "stringio"

class HelpersTest < Minitest::Test
  include Freentonic::Providers::Helpers

  # --- safe_fetch ---

  def test_safe_fetch_returns_result_on_success
    stderr = StringIO.new
    result = safe_fetch(stderr, "test") { 42 }
    assert_equal 42, result
    assert_empty stderr.string
  end

  def test_safe_fetch_returns_nil_on_error
    stderr = StringIO.new
    result = safe_fetch(stderr, "bank details") { raise "boom" }
    assert_nil result
    assert_includes stderr.string, "bank details"
    assert_includes stderr.string, "RuntimeError"
  end

  # --- cents ---

  def test_cents_from_major_units
    assert_equal 1234, cents(12.34)
    assert_equal(-567, cents(-5.67))
    assert_equal 100, cents(1.0)
  end

  def test_cents_already_minor
    assert_equal 1234, cents(1234, already_minor: true)
    assert_equal(-567, cents(-567, already_minor: true))
  end

  def test_cents_from_hash
    assert_equal 1234, cents({"amount" => 12.34})
    assert_equal 500, cents({"value" => 5.0})
    assert_equal 999, cents({"cantidad" => 9.99})
  end

  def test_cents_from_string
    assert_equal 1234, cents("12.34")
    assert_equal 1234, cents("12,34")
  end

  def test_cents_nil
    assert_nil cents(nil)
  end

  def test_cents_hash_with_nil_value
    assert_nil cents({"amount" => nil})
  end

  # --- parse_date ---

  def test_parse_date_unix_ms
    # 2024-03-15 ~12:00 UTC
    date = parse_date(1710504000000)
    assert_equal 2024, date.year
    assert_equal 3, date.month
    assert_equal 15, date.day
  end

  def test_parse_date_unix_seconds
    date = parse_date(1710504000)
    assert_equal 2024, date.year
    assert_equal 3, date.month
  end

  def test_parse_date_iso_string
    date = parse_date("2024-03-15T10:00:00.000Z")
    assert_equal Date.new(2024, 3, 15), date
  end

  def test_parse_date_yyyy_mm_dd
    date = parse_date("2024-03-15")
    assert_equal Date.new(2024, 3, 15), date
  end

  def test_parse_date_dd_mm_yyyy
    date = parse_date("15/03/2024")
    assert_equal Date.new(2024, 3, 15), date
  end

  def test_parse_date_prefers_given_format_for_locale_ambiguous_strings
    # "05/06/2024" is ambiguous; Date.parse's default interpretation is
    # May 6, but for Spanish banks it's 5 June. preferred_formats: pins
    # the correct reading.
    assert_equal Date.new(2024, 6, 5),
                 parse_date("05/06/2024", preferred_formats: ["%d/%m/%Y"])
  end

  def test_parse_date_falls_through_when_preferred_format_doesnt_match
    # ISO input against a DD/MM/YYYY preference → strptime fails, fall
    # through to generic Date.parse which handles ISO.
    assert_equal Date.new(2024, 3, 15),
                 parse_date("2024-03-15", preferred_formats: ["%d/%m/%Y"])
  end

  def test_parse_date_tries_multiple_preferred_formats_in_order
    # First format fails, second matches.
    assert_equal Date.new(2024, 3, 15),
                 parse_date("15-03-2024", preferred_formats: ["%d/%m/%Y", "%d-%m-%Y"])
  end

  def test_parse_date_nil
    assert_nil parse_date(nil)
  end

  # --- extract_fields ---

  def test_extract_fields_simple_rename
    source = { "uuid" => "abc", "amount" => 100, "noise" => "ignored" }
    out = extract_fields(source, { "id" => "uuid", "value" => "amount" })
    assert_equal({ "id" => "abc", "value" => 100 }, out)
  end

  def test_extract_fields_dotted_path_for_nested_lookup
    source = { "status" => { "description" => "settled", "code" => 1 } }
    out = extract_fields(source, { "status" => "status.description" })
    assert_equal({ "status" => "settled" }, out)
  end

  def test_extract_fields_dotted_path_returns_nil_when_intermediate_missing
    source = { "status" => nil }
    out = extract_fields(source, { "status" => "status.description" })
    assert_nil out["status"]
  end

  def test_extract_fields_array_spec_picks_first_non_nil
    source = { "description" => nil, "store" => "Mercadona", "primary" => "ignored" }
    out = extract_fields(source, { "name" => ["description", "store", "primary"] })
    assert_equal "Mercadona", out["name"]
  end

  def test_extract_fields_array_spec_returns_nil_when_all_paths_missing
    source = { "other" => "x" }
    out = extract_fields(source, { "name" => ["description", "store"] })
    assert_nil out["name"]
  end

  def test_extract_fields_keeps_keys_with_nil_values_for_stable_columns
    # Important for raw_payload allowlists where downstream tools rely
    # on a stable column set across syncs.
    source = { "uuid" => "abc" }
    out = extract_fields(source, { "uuid" => "uuid", "missing_field" => "missing_field" })
    assert out.key?("missing_field")
    assert_nil out["missing_field"]
  end

  def test_extract_fields_handles_non_hash_source_gracefully
    assert_equal({}, extract_fields(nil, { "a" => "b" }))
    assert_equal({}, extract_fields("string", { "a" => "b" }))
  end

  def test_extract_fields_stringifies_output_keys
    # Mapping keys may be symbols (idiomatic Ruby in YAML-loaded configs),
    # but output keys are always strings — matches what JSON-bound
    # metadata wants.
    out = extract_fields({ "x" => 1 }, { foo: "x" })
    assert_equal({ "foo" => 1 }, out)
    assert_equal ["foo"], out.keys
  end

  # --- first_present ---

  def test_first_present_returns_first_non_empty_stripped_string
    assert_equal "Mercadona", first_present(nil, "", "  ", "Mercadona", "ignored")
  end

  def test_first_present_strips_whitespace_before_emptiness_check
    assert_equal "abc", first_present("   ", "abc")
  end

  def test_first_present_returns_nil_when_all_blank
    assert_nil first_present(nil, "", "   ", nil)
  end

  def test_first_present_coerces_non_strings_via_to_s
    assert_equal "42", first_present(nil, 42)
  end

  def test_first_present_with_no_args
    assert_nil first_present
  end

  def test_parse_date_garbage
    assert_nil parse_date("not a date")
  end

  def test_parse_date_numeric_string_ms
    date = parse_date("1710504000000")
    assert_equal 2024, date.year
  end

  # --- parse_timestamp_ms ---

  def test_parse_timestamp_ms_from_integer_ms
    assert_equal 1710504000000, parse_timestamp_ms(1710504000000)
  end

  def test_parse_timestamp_ms_from_integer_seconds
    assert_equal 1710504000000, parse_timestamp_ms(1710504000)
  end

  def test_parse_timestamp_ms_from_iso_string
    ts = parse_timestamp_ms("2024-03-15T12:00:00.000Z")
    assert_in_delta 1710504000000, ts, 1000
  end

  def test_parse_timestamp_ms_nil
    assert_nil parse_timestamp_ms(nil)
  end
end
