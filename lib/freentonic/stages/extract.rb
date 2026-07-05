# frozen_string_literal: true

require "date"

module Freentonic
  module Stages
    # Extract stage: uses the workflow's api_client config and a provider-
    # supplied Extractor class to turn captured credentials into a raw
    # provider-shape payload.
    #
    # Reads context[:credentials], writes context[:raw].
    #
    # Extractor contract: the workflow YAML declares
    #
    #   extract:
    #     ruby: ./extractor.rb
    #     class: MyProvider::Extractor
    #
    # Extractor classes must implement
    #
    #   #call(client:, credentials:, from_date:, stdout:, stderr:,
    #         remote_prompt_store: nil, run_dir: nil)
    #
    # and return the raw provider payload (a Hash or Array). The last two
    # kwargs are optional — extractors that predate them keep working
    # because the stage filters its kwargs against the extractor's
    # declared parameters before invoking #call (see #call_extractor).
    #
    # remote_prompt_store is non-nil when FREENTONIC_RUN_DIR is set
    # (i.e. invoke-server runs); extractors use it to surface interactive
    # prompts mid-extraction — for example, asking the operator to
    # complete a PSD2 SCA challenge in their bank's mobile app and waiting
    # for the approval before resuming pagination. The store auto-emits
    # the `[freentonic][prompt] {...}` JSON-line that simplefreen-invoke
    # parses out of stderr to render the prompt in its admin UI.
    class Extract < Base
      def call
        stdout.puts "\nFetching data..."
        from_date = Date.today - @context.fetch(:lookback_days)

        client = source.workflow.build_api_client(@context[:credentials])
        extractor = load_extractor

        @context[:raw] = call_extractor(
          extractor,
          client:              client,
          credentials:         @context[:credentials],
          from_date:           from_date,
          stdout:              stdout,
          stderr:              stderr,
          remote_prompt_store: build_remote_prompt_store,
          run_dir:             run_dir
        )
        @context
      rescue ApiClient::SessionExpired => e
        # The captured session was rejected mid-extraction (401/403). This is
        # expected and actionable — the credentials need refreshing via a new
        # connect — so surface it as a UserError instead of letting the bare
        # SessionExpired escape as a backtrace when the provider doesn't
        # rescue it itself.
        raise UserError,
          "Extract failed: #{e.message}. Re-run connect to capture a fresh session."
      end

      private

      # Pass only the kwargs the extractor declares, so legacy extractors
      # whose `call(...)` signature predates remote_prompt_store/run_dir
      # don't ArgumentError. Extractors that opt in via `**kwargs` get
      # everything.
      def call_extractor(extractor, **all_kwargs)
        params = extractor.method(:call).parameters
        if params.any? { |kind, _| kind == :keyrest }
          extractor.call(**all_kwargs)
        else
          accepted = params.select { |kind, _| %i[key keyreq].include?(kind) }.map(&:last)
          extractor.call(**all_kwargs.slice(*accepted))
        end
      end

      def run_dir
        dir = ENV["FREENTONIC_RUN_DIR"]
        dir if dir && !dir.empty?
      end

      def build_remote_prompt_store
        dir = run_dir
        return nil unless dir
        Freentonic::RemotePromptStore.new(
          prompts_dir: File.join(dir, "prompts"),
          announce_to: stderr
        )
      end

      def load_extractor
        spec = source.extract_spec
        unless spec.is_a?(Hash) && spec["ruby"] && spec["class"]
          raise UserError, "workflow #{source.workflow.path}: extract: must be a hash with ruby: and class: keys"
        end

        workflow_dir = File.dirname(source.workflow.path)
        ruby_path = File.expand_path(spec["ruby"], workflow_dir)
        ruby_path = PathConfinement.resolve_within!(ruby_path, workflow_dir, label: "extract.ruby")
        require ruby_path
        klass = spec["class"].to_s.split("::").inject(Object) { |ns, name| ns.const_get(name, false) }
        klass.new
      end
    end
  end
end
