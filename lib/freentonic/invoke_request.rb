# frozen_string_literal: true

require "digest"

module Freentonic
  class InvokeError < StandardError
    STATUS = {
      bad_request:   400,
      unauthorized:  401,
      not_found:     404,
      conflict:      409,
      unprocessable: 422,
      server_error:  500,
      unavailable:   503,
      timeout:       504
    }.freeze

    attr_reader :status_code, :kind

    def initialize(kind, message)
      @kind = kind
      @status_code = STATUS.fetch(kind) { 500 }
      super(message)
    end
  end

  # Validated invoke request. Constructed from a parsed JSON Hash and the
  # configured workflows root. Resolves the workflow path under the root
  # (rejecting traversal) and derives a deterministic profile_key when the
  # caller doesn't supply one.
  class InvokeRequest
    RUN_ID_PATTERN      = /\A[A-Za-z0-9_\-:.]{1,64}\z/
    PROFILE_KEY_PATTERN = /\A[A-Za-z0-9_.\-]{1,128}\z/
    EXPORT_PATH_PATTERN = /\A[A-Za-z0-9_.\-]{1,128}\z/
    HEADER_NAME_PATTERN = /\A[A-Za-z0-9!#$%&'*+\-.^_`|~]{1,64}\z/
    SECRET_KEY_PATTERN  = /\A[A-Za-z_][A-Za-z0-9_.]{0,127}\z/

    DEFAULT_TIMEOUT = 1800
    MAX_TIMEOUT     = 7200
    ALLOWED_EXPORT_MODES = %w[json jsonl csv http].freeze
    ALLOWED_HTTP_METHODS = %w[POST PUT].freeze

    attr_reader :run_id, :profile_key, :timeout_sec, :lookback, :workflow_path,
                :credentials_inline, :credentials_file, :export, :chrome

    # @param body [Hash] parsed JSON request
    # @param workflows_dir [String] absolute path to the workflows root
    def self.from_hash(body, workflows_dir:)
      new(body, workflows_dir: workflows_dir).tap(&:validate!)
    end

    def initialize(body, workflows_dir:)
      unless body.is_a?(Hash)
        raise InvokeError.new(:bad_request, "request body must be a JSON object")
      end
      @body = body
      @workflows_dir = workflows_dir
    end

    def validate!
      @run_id = require_string("run_id", pattern: RUN_ID_PATTERN)
      workflow_rel = require_string("workflow", kind: :bad_request)
      @workflow_path = resolve_workflow!(workflow_rel)

      @profile_key = parse_profile_key
      @credentials_inline, @credentials_file = parse_credentials
      @export = parse_export
      @timeout_sec = parse_timeout
      @lookback = parse_lookback
      @chrome = parse_chrome

      @profile_key ||= derive_profile_key
      self
    end

    # Directory under the chrome profile root for this request's profile_key.
    # The server supplies the root; this method only composes.
    def chrome_profile_subpath
      @profile_key
    end

    private

    def require_string(key, pattern: nil, kind: :bad_request)
      value = @body[key]
      unless value.is_a?(String) && !value.empty?
        raise InvokeError.new(kind, "#{key} is required and must be a non-empty string")
      end
      if pattern && value !~ pattern
        raise InvokeError.new(kind, "#{key} contains invalid characters or is too long")
      end
      value
    end

    def resolve_workflow!(workflow_rel)
      if workflow_rel.include?("\0")
        raise InvokeError.new(:bad_request, "workflow contains a null byte")
      end

      candidate = File.expand_path(File.join(@workflows_dir, workflow_rel))
      root = File.expand_path(@workflows_dir)

      # Fail fast on obvious traversal before touching the filesystem.
      unless candidate == root || candidate.start_with?(root + File::SEPARATOR)
        raise InvokeError.new(:not_found, "workflow not found under workflows root")
      end

      begin
        resolved = File.realpath(candidate)
      rescue Errno::ENOENT
        raise InvokeError.new(:not_found, "workflow not found: #{workflow_rel}")
      end

      resolved_root = File.realpath(root)
      unless resolved == resolved_root || resolved.start_with?(resolved_root + File::SEPARATOR)
        raise InvokeError.new(:not_found, "workflow resolves outside the workflows root")
      end

      unless File.file?(resolved)
        raise InvokeError.new(:not_found, "workflow is not a regular file: #{workflow_rel}")
      end

      resolved
    end

    def parse_profile_key
      value = @body["profile_key"]
      return nil if value.nil?
      unless value.is_a?(String) && value =~ PROFILE_KEY_PATTERN
        raise InvokeError.new(:bad_request, "profile_key contains invalid characters or is too long")
      end
      value
    end

    def parse_credentials
      creds = @body["credentials"]
      unless creds.is_a?(Hash)
        raise InvokeError.new(:unprocessable, "credentials block is required")
      end
      inline = creds["inline"]
      file   = creds["file"]

      if (inline && file) || (inline.nil? && file.nil?)
        raise InvokeError.new(:unprocessable, "credentials must contain exactly one of 'inline' or 'file'")
      end

      if inline
        unless inline.is_a?(Hash) && !inline.empty?
          raise InvokeError.new(:unprocessable, "credentials.inline must be a non-empty object")
        end
        inline.each do |key, value|
          unless key.is_a?(String) && key =~ SECRET_KEY_PATTERN
            raise InvokeError.new(:unprocessable, "credentials.inline key #{key.inspect} is not a valid identifier")
          end
          unless value.is_a?(String)
            raise InvokeError.new(:unprocessable, "credentials.inline value for #{key} must be a string")
          end
          if value.include?("\n") || value.include?("\0")
            raise InvokeError.new(:unprocessable, "credentials.inline value for #{key} contains a forbidden character")
          end
        end
      end

      if file
        unless file.is_a?(String) && File.absolute_path?(file)
          raise InvokeError.new(:unprocessable, "credentials.file must be an absolute path string")
        end
        unless File.file?(file)
          raise InvokeError.new(:unprocessable, "credentials.file does not exist: #{file}")
        end
      end

      [inline, file]
    end

    def parse_export
      return nil if @body["export"].nil?

      export = @body["export"]
      unless export.is_a?(Hash)
        raise InvokeError.new(:bad_request, "export must be an object")
      end

      mode = export["mode"]
      unless ALLOWED_EXPORT_MODES.include?(mode)
        raise InvokeError.new(:bad_request,
          "export.mode must be one of #{ALLOWED_EXPORT_MODES.join('|')}")
      end

      normalized = { "mode" => mode }

      case mode
      when "http"
        url = export["url"]
        unless url.is_a?(String) && !url.empty?
          raise InvokeError.new(:bad_request, "export.url is required for mode=http")
        end
        normalized["url"] = url

        # The runner scopes the child ENV (unsetenv_others: true), so the only
        # way the http exporter sees a token is through export.token → child
        # FREENTONIC_HTTP_TOKEN. An absent token would silently POST without
        # Authorization and 401 at the receiver, surfacing as a late
        # ExportError. Fail fast here instead.
        token = export["token"]
        if token.nil?
          raise InvokeError.new(:bad_request,
            "export.token is required for mode=http (pass an empty string if the receiver truly expects no Authorization header)")
        end
        unless token.is_a?(String)
          raise InvokeError.new(:bad_request, "export.token must be a string")
        end
        normalized["token"] = token unless token.empty?

        if export["method"]
          method = export["method"].to_s.upcase
          unless ALLOWED_HTTP_METHODS.include?(method)
            raise InvokeError.new(:bad_request, "export.method must be POST or PUT")
          end
          normalized["method"] = method
        end

        if export["content_type"]
          unless export["content_type"].is_a?(String)
            raise InvokeError.new(:bad_request, "export.content_type must be a string")
          end
          normalized["content_type"] = export["content_type"]
        end

        if export["headers"]
          unless export["headers"].is_a?(Hash)
            raise InvokeError.new(:bad_request, "export.headers must be an object")
          end
          export["headers"].each do |k, v|
            unless k.is_a?(String) && k =~ HEADER_NAME_PATTERN
              raise InvokeError.new(:bad_request, "export.headers key #{k.inspect} is not a valid header name")
            end
            unless v.is_a?(String) && !v.include?("\r") && !v.include?("\n")
              raise InvokeError.new(:bad_request, "export.headers value for #{k} must be a string without CRLF")
            end
          end
          normalized["headers"] = export["headers"]
        end

      else # file-based: json|jsonl|csv
        path = export["path"]
        unless path.is_a?(String) && path =~ EXPORT_PATH_PATTERN
          raise InvokeError.new(:bad_request,
            "export.path must be a simple filename (letters, digits, _.-) for mode=#{mode}")
        end
        normalized["path"] = path

        if export["select"]
          unless export["select"].is_a?(String) && !export["select"].empty?
            raise InvokeError.new(:bad_request, "export.select must be a non-empty string")
          end
          normalized["select"] = export["select"]
        end
      end

      normalized
    end

    def parse_timeout
      value = @body["timeout_sec"]
      return DEFAULT_TIMEOUT if value.nil?
      unless value.is_a?(Integer) && value > 0
        raise InvokeError.new(:bad_request, "timeout_sec must be a positive integer")
      end
      if value > MAX_TIMEOUT
        raise InvokeError.new(:bad_request, "timeout_sec exceeds max of #{MAX_TIMEOUT}")
      end
      value
    end

    def parse_lookback
      value = @body["lookback"]
      return nil if value.nil?
      unless value.is_a?(Integer) && value > 0 && value <= 3650
        raise InvokeError.new(:bad_request, "lookback must be a positive integer (days)")
      end
      value
    end

    def parse_chrome
      value = @body["chrome"]
      return {} if value.nil?
      unless value.is_a?(Hash)
        raise InvokeError.new(:bad_request, "chrome must be an object")
      end
      normalized = {}
      if value.key?("isolated")
        unless [true, false].include?(value["isolated"])
          raise InvokeError.new(:bad_request, "chrome.isolated must be boolean")
        end
        normalized["isolated"] = value["isolated"]
      end
      if value.key?("headless")
        unless [true, false].include?(value["headless"])
          raise InvokeError.new(:bad_request, "chrome.headless must be boolean")
        end
        normalized["headless"] = value["headless"]
      end
      normalized
    end

    # sha256(workflow_realpath + "\0" + credentials_fingerprint)[0..15]
    def derive_profile_key
      digest = Digest::SHA256.new
      digest.update(@workflow_path)
      digest.update("\0")
      digest.update(credentials_fingerprint)
      digest.hexdigest[0, 16]
    end

    def credentials_fingerprint
      if @credentials_inline
        sorted = @credentials_inline.sort.map { |k, v| "#{k}=#{v}" }.join("\n")
        Digest::SHA256.hexdigest(sorted)
      else
        Digest::SHA256.file(@credentials_file).hexdigest
      end
    end
  end
end
