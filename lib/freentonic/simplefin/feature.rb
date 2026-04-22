# frozen_string_literal: true

require_relative "crypto"
require_relative "paths"
require_relative "profile_store"
require_relative "state_store"
require_relative "cache_store"
require_relative "claim_store"
require_relative "run_log"

module Freentonic
  module Simplefin
    # Top-level feature container. Owns the long-lived stores, the sync
    # queue worker, and the env-derived config. Constructed once per
    # InvokeServer startup; nil when the feature is disabled.
    #
    # Feature is gated by FREENTONIC_SIMPLEFIN_ENABLED=1. When disabled
    # every route below /simplefin and /admin responds 404 as if the
    # feature didn't exist.
    class Feature
      attr_reader :root, :master_key, :admin_password, :public_url,
                  :profile_store, :state_store, :cache_store, :claim_store,
                  :run_log, :queue, :logger

      def initialize(
        root:           Paths.root,
        master_key:,
        admin_password:,
        public_url:,
        logger:         nil
      )
        @root           = root
        @master_key     = master_key
        @admin_password = admin_password
        @public_url     = public_url.sub(/\/+\z/, "")
        @logger         = logger || ->(_msg) {}

        Paths.ensure_layout!(@root)

        @profile_store = ProfileStore.new(root: @root)
        @state_store   = StateStore.new(root: @root)
        @cache_store   = CacheStore.new(root: @root)
        @claim_store   = ClaimStore.new(root: @root)
        @run_log       = RunLog.new(root: @root)
        @queue         = nil # SyncQueue installed separately so test doubles fit
      end

      def install_queue(queue)
        @queue = queue
      end

      # Background sweeper that periodically GCs expired claims and stale
      # cache files. Returns self so the caller can chain .stop later.
      #
      # The interval is long enough (1h) that this is nearly free even on
      # a container running many profiles; short enough that a long-lived
      # process doesn't accumulate consumed claims or 14-day-stale caches
      # forever.
      def start_housekeeper(interval_seconds: 3600, cache_max_age_seconds: 14 * 24 * 3600)
        @housekeeper_stopping = false
        @housekeeper_thread = Thread.new do
          until @housekeeper_stopping
            interval_seconds.times do
              break if @housekeeper_stopping
              sleep 1
            end
            break if @housekeeper_stopping
            begin
              removed_claims = @claim_store.gc!
              removed_cache  = @cache_store.gc!(max_age_seconds: cache_max_age_seconds)
              if removed_claims.positive? || removed_cache.positive?
                log("housekeeper: removed #{removed_claims} claim(s), #{removed_cache} stale cache(s)")
              end
            rescue StandardError => e
              log("housekeeper error: #{e.class}: #{e.message}")
            end
          end
        end
        self
      end

      def stop_housekeeper(timeout: 5)
        @housekeeper_stopping = true
        @housekeeper_thread&.join(timeout)
        @housekeeper_thread = nil
      end

      # Reset any `queued` / `running` state to `idle` on boot — the
      # in-memory queue is ephemeral and Actual will re-enqueue on the
      # next /accounts call.
      def recover_on_boot!
        @state_store.all.each do |key, state|
          if %w[queued running].include?(state["state"])
            @state_store.force_state(key, "idle",
              "last_error" => "recovered from restart (previous state: #{state["state"]})")
          end
        end
        @claim_store.gc!
        @cache_store.gc!
      end

      def log(msg)
        @logger.call("[simplefin] #{msg}")
      end

      # ── config derivation from ENV ──────────────────────────
      #
      # Read at InvokeServer startup. Missing required env vars are a hard
      # error so the operator sees the problem immediately (docker-entrypoint
      # fails fast before the listener starts).

      ENABLED_ENV    = "FREENTONIC_SIMPLEFIN_ENABLED"
      MASTER_KEY_ENV = "FREENTONIC_SECRETS_KEY"
      ADMIN_PW_ENV   = "FREENTONIC_ADMIN_PASSWORD"
      PUBLIC_URL_ENV = "FREENTONIC_PUBLIC_URL"
      ROOT_ENV       = "FREENTONIC_SIMPLEFIN_ROOT"

      def self.enabled?
        %w[1 true yes on].include?(ENV[ENABLED_ENV].to_s.downcase)
      end

      # Build a Feature from ENV. Raises UserError listing every missing
      # piece of config so operators can fix them in one pass.
      def self.from_env(logger: nil)
        missing = []
        missing << MASTER_KEY_ENV if ENV[MASTER_KEY_ENV].to_s.empty?
        missing << ADMIN_PW_ENV   if ENV[ADMIN_PW_ENV].to_s.empty?
        missing << PUBLIC_URL_ENV if ENV[PUBLIC_URL_ENV].to_s.empty?
        unless missing.empty?
          raise UserError,
            "simplefin: #{ENABLED_ENV}=1 requires: #{missing.join(", ")}"
        end

        master_key = begin
          Crypto.decode_master_key(ENV.fetch(MASTER_KEY_ENV))
        rescue ArgumentError => e
          raise UserError, "simplefin: #{MASTER_KEY_ENV} invalid: #{e.message}"
        end

        new(
          root:           ENV[ROOT_ENV] || Paths.root,
          master_key:     master_key,
          admin_password: ENV.fetch(ADMIN_PW_ENV),
          public_url:     ENV.fetch(PUBLIC_URL_ENV),
          logger:         logger
        )
      end
    end
  end
end
