# frozen_string_literal: true

require "yaml"
require_relative "workflow_actions"
require_relative "path_confinement"

module Freentonic
  class WorkflowSchema
    CONFIG_KEY = "config"
    CREDENTIALS_KEY = "credentials"
    PHASES_KEY = "phases"
    PIPELINE_KEY = "pipeline"
    SECRETS_KEY = "secrets"

    def self.load(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      new(path: path, raw: raw)
    end

    attr_reader :path, :raw

    def initialize(path:, raw:)
      @path = path
      @raw = raw
      validate!
    end

    def config
      @raw.fetch(CONFIG_KEY, {})
    end

    def credentials
      @raw[CREDENTIALS_KEY]
    end

    def pipeline
      @raw.fetch(PIPELINE_KEY, [])
    end

    def phases
      @raw.fetch(PHASES_KEY, {})
    end

    def phase(name)
      Array(phases[name.to_s])
    end

    def secrets
      @raw.fetch(SECRETS_KEY, {})
    end

    def secret_config(name)
      secrets.fetch(name.to_s, {})
    end

    def error_signals
      Array(config["error_signals"])
    end

    # Declarative Normalizer spec: normalize: { ruby: "./normalizer.rb", class: "My::Normalizer" }
    def normalizer
      @raw["normalize"]
    end

    # The `elevate:` session-elevation block, or nil. Runs between connect
    # and extract (Stages::Elevate). Root-level only.
    def elevate_spec
      @raw["elevate"]
    end

    # Builds (and memoizes) the ApiClient subclass from the api_client: YAML
    # without instantiating it. Exposed so `--lint` can validate the
    # endpoint / auth-header / ext translation offline — building the class
    # loads the ext file and runs every define_get/define_post macro, so any
    # malformed api_client config surfaces here. Returns nil when the
    # workflow declares no api_client:.
    def api_client_class
      return nil unless @raw["api_client"]
      require_relative "api_client"
      @_api_client_class ||= build_api_client_class(@raw["api_client"])
    end

    def build_api_client(credentials)
      klass = api_client_class or return nil
      klass.new(credentials)
    end

    # The declared api_client endpoint names, as Strings. This is the
    # whitelist an `extract: plan:` `fetch:` step resolves against — the
    # interpreter never calls a client method not in this list. Empty when
    # the workflow declares no api_client / no endpoints.
    def api_client_endpoint_names
      Array(@raw.dig("api_client", "endpoints")).filter_map do |ep|
        ep["name"].to_s if ep.is_a?(Hash) && ep["name"]
      end
    end

    private

    def build_api_client_class(ac)
      klass = Class.new(Freentonic::ApiClient)
      klass.yaml_config(ac)

      klass.base_url(ac["base_url"]) if ac["base_url"]
      klass.api_root(ac["api_root"]) if ac["api_root"]

      apply_credentials(klass, ac["credentials"])
      klass.batch_keys(*Array(ac["batch_keys"]).map(&:to_s)) if ac["batch_keys"]
      klass.date_format(ac["date_format"])                   if ac["date_format"]

      if ac["derived_credentials"]
        specs = ac["derived_credentials"].each_with_object({}) do |(name, v), h|
          has_regex = v.key?("regex") && !v["regex"].nil?
          has_key   = v.key?("key")   && !v["key"].nil?
          if has_regex && has_key
            raise UserError, "workflow #{@path} derived_credentials[#{name.inspect}]: " \
                             "cannot declare both regex: and key:"
          elsif !has_regex && !has_key
            raise UserError, "workflow #{@path} derived_credentials[#{name.inspect}]: " \
                             "must declare regex: or key:"
          end
          h[name] = if has_regex
                      { from: v["from"], regex: v["regex"], capture: (v["capture"] || 1) }
                    else
                      { from: v["from"], key: v["key"].to_s }
                    end
        end
        klass.derived_credentials(specs)
      end

      if ac["expected_code"] || ac["expected_content_type"]
        klass.expected_response(code: ac["expected_code"],
                                content_type: ac["expected_content_type"])
      end

      apply_auth_headers(klass, ac["auth_headers"])

      Array(ac["endpoints"]).each do |ep|
        name       = ep["name"].to_sym
        path       = ep["path"]
        base       = ep["base"]
        method     = ep["method"]&.upcase
        pagination = ep["pagination"]
        limit      = ep["limit"] || 100
        rk         = Array(ep.dig("response", "extract_batch")).map(&:to_s)
        rk         = nil if rk.empty?
        headers    = ep["headers"]

        case method
        when "GET"
          params = ep["params"] || {}
          klass.define_get(name, path, base: base, params: params, headers: headers,
                           pagination: pagination, limit: limit,
                           response_extract_batch: rk)
        when "POST"
          form = ep["form"]
          json = ep["json"]
          if form && json
            raise UserError,
                  "workflow #{@path} api_client.endpoints[#{name}] declares both " \
                  "form: and json: — pick one (form: → application/x-www-form-urlencoded, " \
                  "json: → application/json with Array/Hash literals preserved)."
          end
          klass.define_post(name, path, base: base, form: form, json: json, headers: headers,
                            pagination: pagination, limit: limit,
                            response_extract_batch: rk)
        when "PUT"
          form = ep["form"]
          json = ep["json"]
          if form && json
            raise UserError,
                  "workflow #{@path} api_client.endpoints[#{name}] declares both " \
                  "form: and json: — pick one (form: → application/x-www-form-urlencoded, " \
                  "json: → application/json with Array/Hash literals preserved)."
          end
          klass.define_put(name, path, base: base, form: form, json: json, headers: headers,
                           limit: limit, response_extract_batch: rk)
        else
          raise UserError,
                "workflow #{@path} api_client.endpoints[#{name}] has unsupported " \
                "method #{ep["method"].inspect} (expected GET, POST, or PUT)."
        end
      end

      load_client_ext(klass, ac["ext"]) if ac["ext"]
      klass
    end

    # Translate the api_client.auth_headers YAML into klass.auth_header
    # macro calls. Accepts two shapes:
    #
    #   1. Hash — flat name→value map applied to all hosts (back-compat).
    #   2. Array — list of host-scoped blocks, each:
    #        { "host" => optional_string, "headers" => Hash }
    #      The "host" key is optional; omit it for a default block that
    #      applies to all hosts. Blocks with "host" only apply to
    #      requests whose URL has that host.
    def apply_auth_headers(klass, ah)
      return if ah.nil?

      if ah.is_a?(Hash)
        ah.each { |name, val| declare_auth_header(klass, name, val, nil) }
        return
      end

      unless ah.is_a?(Array)
        raise UserError, "workflow #{@path} api_client.auth_headers must be a Hash or Array of host blocks"
      end

      ah.each_with_index do |block, idx|
        unless block.is_a?(Hash) && block["headers"].is_a?(Hash) && !block["headers"].empty?
          raise UserError, "workflow #{@path} api_client.auth_headers[#{idx}]: must be a hash with a non-empty headers: hash"
        end
        host = block["host"]
        if host && !(host.is_a?(String) && !host.empty?)
          raise UserError, "workflow #{@path} api_client.auth_headers[#{idx}].host: must be a non-empty string when set"
        end
        block["headers"].each { |name, val| declare_auth_header(klass, name, val, host) }
      end
    end

    def declare_auth_header(klass, name, val, host)
      if (m = val.to_s.match(/\A\{(\w+)\}\z/))
        klass.auth_header(name, from: m[1].to_sym, host: host)
      else
        klass.auth_header(name, val.to_s, host: host)
      end
    end

    def apply_credentials(klass, cred_config)
      return unless cred_config
      if cred_config.is_a?(Array)
        klass.credentials(*cred_config.map(&:to_sym))
      elsif cred_config.is_a?(Hash)
        names    = Array(cred_config["keys"]).map(&:to_sym)
        required = cred_config["required"] || false
        klass.credentials(*names, required: required)
      end
    end

    # ext_spec must be a Hash with explicit "file" and "module" keys.
    # The module name is resolved via a strict nested const_get(name, false)
    # walk, so YAML authors cannot influence which Ruby constant gets
    # resolved beyond what they type explicitly. Prevents a dynamic
    # constant lookup security wart.
    def load_client_ext(klass, ext_spec)
      unless ext_spec.is_a?(Hash) && ext_spec["file"] && ext_spec["module"]
        raise UserError, "workflow #{@path}: api_client.ext must be a hash with file: and module: keys"
      end
      ext_path = File.expand_path(ext_spec["file"], File.dirname(@path))
      ext_path = PathConfinement.resolve_within!(ext_path, File.dirname(@path), label: "api_client.ext.file")
      require ext_path
      mod = ext_spec["module"].to_s.split("::").inject(Object) do |ns, name|
        ns.const_get(name, false)
      end
      klass.include(mod)
    end

    def validate!
      version = @raw["version"]
      unless version == 1
        raise UserError,
              "workflow #{@path} must declare version: 1 " \
              "(the only dialect version; see docs/workflow-schema-versioning.md)"
      end

      unless phases.is_a?(Hash)
        raise UserError, "workflow #{@path} phases must be a hash"
      end

      phases.each do |phase_name, steps|
        next if steps.nil?
        unless steps.is_a?(Array)
          raise UserError, "workflow #{@path} phase #{phase_name.inspect} must be an array or null"
        end
        steps.each_with_index do |step, i|
          validate_step!(phase_name, step, i)
        end
      end

      unless pipeline.is_a?(Array) && pipeline.all? { |p| p.is_a?(String) }
        raise UserError, "workflow #{@path} pipeline must be a list of phase names"
      end

      unknown = pipeline - phases.keys
      unless unknown.empty?
        raise UserError, "workflow #{@path} pipeline references undefined phases: #{unknown.join(", ")}"
      end

      unless secrets.is_a?(Hash)
        raise UserError, "workflow #{@path} secrets must be a hash"
      end

      validate_error_signals!
      validate_extract!
      validate_elevate!
    end

    def validate_error_signals!
      signals = config["error_signals"]
      return if signals.nil?

      unless signals.is_a?(Array)
        raise UserError, "workflow #{@path} config.error_signals must be an array"
      end

      signals.each_with_index do |sig, i|
        unless sig.is_a?(Hash)
          raise UserError, "workflow #{@path} config.error_signals[#{i}] must be a hash"
        end
        unless sig.key?("text") || sig.key?("selector") || sig.key?("title")
          raise UserError, "workflow #{@path} config.error_signals[#{i}] must have text:, selector:, or title:"
        end
      end
    end

    # ── extract: validation ────────────────────────────────────────────
    #
    # `extract:` is optional at load time (a connect-only workflow has
    # none). When present it is exactly one of the escape-hatch form
    # ({ruby:, class:}) or the declarative form (plan:). The ruby form's
    # class resolution is checked at stage/lint time; the plan form is
    # fully statically validated here.
    def validate_extract!
      ext = @raw["extract"] || config["extract"]
      return if ext.nil?

      unless ext.is_a?(Hash)
        raise UserError, "workflow #{@path} extract: must be a hash"
      end

      has_plan = ext.key?("plan")
      has_ruby = ext.key?("ruby") || ext.key?("class")
      if has_plan && has_ruby
        raise UserError, "workflow #{@path} extract: declares both plan: and ruby:/class: — pick one"
      end

      validate_extract_plan!(ext["plan"]) if has_plan
    end

    PLAN_STEP_VERBS = %w[fetch select for_each let concat dedup_by].freeze

    # Bindings the interpreter pre-seeds before the first step (see
    # ExtractPlan::PlanExtractor#call / ExtractPlan.seed_scope). Static
    # validation starts from this set so a plan (or the elevate phase) may
    # reference them without an explicit binding step.
    PLAN_SEED_BINDINGS = %w[from_date from_ms now_ms today lookback_days].freeze

    # ── elevate: validation ────────────────────────────────────────────
    #
    # The session-elevation phase reuses the extract-plan step grammar
    # (fetch/select/for_each/let/concat/dedup_by, each optionally when:-
    # gated) and adds two session-affecting step kinds. Like a plan it is
    # walked linearly with binding tracking, seeded with PLAN_SEED_BINDINGS,
    # and its `fetch:` resolves against the same declared-endpoint
    # whitelist. Unlike a plan it has no output:.
    ELEVATE_STEP_VERBS =
      (PLAN_STEP_VERBS + %w[await_operator_approval rebind_credential]).freeze

    def validate_elevate!
      ev = @raw["elevate"]
      return if ev.nil?
      loc = "workflow #{@path} elevate"
      unless ev.is_a?(Hash)
        raise UserError, "#{loc}: must be a hash with steps:"
      end

      bound = PLAN_SEED_BINDINGS.dup
      validate_plan_when!(ev["when"], "#{loc}.when", bound) if ev.key?("when")

      if ev.key?("on_failure") && !%w[degrade abort].include?(ev["on_failure"])
        raise UserError,
              "#{loc}.on_failure: must be \"degrade\" or \"abort\" (got #{ev["on_failure"].inspect})"
      end

      steps = ev["steps"]
      unless steps.is_a?(Array) && !steps.empty?
        raise UserError, "#{loc}.steps: must be a non-empty array"
      end

      endpoints = api_client_endpoint_names
      steps.each_with_index do |step, i|
        validate_elevate_step!(step, "#{loc}.steps[#{i}]", endpoints, bound)
      end
    end

    def validate_elevate_step!(step, loc, endpoints, bound)
      unless step.is_a?(Hash)
        raise UserError, "#{loc}: must be a hash"
      end
      verbs = step.keys & ELEVATE_STEP_VERBS
      if verbs.empty?
        raise UserError, "#{loc}: unknown step (expected one of #{ELEVATE_STEP_VERBS.join(", ")}; " \
                         "got keys #{step.keys.inspect})"
      end
      if verbs.size > 1
        raise UserError, "#{loc}: a step must declare exactly one verb, found #{verbs.inspect}"
      end

      case verbs.first
      when "await_operator_approval" then validate_elevate_await!(step, loc, bound)
      when "rebind_credential"       then validate_elevate_rebind!(step, loc, bound)
      else
        # Shared plan verb — delegate to the plan validator, which checks
        # the single-verb rule + when: gate and tracks new bindings.
        validate_plan_step!(step, loc, endpoints, bound, allow_yield: false)
      end
    end

    # await_operator_approval: { message:, timeout? } — message may embed
    # {tokens}; each must reference a bound name. Binds nothing.
    def validate_elevate_await!(step, loc, bound)
      validate_plan_when!(step["when"], "#{loc}.when", bound) if step.key?("when")
      spec = step["await_operator_approval"]
      unless spec.is_a?(Hash) && spec["message"].is_a?(String) && !spec["message"].empty?
        raise UserError, "#{loc}.await_operator_approval: requires a non-empty message:"
      end
      validate_embedded_refs!(spec["message"], "#{loc}.await_operator_approval.message", bound)
      return unless spec.key?("timeout")

      t = spec["timeout"]
      unless t.is_a?(Integer) && t.positive?
        raise UserError, "#{loc}.await_operator_approval.timeout: must be a positive integer (got #{t.inspect})"
      end
    end

    # rebind_credential: { header:, host?, value: } — value may embed
    # {tokens}; each must reference a bound name. Mutates the client, binds
    # nothing into the scope.
    def validate_elevate_rebind!(step, loc, bound)
      validate_plan_when!(step["when"], "#{loc}.when", bound) if step.key?("when")
      spec = step["rebind_credential"]
      unless spec.is_a?(Hash)
        raise UserError, "#{loc}.rebind_credential: must be a hash"
      end
      unless spec["header"].is_a?(String) && !spec["header"].empty?
        raise UserError, "#{loc}.rebind_credential: requires a non-empty header:"
      end
      unless spec["value"].is_a?(String) && !spec["value"].empty?
        raise UserError, "#{loc}.rebind_credential: requires a non-empty value:"
      end
      if spec.key?("host") && !(spec["host"].is_a?(String) && !spec["host"].empty?)
        raise UserError, "#{loc}.rebind_credential.host: must be a non-empty string when present"
      end
      validate_embedded_refs!(spec["value"], "#{loc}.rebind_credential.value", bound)
    end

    # Every {token} embedded in an elevate message:/value: must reference a
    # name bound by this point (its root binding). The embedded analogue of
    # validate_plan_refs!, which only checks whole-token strings.
    def validate_embedded_refs!(str, loc, bound)
      return unless str.is_a?(String)
      str.scan(/\{([^}]+)\}/).each do |(token)|
        root = token.split(".").first
        next if bound.include?(root)
        raise UserError,
              "#{loc}: {#{token}} references unbound name #{root.inspect} (bound: #{bound.join(", ")})"
      end
    end

    # Walk the plan linearly, tracking which names are bound so far, and
    # fail loud on: a fetch to an undeclared endpoint, a reference to an
    # unbound name, a malformed/unknown step, or a for_each with no yield.
    # Bindings start with the interpreter's pre-seeded scope.
    def validate_extract_plan!(plan)
      loc = "workflow #{@path} extract.plan"
      unless plan.is_a?(Hash)
        raise UserError, "#{loc}: must be a hash with steps: and output:"
      end

      steps = plan["steps"]
      unless steps.is_a?(Array)
        raise UserError, "#{loc}.steps: must be an array"
      end
      unless plan["output"].is_a?(Hash)
        raise UserError, "#{loc}.output: must be a hash mapping keys to \"{binding}\" values"
      end

      endpoints = api_client_endpoint_names
      bound     = PLAN_SEED_BINDINGS.dup

      steps.each_with_index do |step, i|
        validate_plan_step!(step, "#{loc}.steps[#{i}]", endpoints, bound, allow_yield: false)
      end

      validate_plan_refs!(plan["output"], "#{loc}.output", bound)
    end

    def validate_plan_step!(step, loc, endpoints, bound, allow_yield:)
      unless step.is_a?(Hash)
        raise UserError, "#{loc}: must be a hash"
      end

      allowed = PLAN_STEP_VERBS + (allow_yield ? %w[yield] : [])
      verbs   = step.keys & allowed
      if verbs.empty?
        raise UserError, "#{loc}: unknown step (expected one of #{allowed.join(", ")}; " \
                         "got keys #{step.keys.inspect})"
      end
      if verbs.size > 1
        raise UserError, "#{loc}: a step must declare exactly one verb, found #{verbs.inspect}"
      end

      # A `when:` gate may accompany any verb. Its keys reference bindings
      # visible at this point; its operators are the when_context set.
      validate_plan_when!(step["when"], "#{loc}.when", bound) if step.key?("when")

      case verbs.first
      when "fetch"    then validate_plan_fetch!(step, loc, endpoints, bound)
      when "select"   then validate_plan_select!(step, loc, bound)
      when "for_each" then validate_plan_for_each!(step, loc, endpoints, bound)
      when "let"      then validate_plan_let!(step, loc, bound)
      when "concat"   then validate_plan_concat!(step, loc, bound)
      when "dedup_by" then validate_plan_dedup_by!(step, loc, bound)
      when "yield"    then validate_plan_yield!(step, loc, bound)
      end
    end

    # let: <name> — exactly one of value: / coalesce: / days_ago:. Binds
    # <name>. `value:`/`coalesce:` templates must reference bound names;
    # `days_ago:` must be a non-negative integer.
    def validate_plan_let!(step, loc, bound)
      name = step["let"]
      unless name.is_a?(String) && !name.empty?
        raise UserError, "#{loc}.let: must be a non-empty binding name"
      end
      sources = %w[value coalesce days_ago].select { |k| step.key?(k) }
      unless sources.size == 1
        raise UserError, "#{loc}.let: must declare exactly one of value:, coalesce:, days_ago: " \
                         "(found #{sources.empty? ? "none" : sources.inspect})"
      end
      case sources.first
      when "value"
        validate_plan_refs!(step["value"], "#{loc}.value", bound)
      when "coalesce"
        list = step["coalesce"]
        unless list.is_a?(Array) && !list.empty?
          raise UserError, "#{loc}.coalesce: must be a non-empty array"
        end
        list.each { |v| validate_plan_refs!(v, "#{loc}.coalesce", bound) }
      when "days_ago"
        n = step["days_ago"]
        unless n.is_a?(Integer) && n >= 0
          raise UserError, "#{loc}.days_ago: must be a non-negative integer (got #{n.inspect})"
        end
      end
      bound << name
    end

    # concat: [name, …] — every name must be bound; binds `as:`.
    def validate_plan_concat!(step, loc, bound)
      names = step["concat"]
      unless names.is_a?(Array) && !names.empty? && names.all? { |n| n.is_a?(String) && !n.empty? }
        raise UserError, "#{loc}.concat: must be a non-empty array of binding names"
      end
      names.each do |n|
        unless bound.include?(n)
          raise UserError, "#{loc}.concat: #{n.inspect} is not bound by an earlier step " \
                           "(bound: #{bound.join(", ")})"
        end
      end
      unless step["as"].is_a?(String) && !step["as"].empty?
        raise UserError, "#{loc}.concat: requires a non-empty as: to bind the result"
      end
      bound << step["as"]
    end

    # dedup_by: key | [key, …] — from: must be bound; binds `as:`.
    def validate_plan_dedup_by!(step, loc, bound)
      keys = step["dedup_by"]
      ok = (keys.is_a?(String) && !keys.empty?) ||
           (keys.is_a?(Array) && !keys.empty? && keys.all? { |k| k.is_a?(String) && !k.empty? })
      unless ok
        raise UserError, "#{loc}.dedup_by: must be a non-empty field name or array of field names"
      end
      unless bound.include?(step["from"].to_s)
        raise UserError, "#{loc}.dedup_by.from: #{step["from"].inspect} is not bound by an earlier step " \
                         "(bound: #{bound.join(", ")})"
      end
      unless step["as"].is_a?(String) && !step["as"].empty?
        raise UserError, "#{loc}.dedup_by: requires a non-empty as: to bind the result"
      end
      bound << step["as"]
    end

    # when: { binding: { op: operand } } — reuses the when_context
    # operator set. Every key must be a bound name; operators and operand
    # types are checked exactly as validate_when_context! does for phases.
    def validate_plan_when!(gate, loc, bound)
      unless gate.is_a?(Hash) && !gate.empty?
        raise UserError, "#{loc}: must be a non-empty hash of { binding: { op: operand } }"
      end
      gate.each do |key, ops|
        unless bound.include?(key.to_s)
          raise UserError, "#{loc}: #{key.inspect} is not a bound name (bound: #{bound.join(", ")})"
        end
        unless ops.is_a?(Hash) && !ops.empty?
          raise UserError, "#{loc} key #{key.inspect} must map to a non-empty hash of operators"
        end
        ops.each do |op, operand|
          unless WHEN_CONTEXT_OPS.include?(op)
            raise UserError, "#{loc} key #{key.inspect}: unknown operator #{op.inspect} (allowed: #{WHEN_CONTEXT_OPS.join(", ")})"
          end
          if WHEN_CONTEXT_NUMERIC_OPS.include?(op) && !operand.is_a?(Numeric)
            raise UserError, "#{loc} key #{key.inspect}: operator #{op.inspect} requires a numeric operand, got #{operand.inspect}"
          end
          if WHEN_CONTEXT_PRESENCE_OPS.include?(op) && ![true, false].include?(operand)
            raise UserError, "#{loc} key #{key.inspect}: operator #{op.inspect} requires a boolean operand, got #{operand.inspect}"
          end
        end
      end
    end

    def validate_plan_fetch!(step, loc, endpoints, bound)
      name = step["fetch"]
      unless name.is_a?(String) && !name.empty?
        raise UserError, "#{loc}.fetch: must be a non-empty endpoint name"
      end
      unless endpoints.include?(name)
        raise UserError, "#{loc}.fetch: #{name.inspect} is not a declared api_client endpoint " \
                         "(known: #{endpoints.empty? ? "none" : endpoints.join(", ")})"
      end
      if step.key?("args")
        unless step["args"].is_a?(Hash)
          raise UserError, "#{loc}.args: must be a hash"
        end
        validate_plan_refs!(step["args"], "#{loc}.args", bound)
      end
      bind_plan_as!(step, loc, bound)
    end

    def validate_plan_select!(step, loc, bound)
      spec = step["select"]
      unless spec.is_a?(Hash) && spec["from"] && spec.key?("path")
        raise UserError, "#{loc}.select: must be a hash with from: and path:"
      end
      unless bound.include?(spec["from"].to_s)
        raise UserError, "#{loc}.select.from: #{spec["from"].inspect} is not bound by an earlier step " \
                         "(bound: #{bound.join(", ")})"
      end
      unless step["as"].is_a?(String) && !step["as"].empty?
        raise UserError, "#{loc}.select: requires a non-empty as: to bind the result"
      end
      bound << step["as"]
    end

    def validate_plan_for_each!(step, loc, endpoints, bound)
      spec = step["for_each"]
      unless spec.is_a?(Hash) && spec["source"]
        raise UserError, "#{loc}.for_each: must be a hash with source:"
      end
      unless bound.include?(spec["source"].to_s)
        raise UserError, "#{loc}.for_each.source: #{spec["source"].inspect} is not bound by an earlier step " \
                         "(bound: #{bound.join(", ")})"
      end
      unless step["as_item"].is_a?(String) && !step["as_item"].empty?
        raise UserError, "#{loc}.for_each: requires as_item: (the loop variable name)"
      end
      do_steps = step["do"]
      unless do_steps.is_a?(Array) && !do_steps.empty?
        raise UserError, "#{loc}.for_each: requires a non-empty do: array"
      end
      unless step["as"].is_a?(String) && !step["as"].empty?
        raise UserError, "#{loc}.for_each: requires a non-empty as: to bind the collected result"
      end
      if step.key?("collect") && !%w[array map].include?(step["collect"].to_s)
        raise UserError, "#{loc}.for_each.collect: must be \"array\" or \"map\" (got #{step["collect"].inspect})"
      end
      map_mode = step["collect"].to_s == "map"
      if map_mode && !(step["key"].is_a?(String) && !step["key"].empty?)
        raise UserError, "#{loc}.for_each: collect: map requires a key: template"
      end

      inner     = bound.dup << step["as_item"]
      saw_yield = false
      do_steps.each_with_index do |sub, i|
        validate_plan_step!(sub, "#{loc}.do[#{i}]", endpoints, inner, allow_yield: true)
        saw_yield ||= sub.is_a?(Hash) && sub.key?("yield")
      end
      unless saw_yield
        raise UserError, "#{loc}.for_each.do: must contain a yield: step"
      end

      validate_plan_refs!(step["key"], "#{loc}.for_each.key", inner) if map_mode
      bound << step["as"]
    end

    def validate_plan_yield!(step, loc, bound)
      validate_plan_refs!(step["yield"], "#{loc}.yield", bound)
      return unless step.key?("skip_if_nil")

      ref = step["skip_if_nil"]
      unless ref.is_a?(String) && bound.include?(ref)
        raise UserError, "#{loc}.skip_if_nil: #{ref.inspect} is not a bound name"
      end
    end

    def bind_plan_as!(step, loc, bound)
      return unless step.key?("as")

      as = step["as"]
      unless as.is_a?(String) && !as.empty?
        raise UserError, "#{loc}.as: must be a non-empty string"
      end
      bound << as
    end

    # Every whole-token {name} / {name.path} in a template value must have
    # a bound root. Literals, numbers, and partial strings pass through.
    def validate_plan_refs!(node, loc, bound)
      case node
      when String
        m = /\A\{([^}]+)\}\z/.match(node)
        return unless m
        root = m[1].split(".").first
        unless bound.include?(root)
          raise UserError, "#{loc}: {#{m[1]}} references unbound name #{root.inspect} " \
                           "(bound: #{bound.join(", ")})"
        end
      when Hash  then node.each_value { |v| validate_plan_refs!(v, loc, bound) }
      when Array then node.each { |v| validate_plan_refs!(v, loc, bound) }
      end
    end

    WHEN_CONTEXT_NUMERIC_OPS = %w[gt gte lt lte].freeze
    WHEN_CONTEXT_EQUALITY_OPS = %w[eq neq].freeze
    WHEN_CONTEXT_PRESENCE_OPS = %w[present absent].freeze
    WHEN_CONTEXT_OPS = (WHEN_CONTEXT_NUMERIC_OPS + WHEN_CONTEXT_EQUALITY_OPS + WHEN_CONTEXT_PRESENCE_OPS).freeze

    def validate_step!(phase_name, step, index)
      unless step.is_a?(Hash) && step["action"].is_a?(String)
        raise UserError, "workflow #{@path} phase #{phase_name.inspect} step #{index}: must be a hash with an action: key"
      end

      action = step["action"]
      unless WorkflowActions.known?(action)
        raise UserError, "workflow #{@path} phase #{phase_name.inspect} step #{index}: " \
                         "unknown action #{action.inspect} (known actions: #{WorkflowActions.names.sort.join(", ")})"
      end

      validate_when_context!(phase_name, step, index) if step.key?("when_context")

      case step["action"]
      when "click_text"
        loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: click_text"
        unless step["text"].is_a?(String) && !step["text"].empty?
          raise UserError, "#{loc} requires a non-empty text:"
        end
        if step.key?("role") && !%w[button link any].include?(step["role"])
          raise UserError, "#{loc} role: must be one of button, link, any (got #{step["role"].inspect})"
        end
        if step.key?("within") && !step["within"].is_a?(String)
          raise UserError, "#{loc} within: must be a string"
        end
        if step.key?("match") && !%w[exact contains prefix].include?(step["match"])
          raise UserError, "#{loc} match: must be one of exact, contains, prefix (got #{step["match"].inspect})"
        end
        if step.key?("timeout") && !(step["timeout"].is_a?(Integer) && step["timeout"] >= 1)
          raise UserError, "#{loc} timeout: must be a positive integer"
        end
      when "fill", "fill_if_present"
        if step.key?("clear") && ![true, false].include?(step["clear"])
          raise UserError, "workflow #{@path} phase #{phase_name.inspect} step #{index}: #{step["action"]} clear: must be true or false"
        end
      when "record_requests"
        validate_record_requests!(phase_name, step, index)
      when "dump_requests"
        validate_dump_requests!(phase_name, step, index)
      when "pause"
        validate_pause!(phase_name, step, index)
      when "capture_url"
        validate_capture_url!(phase_name, step, index)
      when "capture_response_header"
        validate_capture_response_header!(phase_name, step, index)
      when "elevate_session"
        validate_elevate_session!(phase_name, step, index)
      when "capture_local_storage", "capture_session_storage"
        validate_capture_dom_storage!(phase_name, step, index)
      when "capture_outbound_request_headers"
        validate_capture_outbound_request_headers!(phase_name, step, index)
      when "prompt_stdin_and_fill"
        loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: prompt_stdin_and_fill"
        unless step["selector"].is_a?(String) && !step["selector"].empty?
          raise UserError, "#{loc} requires a non-empty selector:"
        end
        unless step["prompt"].is_a?(String) && !step["prompt"].empty?
          raise UserError, "#{loc} requires a non-empty prompt:"
        end
        unless step["timeout"].is_a?(Integer) && step["timeout"] >= 1
          raise UserError, "#{loc} requires a positive integer timeout: in seconds"
        end
        if step.key?("submit_selector") && !step["submit_selector"].is_a?(String)
          raise UserError, "#{loc} submit_selector: must be a string"
        end
        if step.key?("mask") && ![true, false].include?(step["mask"])
          raise UserError, "#{loc} mask: must be true or false"
        end
        if step.key?("if_present") && ![true, false].include?(step["if_present"])
          raise UserError, "#{loc} if_present: must be true or false"
        end
      when "await_external_approval"
        loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: await_external_approval"
        unless step["message"].is_a?(String) && !step["message"].empty?
          raise UserError, "#{loc} requires a non-empty message:"
        end
        unless step["url_includes"].is_a?(String) && !step["url_includes"].empty?
          raise UserError, "#{loc} requires a non-empty url_includes:"
        end
        if step.key?("timeout") && !(step["timeout"].is_a?(Integer) && step["timeout"] >= 1)
          raise UserError, "#{loc} timeout: must be a positive integer"
        end
      end

      validate_required_keys!(phase_name, step, index)
    end

    # Load-time presence check for every action's required keys, driven by the
    # WorkflowActions registry. Runs after the per-action `case` so bespoke
    # validators (which give richer type-level messages) win when they cover a
    # key; this backstops the ~20 actions that have no bespoke validator.
    def validate_required_keys!(phase_name, step, index)
      action  = step["action"]
      missing = WorkflowActions.required_keys(action).reject { |k| step.key?(k) }
      return if missing.empty?

      raise UserError, "workflow #{@path} phase #{phase_name.inspect} step #{index}: " \
                       "#{action} requires #{missing.map { |k| "#{k}:" }.join(", ")}"
    end

    MAX_ENTRIES_CAP    = 10_000
    MAX_BODY_BYTES_CAP = 4 * 1024 * 1024  # 4 MB

    def validate_record_requests!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: record_requests"

      url_matches = step["url_matches"]
      unless url_matches.is_a?(Array) && !url_matches.empty? && url_matches.all? { |u| u.is_a?(String) && !u.empty? }
        raise UserError, "#{loc} requires a non-empty url_matches: array of strings"
      end

      if step.key?("include_response_body") && ![true, false].include?(step["include_response_body"])
        raise UserError, "#{loc} include_response_body: must be true or false"
      end

      if step.key?("max_body_bytes")
        v = step["max_body_bytes"]
        unless v.is_a?(Integer) && v >= 1 && v <= MAX_BODY_BYTES_CAP
          raise UserError, "#{loc} max_body_bytes: must be an integer between 1 and #{MAX_BODY_BYTES_CAP}"
        end
      end

      if step.key?("max_entries")
        v = step["max_entries"]
        unless v.is_a?(Integer) && v >= 1 && v <= MAX_ENTRIES_CAP
          raise UserError, "#{loc} max_entries: must be an integer between 1 and #{MAX_ENTRIES_CAP}"
        end
      end
    end

    def validate_dump_requests!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: dump_requests"

      unless step["path"].is_a?(String) && !step["path"].empty?
        raise UserError, "#{loc} requires a non-empty path:"
      end

      if step.key?("format") && !%w[ndjson har].include?(step["format"])
        raise UserError, "#{loc} format: must be ndjson or har (got #{step["format"].inspect})"
      end

      if step.key?("reset") && ![true, false].include?(step["reset"])
        raise UserError, "#{loc} reset: must be true or false"
      end
    end

    def validate_pause!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: pause"

      unless step["message"].is_a?(String) && !step["message"].empty?
        raise UserError, "#{loc} requires a non-empty message:"
      end

      unless step["timeout"].is_a?(Integer) && step["timeout"] >= 1
        raise UserError, "#{loc} requires a positive integer timeout: in seconds"
      end
    end

    def validate_capture_url!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: capture_url"

      unless step["as"].is_a?(String) && !step["as"].empty?
        raise UserError, "#{loc} requires a non-empty as:"
      end
    end

    def validate_elevate_session!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: elevate_session"

      signals = step["wait_for_first_of"]
      unless signals.is_a?(Hash)
        raise UserError, "#{loc} requires a wait_for_first_of: hash with branches: and timeout:"
      end

      branches = signals["branches"]
      unless branches.is_a?(Array) && !branches.empty?
        raise UserError, "#{loc} wait_for_first_of.branches: must be a non-empty array"
      end

      branches.each_with_index do |branch, b_idx|
        validate_elevation_branch!(loc, branch, "wait_for_first_of.branches[#{b_idx}]")
      end

      if signals.key?("timeout") && !(signals["timeout"].is_a?(Integer) && signals["timeout"] >= 1)
        raise UserError, "#{loc} wait_for_first_of.timeout: must be a positive integer"
      end

      sca_branches = branches.select { |b| b["on_match"].to_s == "sca" }

      if sca_branches.any? && !step.key?("on_sca")
        raise UserError, "#{loc} a branch is tagged on_match: sca but the step has no on_sca: block"
      end

      if step.key?("on_sca")
        on_sca = step["on_sca"]
        unless on_sca.is_a?(Hash)
          raise UserError, "#{loc} on_sca: must be a hash"
        end
        unless on_sca["prompt"].is_a?(String) && !on_sca["prompt"].empty?
          raise UserError, "#{loc} on_sca.prompt: must be a non-empty string"
        end
        completion = on_sca["wait_for_first_of"]
        unless completion.is_a?(Hash) && completion["branches"].is_a?(Array) && !completion["branches"].empty?
          raise UserError, "#{loc} on_sca.wait_for_first_of.branches: must be a non-empty array"
        end
        completion["branches"].each_with_index do |branch, b_idx|
          validate_elevation_branch!(loc, branch, "on_sca.wait_for_first_of.branches[#{b_idx}]")
        end
        if completion.key?("timeout") && !(completion["timeout"].is_a?(Integer) && completion["timeout"] >= 1)
          raise UserError, "#{loc} on_sca.wait_for_first_of.timeout: must be a positive integer"
        end
        if on_sca.key?("prompt_timeout") && !(on_sca["prompt_timeout"].is_a?(Integer) && on_sca["prompt_timeout"] >= 1)
          raise UserError, "#{loc} on_sca.prompt_timeout: must be a positive integer"
        end
      end

      %w[navigate_to trigger_selector].each do |opt|
        next unless step.key?(opt)
        unless step[opt].is_a?(String) && !step[opt].empty?
          raise UserError, "#{loc} #{opt}: must be a non-empty string when set"
        end
      end
    end

    def validate_elevation_branch!(loc, branch, path)
      unless branch.is_a?(Hash)
        raise UserError, "#{loc} #{path} must be a hash"
      end
      sel = branch["selector"]
      url = branch["url_includes"]
      if (sel.nil? || sel.to_s.empty?) && (url.nil? || url.to_s.empty?)
        raise UserError, "#{loc} #{path} must have a non-empty selector: or url_includes:"
      end
      if sel && !(sel.is_a?(String) && !sel.empty?)
        raise UserError, "#{loc} #{path}.selector must be a non-empty string"
      end
      if url && !(url.is_a?(String) && !url.empty?)
        raise UserError, "#{loc} #{path}.url_includes must be a non-empty string"
      end
      if branch.key?("on_match") && !branch["on_match"].is_a?(String)
        raise UserError, "#{loc} #{path}.on_match must be a string when set"
      end
    end

    def validate_capture_outbound_request_headers!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: capture_outbound_request_headers"

      %w[host path as].each do |key|
        unless step[key].is_a?(String) && !step[key].empty?
          raise UserError, "#{loc} requires a non-empty #{key}:"
        end
      end

      headers = step["headers"]
      unless headers.is_a?(Array) && !headers.empty? && headers.all? { |h| h.is_a?(String) && !h.empty? }
        raise UserError, "#{loc} headers: must be a non-empty array of non-empty strings"
      end

      if step.key?("most_recent") && ![true, false].include?(step["most_recent"])
        raise UserError, "#{loc} most_recent: must be true or false"
      end

      if step.key?("required") && ![true, false].include?(step["required"])
        raise UserError, "#{loc} required: must be true or false"
      end
    end

    def validate_capture_dom_storage!(phase_name, step, index)
      action = step["action"]
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: #{action}"

      %w[origin as].each do |key|
        unless step[key].is_a?(String) && !step[key].empty?
          raise UserError, "#{loc} requires a non-empty #{key}:"
        end
      end

      if step.key?("keys")
        unless step["keys"].is_a?(Array) && !step["keys"].empty? && step["keys"].all? { |k| k.is_a?(String) && !k.empty? }
          raise UserError, "#{loc} keys: must be a non-empty array of non-empty strings when set"
        end
      end

      if step.key?("required") && ![true, false].include?(step["required"])
        raise UserError, "#{loc} required: must be true or false"
      end
    end

    def validate_capture_response_header!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: capture_response_header"

      %w[host path header as].each do |key|
        unless step[key].is_a?(String) && !step[key].empty?
          raise UserError, "#{loc} requires a non-empty #{key}:"
        end
      end

      if step.key?("required") && ![true, false].include?(step["required"])
        raise UserError, "#{loc} required: must be true or false"
      end
    end

    def validate_when_context!(phase_name, step, index)
      loc = "workflow #{@path} phase #{phase_name.inspect} step #{index}: when_context"
      gate = step["when_context"]

      unless gate.is_a?(Hash)
        raise UserError, "#{loc} must be a hash"
      end

      gate.each do |key, ops|
        unless ops.is_a?(Hash) && !ops.empty?
          raise UserError, "#{loc} key #{key.inspect} must map to a non-empty hash of operators"
        end

        ops.each do |op, operand|
          unless WHEN_CONTEXT_OPS.include?(op)
            raise UserError, "#{loc} key #{key.inspect}: unknown operator #{op.inspect} (allowed: #{WHEN_CONTEXT_OPS.join(", ")})"
          end

          if WHEN_CONTEXT_NUMERIC_OPS.include?(op) && !operand.is_a?(Numeric)
            raise UserError, "#{loc} key #{key.inspect}: operator #{op.inspect} requires a numeric operand, got #{operand.inspect}"
          end

          if WHEN_CONTEXT_PRESENCE_OPS.include?(op) && ![true, false].include?(operand)
            raise UserError, "#{loc} key #{key.inspect}: operator #{op.inspect} requires a boolean operand, got #{operand.inspect}"
          end
        end
      end
    end
  end
end
