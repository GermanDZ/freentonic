# frozen_string_literal: true

require "json"
require "time"

module Freentonic
  # Serializes a debug request log (Array of entry hashes) to disk.
  # Supports two formats:
  #   - ndjson: one JSON object per line (default, greppable, diffable)
  #   - har:    minimal HAR 1.2 file (importable by Chrome DevTools)
  #
  # Path safety: rejects paths that look like they'd land inside a provider
  # repo or the current git repo — a speed bump to reduce accidental commits
  # of captured traffic.
  class DebugRequestWriter
    UNSAFE_PATH_PATTERNS = [
      /freentonic-providers[\/\\]/i
    ].freeze

    def initialize(path:, format: "ndjson")
      @path = File.expand_path(path)
      @format = format.to_s
      validate_path!
    end

    def write(entries)
      case @format
      when "ndjson" then write_ndjson(entries)
      when "har"    then write_har(entries)
      else
        raise UserError, "dump_requests: unknown format #{@format.inspect} (expected ndjson or har)"
      end
    end

    private

    def validate_path!
      UNSAFE_PATH_PATTERNS.each do |pattern|
        if @path.match?(pattern)
          raise UserError,
                "dump_requests: refusing to write to #{@path.inspect} — " \
                "path matches #{pattern.inspect}. Write captures outside your repo."
        end
      end

      # Reject paths inside the current git repo root (if we can detect it).
      git_root = detect_git_root
      if git_root && @path.start_with?(git_root + "/")
        raise UserError,
              "dump_requests: refusing to write to #{@path.inspect} — " \
              "path is inside the git repo at #{git_root}. " \
              "Write captures to /tmp or another directory outside the repo."
      end
    end

    def detect_git_root
      dir = Dir.pwd
      loop do
        return dir if Dir.exist?(File.join(dir, ".git"))
        parent = File.dirname(dir)
        return nil if parent == dir
        dir = parent
      end
    rescue StandardError
      nil
    end

    # 0600: these files hold raw request headers, session cookies, and
    # response bodies — match the secret-file discipline used for
    # screenshots, recordings, and prompt files.
    SECRET_FILE_MODE = File::WRONLY | File::CREAT | File::TRUNC

    def write_ndjson(entries)
      File.open(@path, SECRET_FILE_MODE, 0o600) do |f|
        entries.each do |entry|
          f.puts(JSON.generate(entry))
        end
      end
    end

    def write_har(entries)
      har = {
        "log" => {
          "version" => "1.2",
          "creator" => {
            "name" => "freentonic",
            "version" => defined?(Freentonic::VERSION) ? Freentonic::VERSION : "0.0.0"
          },
          "entries" => entries.map { |e| har_entry(e) }
        }
      }
      File.open(@path, SECRET_FILE_MODE, 0o600) do |f|
        f.write(JSON.pretty_generate(har))
      end
    end

    def har_entry(entry)
      req = entry["request"] || {}
      resp = entry["response"] || {}
      timings = entry["timings"] || {}

      {
        "startedDateTime" => timings["started_at"] || Time.now.iso8601,
        "time" => timings["duration_ms"] || 0,
        "request" => {
          "method" => req["method"] || "GET",
          "url" => req["url"] || "",
          "httpVersion" => "HTTP/1.1",
          "cookies" => [],
          "headers" => har_headers(req["headers"]),
          "queryString" => [],
          "headersSize" => -1,
          "bodySize" => (req["body"] || "").bytesize,
          "postData" => req["body"] ? { "mimeType" => "application/octet-stream", "text" => req["body"] } : nil
        }.compact,
        "response" => {
          "status" => resp["status"] || 0,
          "statusText" => "",
          "httpVersion" => "HTTP/1.1",
          "cookies" => [],
          "headers" => har_headers(resp["headers"]),
          "content" => {
            "size" => (resp["body"] || "").bytesize,
            "mimeType" => resp.dig("headers", "content-type") || resp.dig("headers", "Content-Type") || "application/octet-stream",
            "text" => resp["body"]
          }.compact,
          "redirectURL" => "",
          "headersSize" => -1,
          "bodySize" => (resp["body"] || "").bytesize
        },
        "cache" => {},
        "timings" => {
          "send" => -1,
          "wait" => timings["duration_ms"] || -1,
          "receive" => -1
        }
      }
    end

    def har_headers(headers)
      return [] unless headers.is_a?(Hash)
      headers.map { |name, value| { "name" => name.to_s, "value" => value.to_s } }
    end
  end
end
