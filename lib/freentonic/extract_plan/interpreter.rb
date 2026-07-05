# frozen_string_literal: true

module Freentonic
  module ExtractPlan
    # Executes a validated `extract: plan:` against a live api_client,
    # producing the raw provider payload the normalizer consumes.
    #
    # The verb set is fixed and closed — fetch / select / for_each (with
    # its nested yield), plus the Phase-2 data-shaping verbs let / concat /
    # dedup_by — dispatched by a `case` on the step's key. There is no
    # `send` off a YAML-supplied method name anywhere except the endpoint
    # call, and that name is checked against the workflow's declared
    # endpoint list first (see #invoke). That whitelist is the security
    # boundary: a plan can only call endpoints the workflow already
    # declares, never `raw_request`, `update_auth_headers!`, or any other
    # client method.
    #
    # Any step may carry a `when:` gate (`{ binding: { op: operand } }`)
    # reusing the workflow's `when_context` operator set. When the gate is
    # false the step is a no-op — it neither fetches nor binds, so a
    # downstream reference to its `as:` reads nil (Array-coerced to []).
    class Interpreter
      def initialize(plan, endpoint_names:, stdout:, stderr:)
        @steps          = Array(plan["steps"])
        @output         = plan["output"]
        @endpoint_names = Array(endpoint_names).map(&:to_s)
        @stdout         = stdout
        @stderr         = stderr
      end

      # Run every top-level step, then assemble and return `output:`.
      def run(client:, scope:)
        @steps.each { |step| execute(step, client, scope) }
        scope.resolve(@output)
      end

      private

      def execute(step, client, scope)
        return if step.key?("when") && !gate_passes?(step["when"], scope)

        dispatch(step, client, scope)
      end

      # Verb dispatch, split out from the `when:` gate so a subclass (the
      # elevate interpreter) can add step kinds without re-implementing the
      # gate — it overrides #dispatch and falls back to `super` for the
      # shared verbs.
      def dispatch(step, client, scope)
        if step.key?("fetch")        then do_fetch(step, client, scope)
        elsif step.key?("select")    then do_select(step, scope)
        elsif step.key?("for_each")  then do_for_each(step, client, scope)
        elsif step.key?("let")       then do_let(step, scope)
        elsif step.key?("concat")    then do_concat(step, scope)
        elsif step.key?("dedup_by")  then do_dedup_by(step, scope)
        elsif step.key?("yield")
          raise UserError, "extract.plan: yield: is only valid inside a for_each do: block"
        else
          raise UserError, "extract.plan: unknown step #{step.keys.inspect}"
        end
      end

      # fetch: <endpoint> — call a declared endpoint, optionally with
      # interpolated args, binding the (optionally batch-unwrapped) result.
      # `safe: true` degrades a failed non-critical fetch to `default:`
      # (or nil) with an stderr note — but a SessionExpired always
      # propagates so the Extract stage can re-wrap it as an actionable
      # "re-run connect" UserError.
      def do_fetch(step, client, scope)
        name = step["fetch"].to_s
        unless @endpoint_names.include?(name)
          raise UserError,
            "extract.plan: fetch: #{name.inspect} is not a declared api_client endpoint " \
            "(known: #{@endpoint_names.join(", ")})"
        end

        args   = step["args"] ? symbolize(scope.resolve(step["args"])) : {}
        result = invoke(client, name, args, step)
        result = extract_batch(result, step["extract_batch"]) if step["extract_batch"]
        scope.bind(step["as"], result)
      end

      def invoke(client, name, args, step)
        args.empty? ? client.public_send(name) : client.public_send(name, **args)
      rescue ApiClient::SessionExpired
        raise
      rescue StandardError => e
        raise unless step["safe"]
        @stderr.puts "    ✗ #{name}: #{e.class}: #{e.message}"
        step.key?("default") ? step["default"] : nil
      end

      # select: { from:, path:, default: } — dig a sub-value out of an
      # already-bound result. `path` is a single key, a dotted path, or a
      # fallback chain (Array → first present).
      def do_select(step, scope)
        spec    = step["select"]
        source  = scope.get(spec["from"])
        value   = dig_first(source, spec["path"])
        value   = spec["default"] if value.nil? && spec.key?("default")
        scope.bind(step["as"], value)
      end

      # let: <name> — bind a name to a computed value. Exactly one source:
      #   value:     a resolved template (Date/string/number/{token})
      #   coalesce:  an ordered list of templates → first non-nil wins
      #              (the declarative `a || b || "literal"` idiom)
      #   days_ago:  an integer N → the pre-seeded `today` minus N days
      #              (a Date), for lookback-window arithmetic
      def do_let(step, scope)
        name = step["let"].to_s
        value =
          if step.key?("coalesce")
            resolve_coalesce(step["coalesce"], scope)
          elsif step.key?("days_ago")
            days_ago(step["days_ago"], scope)
          else
            scope.resolve(step["value"])
          end
        scope.bind(name, value)
      end

      # concat: [name, …] — bind `as:` to the concatenation of the named
      # bound collections. Each is Array()-coerced, so an unbound name (a
      # `when:`-skipped fetch's `as:`) contributes []. This is the
      # structured form of `a + b` / `txs.concat(more)`.
      def do_concat(step, scope)
        merged = Array(step["concat"]).flat_map { |name| Array(scope.get(name)) }
        scope.bind(step["as"], merged)
      end

      # dedup_by: key | [key, …] — bind `as:` to `from:` with duplicate
      # rows removed, keeping the first occurrence of each key. The key is
      # a single field or a fallback list (first non-nil field value wins).
      # A row whose key resolves to nil is ALWAYS kept — never deduped —
      # matching Unicaja's cross-endpoint merge where a missing sequence
      # number must pass through rather than collapse rows together.
      def do_dedup_by(step, scope)
        fields = Array(step["dedup_by"]).map(&:to_s)
        rows   = Array(scope.get(step["from"]))
        seen   = {}
        result = rows.select do |row|
          key = dedup_key(row, fields)
          if key.nil? then true
          elsif seen[key] then false
          else seen[key] = true
          end
        end
        scope.bind(step["as"], result)
      end

      def dedup_key(row, fields)
        return nil unless row.is_a?(Hash)
        fields.lazy.map { |f| row[f] }.find { |v| !v.nil? }
      end

      def resolve_coalesce(list, scope)
        Array(list).lazy.map { |tmpl| scope.resolve(tmpl) }.find { |v| !v.nil? }
      end

      # `today` is pre-seeded as a Date; subtracting an integer keeps the
      # arithmetic anchored to the same reference the whole plan sees.
      def days_ago(n, scope)
        today = scope.get("today")
        today.nil? ? nil : today - Integer(n)
      end

      # Evaluate a `when:` gate against the current scope. Delegates to the
      # shared WhenGate so the plan's per-step gate and the elevate phase's
      # block gate can never diverge.
      def gate_passes?(gate, scope)
        WhenGate.passes?(gate, scope)
      end

      # for_each: iterate a bound collection, run `do:` sub-steps per item
      # in a child scope, and collect each iteration's `yield:` into `as:`
      # (an Array, or a Hash keyed by `key:` when `collect: map`).
      def do_for_each(step, client, scope)
        spec     = step["for_each"]
        items    = collection_for(spec, scope)
        as_item  = step["as_item"]
        do_steps = Array(step["do"])
        as_map   = step["collect"].to_s == "map"
        result   = as_map ? {} : []

        items.each do |item|
          child   = scope.child.bind(as_item, item)
          yielded = run_iteration(do_steps, client, child)
          next if yielded.equal?(SKIP)

          if as_map
            result[child.resolve(step["key"])] = yielded
          else
            result << yielded
          end
        end

        scope.bind(step["as"], result)
      end

      SKIP = Object.new.freeze
      private_constant :SKIP

      def run_iteration(do_steps, client, child)
        yielded = SKIP
        do_steps.each do |sub|
          if sub.key?("yield")
            skip_ref = sub["skip_if_nil"]
            next if skip_ref && child.get(skip_ref).nil?
            yielded = child.resolve(sub["yield"])
          else
            execute(sub, client, child)
          end
        end
        yielded
      end

      # Build the iteration collection: the bound `source`, optionally
      # plucking a field out of each element, then compact + uniq — the
      # structured, whitelisted form of `xs.map { |x| x[f] }.compact.uniq`.
      def collection_for(spec, scope)
        items = Array(scope.get(spec["source"]))
        if (field = spec["pluck"])
          items = items.map { |el| el.is_a?(Hash) ? el[field] : nil }
        end
        items = items.compact if spec["compact"]
        items = items.uniq    if spec["uniq"]
        items
      end

      # First non-nil dotted-path lookup; String path → single lookup,
      # Array path → fallback chain.
      def dig_first(source, path)
        case path
        when Array
          path.lazy.map { |p| dig_path(source, p) }.find { |v| !v.nil? }
        else
          dig_path(source, path)
        end
      end

      def dig_path(source, path)
        return nil if path.nil? || source.nil?
        path.to_s.split(".").inject(source) do |acc, key|
          if acc.is_a?(Hash)
            acc[key]
          elsif acc.is_a?(Array) && key.match?(/\A\d+\z/)
            acc[key.to_i]
          end
        end
      end

      # Mirror of ApiClient#ep_extract_batch for the plan's optional
      # endpoint-level unwrap: Array → as-is, Hash → first matching key,
      # else [].
      def extract_batch(data, keys)
        return data if data.is_a?(Array)
        return [] unless data.is_a?(Hash)
        Array(keys).each { |k| (v = data[k.to_s]) && (return v) }
        []
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end
    end
  end
end
