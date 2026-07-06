# frozen_string_literal: true

require_relative "errors"

module Freentonic
  # Registry of named PURE functions, invocable from any plan context via
  # the `apply:` verb (extract plans, the elevate phase, and — from Ask 8 —
  # normalize plans). See docs/pure-functions-plan.md.
  #
  # The purity contract every function must honor:
  #   - args in → value out. No I/O, no api_client, no scope access.
  #   - No clock, no randomness: anything time-anchored takes a date /
  #     timestamp argument (plans seed `today` / `now_ms` for exactly this).
  #   - No mutation of inputs — enforced, not asked: Fn.call deep-freezes
  #     every resolved arg before invoking the impl, so a mutating impl
  #     raises FrozenError instead of corrupting a shared plan binding.
  #
  # The registry is closed at runtime: only functions compiled into the
  # gem exist, so no provider-authored code ever executes during a sync.
  # `Fn.names` is the whitelist the workflow schema validates `apply:`
  # against — the same pattern as the declared-endpoint list for `fetch:`.
  #
  # Every definition MUST declare a description, an impl, and at least one
  # example. Examples are executable: the registry test harness runs each
  # one through the purity checks (frozen args, called twice, identical
  # results), so a new function cannot be registered without being born
  # covered.
  #
  #   Freentonic::Fn.define "pan_last4" do |f|
  #     f.description "Last 4 digits of a (possibly masked) card number."
  #     f.param :value
  #     f.example args: { "value" => "**** **** **** 8619" }, returns: "8619"
  #     f.impl { |value:| Providers::Helpers.pan_last4(value) }
  #   end
  module Fn
    Param = Data.define(:name, :type, :required, :default)

    # An executable usage sample. `returns` asserts exact equality;
    # `matching` asserts a subset of the result's `to_h` attributes
    # (for entity-returning functions whose digest ids would be noise
    # to spell out by hand). Exactly one of the two is declared;
    # `matching: nil` means returns-mode (where nil IS a legal expected
    # value — `cents(nil) → nil`).
    Example = Data.define(:args, :returns, :matching)

    Definition = Data.define(:name, :description, :params, :examples, :impl) do
      def param_names = params.map(&:name)
      def required_param_names = params.select(&:required).map(&:name)
    end

    # Type tags checked at call time. `:any` skips the check; nil values
    # always pass (optional params default to nil — the impl owns nil
    # semantics, matching the helpers these wrap).
    TYPE_CHECKS = {
      any:     ->(_v) { true },
      array:   ->(v) { v.is_a?(Array) },
      hash:    ->(v) { v.is_a?(Hash) },
      string:  ->(v) { v.is_a?(String) },
      integer: ->(v) { v.is_a?(Integer) },
      number:  ->(v) { v.is_a?(Numeric) },
      boolean: ->(v) { v == true || v == false }
    }.freeze

    # Collects one definition's parts, then #build validates completeness.
    class Builder
      def initialize(name)
        @name        = name
        @description = nil
        @params      = []
        @examples    = []
        @impl        = nil
      end

      def description(text)
        @description = text
      end

      def param(name, type = :any, required: false, default: nil)
        unless TYPE_CHECKS.key?(type)
          raise ArgumentError, "Fn #{@name}: unknown param type #{type.inspect} " \
                               "(allowed: #{TYPE_CHECKS.keys.join(", ")})"
        end
        @params << Param.new(name: name.to_s, type: type, required: required,
                             default: Fn.deep_freeze(default))
      end

      UNSET = Object.new.freeze

      def example(args:, returns: UNSET, matching: nil)
        has_returns = !returns.equal?(UNSET)
        if has_returns == !matching.nil?
          raise ArgumentError, "Fn #{@name}: an example declares exactly one of returns:/matching:"
        end
        @examples << Example.new(args: Fn.deep_freeze(args.transform_keys(&:to_s)),
                                 returns: has_returns ? Fn.deep_freeze(returns) : nil,
                                 matching: Fn.deep_freeze(matching))
      end

      def impl(&block)
        @impl = block
      end

      def build
        { description: @description, params: @params, examples: @examples, impl: @impl }
          .each do |part, value|
            blank = value.nil? || (value.respond_to?(:empty?) && value.empty?)
            next unless blank && part != :params
            raise ArgumentError, "Fn #{@name}: must declare #{part} (see docs/pure-functions-plan.md)"
          end
        Definition.new(name: @name, description: @description, params: @params.freeze,
                       examples: @examples.freeze, impl: @impl)
      end
    end

    @registry = {}

    class << self
      def define(name, &block)
        name = name.to_s
        raise ArgumentError, "Fn.define: duplicate function name #{name.inspect}" if @registry.key?(name)

        builder = Builder.new(name)
        yield builder
        @registry[name] = builder.build
      end

      def registered?(name) = @registry.key?(name.to_s)
      def names             = @registry.keys
      def all               = @registry.values

      def fetch(name)
        @registry.fetch(name.to_s) do
          raise UserError, "apply: #{name.to_s.inspect} is not a registered function " \
                           "(known: #{names.join(", ")})"
        end
      end

      # Invoke a function with a String-keyed args Hash (the shape a plan's
      # resolved `args:` arrives in). Validates arg names / required
      # presence / type tags, applies defaults, deep-freezes every value,
      # and calls the impl with keyword args.
      def call(name, args = {})
        defn = fetch(name)
        args = (args || {}).transform_keys(&:to_s)

        unknown = args.keys - defn.param_names
        unless unknown.empty?
          raise UserError, "apply: #{defn.name}: unknown parameter(s) #{unknown.join(", ")} " \
                           "(params: #{defn.param_names.join(", ")})"
        end
        missing = defn.required_param_names - args.keys
        unless missing.empty?
          raise UserError, "apply: #{defn.name}: missing required parameter(s) #{missing.join(", ")}"
        end

        kwargs = defn.params.to_h do |p|
          value = args.key?(p.name) ? args[p.name] : p.default
          check_type!(defn.name, p, value)
          [p.name.to_sym, deep_freeze(value)]
        end
        defn.impl.call(**kwargs)
      end

      # Recursively freeze the plain-data containers YAML/scope values are
      # made of. Non-container objects (Date, BigDecimal, entities) pass
      # through — canonical entities are frozen value objects already.
      def deep_freeze(obj)
        case obj
        when Hash
          obj.each { |k, v| deep_freeze(k); deep_freeze(v) }
          obj.freeze
        when Array
          obj.each { |v| deep_freeze(v) }
          obj.freeze
        when String
          obj.freeze
        else
          obj
        end
      end

      # Test-only: remove a definition registered by a test. Production
      # code never unregisters — the registry is append-at-boot, then read.
      def unregister(name)
        @registry.delete(name.to_s)
      end

      private

      def check_type!(fn_name, param, value)
        return if value.nil? || TYPE_CHECKS.fetch(param.type).call(value)

        raise UserError, "apply: #{fn_name}: parameter #{param.name} must be #{param.type} " \
                         "(got #{value.class})"
      end
    end
  end
end

require_relative "fn/builtins"
