# frozen_string_literal: true

require "time"

require_relative "atomic_file"
require_relative "crypto"
require_relative "paths"

module Freentonic
  module Simplefin
    # CRUD over /workspace/simplefin/profiles/<key>.json.
    #
    # Each profile JSON has this shape (values shortened):
    #
    #   {
    #     "profile_key":       "ing_personal",
    #     "display_name":      "ING (personal)",
    #     "workflow":          "ing/workflow.yml",
    #     "lookback_days":     30,
    #     "max_lookback_days": 365,
    #     "created_at":        "2026-04-22T10:00:00Z",
    #     "updated_at":        "2026-04-22T10:00:00Z",
    #     "secrets_salt":      "base64...",        # PBKDF2 salt for AES subkey
    #     "secrets_envelopes": {                    # AES-GCM per-value
    #       "USER_DNI": { "iv": "...", "ct": "...", "tag": "...", "salt": "..." },
    #       ...
    #     },
    #     "access_url": {
    #       "username":    "simplefin",
    #       "password_pw": { "algo": "pbkdf2-hmac-sha256", ... }   # or null
    #     }
    #   }
    class ProfileStore
      def initialize(root: Paths.root)
        @root = root
        Paths.ensure_layout!(@root)
      end

      def list
        dir = Paths.profiles_dir(@root)
        return [] unless Dir.exist?(dir)
        Dir.children(dir).sort.each_with_object([]) do |name, acc|
          next unless name.end_with?(".json")
          key = name.sub(/\.json\z/, "")
          next unless key =~ Paths::FILENAME_PATTERN
          profile = read(key)
          acc << profile if profile
        end
      end

      def exists?(key)
        File.exist?(Paths.profile_path(key, @root))
      end

      def read(key)
        AtomicFile.read_json(Paths.profile_path(key, @root))
      end

      # Create a new profile. `attrs` accepts a subset of the stored fields.
      # Raises ArgumentError if the profile already exists.
      def create(key:, workflow:, display_name: nil, lookback_days: 30, max_lookback_days: 365,
                 sync_interval_seconds: nil, hidden_accounts: [])
        Paths.validate_component!(key, "profile_key")
        validate_workflow!(workflow)
        if exists?(key)
          raise ArgumentError, "simplefin: profile #{key.inspect} already exists"
        end
        now = Time.now.utc.iso8601
        profile = {
          "profile_key"           => key,
          "display_name"          => display_name || key,
          "workflow"              => workflow,
          "lookback_days"         => coerce_lookback(lookback_days),
          "max_lookback_days"     => coerce_lookback(max_lookback_days),
          "sync_interval_seconds" => coerce_interval(sync_interval_seconds),
          "hidden_accounts"       => coerce_hidden_accounts(hidden_accounts),
          "created_at"            => now,
          "updated_at"            => now,
          "secrets_salt"          => nil,
          "secrets_envelopes"     => {},
          "access_url"            => { "username" => nil, "password_pw" => nil }
        }
        AtomicFile.write_json(Paths.profile_path(key, @root), profile)
        profile
      end

      def update(key)
        path = Paths.profile_path(key, @root)
        AtomicFile.update_json(path) do |current|
          raise ArgumentError, "simplefin: profile #{key.inspect} not found" if current.nil? || current.empty?
          updated = yield(current.dup) || current
          updated["updated_at"] = Time.now.utc.iso8601
          updated
        end
        read(key)
      end

      def delete(key)
        AtomicFile.delete(Paths.profile_path(key, @root))
      end

      # Re-encrypt a whole credential set and persist. Replaces any previous
      # secrets_envelopes wholesale (old IV / ct unrecoverable).
      def write_credentials(key, plain_secrets, master_key:)
        unless plain_secrets.is_a?(Hash) && !plain_secrets.empty?
          raise ArgumentError, "simplefin: credentials must be a non-empty hash"
        end
        update(key) do |profile|
          salt = Crypto.random_salt
          envelopes = {}
          plain_secrets.each do |name, value|
            unless name.is_a?(String) && name =~ /\A[A-Za-z_][A-Za-z0-9_.]{0,127}\z/
              raise ArgumentError, "simplefin: credential name #{name.inspect} is not a valid identifier"
            end
            unless value.is_a?(String) && !value.include?("\n") && !value.include?("\0")
              raise ArgumentError, "simplefin: credential #{name} must be a string without NUL or newline"
            end
            envelopes[name] = Crypto.encrypt(master_key, salt, value)
          end
          profile["secrets_salt"]      = Crypto.encrypt(master_key, salt, "")["salt"]
          profile["secrets_envelopes"] = envelopes
          profile
        end
      end

      # Decrypt the stored credential envelopes. Returns a Hash of
      # { NAME => plaintext }. Raises if the master key is wrong.
      def read_credentials(key, master_key:)
        profile = read(key) or raise ArgumentError, "simplefin: profile #{key.inspect} not found"
        envelopes = profile["secrets_envelopes"] || {}
        envelopes.each_with_object({}) do |(name, env), acc|
          acc[name] = Crypto.decrypt(master_key, env)
        end
      end

      def set_access_url(key, username:, password_plain:)
        unless username.is_a?(String) && username =~ /\A[A-Za-z0-9_.\-]{1,64}\z/
          raise ArgumentError, "simplefin: access-url username has invalid characters"
        end
        unless password_plain.is_a?(String) && !password_plain.empty?
          raise ArgumentError, "simplefin: access-url password must be a non-empty string"
        end
        update(key) do |profile|
          profile["access_url"] = {
            "username"    => username,
            "password_pw" => Crypto.hash_password(password_plain)
          }
          profile
        end
      end

      def clear_access_url(key)
        update(key) do |profile|
          profile["access_url"] = { "username" => nil, "password_pw" => nil }
          profile
        end
      end

      def access_url_configured?(key)
        profile = read(key)
        return false unless profile
        au = profile["access_url"] || {}
        au["username"].is_a?(String) && au["password_pw"].is_a?(Hash)
      end

      # Verify an incoming (user, password) against the stored hash. Uses
      # constant-time compare on the hash output. Returns true/false.
      def verify_access(key, provided_user, provided_password)
        profile = read(key)
        return false unless profile
        au = profile["access_url"] || {}
        stored_user = au["username"]
        pw_record   = au["password_pw"]
        return false unless stored_user.is_a?(String) && pw_record.is_a?(Hash)
        return false unless Crypto.secure_compare(stored_user, provided_user.to_s)
        Crypto.verify_password(provided_password.to_s, pw_record)
      end

      private

      def coerce_lookback(value)
        int = Integer(value)
        raise ArgumentError, "simplefin: lookback_days must be positive" unless int.positive?
        raise ArgumentError, "simplefin: lookback_days exceeds 3650" if int > 3650
        int
      end

      # nil / 0 / "" → disabled (no auto-sync). Integer, in seconds.
      # Floor clamped to 5 min so a misconfiguration can't spam Chrome.
      def coerce_interval(value)
        return nil if value.nil? || value == "" || value == 0 || value == "0"
        int = Integer(value)
        return nil unless int.positive?
        raise ArgumentError, "simplefin: sync_interval_seconds must be >= 300 (5 min)" if int < 300
        int
      end

      def coerce_hidden_accounts(value)
        return [] if value.nil?
        unless value.is_a?(Array) && value.all? { |v| v.is_a?(String) && !v.empty? }
          raise ArgumentError, "simplefin: hidden_accounts must be an array of non-empty strings"
        end
        value.uniq
      end

      def validate_workflow!(workflow)
        unless workflow.is_a?(String) && !workflow.empty?
          raise ArgumentError, "simplefin: workflow is required"
        end
        if workflow.include?("\0") || workflow.include?("..")
          raise ArgumentError, "simplefin: workflow must not contain '..' or NUL"
        end
      end
    end
  end
end
