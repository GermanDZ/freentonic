# frozen_string_literal: true

require "time"

require_relative "atomic_file"
require_relative "paths"

module Freentonic
  module Simplefin
    # Per-profile state machine persistence.
    #
    # A state file looks like:
    #
    #   {
    #     "state":         "idle" | "queued" | "running" | "ready" |
    #                      "error" | "needs_reauth",
    #     "last_run_id":   "...",
    #     "last_error":    "short reason",   # when state == error / needs_reauth
    #     "last_synced_at":"2026-04-22T10:00:00Z",
    #     "updated_at":    "2026-04-22T10:00:00Z"
    #   }
    class StateStore
      STATES = %w[idle queued running ready error needs_reauth].freeze

      def initialize(root: Paths.root)
        @root = root
        Paths.ensure_layout!(@root)
      end

      def read(key)
        AtomicFile.read_json(Paths.state_path(key, @root)) || default_state
      end

      # Atomic compare-and-set. yields current → new hash. If the block
      # returns :abort the write is skipped. Returns the new state or nil.
      def update(key)
        path = Paths.state_path(key, @root)
        new_state = nil
        AtomicFile.update_json(path) do |current|
          hash = current.nil? || current.empty? ? default_state : current
          result = yield(hash)
          if result == :abort
            new_state = nil
            next nil
          end
          result["updated_at"] = Time.now.utc.iso8601
          unless STATES.include?(result["state"])
            raise ArgumentError, "simplefin: invalid state #{result["state"].inspect}"
          end
          new_state = result
        end
        new_state
      end

      # Bulk helper: force-transition (e.g. on startup recovery).
      def force_state(key, state, extras = {})
        update(key) do |current|
          current.merge(extras).merge("state" => state)
        end
      end

      def all
        dir = Paths.state_dir(@root)
        return {} unless Dir.exist?(dir)
        Dir.children(dir).each_with_object({}) do |name, acc|
          next unless name.end_with?(".json")
          key = name.sub(/\.json\z/, "")
          next unless key =~ Paths::FILENAME_PATTERN
          acc[key] = read(key)
        end
      end

      def default_state
        {
          "state"          => "idle",
          "last_run_id"    => nil,
          "last_error"     => nil,
          "last_synced_at" => nil,
          "updated_at"     => Time.now.utc.iso8601
        }
      end
    end
  end
end
