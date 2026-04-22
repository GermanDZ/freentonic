# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "../simplefin/reshape"
require_relative "../simplefin/paths"

module Freentonic
  module Exporters
    # Writes the normalized payload to a SimpleFIN bridge cache file, after
    # reshaping it into the wire envelope Actual Budget's SimpleFIN adapter
    # expects. Used by the in-process SyncQueue inside the invoke server.
    #
    # Options:
    #   profile_key — required. Validated against the same charset as
    #                 InvokeRequest::PROFILE_KEY_PATTERN. Falls back to
    #                 ENV["FREENTONIC_SIMPLEFIN_PROFILE_KEY"] so the key
    #                 doesn't have to appear on the child's argv.
    #   cache_root  — defaults to ENV["FREENTONIC_SIMPLEFIN_ROOT"] or
    #                 /workspace/simplefin. The final write path is
    #                 <cache_root>/cache/<profile_key>/latest.json.
    class Simplefin < Base
      def write(payload)
        profile_key = (@options[:profile_key] || ENV["FREENTONIC_SIMPLEFIN_PROFILE_KEY"]).to_s
        if profile_key.empty? || profile_key !~ Freentonic::Simplefin::Paths::FILENAME_PATTERN
          raise UserError,
            "simplefin exporter: missing or invalid --export-simplefin-key (or FREENTONIC_SIMPLEFIN_PROFILE_KEY)"
        end

        root = (@options[:cache_root] || ENV["FREENTONIC_SIMPLEFIN_ROOT"] || "/workspace/simplefin").to_s
        envelope = Freentonic::Simplefin::Reshape.call(payload)

        cache_path = Freentonic::Simplefin::Paths.cache_path(profile_key, root)
        FileUtils.mkdir_p(File.dirname(cache_path), mode: 0o700)

        tmp = "#{cache_path}.tmp.#{Process.pid}"
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
          f.flock(File::LOCK_EX)
          f.write(::JSON.generate(envelope))
          f.fsync
        end
        File.rename(tmp, cache_path)

        # Mirror the http exporter's done-line so the invoke run log is
        # readable end-to-end.
        $stdout.puts("  → simplefin: wrote #{envelope["accounts"].size} account(s) to #{cache_path} " \
                     "(#{envelope["errors"].size} reshape error(s))")
        envelope
      rescue SystemCallError => e
        raise ExportError, "simplefin exporter: failed to write cache: #{e.class}: #{e.message}"
      end
    end

    register(:simplefin, Simplefin)
  end
end
