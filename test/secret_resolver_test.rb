require_relative "test_helper"
require "stringio"

module Freentonic
    class SecretResolverTest < Minitest::Test
      class FakeSecretStore
        attr_reader :fetch_calls, :prompt_calls

        def initialize(initial_values = {})
          @values = initial_values
          @fetch_calls = []
          @prompt_calls = []
        end

        def fetch(source_key:, secret_name:)
          @fetch_calls << [source_key, secret_name]
          @values[[source_key, secret_name]]
        end

        def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
          @prompt_calls << [source_key, secret_name, prompt]
          value = "prompted-#{secret_name.downcase}"
          @values[[source_key, secret_name]] = value
          value
        end
      end

      class SchemaDouble
        def initialize(secret_prompts = {})
          @secret_prompts = secret_prompts
        end

        def secret_config(name)
          prompt = @secret_prompts[name.to_s]
          prompt ? { "prompt" => prompt } : {}
        end
      end

      class SourceDouble
        def key
          "ing"
        end
      end

      def test_returns_stored_secret_without_prompting
        store = FakeSecretStore.new(["ing", "PIN_DIGIT_1"] => "7")
        resolver = SecretResolver.new(secret_store: store, stdout: StringIO.new, stderr: StringIO.new)

        value = resolver.resolve_value(
          source: SourceDouble.new,
          schema: SchemaDouble.new,
          value: "secret(PIN_DIGIT_1)"
        )

        assert_equal "7", value
        assert_equal [["ing", "PIN_DIGIT_1"]], store.fetch_calls
        assert_empty store.prompt_calls
      end

      def test_prompts_once_and_caches_prompted_secret
        store = FakeSecretStore.new
        resolver = SecretResolver.new(secret_store: store, stdout: StringIO.new, stderr: StringIO.new)
        schema = SchemaDouble.new("PIN_DIGIT_2" => "Second PIN digit")
        source = SourceDouble.new

        first = resolver.resolve_value(source: source, schema: schema, value: "secret(PIN_DIGIT_2)")
        second = resolver.resolve_value(source: source, schema: schema, value: "secret(PIN_DIGIT_2)")

        assert_equal "prompted-pin_digit_2", first
        assert_equal first, second
        assert_equal [["ing", "PIN_DIGIT_2"]], store.prompt_calls.map { |call| call.first(2) }
      end

      def test_recursively_resolves_secret_references
        store = FakeSecretStore.new(
          ["ing", "PIN_DIGIT_1"] => "1",
          ["ing", "PIN_DIGIT_2"] => "3",
          ["ing", "USER_DNI"] => "12345678A"
        )
        resolver = SecretResolver.new(secret_store: store, stdout: StringIO.new, stderr: StringIO.new)

        resolved = resolver.resolve_value(
          source: SourceDouble.new,
          schema: SchemaDouble.new,
          value: {
            "dni" => "secret(USER_DNI)",
            "digits" => ["secret(PIN_DIGIT_1)", "secret(PIN_DIGIT_2)"]
          }
        )

        assert_equal(
          {
            "dni" => "12345678A",
            "digits" => ["1", "3"]
          },
          resolved
        )
      end
    end
  end
