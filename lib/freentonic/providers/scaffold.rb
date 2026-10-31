require "fileutils"

module Freentonic
  module Providers
    # `rake new[name]` in freentonic-providers: a declarative provider that
    # lints clean and whose tests pass as generated, so authoring starts
    # from a green baseline. No provider Ruby — extract and normalize are
    # plans (a declarative-only server refuses `ruby:` stages).
    class Scaffold
      attr_reader :name, :camel_name, :dir

      def initialize(name)
        @name = name.downcase.gsub(/[^a-z0-9_]/, "_")
        @camel_name = @name.split("_").map(&:capitalize).join
        @dir = File.expand_path(@name, Dir.pwd)
      end

      # The files #generate! writes, relative to the provider's parent
      # directory — for the caller to list.
      def files
        [
          "workflow.yml",
          "config.yml",
          "test/#{name}_extract_credentials_test.rb",
          "test/#{name}_extract_plan_test.rb",
          "test/#{name}_normalizer_test.rb"
        ].map { |f| File.join(name, f) }
      end

      def generate!
        raise "Directory #{dir} already exists" if Dir.exist?(dir)

        FileUtils.mkdir_p(File.join(dir, "test"))

        write_workflow_yml
        write_config_yml
        write_credential_test
        write_extract_plan_test
        write_normalizer_test

        @name
      end

      private

      def write_workflow_yml
        File.write(File.join(dir, "workflow.yml"), <<~YAML)
          version: 1

          config:
            key: #{name}
            default_lookback_days: 90

          # Declare secrets the user must provide on first run.
          # Values are cached in the macOS Keychain after first entry.
          secrets:
            USER_EMAIL:
              prompt: "#{camel_name} email or username"
            USER_PASSWORD:
              prompt: "#{camel_name} password or passcode"

          pipeline:
            - connect
            - login
            - approve_2fa
            - post_login
            - capture_credentials

          phases:
            connect:
              - action: navigate
                url: "https://REPLACE_WITH_LOGIN_URL"
              # wait_network_idle handles all states: fresh login,
              # remembered credentials, or already logged in.
              - action: wait_network_idle
                seconds: 3

            login:
              # Use _if_present actions so already-logged-in is a no-op.
              # REPLACE selectors below after inspecting the actual page.
              # Rule: NEVER guess selectors — ask for a screenshot first.
              - action: fill_if_present
                selector: "input[type='email'], input[name='email']"
                value: "secret(USER_EMAIL)"
              - action: click_if_present
                selector: "button[type='submit']"
              - action: fill_if_present
                selector: "input[type='password']"
                value: "secret(USER_PASSWORD)"
              - action: click_if_present
                selector: "button[type='submit']"

            approve_2fa:
              # Wait for the post-login page. Use a SPECIFIC path, not
              # just the domain — broad matches can fire before 2FA completes.
              - action: wait_url
                includes: "REPLACE_WITH_POST_LOGIN_URL_PATH"
                timeout: 300

            post_login:
              - action: wait_network_idle
                seconds: 8

            capture_credentials:
              # Capture cookies first — they're the most common auth mechanism.
              # capture_cookie_header uses CDP and gets httpOnly cookies that
              # are invisible in HAR exports.
              - action: capture_cookie_header
                host: "REPLACE_WITH_API_HOST"
                path: "/api/"
                as: cookie
              # Add capture_header for any custom auth headers (x-csrf-token, etc.)
              # - action: capture_header
              #   name: "X-Custom-Header"
              #   as: custom_header
              #   retries: 5
              #   interval_seconds: 2

          # No usable API (requests encrypted or signed in the page)? Drop
          # credentials: and api_client:, capture the app's own responses with
          # capture_response_json, and declare them in a top-level captured:
          # block for the extract plan — see docs/extract-plan.md.
          credentials:
            require:
              - cookie
            validate:
              - key: cookie
                not_empty: true
            map:
              - { from: cookie, as: cookie }

          api_client:
            base_url: "https://REPLACE_WITH_API_HOST"
            api_root: "/REPLACE_WITH_API_ROOT"
            credentials: [cookie]
            auth_headers:
              Cookie: "{cookie}"
            batch_keys: []
            date_format: "%Y-%m-%d"
            endpoints:
              # Add endpoints discovered from HAR analysis.
              # Run: rake har[~/Downloads/#{name}_login.har]
              - name: fetch_accounts
                method: GET
                path: "/accounts"
              # Pagination is declared here, not in the plan: offset (as
              # below) or kind: cursor. The plan sees one flattened list.
              - name: fetch_movements
                method: GET
                path: "/accounts/{account_id}/movements"
                params:
                  from: "{from_date|date}"
                  limit: 100
                  offset: "{offset}"
                pagination: offset
                limit: 100

          # Captured session → raw payload:
          #   { accounts: [<account>], movements: { <account id>: [<movement>] } }
          extract:
            plan:
              steps:
                # The product list is essential: no safe:, so a dead session
                # fails the run as "re-run connect", not as 0 accounts.
                - fetch: fetch_accounts
                  as: accounts
                - for_each:
                    source: accounts
                  as_item: account
                  as: movements
                  collect: map
                  key: "{account.id}"
                  do:
                    # One failing account mustn't sink the run: safe: logs it
                    # to stderr and binds default: instead.
                    - fetch: fetch_movements
                      args: { account_id: "{account.id}", from_date: "{from_date}" }
                      as: rows
                      safe: true
                      default: []
                    - yield: "{rows}"
              output:
                accounts: "{accounts}"
                movements: "{movements}"

          # Raw payload → canonical accounts + transactions. REPLACE the field
          # names after inspecting a --dump-raw of a real run.
          normalize:
            plan:
              steps:
                - select: { from: raw, path: accounts, default: [] }
                  as: raw_accounts
                - select: { from: raw, path: movements, default: {} }
                  as: movements_by_account
                - for_each: { source: raw_accounts }
                  as_item: acct
                  as: results
                  do:
                    - select: { from: acct, path: id }
                      as: acct_id
                    - skip_when: { acct_id: { absent: true } }
                    - let: currency
                      coalesce: ["{acct.currency}", "EUR"]
                    - apply: cents
                      args: { amount: "{acct.balance}" }
                      as: balance_cents
                    - apply: cents_to_amount
                      args: { cents: "{balance_cents}" }
                      as: balance_amount
                    - apply: remove_whitespace
                      args: { value: "{acct.iban}" }
                      as: iban
                    - apply: build_account
                      args:
                        institution: "{config.institution}"
                        source_id: "{acct_id}"
                        currency: "{currency}"
                        name: "{acct.name}"
                        type: checking
                        iban: "{iban}"
                        balance: { current: "{balance_amount}", timestamp: null }
                      as: account

                    - lookup: { from: movements_by_account, key: "{acct_id}", default: [] }
                      as: rows
                    - for_each: { source: rows }
                      as_item: mv
                      as: txns
                      do:
                        - select: { from: mv, path: id }
                          as: mv_id
                        - skip_when: { mv_id: { absent: true } }
                        - apply: cents
                          args: { amount: "{mv.amount}" }
                          as: amount_cents
                        - skip_when: { amount_cents: { absent: true } }
                        - skip_when: { amount_cents: { eq: 0 } }
                        - apply: cents_to_amount
                          args: { cents: "{amount_cents}" }
                          as: amount
                        - apply: parse_date
                          args:
                            value: "{mv.date}"
                            input_timezone: "{config.input_timezone}"
                            output_timezone: "{config.output_timezone}"
                          as: date
                        - skip_when: { date: { absent: true } }
                        - apply: strip
                          args: { value: "{mv.description}" }
                          as: description
                        - apply: build_transaction
                          args:
                            account_id: "{account.id}"
                            source_id: "{mv_id}"
                            amount: "{amount}"
                            currency: "{currency}"
                            date: "{date}"
                            description: "{description}"
                            raw_description: "{description}"
                            status: posted
                          as: txn
                        - yield: "{txn}"
                    - yield: { account: "{account}", txns: "{txns}" }

                - apply: pluck
                  args: { list: "{results}", key: account }
                  as: accounts
                - apply: pluck
                  args: { list: "{results}", key: txns }
                  as: txn_groups
                - apply: flatten
                  args: { list: "{txn_groups}" }
                  as: transactions
              output:
                accounts: "{accounts}"
                transactions: "{transactions}"
        YAML
      end

      def write_config_yml
        File.write(File.join(dir, "config.yml"), <<~YAML)
          # Constants the normalize plan reads as {config.*}.
          institution: #{name}
          scraper_version: #{name}/0.1

          # The zone a movement's calendar day is booked in, independent of
          # where freentonic runs. REPLACE with the bank's zone (e.g.
          # Europe/Madrid; named zones need the tzinfo gem).
          input_timezone: UTC
          output_timezone: UTC
        YAML
      end

      def write_credential_test
        File.write(File.join(dir, "test", "#{name}_extract_credentials_test.rb"), <<~RUBY)
          require "minitest/autorun"
          require "stringio"
          require "freentonic"

          class #{camel_name}ExtractCredentialsTest < Minitest::Test
            WORKFLOW_PATH = File.expand_path("../workflow.yml", __dir__)

            def source
              Freentonic::Source.new(workflow_path: WORKFLOW_PATH)
            end

            def test_maps_captured_context_to_credentials
              credentials = source.extract_credentials(
                nil,
                workflow_context: { "cookie" => "session=abc123" },
                stdout: StringIO.new,
                stderr: StringIO.new
              )

              assert_equal({ cookie: "session=abc123" }, credentials)
            end

            def test_raises_when_required_key_missing
              assert_raises(Freentonic::UserError) do
                source.extract_credentials(
                  nil, workflow_context: {}, stdout: StringIO.new, stderr: StringIO.new
                )
              end
            end
          end
        RUBY
      end

      def write_extract_plan_test
        File.write(File.join(dir, "test", "#{name}_extract_plan_test.rb"), <<~RUBY)
          require "minitest/autorun"
          require "stringio"
          require "date"
          require "freentonic"

          # Runs the workflow's extract plan against canned API responses.
          class #{camel_name}ExtractPlanTest < Minitest::Test
            WORKFLOW = File.expand_path("../workflow.yml", __dir__)

            # Stands in for the generated api_client: one method per endpoint.
            class FakeClient
              def fetch_accounts = [{ "id" => "acc-1", "name" => "Main" }, { "id" => "acc-2", "name" => "Card" }]

              def fetch_movements(account_id:, from_date:)
                raise "HTTP 500" if account_id == "acc-2"

                [{ "id" => "mv-1", "date" => "2024-03-15", "amount" => -12.34 }]
              end
            end

            def extract
              schema = Freentonic::WorkflowSchema.load(WORKFLOW)
              Freentonic::ExtractPlan::PlanExtractor.new(
                schema.raw.dig("extract", "plan"), endpoint_names: schema.api_client_endpoint_names
              ).call(client: FakeClient.new, credentials: {}, from_date: Date.new(2024, 1, 1),
                     stdout: StringIO.new, stderr: StringIO.new)
            end

            def test_fetches_movements_per_account
              assert_equal 1, extract["movements"].fetch("acc-1").size
            end

            def test_a_failing_account_does_not_sink_the_run
              assert_equal [], extract["movements"].fetch("acc-2")
            end
          end
        RUBY
      end

      def write_normalizer_test
        File.write(File.join(dir, "test", "#{name}_normalizer_test.rb"), <<~RUBY)
          require "minitest/autorun"
          require "bigdecimal"
          require "stringio"
          require "date"
          require "freentonic"

          # Runs the workflow's normalize plan on a hand-crafted raw payload.
          # Never commit a real dump — model fixtures on its shape only.
          class #{camel_name}NormalizerTest < Minitest::Test
            WORKFLOW = File.expand_path("../workflow.yml", __dir__)

            def normalize(raw)
              Freentonic::Normalizers::Builder.for_workflow(WORKFLOW, stdout: StringIO.new, stderr: StringIO.new).call(raw)
            end

            def raw(movements)
              {
                "accounts" => [{ "id" => "acc-1", "name" => "Main Account", "iban" => "XX00 1234 5678 9012",
                                 "currency" => "EUR", "balance" => 1234.56 }],
                "movements" => { "acc-1" => movements }
              }
            end

            def test_normalizes_account_with_movements
              payload = normalize(raw([{ "id" => "mv-1", "date" => "2024-03-15", "amount" => -12.34,
                                         "description" => " Test payment " }]))

              account = payload.accounts.first
              assert_equal "checking", account.type
              assert_equal "XX00123456789012", account.iban
              assert_equal BigDecimal("1234.56"), account.balance.current

              txn = payload.transactions.first
              assert_equal account.id, txn.account_id
              assert_equal BigDecimal("-12.34"), txn.amount
              assert_equal Date.new(2024, 3, 15), txn.date
              assert_equal "Test payment", txn.description
            end

            def test_skips_movements_without_an_amount
              payload = normalize(raw([
                { "id" => "mv-ok", "date" => "2024-03-15", "amount" => -5.0, "description" => "Valid" },
                { "id" => "mv-nil", "date" => "2024-03-15", "amount" => nil, "description" => "Skip" }
              ]))

              assert_equal ["mv-ok"], payload.transactions.map(&:source_id)
            end
          end
        RUBY
      end
    end
  end
end
