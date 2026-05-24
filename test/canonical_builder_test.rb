require_relative "test_helper"
require "bigdecimal"

class CanonicalBuilderTest < Minitest::Test
  Builder = Freentonic::Providers::CanonicalBuilder

  # --- cents_to_amount ---------------------------------------------------

  def test_cents_to_amount_positive
    assert_equal BigDecimal("45.20"), Builder.cents_to_amount(4520)
  end

  def test_cents_to_amount_negative
    assert_equal BigDecimal("-12.34"), Builder.cents_to_amount(-1234)
  end

  def test_cents_to_amount_zero
    assert_equal BigDecimal("0"), Builder.cents_to_amount(0)
  end

  def test_cents_to_amount_nil
    assert_nil Builder.cents_to_amount(nil)
  end

  def test_cents_to_amount_precision_where_float_drifts
    # 99 cents / 100.0 (Float) -> 0.99 exactly today, but e.g. 10/100.0+0.1 drifts.
    # Use a value that exercises BigDecimal precision explicitly.
    bd = Builder.cents_to_amount(1)
    assert_equal BigDecimal("0.01"), bd
    assert_equal "0.01", bd.to_s("F")
  end

  # --- map_status --------------------------------------------------------

  def test_map_status_settled_to_posted
    assert_equal "posted", Builder.map_status("settled")
  end

  def test_map_status_pending_pass_through
    assert_equal "pending", Builder.map_status("pending")
  end

  def test_map_status_nil
    assert_nil Builder.map_status(nil)
  end

  # --- map_status_from ---------------------------------------------------

  def test_map_status_from_canonicalizes_posted
    map = { "COMPLETED" => "posted", "PENDING" => "pending" }
    assert_equal "posted",  Builder.map_status_from("COMPLETED", map)
    assert_equal "pending", Builder.map_status_from("PENDING", map)
  end

  def test_map_status_from_passes_through_custom_status
    map = { "DECLINED" => "declined", "REVERTED" => "reverted" }
    assert_equal "declined", Builder.map_status_from("DECLINED", map)
    assert_equal "reverted", Builder.map_status_from("REVERTED", map)
  end

  def test_map_status_from_case_insensitive_raw
    map = { "completed" => "posted" }
    assert_equal "posted", Builder.map_status_from("Completed", map)
    assert_equal "posted", Builder.map_status_from("COMPLETED", map)
  end

  def test_map_status_from_unknown_raw_returns_nil
    assert_nil Builder.map_status_from("AUTHORIZED", { "COMPLETED" => "posted" })
  end

  def test_map_status_from_nil_inputs
    assert_nil Builder.map_status_from(nil, { "X" => "posted" })
    assert_nil Builder.map_status_from("", { "X" => "posted" })
    assert_nil Builder.map_status_from("X", nil)
  end

  # --- spanish_iban_portable_keys ---------------------------------------

  def test_spanish_iban_portable_keys_returns_ref_and_id
    ref, pid = Builder.spanish_iban_portable_keys("ES0012345678901234567890", bank_code: "1465")
    assert_equal "1465:7890", ref
    assert_equal "bank:1465:7890", pid
  end

  def test_spanish_iban_portable_keys_rejects_non_spanish
    assert_equal [nil, nil], Builder.spanish_iban_portable_keys("FR0012345678901234567890", bank_code: "1465")
  end

  def test_spanish_iban_portable_keys_rejects_short_iban
    assert_equal [nil, nil], Builder.spanish_iban_portable_keys("ES12", bank_code: "1465")
  end

  def test_spanish_iban_portable_keys_rejects_nil_iban
    assert_equal [nil, nil], Builder.spanish_iban_portable_keys(nil, bank_code: "1465")
  end

  def test_spanish_iban_portable_keys_requires_bank_code
    assert_equal [nil, nil], Builder.spanish_iban_portable_keys("ES0012345678901234567890", bank_code: nil)
    assert_equal [nil, nil], Builder.spanish_iban_portable_keys("ES0012345678901234567890", bank_code: "")
  end

  # --- card_pan_portable_keys -------------------------------------------

  def test_card_pan_portable_keys_full_pan
    ref, pid = Builder.card_pan_portable_keys("4174804472958619", bank_code: "1465")
    assert_equal "1465:8619", ref
    assert_equal "card:1465:8619", pid
  end

  def test_card_pan_portable_keys_masked_pan
    ref, pid = Builder.card_pan_portable_keys("**** **** **** 8619", bank_code: "2103")
    assert_equal "2103:8619", ref
    assert_equal "card:2103:8619", pid
  end

  def test_card_pan_portable_keys_rejects_short_pan
    assert_equal [nil, nil], Builder.card_pan_portable_keys("12", bank_code: "1465")
  end

  def test_card_pan_portable_keys_rejects_nil
    assert_equal [nil, nil], Builder.card_pan_portable_keys(nil, bank_code: "1465")
  end

  def test_card_pan_portable_keys_requires_bank_code
    assert_equal [nil, nil], Builder.card_pan_portable_keys("4174804472958619", bank_code: nil)
  end

  # --- build_account -----------------------------------------------------

  def test_build_account_produces_canonical_entity
    acct = Builder.build_account(
      institution: "ing",
      source_id:   "prod-1",
      currency:    "EUR",
      name:        "My checking",
      type:        "checking",
      iban:        "ES0012345678901234567890",
      balance:     { current: BigDecimal("1234.56"), timestamp: nil },
      metadata:    { "ing_product_type" => 20 }
    )
    assert_kind_of Freentonic::Canonical::Account, acct
    assert_match(/\Aacc_[0-9a-f]{16}\z/, acct.id)
    assert_equal "ing",                  acct.institution
    assert_equal "ES0012345678901234567890", acct.iban
    assert_equal BigDecimal("1234.56"),  acct.balance.current
    assert_equal({ "ing_product_type" => 20 }, acct.metadata)
  end

  def test_build_account_portable_ref_collides_cross_provider
    # The simulated end-to-end check: two normalizers (a direct provider
    # and an aggregator) produce identical Account.id for the same physical
    # account when both pass the same portable_ref derived from their
    # respective payloads.
    direct = Builder.build_account(
      institution: "ing", source_id: "ing-uuid-aaa", currency: "EUR",
      name: "Cuenta Naranja", iban: "ES0000000000000000000000",
      portable_ref: "9999:0001"
    )
    aggregator = Builder.build_account(
      institution: "fintonic", source_id: "fintonic-id-zzz", currency: "EUR",
      name: "ING Cuenta Naranja",
      portable_ref: "9999:0001"
    )
    assert_equal direct.id, aggregator.id
    # Other fields stay provider-specific — the collision is on id only.
    assert_equal "ing-uuid-aaa",      direct.source_id
    assert_equal "fintonic-id-zzz",   aggregator.source_id
  end

  def test_build_account_portable_id_is_independent_of_portable_ref
    # Providers pass both: portable_ref drives the digest, portable_id is
    # the human-readable companion. Hash collides on portable_ref alone,
    # even when the two providers chose different display strings.
    a = Builder.build_account(
      institution: "ing", source_id: "ing-uuid", currency: "EUR",
      portable_ref: "9999:0001", portable_id: "bank:9999:0001"
    )
    b = Builder.build_account(
      institution: "fintonic", source_id: "ftc-id", currency: "EUR",
      portable_ref: "9999:0001", portable_id: "ES_9999_0001"
    )
    assert_equal a.id, b.id
    assert_equal "bank:9999:0001", a.portable_id
    assert_equal "ES_9999_0001",   b.portable_id
  end

  def test_build_account_portable_id_defaults_to_nil
    acct = Builder.build_account(institution: "ing", source_id: "p", currency: "EUR")
    assert_nil acct.portable_id
  end

  def test_build_account_without_portable_ref_keeps_legacy_id
    # Back-compat for accounts that can't surface a portable key.
    a = Builder.build_account(institution: "ing", source_id: "p", currency: "EUR")
    b = Builder.build_account(institution: "ing", source_id: "p", currency: "EUR",
                              portable_ref: nil)
    assert_equal a.id, b.id
  end

  def test_build_account_id_is_deterministic
    args = { institution: "ing", source_id: "p", currency: "EUR" }
    a = Builder.build_account(**args)
    b = Builder.build_account(**args)
    assert_equal a.id, b.id
  end

  # --- build_transaction -------------------------------------------------

  def test_build_transaction_produces_canonical_entity
    tx = Builder.build_transaction(
      account_id:      "acc_0123456789abcdef",
      amount:          BigDecimal("-12.34"),
      currency:        "EUR",
      source_id:       "mv-1",
      date:            Date.new(2024, 3, 15),
      raw_description: "COFFEE SHOP",
      description:     "Coffee Shop",
      status:          "posted",
      metadata:        { "ing" => { "uuid" => "mv-1" } }
    )
    assert_kind_of Freentonic::Canonical::Transaction, tx
    assert_match(/\Atxn_[0-9a-f]{16}\z/, tx.id)
    assert_equal "acc_0123456789abcdef", tx.account_id
    assert_equal BigDecimal("-12.34"),   tx.amount
    assert_equal({ "uuid" => "mv-1" }, tx.metadata["ing"])
  end

  def test_build_transaction_id_is_deterministic
    args = {
      account_id: "acc_x", amount: BigDecimal("1"), currency: "EUR",
      date: Date.new(2024, 1, 1), raw_description: "r"
    }
    assert_equal Builder.build_transaction(**args).id,
                 Builder.build_transaction(**args).id
  end

  def test_build_transaction_source_id_disambiguates_same_day_duplicates
    base = {
      account_id: "acc_1", amount: BigDecimal("-680"), currency: "EUR",
      date: Date.new(2026, 5, 4), raw_description: "KEPLER"
    }
    a = Builder.build_transaction(**base, source_id: "v1id-aaaa")
    b = Builder.build_transaction(**base, source_id: "v1id-bbbb")
    refute_equal a.id, b.id
    assert_equal "v1id-aaaa", a.source_id
    assert_equal "v1id-bbbb", b.source_id
  end

  def test_build_transaction_blank_source_id_uses_legacy_derivation
    # Mixed presence is fine: rows without a source_id still get a stable id
    # from (account_id, date, amount, raw_description).
    no_source = Builder.build_transaction(
      account_id: "acc_1", amount: BigDecimal("-680"), currency: "EUR",
      date: Date.new(2026, 5, 4), raw_description: "KEPLER"
    )
    blank_source = Builder.build_transaction(
      account_id: "acc_1", amount: BigDecimal("-680"), currency: "EUR",
      date: Date.new(2026, 5, 4), raw_description: "KEPLER", source_id: ""
    )
    assert_equal no_source.id, blank_source.id
  end

  def test_build_transaction_id_falls_back_to_description_when_raw_missing
    # Should not crash and should still produce a txn_ id when raw_description is nil.
    tx = Builder.build_transaction(
      account_id: "acc_x", amount: BigDecimal("1"), currency: "EUR",
      date: Date.new(2024, 1, 1), description: "cleaned",
      raw_description: nil
    )
    assert_match(/\Atxn_[0-9a-f]{16}\z/, tx.id)
  end

  # --- build_liability ---------------------------------------------------

  def test_build_liability_produces_canonical_entity
    liab = Builder.build_liability(
      account_id: "acc_abc",
      type:       "credit_card",
      currency:   "EUR",
      source_id:  "cc-1",
      balance:    BigDecimal("500"),
      limit:      BigDecimal("1500")
    )
    assert_kind_of Freentonic::Canonical::Liability, liab
    assert_match(/\Aliab_[0-9a-f]{16}\z/, liab.id)
    assert_equal "acc_abc",              liab.account_id
    assert_equal "credit_card",          liab.type
    assert_equal BigDecimal("500"),      liab.balance
    assert_equal BigDecimal("1500"),     liab.limit
  end

  # --- payload -----------------------------------------------------------

  def test_payload_wraps_entities_and_injects_scraper_version
    acct = Builder.build_account(institution: "ing", source_id: "p", currency: "EUR")
    env = Builder.payload(accounts: [acct], transactions: [], scraper_version: "ing/0.1")
    assert_kind_of Freentonic::Canonical::CanonicalPayload, env
    assert_equal "0.1", env.schema_version
    assert_equal "ing/0.1", env.meta["scraper_version"]
    assert_equal 1, env.accounts.size
  end
end
