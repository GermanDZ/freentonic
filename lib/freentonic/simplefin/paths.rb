# frozen_string_literal: true

require "fileutils"

module Freentonic
  module Simplefin
    # Filesystem layout + path-validation helpers. Every filename component
    # that originates outside the server (profile keys, claim IDs, run IDs)
    # must be matched against FILENAME_PATTERN before being joined into a
    # path — otherwise a caller could escape the workspace with "../../etc".
    module Paths
      # Same charset as InvokeRequest::PROFILE_KEY_PATTERN so a key minted by
      # the admin API can be reused as an InvokeRequest.profile_key without
      # mutation.
      FILENAME_PATTERN = /\A[A-Za-z0-9_.\-]{1,128}\z/

      module_function

      def root
        ENV["FREENTONIC_SIMPLEFIN_ROOT"] || "/workspace/simplefin"
      end

      def profiles_dir(root_dir = root) = File.join(root_dir, "profiles")
      def state_dir(root_dir = root)    = File.join(root_dir, "state")
      def cache_dir(root_dir = root)    = File.join(root_dir, "cache")
      def claims_dir(root_dir = root)   = File.join(root_dir, "claims")
      def runs_dir(root_dir = root)     = File.join(root_dir, "runs")

      # Ensure the layout exists with owner-only permissions. Safe to call
      # many times (mkdir_p is idempotent).
      def ensure_layout!(root_dir = root)
        FileUtils.mkdir_p(root_dir, mode: 0o700)
        [profiles_dir(root_dir), state_dir(root_dir), cache_dir(root_dir),
         claims_dir(root_dir), runs_dir(root_dir)].each do |d|
          FileUtils.mkdir_p(d, mode: 0o700)
        end
      end

      # Validate a single filename component. Raises ArgumentError when the
      # input escapes the accepted charset (anything a shell, a filesystem,
      # or a URL might interpret surprisingly).
      def validate_component!(value, label = "name")
        unless value.is_a?(String) && value =~ FILENAME_PATTERN
          raise ArgumentError,
            "simplefin: #{label} must match [A-Za-z0-9_.-]{1,128} (got #{value.inspect})"
        end
        value
      end

      def profile_path(key, root_dir = root)
        validate_component!(key, "profile_key")
        File.join(profiles_dir(root_dir), "#{key}.json")
      end

      def state_path(key, root_dir = root)
        validate_component!(key, "profile_key")
        File.join(state_dir(root_dir), "#{key}.json")
      end

      def cache_path(key, root_dir = root)
        validate_component!(key, "profile_key")
        File.join(cache_dir(root_dir), key, "latest.json")
      end

      def claim_path(claim_id, root_dir = root)
        validate_component!(claim_id, "claim_id")
        File.join(claims_dir(root_dir), "#{claim_id}.json")
      end

      def run_log_path(key, run_id, root_dir = root)
        validate_component!(key, "profile_key")
        validate_component!(run_id, "run_id")
        File.join(runs_dir(root_dir), key, "#{run_id}.json")
      end
    end
  end
end
