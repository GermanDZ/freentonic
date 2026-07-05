# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "freentonic/invoke_server"

module Freentonic
  # Coverage for the multi-token / token-file auth added for zero-downtime
  # rotation: InvokeServer.load_tokens (source union + file parsing) and the
  # authenticated? contract that accepts *any* configured token.
  class InvokeServerTokensTest < Minitest::Test
    # ─── load_tokens: source union + normalization ───

    def test_cli_tokens_and_env_token_are_unioned
      tokens = InvokeServer.load_tokens(cli_tokens: %w[a b], env_token: "c")
      assert_equal %w[a b c], tokens
    end

    def test_env_token_is_comma_split
      tokens = InvokeServer.load_tokens(env_token: "one, two ,three")
      assert_equal %w[one two three], tokens
    end

    def test_duplicates_are_deduped
      tokens = InvokeServer.load_tokens(cli_tokens: %w[dup dup], env_token: "dup")
      assert_equal %w[dup], tokens
    end

    def test_blank_and_whitespace_tokens_dropped
      tokens = InvokeServer.load_tokens(cli_tokens: ["  ", ""], env_token: " , realtok , ")
      assert_equal %w[realtok], tokens
    end

    def test_nil_sources_yield_empty
      assert_empty InvokeServer.load_tokens
    end

    def test_token_file_one_per_line_with_comments_and_blanks
      Dir.mktmpdir do |d|
        path = File.join(d, "tokens.txt")
        File.write(path, "# rotation file\nalpha\n\n  beta  \n# trailing comment\n")
        tokens = InvokeServer.load_tokens(cli_files: [path])
        assert_equal %w[alpha beta], tokens
      end
    end

    def test_env_token_file_is_read
      Dir.mktmpdir do |d|
        path = File.join(d, "tokens.txt")
        File.write(path, "gamma\n")
        tokens = InvokeServer.load_tokens(env_token_file: path)
        assert_equal %w[gamma], tokens
      end
    end

    def test_all_sources_merge_and_dedupe
      Dir.mktmpdir do |d|
        path = File.join(d, "tokens.txt")
        File.write(path, "old\nnew\n")
        tokens = InvokeServer.load_tokens(
          cli_tokens: %w[cli], env_token: "new", cli_files: [path]
        )
        # old+new from file, new also from env (deduped), cli from flag.
        assert_equal %w[cli new old].sort, tokens.sort
        assert_equal tokens.uniq, tokens
      end
    end

    def test_missing_token_file_is_user_error
      err = assert_raises(UserError) do
        InvokeServer.load_tokens(cli_files: ["/no/such/tokens.txt"])
      end
      assert_includes err.message, "not found"
    end

    def test_empty_env_token_file_path_ignored
      # An unset FREENTONIC_INVOKE_TOKEN_FILE arrives as "" — must not be
      # treated as a path (which would raise "not found").
      assert_empty InvokeServer.load_tokens(env_token_file: "")
    end

    # ─── authenticated?: accept any configured token ───

    FakeReq = Struct.new(:headers)

    def server_with(*tokens)
      InvokeServer.new(runner: Object.new, invoke_tokens: tokens)
    end

    def authed?(server, header)
      req = FakeReq.new(header ? { "authorization" => header } : {})
      server.send(:authenticated?, req)
    end

    def test_any_of_the_configured_tokens_is_accepted
      server = server_with("old-tok", "new-tok")
      assert authed?(server, "Bearer old-tok")
      assert authed?(server, "Bearer new-tok")
    end

    def test_unknown_token_rejected
      server = server_with("old-tok", "new-tok")
      refute authed?(server, "Bearer nope")
    end

    def test_missing_header_rejected_when_tokens_set
      refute authed?(server_with("tok"), nil)
    end

    def test_non_bearer_scheme_rejected
      refute authed?(server_with("tok"), "Basic dG9rOg==")
    end

    def test_open_auth_when_no_tokens
      # No tokens configured ⇒ auth disabled, everything passes.
      assert authed?(server_with, nil)
    end

    def test_empty_string_tokens_disable_auth
      # Constructor drops empties, so ["", nil] ⇒ no tokens ⇒ open.
      assert authed?(InvokeServer.new(runner: Object.new, invoke_tokens: ["", nil]), nil)
    end
  end
end
