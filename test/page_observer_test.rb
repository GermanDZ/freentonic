require_relative "test_helper"
require "json"

module Freentonic
  class PageObserverTest < Minitest::Test
    # Duck-types a CDP session: records commands and returns a canned
    # Runtime.evaluate value (the JSON string observe.js would produce).
    class SeededSession
      attr_reader :commands

      def initialize(value:)
        @value = value
        @commands = []
      end

      def send_command(method, params = {}, timeout: 30)
        @commands << { method: method, params: params, timeout: timeout }
        if method == "Runtime.evaluate"
          { "result" => { "value" => @value } }
        else
          {}
        end
      end
    end

    def canned_inventory(extra_input_keys: {})
      password = {
        "tag" => "input", "selector" => "#pwd", "selector_strategy" => "id",
        "needs_review" => false, "type" => "password", "label" => "Password",
        "masked" => true
      }.merge(extra_input_keys)

      {
        "url"   => "https://bank.example/login",
        "title" => "Login",
        "interactive" => [
          { "tag" => "input", "selector" => "#dni", "selector_strategy" => "id",
            "needs_review" => false, "type" => "text", "label" => "DNI", "masked" => false },
          password,
          { "tag" => "button", "selector" => "#submit", "selector_strategy" => "id",
            "needs_review" => false, "text" => "Entrar" }
        ]
      }
    end

    def test_observe_returns_interactive_inventory
      session = SeededSession.new(value: JSON.generate(canned_inventory))
      observation = PageObserver.observe(session)

      assert_equal "https://bank.example/login", observation["url"]
      assert_equal "Login", observation["title"]
      assert_equal 3, observation["interactive"].size

      dni = observation["interactive"].first
      assert_equal "#dni", dni["selector"]
      assert_equal "id", dni["selector_strategy"]
      assert_equal "text", dni["type"]
    end

    def test_observe_sends_one_runtime_evaluate
      session = SeededSession.new(value: JSON.generate(canned_inventory))
      PageObserver.observe(session)

      evals = session.commands.select { |c| c[:method] == "Runtime.evaluate" }
      assert_equal 1, evals.size
      # The eval requests the value by-value and pierces shadow/iframes.
      expr = evals.first[:params][:expression]
      assert_includes expr, "deepQuery"
      assert_includes expr, "elementSummary"
      assert_includes expr, "describeInputValue"
      assert_equal true, evals.first[:params][:returnByValue]
    end

    def test_observe_marks_sensitive_inputs_masked_with_no_value
      session = SeededSession.new(value: JSON.generate(canned_inventory))
      observation = PageObserver.observe(session)

      pwd = observation["interactive"].find { |e| e["type"] == "password" }
      assert_equal true, pwd["masked"]
      refute pwd.key?("value"), "masked input must not carry a value"
    end

    def test_observe_never_surfaces_element_values
      # Even if the injected source were tampered to emit a raw value, the
      # Ruby-side whitelist drops it before it can reach a caller.
      session = SeededSession.new(
        value: JSON.generate(canned_inventory(extra_input_keys: { "value" => "SUPERSECRET" }))
      )
      observation = PageObserver.observe(session)

      json = JSON.generate(observation)
      refute_includes json, "SUPERSECRET"
      observation["interactive"].each do |el|
        refute el.key?("value"), "no element may carry a value key"
      end
    end

    def test_observe_returns_empty_structure_for_non_hash
      session = SeededSession.new(value: true) # FakeSession-style default
      observation = PageObserver.observe(session)

      assert_nil observation["url"]
      assert_nil observation["title"]
      assert_equal [], observation["interactive"]
    end

    def test_observe_parses_object_value_without_json_string
      # returnByValue can hand back an already-deserialized object; observe
      # must normalize it just the same.
      session = SeededSession.new(value: canned_inventory)
      observation = PageObserver.observe(session)
      assert_equal 3, observation["interactive"].size
    end

    def test_expression_is_static_and_pierces_shadow_dom
      expr = PageObserver.expression
      assert_includes expr, "IFRAME"
      assert_includes expr, "contentDocument"
      assert_includes expr, "shadowRoot"
      assert_includes expr, "JSON.stringify"
    end

    def test_allowed_element_keys_excludes_value
      refute_includes PageObserver::ALLOWED_ELEMENT_KEYS, "value"
      assert_includes PageObserver::ALLOWED_ELEMENT_KEYS, "masked"
      assert_includes PageObserver::ALLOWED_ELEMENT_KEYS, "selector"
    end
  end
end
