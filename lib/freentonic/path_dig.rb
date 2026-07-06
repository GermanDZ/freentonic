# frozen_string_literal: true

module Freentonic
  # Dotted-path reader over the plain-data shapes plans traffic in — Hashes
  # (by String key), Arrays (by integer index), and frozen canonical `Data`
  # entities (by DECLARED member only, never an arbitrary `send`). The single
  # home for the "walk a value by a dotted path" rule that the extract-plan
  # interpreter, the template scope, and the Fn layer all share.
  #
  # The Data branch is what lets a plan chain builders — build an Account,
  # then read `{account.id}` on the transactions attached to it — and what
  # lets a Fn (e.g. collapse_prefix_dups) read `account_id`/`date`/`amount`
  # off already-built entities. The member whitelist (`members.include?`)
  # keeps it to the entity's declared fields: no method dispatch off plan or
  # provider input.
  module PathDig
    module_function

    # Walk `source` by `path` ("a.b.0.c"). Any missing / non-container /
    # undeclared-member segment short-circuits to nil.
    def dig(source, path)
      return nil if path.nil? || source.nil?

      path.to_s.split(".").inject(source) { |value, key| step(value, key) }
    end

    # One path segment. Hash → key; Array → integer index; Data → declared
    # member via public_send; anything else → nil.
    def step(value, key)
      if value.is_a?(Hash)
        value[key]
      elsif value.is_a?(Array) && key.match?(/\A\d+\z/)
        value[key.to_i]
      elsif value.is_a?(Data) && value.members.include?(key.to_sym)
        value.public_send(key)
      end
    end
  end
end
