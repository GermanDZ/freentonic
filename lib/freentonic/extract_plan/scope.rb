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
    # digs into a bound Hash. Hashes and Arrays are resolved recursively so
    # `yield:`/`output:`/`args:` can carry nested structure; non-String
    # scalars (numbers, booleans) pass through untouched.
    class Scope
      TOKEN = /\A\{([^}]+)\}\z/

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

      private

      def resolve_string(str)
        m = TOKEN.match(str)
        return str unless m # literal (or a string that merely contains braces)

        root, *path = m[1].split(".")
        value = @bindings[root]
        path.each { |key| value = value.is_a?(Hash) ? value[key] : nil }
        value
      end
    end
  end
end
