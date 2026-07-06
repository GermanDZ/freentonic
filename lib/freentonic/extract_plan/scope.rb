# frozen_string_literal: true

module Freentonic
  module ExtractPlan
    # Variable bindings for a running plan plus the value-template
    # resolver. A Scope is a flat name→value map; a `for_each` iteration
    # runs in a #child scope that inherits the parent's bindings and adds
    # its loop variable, so an inner fetch can see both.
    #
    # Value templates follow the same whole-token rule as the api_client
    # DSL (`ApiClient::Interpolation`): a String is a token only if it
    # matches `\A\{…\}\z` exactly — everything else is a literal. The one
    # addition here is a dotted path inside the token, `{pocket.id}`, which
    # digs into a bound Hash — or an Array, when the segment is an integer
    # index (`{accessTokens.0.accessToken}`). Hashes and Arrays are resolved
    # recursively so `yield:`/`output:`/`args:` can carry nested structure;
    # non-String scalars (numbers, booleans) pass through untouched.
    #
    # `#interpolate` is a separate, richer resolver for human/credential
    # strings that must embed a token inside surrounding text (an
    # operator-approval message, a `Bearer {token}` header). It is used
    # ONLY by the elevate phase's message:/value: fields — the plan's
    # structured args keep the stricter whole-token rule.
    class Scope
      TOKEN     = /\A\{([^}]+)\}\z/
      EMBEDDED  = /\{([^}]+)\}/

      def initialize(bindings = {})
        @bindings = bindings
      end

      # Bind a name to a value, returning self so callers can chain.
      # Nil/empty names are ignored (an optional `as:` that wasn't set).
      def bind(name, value)
        return self if name.nil? || name.to_s.empty?
        @bindings = @bindings.merge(name.to_s => value)
        self
      end

      # A fresh scope inheriting the current bindings — used per for_each
      # iteration so loop-local bindings don't leak back to the parent.
      def child
        Scope.new(@bindings.dup)
      end

      # Read a bound value by bare name (no path). Returns nil when unbound.
      def get(name)
        @bindings[name.to_s]
      end

      # Resolve a template value (String token, Hash, Array, or literal).
      def resolve(node)
        case node
        when String then resolve_string(node)
        when Hash   then node.each_with_object({}) { |(k, v), h| h[k] = resolve(v) }
        when Array  then node.map { |v| resolve(v) }
        else node
        end
      end

      # Interpolate every `{token}` embedded in a string, digging each
      # against the bindings (Hash keys + Array indices). A token that
      # resolves to nil becomes "" in lenient mode; in strict mode
      # (`strict: true`) a nil raises a KeyError-style ArgumentError so the
      # caller can fail the step rather than install a truncated value.
      # Non-String input passes through untouched.
      def interpolate(str, strict: false)
        return str unless str.is_a?(String)
        str.gsub(EMBEDDED) do
          value = dig_token(Regexp.last_match(1))
          if value.nil? && strict
            raise ArgumentError, "template {#{Regexp.last_match(1)}} resolved to nil"
          end
          value.to_s
        end
      end

      private

      def resolve_string(str)
        m = TOKEN.match(str)
        return str unless m # literal (or a string that merely contains braces)

        dig_token(m[1])
      end

      # Walk a dotted token path from a root binding, descending Hashes by
      # key and Arrays by integer index. Any non-container / missing
      # segment short-circuits to nil.
      def dig_token(token)
        root, *path = token.split(".")
        path.inject(@bindings[root]) { |value, key| step_into(value, key) }
      end

      # One path segment over Hash / Array / canonical Data entity. Shared
      # with the interpreter and the Fn layer — see Freentonic::PathDig.
      def step_into(value, key) = PathDig.step(value, key)
    end
  end
end
