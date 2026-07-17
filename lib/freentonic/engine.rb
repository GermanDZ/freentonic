# frozen_string_literal: true

require "date"

module Freentonic
  # Pipeline driver. Runs the Connect → Extract → Normalize → Export stages
  # in order, reading from and writing to a shared context Hash.
  #
  # Stage control:
  #   only_stage:     run exactly one stage (e.g. :extract)
  #   through_stage:  run every stage up to and including this one
  #
  # Serialization hooks (all optional, driven by CLI flags):
  #   dump_raw:         path to write context[:raw] as pretty JSON after Extract
  #   dump_normalized:  path to write context[:normalized] as pretty JSON after Normalize
  #   from_raw:         path to load raw payload from (skips Connect + Extract)
  #   from_normalized:  path to load normalized payload from (skips everything upstream)
  class Engine
    STAGE_ORDER = %i[connect elevate extract normalize export].freeze

    STAGE_CLASSES = {
      connect:   Stages::Connect,
      elevate:   Stages::Elevate,
      extract:   Stages::Extract,
      normalize: Stages::Normalize,
      export:    Stages::Export
    }.freeze

    def initialize(context:)
      @context = context
    end

    def run
      load_serialized_inputs!
      planned = stages_to_run
      ensure_ruby_capability!(planned)
      reporter.event("pipeline.start", stages: planned.map(&:to_s))
      planned.each do |name|
        reporter.stage(name) { run_stage(name) }
        persist_stage_output(name)
      end
      reporter.event("pipeline.finish", ok: true)
      @context
    end

    private

    # Fail fast, before any stage builds or the api_client is constructed, if
    # this run would execute provider Ruby a declarative-only server has not
    # opted into. Precise to the planned stages: a --from-normalized replay
    # that skips normalize won't trip on a normalize: ruby: workflow. See
    # Freentonic::RubyCapability.
    def ensure_ruby_capability!(planned)
      source = @context[:source]
      return unless source.respond_to?(:workflow?) && source.workflow?

      schema   = source.workflow
      features = []
      features << "extract: ruby:"   if planned.include?(:extract)   && schema.extract_uses_ruby?
      features << "normalize: ruby:" if planned.include?(:normalize) && schema.normalize_uses_ruby?
      # The api_client (and thus its ext module) is used by any fetching stage.
      if (planned & %i[connect elevate extract]).any? && schema.api_client_uses_ruby?
        features << "api_client ext"
      end
      RubyCapability.ensure_enabled!(features)
    end

    def reporter
      @context[:reporter] || Reporter.null
    end

    def stages_to_run
      only = @context[:only_stage]
      through = @context[:through_stage]
      # Interactive (browse), recording, and step modes all short-circuit the
      # pipeline at Connect: the operator just wants Chrome open at the
      # bank URL so they can interact via VNC (or drive it a step at a time
      # via the JSONL REPL). Extract/Normalize/Export have nothing to do —
      # and Connect doesn't populate credentials in those modes, so Extract
      # would NoMethodError on a nil creds hash if it ran.
      only = :connect if @context[:interactive] || @context[:recording] || @context[:step]

      skip = Set.new
      skip << :connect   if @context[:from_raw] || @context[:from_normalized]
      skip << :elevate   if @context[:from_raw] || @context[:from_normalized]
      skip << :extract   if @context[:from_raw] || @context[:from_normalized]
      skip << :normalize if @context[:from_normalized]

      base = if only
               [only.to_sym]
             elsif through
               idx = STAGE_ORDER.index(through.to_sym) or raise UserError, "unknown stage #{through.inspect}"
               STAGE_ORDER[0..idx]
             else
               STAGE_ORDER
             end

      base.reject { |s| skip.include?(s) }
    end

    def run_stage(name)
      klass = STAGE_CLASSES.fetch(name) { raise UserError, "unknown stage #{name.inspect}" }
      klass.new(context: @context).call
    end

    def load_serialized_inputs!
      if (path = @context[:from_normalized])
        @context[:normalized] = parse_serialized_input(path, "--from-normalized")
      elsif (path = @context[:from_raw])
        @context[:raw] = parse_serialized_input(path, "--from-raw")
      end
    end

    # Reads and JSON-parses an offline replay input. A missing file or
    # malformed JSON is operator error (a bad path or a truncated dump), not
    # a framework bug — surface it as a UserError the CLI renders cleanly
    # instead of an uncaught Errno / JSON::ParserError backtrace.
    def parse_serialized_input(path, flag)
      ::JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise UserError, "#{flag}: file not found: #{path}"
    rescue ::JSON::ParserError => e
      raise UserError, "#{flag}: #{path} is not valid JSON (#{e.message})"
    end

    # Explicit allowlist: only :raw and :normalized are ever serialized.
    # Other context keys (e.g. :debug_request_log from record_requests)
    # are intentionally excluded — captured network traffic must never
    # appear in stage dumps.
    def persist_stage_output(name)
      case name
      when :extract
        dump_json(@context[:raw], @context[:dump_raw]) if @context[:dump_raw]
      when :normalize
        dump_json(@context[:normalized], @context[:dump_normalized]) if @context[:dump_normalized]
      end
    end

    def dump_json(data, path)
      json = ::JSON.pretty_generate(data)
      if path == "-" || path.nil?
        $stdout.puts(json)
      else
        File.write(path, json)
      end
    end
  end
end

require "json"
require "set"
