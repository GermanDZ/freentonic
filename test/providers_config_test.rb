# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class ProvidersConfigTest < Minitest::Test
  Config = Freentonic::Providers::Config

  def setup
    Config.__reset_for_tests!
  end

  # ---------- Happy path ----------

  def test_load_provider_returns_parsed_hash_with_symbol_keys
    with_provider_dir do |dir, name|
      write(dir, "config.yml", <<~YAML)
        institution: ing
        scraper_version: ing/0.2
        kind_by_product_type:
          1: null
          3: liability
          10: asset
          20: asset
      YAML

      cfg = Config.load_provider!(dir)
      assert_equal "ing",      cfg[:institution]
      assert_equal "ing/0.2",  cfg[:scraper_version]
      assert_nil               cfg[:kind_by_product_type][1]
      assert_equal "liability", cfg[:kind_by_product_type][3]
      assert_equal "asset",     cfg[:kind_by_product_type][10]
      assert_equal "asset",     cfg[:kind_by_product_type][20]
    end
  end

  def test_load_provider_returns_nil_when_config_missing
    with_provider_dir do |dir, _name|
      assert_nil Config.load_provider!(dir)
    end
  end

  def test_load_provider_caches_per_institution_basename
    with_provider_dir(name: "bank") do |dir, _name|
      write(dir, "config.yml", "institution: bank\n")

      first  = Config.load_provider!(dir)
      second = Config.load_provider!(dir)
      assert_same first, second  # cached, same object identity
    end
  end

  def test_for_returns_loaded_config
    with_provider_dir(name: "bank") do |dir, _name|
      write(dir, "config.yml", "institution: bank\nscraper_version: bank/1\n")
      Config.load_provider!(dir)

      cfg = Config.for(:bank)
      assert_equal "bank/1", cfg[:scraper_version]
    end
  end

  def test_for_raises_when_not_loaded
    err = assert_raises(Config::InvalidConfigError) { Config.for(:never_loaded) }
    assert_match(/no Config registered/, err.message)
    assert_match(/load_provider!/, err.message)
  end

  def test_for_with_string_institution_works
    with_provider_dir(name: "bank") do |dir, _name|
      write(dir, "config.yml", "institution: bank\n")
      Config.load_provider!(dir)

      assert_equal "bank", Config.for("bank")[:institution]
    end
  end

  # ---------- Cached nil for missing config ----------

  def test_load_provider_caches_nil_when_no_config_yml
    with_provider_dir(name: "bare") do |dir, _name|
      first  = Config.load_provider!(dir)
      second = Config.load_provider!(dir)
      assert_nil first
      assert_nil second
    end
  end

  # ---------- Security: parser hardening ----------

  def test_rejects_yaml_with_ruby_object_tag
    with_provider_dir do |dir, _name|
      write(dir, "config.yml", <<~YAML)
        institution: !ruby/object:String
          ivars: { "@custom": "evil" }
      YAML

      err = assert_raises(Config::InvalidConfigError) { Config.load_provider!(dir) }
      assert_match(/unsafe or malformed YAML/, err.message)
    end
  end

  def test_rejects_yaml_aliases
    with_provider_dir do |dir, _name|
      write(dir, "config.yml", <<~YAML)
        _anchor: &shared "x"
        institution: *shared
      YAML

      err = assert_raises(Config::InvalidConfigError) { Config.load_provider!(dir) }
      assert_match(/unsafe or malformed YAML/, err.message)
    end
  end

  def test_rejects_malformed_yaml
    with_provider_dir do |dir, _name|
      write(dir, "config.yml", "kind_by_product_type: [unclosed\n")
      err = assert_raises(Config::InvalidConfigError) { Config.load_provider!(dir) }
      assert_match(/unsafe or malformed YAML/, err.message)
    end
  end

  # ---------- Frozen output (immutability) ----------

  def test_loaded_config_is_frozen
    with_provider_dir(name: "bank") do |dir, _name|
      write(dir, "config.yml", "institution: bank\n")
      cfg = Config.load_provider!(dir)
      assert_predicate cfg, :frozen?
    end
  end

  # ---------- Helpers ----------

  private

  def with_provider_dir(name: "bank")
    Dir.mktmpdir do |root|
      provider_dir = File.join(root, name)
      FileUtils.mkdir_p(provider_dir)
      yield provider_dir, name
    end
  end

  def write(dir, filename, content)
    File.write(File.join(dir, filename), content)
  end
end
