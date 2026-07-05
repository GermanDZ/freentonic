# frozen_string_literal: true

module Freentonic
  module Elevate
    # Runs the `elevate:` step sequence — the session-elevation lifecycle
    # moment between connect and extract. It reuses the extract-plan
    # interpreter's verbs (fetch / select / for_each / let / concat /
    # dedup_by, each optionally `when:`-gated) via the #dispatch seam, and
    # adds the two session-affecting step kinds that a locked-down extract
    # plan is forbidden from having:
    #
    #   await_operator_approval — pause the flow for a human to approve an
    #     out-of-band challenge (SCA push) on their phone, surfaced through
    #     the RemotePromptStore the invoke server watches.
    #   rebind_credential       — install a value derived from a fetched
    #     response as an auth header on the shared client, so the later
    #     Extract stage inherits the elevated credential.
    #
    # Unlike a plan there is no `output:` — the phase's product is the
    # mutation it leaves on the client, not a returned hash. Failures
    # (approval timeout, empty rebind value, a fetch error) propagate to the
    # Elevate stage, which applies the `on_failure: degrade|abort` policy.
    class Interpreter < ExtractPlan::Interpreter
      # Default operator-approval wait, matching the browser SCA prompt.
      DEFAULT_APPROVAL_TIMEOUT = 180

      # @param steps [Array<Hash>] the elevate step sequence.
      # @param prompt_store [RemotePromptStore, nil] operator channel;
      #   nil (no FREENTONIC_RUN_DIR) makes await_operator_approval fail
      #   rather than hang a headless run.
      def initialize(steps:, endpoint_names:, stdout:, stderr:, prompt_store:)
        super({ "steps" => steps }, endpoint_names: endpoint_names,
              stdout: stdout, stderr: stderr)
        @prompt_store = prompt_store
      end

      # Run every step for its side effects; the elevate phase yields no
      # value (contrast ExtractPlan::Interpreter#run, which assembles
      # output:).
      def run(client:, scope:)
        @steps.each { |step| execute(step, client, scope) }
        nil
      end

      private

      def dispatch(step, client, scope)
        if step.key?("await_operator_approval") then do_await(step, scope)
        elsif step.key?("rebind_credential")     then do_rebind(step, client, scope)
        else super
        end
      end

      # await_operator_approval: { message:, timeout: } — surface a
      # confirm prompt and block until the operator approves or the
      # deadline passes. No operator channel → fail (never hang headless);
      # a RemotePromptStore::Timeout propagates to the on_failure policy.
      def do_await(step, scope)
        spec    = step["await_operator_approval"]
        message = scope.interpolate(spec["message"])
        timeout = Integer(spec["timeout"] || DEFAULT_APPROVAL_TIMEOUT)

        unless @prompt_store
          raise UserError, "await_operator_approval: no operator channel " \
                           "(set FREENTONIC_RUN_DIR so the invoke server can surface the prompt)"
        end

        @stdout.puts "    ⏳ #{message}"
        @prompt_store.prompt(kind: :confirm, message: message, mask: false,
                             timeout_seconds: timeout)
        @stdout.puts "    ✓ operator approved"
      end

      # rebind_credential: { header:, host:, value: } — resolve value
      # (embedded {token} interpolation, strict: a nil token fails the
      # step) and install it as an auth header on the shared client via
      # update_auth_headers!. The one sanctioned session mutation — the
      # declarative form of the imperative Bearer rotation ING did in Ruby.
      def do_rebind(step, client, scope)
        spec   = step["rebind_credential"]
        header = spec["header"].to_s
        host   = spec["host"]
        value  = resolve_rebind_value(spec["value"], header, scope)

        client.update_auth_headers!({ header => value }, host: host)
        @stdout.puts "    🔑 rebound #{header}#{host ? " @ #{host}" : ""}"
      end

      def resolve_rebind_value(template, header, scope)
        value = scope.interpolate(template, strict: true)
        raise UserError, "rebind_credential[#{header}]: value resolved empty" if value.to_s.empty?
        value
      rescue ArgumentError => e
        # strict interpolation raises ArgumentError on a nil token
        raise UserError, "rebind_credential[#{header}]: #{e.message}"
      end
    end
  end
end
