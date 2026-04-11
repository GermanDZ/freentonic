# frozen_string_literal: true

require "optparse"

module Freentonic
  # Command-line entry point. Drives the Engine from argv.
  #
  # Usage examples:
  #
  #   freentonic --workflow providers/ing.yml \
  #     --export json --export-path out.json
  #
  #   freentonic --workflow providers/ing.yml \
  #     --through extract --dump-raw /tmp/ing_raw.json
  #
  #   freentonic --workflow providers/ing.yml \
  #     --from-raw /tmp/ing_raw.json \
  #     --export http --export-url https://api.example.com/push --export-token $TOK
  class Cli
    STAGE_NAMES = %w[connect extract normalize export].freeze

    def initialize(stdout: $stdout, stderr: $stderr)
      @stdout = stdout
      @stderr = stderr
    end

    def run(argv)
      argv = pre_process_requires(argv.dup)
      options = parse(argv)
      validate!(options)
      execute(options)
      0
    rescue UserError => error
      @stderr.puts(error.message)
      1
    rescue ExportError => error
      @stderr.puts(error.message)
      2
    end

    private

    # `-r path/to/file.rb` loads user code BEFORE option parsing so custom
    # exporters / normalizers / secret backends have a chance to call
    # Freentonic::Exporters.register and friends at load time.
    def pre_process_requires(argv)
      remaining = []
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "-r" || arg == "--require"
          path = argv[i + 1] or raise UserError, "-r requires a path argument"
          require File.expand_path(path)
          i += 2
        elsif arg.start_with?("-r")
          require File.expand_path(arg[2..])
          i += 1
        else
          remaining << arg
          i += 1
        end
      end
      remaining
    end

    def parse(argv)
      options = {
        workflow: nil,
        lookback_days: nil,
        isolated: false,
        cdp_port: nil,
        only_stage: nil,
        through_stage: nil,
        dump_raw: nil,
        from_raw: nil,
        dump_normalized: nil,
        from_normalized: nil,
        secrets_backend: nil,
        secrets_file: nil,
        exporters: [] # array of { name:, options: {} }
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: freentonic --workflow PATH [options]"

        opts.on("--workflow PATH", "Path to workflow YAML") { |v| options[:workflow] = v }
        opts.on("--lookback DAYS", Integer, "Days of history to fetch") { |v| options[:lookback_days] = v }
        opts.on("--isolated", "Use a temporary Chrome profile (fresh login)") { options[:isolated] = true }
        opts.on("--port PORT", Integer, "Chrome debug port (default 9222)") { |v| options[:cdp_port] = v }

        opts.on("--only-stage STAGE", STAGE_NAMES, "Run exactly one stage (#{STAGE_NAMES.join("|")})") { |v| options[:only_stage] = v.to_sym }
        opts.on("--through STAGE", STAGE_NAMES, "Run stages up to and including this one") { |v| options[:through_stage] = v.to_sym }

        opts.on("--dump-raw PATH", "Write raw payload to PATH after extract ('-' = stdout)") { |v| options[:dump_raw] = v }
        opts.on("--from-raw PATH", "Load raw payload from PATH, skip connect + extract") { |v| options[:from_raw] = v }
        opts.on("--dump-normalized PATH", "Write normalized payload to PATH after normalize") { |v| options[:dump_normalized] = v }
        opts.on("--from-normalized PATH", "Load normalized payload from PATH, skip everything upstream") { |v| options[:from_normalized] = v }

        opts.on("--secrets BACKEND", "Secret backend (#{Secrets.registered.join("|")})") { |v| options[:secrets_backend] = v.to_sym }
        opts.on("--secrets-file PATH", "Path for plain_file backend") { |v| options[:secrets_file] = v }

        opts.on("--export NAME", "Add an exporter (#{Exporters.registered.join("|")}); repeatable") do |v|
          options[:exporters] << { name: v.to_sym, options: {} }
        end

        # Per-exporter options attach to the most recently declared --export.
        opts.on("--export-path PATH", "Path for the last-declared exporter") { |v| attach(options, :path, v) }
        opts.on("--export-url URL", "URL for the http exporter") { |v| attach(options, :url, v) }
        opts.on("--export-token TOKEN", "Bearer token for the http exporter") { |v| attach(options, :token, v) }
        opts.on("--export-method METHOD", "HTTP method (POST|PUT) for the http exporter") { |v| attach(options, :method, v) }
        opts.on("--export-content-type TYPE", "Content-Type for the http exporter") { |v| attach(options, :content_type, v) }
        opts.on("--export-header KV", "Extra header KEY=VAL for the http exporter (repeatable)") do |v|
          k, val = v.split("=", 2)
          raise UserError, "--export-header expects KEY=VALUE" unless k && val
          headers = (last_exporter(options)[:options][:headers] ||= {})
          headers[k] = val
        end
        opts.on("--export-csv-select PATH", "Nested path for csv/jsonl flattening (e.g. accounts.movements)") { |v| attach(options, :select, v) }

        opts.on("-h", "--help") { puts opts; exit 0 }
        opts.on("--version") { puts "freentonic #{Freentonic::VERSION}"; exit 0 }
      end

      parser.parse!(argv)
      options
    end

    def attach(options, key, value)
      last_exporter(options)[:options][key] = value
    end

    def last_exporter(options)
      options[:exporters].last or raise UserError,
        "--export-* flag before --export NAME (declare the exporter first)"
    end

    def validate!(options)
      unless options[:workflow] || options[:from_raw] || options[:from_normalized]
        raise UserError, "missing --workflow PATH"
      end

      if options[:only_stage] && options[:through_stage]
        raise UserError, "--only-stage and --through are mutually exclusive"
      end

      if options[:exporters].empty? && options[:only_stage] != :connect && options[:only_stage] != :extract && options[:dump_raw].nil? && options[:dump_normalized].nil?
        raise UserError, "no exporters configured — pass --export NAME or --dump-raw / --dump-normalized"
      end
    end

    def execute(options)
      source = options[:workflow] ? Source.new(workflow_path: File.expand_path(options[:workflow])) : nil

      secret_store = build_secret_store(options)
      secret_resolver = SecretResolver.new(secret_store: secret_store, stdout: @stdout, stderr: @stderr)

      exporters = options[:exporters].map { |cfg| Exporters.build(cfg[:name], cfg[:options]) }

      context = {
        source: source,
        stdout: @stdout,
        stderr: @stderr,
        secret_resolver: secret_resolver,
        lookback_days: options[:lookback_days] || source&.default_lookback_days || 14,
        isolated: options[:isolated],
        cdp_port: options[:cdp_port],
        only_stage: options[:only_stage],
        through_stage: options[:through_stage],
        dump_raw: options[:dump_raw],
        from_raw: options[:from_raw],
        dump_normalized: options[:dump_normalized],
        from_normalized: options[:from_normalized],
        exporters: exporters
      }

      Engine.new(context: context).run
    end

    def build_secret_store(options)
      name = options[:secrets_backend] || Secrets.default_name
      if name == :plain_file
        path = options[:secrets_file] or raise UserError, "--secrets plain_file requires --secrets-file PATH"
        @stderr.puts(Secrets::PlainFile.insecure_banner)
        Secrets::PlainFile.new(path: path)
      else
        Secrets.build(name)
      end
    end
  end
end
