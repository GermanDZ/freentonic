# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class ProvidersNormalizerBaseTest < Minitest::Test
  Config           = Freentonic::Providers::Config
  NormalizerBase   = Freentonic::Providers::NormalizerBase

  def setup
    Config.__reset_for_tests!
  end

  # ---------- Inherited behavior ----------

  def test_subclass_inherits_helpers
    klass = Class.new(NormalizerBase)
    instance = klass.new
    # Helpers#cents is now an instance method on the subclass.
    assert_equal 1234, instance.cents(12.34)
  end

  def test_subclass_inherits_builder_constant
    klass = Class.new(NormalizerBase)
    assert_equal Freentonic::Providers::CanonicalBuilder, klass::Builder
  end

  # ---------- provider!(dir) macro ----------

  def test_provider_macro_auto_defines_constants_from_config_yml
    with_provider_dir("ing") do |dir|
      File.write(File.join(dir, "config.yml"), <<~YAML)
        institution: ing
        scraper_version: ing/0.2
        kind_by_product_type:
          1: null
          3: liability
          10: asset
      YAML

      klass = Class.new(NormalizerBase) { provider!(dir) }

      assert_equal "ing",      klass::INSTITUTION
      assert_equal "ing/0.2",  klass::SCRAPER_VERSION
      assert_equal({1 => nil, 3 => "liability", 10 => "asset"}, klass::KIND_BY_PRODUCT_TYPE)
      assert_predicate klass::KIND_BY_PRODUCT_TYPE, :frozen?
      assert_equal({institution: "ing", scraper_version: "ing/0.2",
                    kind_by_product_type: {1 => nil, 3 => "liability", 10 => "asset"}},
                   klass::CONFIG)
    end
  end

  def test_provider_macro_is_a_no_op_when_no_config_yml
    with_provider_dir("bare") do |dir|
      klass = Class.new(NormalizerBase) { provider!(dir) }
      refute klass.const_defined?(:CONFIG, false)
      refute klass.const_defined?(:INSTITUTION, false)
    end
  end

  def test_provider_macro_does_not_overwrite_explicit_constants
    with_provider_dir("ing") do |dir|
      File.write(File.join(dir, "config.yml"), <<~YAML)
        institution: ing
        kind_by_product_type:
          1: liability
      YAML

      klass = Class.new(NormalizerBase) do
        const_set(:KIND_BY_PRODUCT_TYPE, {99 => "custom"}.freeze)  # set first
        provider!(dir)                                              # then macro
      end

      # Explicit assignment wins.
      assert_equal({99 => "custom"}, klass::KIND_BY_PRODUCT_TYPE)
      # Other constants still defined from YAML.
      assert_equal "ing", klass::INSTITUTION
    end
  end

  def test_provider_macro_picks_up_provider_specific_keys_as_upcase_constants
    # Any top-level key in config.yml — not just institution + scraper_version
    # — gets a corresponding UPCASE constant. Lets providers move arbitrary
    # constants (lookup tables, magic strings, format hints) into config.yml
    # without touching the macro.
    with_provider_dir("bank") do |dir|
      File.write(File.join(dir, "config.yml"), <<~YAML)
        institution: bank
        date_formats: ["%d/%m/%Y", "%d-%m-%Y"]
        pending_status_label: "Pending"
      YAML

      klass = Class.new(NormalizerBase) { provider!(dir) }

      assert_equal ["%d/%m/%Y", "%d-%m-%Y"], klass::DATE_FORMATS
      assert_predicate klass::DATE_FORMATS, :frozen?
      assert_equal "Pending", klass::PENDING_STATUS_LABEL
    end
  end

  # ---------- Helpers ----------

  private

  def with_provider_dir(name)
    Dir.mktmpdir do |root|
      dir = File.join(root, name)
      FileUtils.mkdir_p(dir)
      yield dir
    end
  end
end
