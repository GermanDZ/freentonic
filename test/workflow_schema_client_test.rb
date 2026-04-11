require_relative "test_helper"

module Freentonic
    class WorkflowSchemaClientTest < Minitest::Test
      def schema_with(api_client_config)
        WorkflowSchema.new(path: "/fake/providers/test.yml", raw: {
          "version"  => 1,
          "config"   => { "key" => "test", "default_lookback_days" => 30 },
          "pipeline" => [],
          "phases"   => {},
          "api_client" => api_client_config
        })
      end

      def test_builds_client_with_credentials
        schema = schema_with("credentials" => ["token"])
        client = schema.build_api_client({ token: "tok-123" })
        assert_equal "tok-123", client.send(:token)
      end

      def test_builds_client_with_required_credentials
        schema = schema_with(
          "credentials" => { "keys" => ["token", "secret"], "required" => true }
        )
        assert_raises(ArgumentError) { schema.build_api_client({ token: nil, secret: "s" }) }
        client = schema.build_api_client({ token: "t", secret: "s" })
        assert_equal "t", client.send(:token)
      end

      def test_static_auth_header
        schema = schema_with("auth_headers" => { "X-Static" => "value" })
        client = schema.build_api_client({})
        assert_equal "value", client.send(:auth_headers)["X-Static"]
      end

      def test_dynamic_auth_header
        schema = schema_with(
          "credentials"  => ["token"],
          "auth_headers" => { "Authorization" => "{token}" }
        )
        client = schema.build_api_client({ token: "my-tok" })
        assert_equal "my-tok", client.send(:auth_headers)["Authorization"]
      end

      def test_batch_keys
        schema = schema_with("batch_keys" => ["items", "results"])
        client = schema.build_api_client({})
        assert_equal [1, 2], client.send(:extract_batch, { "items" => [1, 2] })
        assert_equal [3],    client.send(:extract_batch, { "results" => [3] })
        assert_equal [],     client.send(:extract_batch, { "other" => [4] })
      end

      def test_date_format
        schema = schema_with("date_format" => "%d/%m/%Y")
        client = schema.build_api_client({})
        assert_equal "15/03/2024", client.send(:format_date, Date.new(2024, 3, 15))
        assert_equal "15/03/2024", client.send(:format_date, "2024-03-15")
      end

      def test_yaml_value
        schema = schema_with("base_url" => "https://example.com", "custom_key" => "hello")
        client = schema.build_api_client({})
        assert_equal "https://example.com", client.send(:yaml_value, "base_url")
        assert_equal "hello",               client.send(:yaml_value, "custom_key")
      end

      def test_class_is_memoized
        schema = schema_with("credentials" => ["token"])
        klass1 = schema.build_api_client({ token: "a" }).class
        klass2 = schema.build_api_client({ token: "b" }).class
        assert_same klass1, klass2
      end

      def test_returns_nil_when_no_api_client_section
        schema = WorkflowSchema.new(path: "/fake/test.yml", raw: {
          "version"  => 1,
          "config"   => { "key" => "test", "default_lookback_days" => 30 },
          "pipeline" => [],
          "phases"   => {}
        })
        assert_nil schema.build_api_client({})
      end
    end
  end
