# frozen_string_literal: true

# Example extractor for example_bank.yml.
#
# Extractors are the first provider-specific Ruby in the pipeline. They
# receive a fully-configured ApiClient (built from the workflow's
# api_client: stanza), the captured credentials, and the resolved
# from_date — and return a raw provider-shaped payload that the
# normalizer will lift into the canonical model.
#
# This example fetches accounts then iterates them to fetch movements per
# account. Adapt the shape to whatever your bank's API exposes; the only
# contract is "return a JSON-serializable Ruby value the normalizer
# understands."

module ExampleBank
  class Extractor
    def call(client:, credentials:, from_date:, stdout:, stderr:)
      stdout.puts "  → fetching accounts list"
      accounts = client.fetch_accounts

      movements_by_account = {}
      Array(accounts).each do |acct|
        ref = acct["ref"] || acct["id"]
        stdout.puts "  → fetching movements for #{acct['alias'] || ref}"
        movements_by_account[ref] = Array(client.fetch_movements(id: ref, from_date: from_date))
      end

      {
        "accounts" => accounts,
        "movements" => movements_by_account,
        "fetched_at" => Time.now.utc.iso8601
      }
    end
  end
end
