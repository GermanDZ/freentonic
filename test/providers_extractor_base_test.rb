# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class ProvidersExtractorBaseTest < Minitest::Test
  Config         = Freentonic::Providers::Config
  ExtractorBase  = Freentonic::Providers::ExtractorBase

  def setup
    Config.__reset_for_tests!
  end

  # ---------- Inheritance / instance behavior ----------

  def test_subclass_inherits_helpers
    klass = Class.new(ExtractorBase)
    instance = klass.new
    assert_equal 1234, instance.cents(12.34)
    assert_equal "abc", instance.first_present(nil, "abc")
  end

  def test_subclass_does_not_inherit_normalizers_base
    # ExtractorBase is intentionally NOT a normalizer — extractors are
    # duck-typed by the Extract stage. Make sure we didn't accidentally
    # tie the two together.
    refute ExtractorBase.ancestors.include?(Freentonic::Normalizers::Base)
  end

  # ---------- provider!(dir) macro ----------

  def test_provider_macro_auto_defines_constants_from_config_yml
    with_provider_dir("ing") do |dir|
      File.write(File.join(dir, "config.yml"), <<~YAML)
        institution: ing
        kind_by_product_type:
          1: null
          3: liability
      YAML

      klass = Class.new(ExtractorBase) { provider!(dir) }
      assert_equal "ing", klass::INSTITUTION
      assert_equal({1 => nil, 3 => "liability"}, klass::KIND_BY_PRODUCT_TYPE)
    end
  end

  def test_provider_macro_no_op_when_no_config_yml
    with_provider_dir("bare") do |dir|
      klass = Class.new(ExtractorBase) { provider!(dir) }
      refute klass.const_defined?(:CONFIG, false)
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
