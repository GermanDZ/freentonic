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
    STAGE_ORDER = %i[connect extract normalize export].freeze

    STAGE_CLASSES = {
      connect:   Stages::Connect,
      extract:   Stages::Extract,
      normalize: Stages::Normalize,
      export:    Stages::Export
    }.freeze

    def initialize(context:)
      @context = context
    end

    def run
      load_serialized_inputs!
      stages_to_run.each do |name|
        run_stage(name)
        persist_stage_output(name)
      end
      @context
    end

    private

    def stages_to_run
      only = @context[:only_stage]
      through = @context[:through_stage]

      skip = Set.new
      skip << :connect   if @context[:from_raw] || @context[:from_normalized]
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
        @context[:normalized] = ::JSON.parse(File.read(path))
      elsif (path = @context[:from_raw])
        @context[:raw] = ::JSON.parse(File.read(path))
      end
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
