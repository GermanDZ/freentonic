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

      # Indexed-reference form: `secret(NAME[N])` looks up the bare
      # `NAME` and slices character `N`. Lets a workflow replay a single
      # stored PIN like "1234" into 4 separate input fields without
      # forcing the operator to store each digit independently.
      def test_indexed_reference_slices_bare_secret
        store = FakeSecretStore.new(["ing", "USER_PIN"] => "1234")
        resolver = SecretResolver.new(secret_store: store, stdout: StringIO.new, stderr: StringIO.new)
        source = SourceDouble.new
        schema = SchemaDouble.new

        assert_equal "1", resolver.resolve_value(source: source, schema: schema, value: "secret(USER_PIN[0])")
        assert_equal "2", resolver.resolve_value(source: source, schema: schema, value: "secret(USER_PIN[1])")
        assert_equal "3", resolver.resolve_value(source: source, schema: schema, value: "secret(USER_PIN[2])")
        assert_equal "4", resolver.resolve_value(source: source, schema: schema, value: "secret(USER_PIN[3])")
        # The bare secret is fetched exactly once across all references.
        assert_equal 1, store.fetch_calls.count { |_, name| name == "USER_PIN" }
        # The literal indexed name is NEVER looked up in the store
        # (would fail the store's key-validation regex, since brackets
        # aren't allowed in stored secret names).
        store.fetch_calls.each { |_, name| refute_match(/\[/, name, "bracketed name leaked to store: #{name}") }
      end

      def test_indexed_reference_out_of_range_raises_user_error
        store = FakeSecretStore.new(["ing", "USER_PIN"] => "12")
        resolver = SecretResolver.new(secret_store: store, stdout: StringIO.new, stderr: StringIO.new)

        error = assert_raises(UserError) do
          resolver.resolve_value(
            source: SourceDouble.new,
            schema: SchemaDouble.new,
            value: "secret(USER_PIN[5])"
          )
        end
        assert_match(/index 5 out of range/, error.message)
        assert_match(/USER_PIN/, error.message)
        assert_match(/length 2/, error.message)
      end

      def test_indexed_reference_prompts_for_bare_name_when_missing
        store = FakeSecretStore.new
        resolver = SecretResolver.new(secret_store: store, stdout: StringIO.new, stderr: StringIO.new)
        schema = SchemaDouble.new("USER_PIN" => "Enter your 4-digit PIN")

        # FakeSecretStore.prompt_and_store stores "prompted-user_pin"
        # (13 chars) — we expect index 0 to slice to "p".
        value = resolver.resolve_value(source: SourceDouble.new, schema: schema, value: "secret(USER_PIN[0])")
        assert_equal "p", value
        # Prompt was issued for the *bare* name, not the indexed form.
        assert_equal [["ing", "USER_PIN"]], store.prompt_calls.map { |call| call.first(2) }
      end

      def test_indexed_reference_caches_per_index_independently
        store = FakeSecretStore.new(["ing", "USER_PIN"] => "9876")
        resolver = SecretResolver.new(secret_store: store, stdout: StringIO.new, stderr: StringIO.new)
        source = SourceDouble.new

        2.times do
          assert_equal "9", resolver.resolve_value(source: source, schema: SchemaDouble.new, value: "secret(USER_PIN[0])")
          assert_equal "8", resolver.resolve_value(source: source, schema: SchemaDouble.new, value: "secret(USER_PIN[1])")
        end
        # Bare USER_PIN fetched once total — index lookups don't refetch.
        assert_equal 1, store.fetch_calls.count { |_, name| name == "USER_PIN" }
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
