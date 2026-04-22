# frozen_string_literal: true

require "time"

require_relative "atomic_file"
require_relative "paths"

module Freentonic
  module Simplefin
    # Per-profile history of recent sync runs. One JSON file per run:
    #   {
    #     "run_id":      "...",
    #     "profile_key": "...",
    #     "started_at":  "...",
    #     "finished_at": "...",
    #     "duration_ms": 12345,
    #     "exit_code":   0,
    #     "error_kind":  nil | "user_error" | ...,
    #     "outcome":     "ready" | "error" | "needs_reauth",
    #     "message":     "short human description",
    #     "headed":      false,
    #     "log_path":    "runs/<run_id>/log"
    #   }
    class RunLog
      MAX_RETAINED = 100

      def initialize(root: Paths.root)
        @root = root
        Paths.ensure_layout!(@root)
      end

      def record(profile_key, entry)
        Paths.validate_component!(profile_key, "profile_key")
        run_id = entry.fetch(:run_id) { entry.fetch("run_id") }
        Paths.validate_component!(run_id, "run_id")
        dir = File.join(Paths.runs_dir(@root), profile_key)
        FileUtils.mkdir_p(dir, mode: 0o700)
        normalized = entry.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
        normalized["profile_key"] ||= profile_key
        AtomicFile.write_json(Paths.run_log_path(profile_key, run_id, @root), normalized)
        prune!(profile_key)
        normalized
      end

      # Most-recent-first list of recorded runs. Each entry is the hash
      # previously written by #record.
      def recent(profile_key, limit: 20)
        Paths.validate_component!(profile_key, "profile_key")
        dir = File.join(Paths.runs_dir(@root), profile_key)
        return [] unless Dir.exist?(dir)
        entries = Dir.children(dir).select { |n| n.end_with?(".json") }
        entries = entries.sort_by do |name|
          path = File.join(dir, name)
          -(File.mtime(path).to_f rescue 0.0)
        end
        entries.first(limit).map do |name|
          AtomicFile.read_json(File.join(dir, name))
        end.compact
      end

      private

      def prune!(profile_key)
        dir = File.join(Paths.runs_dir(@root), profile_key)
        return unless Dir.exist?(dir)
        names = Dir.children(dir).select { |n| n.end_with?(".json") }
        return if names.size <= MAX_RETAINED
        # Keep the freshest MAX_RETAINED by mtime, discard the rest.
        names
          .map { |n| [File.join(dir, n), File.mtime(File.join(dir, n)).to_f] }
          .sort_by { |_, m| -m }
          .drop(MAX_RETAINED)
          .each { |p, _| File.unlink(p) rescue nil }
      end
    end
  end
end
