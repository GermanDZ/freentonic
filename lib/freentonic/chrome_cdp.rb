# frozen_string_literal: true

# Chrome / CDP helpers.
#
# Uses a dedicated Chrome profile at ~/.cache/freentonic/chrome so it
# doesn't conflict with the user's normal Chrome (macOS singleton).
# Device-trust state set during login persists between runs so only
# short-lived secrets are needed after the first session.
#
# --isolated flag uses a temp profile instead (no saved state).

require "net/http"
require "json"
require "uri"
require "socket"
require "base64"
require "securerandom"

module Freentonic
  module ChromeCdp
    CHROME_PATH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    # Prefer the actual Chromium ELF over /usr/bin/chromium on Debian —
    # the latter is a wrapper shell script that injects flags like
    # `--load-extension=` (empty), `--media-router=0`,
    # `--enable-remote-extensions`, and `--show-component-extension-options`.
    # Anti-bot fingerprinters check for these because no real user
    # ever has them. Calling the unwrapped binary gives us a clean
    # Chrome process whose only flags are the ones we explicitly pass.
    LINUX_CHROME_PATHS = %w[
      /usr/bin/google-chrome
      /usr/lib/chromium/chromium
      /usr/lib/chromium-browser/chromium-browser
      /usr/bin/chromium
      /usr/bin/chromium-browser
      /snap/bin/chromium
    ].freeze

    DEFAULT_PORT = 9222

    # Dedicated profile dir — separate from the system Chrome profile so
    # there's no singleton conflict. The user's normal Chrome can stay open.
    # Device-trust state set during login persists between runs, so only
    # short-lived secrets are needed after the first session.
    DEFAULT_PROFILE_DIR = File.expand_path("~/.cache/freentonic/chrome")

    @port = nil
    @pid = nil
    @profile_dir = nil
    @isolated = false
    @headless = false
    @no_sandbox = false

    class << self
      attr_reader :port, :profile_dir
    end

    def self.configure(port: DEFAULT_PORT, isolated: false, headless: false, no_sandbox: false)
      @port = port
      @isolated = isolated
      @headless = headless
      @no_sandbox = no_sandbox
      if isolated
        require "tmpdir"
        require "fileutils"
        @profile_dir = Dir.mktmpdir("freentonic-chrome-")
      else
        @profile_dir = resolve_profile_dir_from_env
        require "fileutils"
        FileUtils.mkdir_p(@profile_dir)
      end
    end

    # Precedence when running under the invoke server (non-isolated mode):
    #   1. FREENTONIC_CHROME_PROFILE_DIR  — absolute path, wins outright
    #   2. FREENTONIC_CHROME_PROFILE_KEY  — subdir under DEFAULT_PROFILE_DIR
    #   3. DEFAULT_PROFILE_DIR            — legacy single-profile CLI usage
    def self.resolve_profile_dir_from_env
      if (explicit = ENV["FREENTONIC_CHROME_PROFILE_DIR"]) && !explicit.empty?
        return explicit
      end
      if (key = ENV["FREENTONIC_CHROME_PROFILE_KEY"]) && !key.empty?
        return File.join(DEFAULT_PROFILE_DIR, key)
      end
      DEFAULT_PROFILE_DIR
    end

    # ─── Chrome lifecycle ───

    def self.chrome_binary
      return CHROME_PATH if File.exist?(CHROME_PATH)
      LINUX_CHROME_PATHS.each { |p| return p if File.exist?(p) }
      abort "Chrome/Chromium not found."
    end

    def self.debug_port_open?
      Net::HTTP.start("127.0.0.1", @port, open_timeout: 2, read_timeout: 2) do |http|
        http.get("/json/version")
      end
      true
    rescue StandardError
      false
    end

    def self.any_chrome_running?
      output = IO.popen(["pgrep", "-x", "Google Chrome"], err: File::NULL, &:read).to_s
      !output.strip.empty?
    rescue
      false
    end

    # pgrep -f takes a regex, so any regex metacharacters in the profile
    # path (`.`, `-` in a char class context, etc.) would over-match and
    # risk killing Chrome of a neighbouring profile. Escape before use.
    def self.pgrep_pattern_for(profile_dir)
      "user-data-dir=#{Regexp.escape(profile_dir)}"
    end

    # Check if a previous Chrome on our dedicated profile is still running.
    def self.owned_chrome_running?
      output = IO.popen(["pgrep", "-f", pgrep_pattern_for(@profile_dir)], err: File::NULL, &:read).to_s
      !output.strip.empty?
    rescue
      false
    end

    def self.kill_owned_chrome!
      pids = IO.popen(["pgrep", "-f", pgrep_pattern_for(@profile_dir)], err: File::NULL, &:read).to_s.split.map(&:to_i)
      pids.each { |pid| Process.kill("TERM", pid) rescue nil }
      10.times do
        return true unless owned_chrome_running?
        sleep 0.5
      end
      pids.each { |pid| Process.kill("KILL", pid) rescue nil }
      sleep 1
      !owned_chrome_running?
    end

    # Same contract as kill_owned_chrome!, but parameterized on a profile dir
    # rather than the module-level @profile_dir. Used by the invoke server to
    # clean up after a child that died before closing Chrome gracefully.
    # Safe to call when no Chrome is running for that profile (returns true).
    def self.kill_chrome_for(profile_dir)
      return true if profile_dir.nil? || profile_dir.empty?
      pattern = pgrep_pattern_for(profile_dir)
      probe = lambda do
        output = IO.popen(["pgrep", "-f", pattern], err: File::NULL, &:read).to_s
        !output.strip.empty?
      end

      return true unless probe.call

      pids = IO.popen(["pgrep", "-f", pattern], err: File::NULL, &:read).to_s.split.map(&:to_i)
      pids.each { |pid| Process.kill("TERM", pid) rescue nil }
      10.times do
        return true unless probe.call
        sleep 0.5
      end
      pids.each { |pid| Process.kill("KILL", pid) rescue nil }
      sleep 1
      !probe.call
    rescue StandardError
      false
    end

    def self.launch_chrome(url: nil)
      # Check if debug port is already open from a previous run
      if debug_port_open?
        return :attached
      end

      # Kill any previous Chrome we launched against our dedicated profile.
      if owned_chrome_running?
        puts "  Killing previous freentonic Chrome..."
        kill_owned_chrome!
      end

      # Remove stale lock files from crashed/killed Chrome instances
      require "fileutils"
      %w[SingletonLock SingletonCookie SingletonSocket].each do |f|
        path = File.join(@profile_dir, f)
        File.delete(path) if File.symlink?(path) || File.exist?(path)
      end

      args = [
        chrome_binary,
        "--remote-debugging-port=#{@port}",
        "--user-data-dir=#{@profile_dir}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=IsolateOrigins,site-per-process",
        "--disable-infobars",
        "--lang=es-ES",
        # Match the Xvfb display (1920x1080 in docker-entrypoint.sh) so the
        # Chrome window fills the X display end-to-end. Without this,
        # Chromium picks a smaller default and the noVNC viewer shows
        # Chrome anchored in a corner with empty desktop margin around it.
        # Headed (recording) and headless both want the same dimensions —
        # headless only needs an explicit size at all because there's no
        # display to inherit from, but matching Xvfb is correct in both.
        "--window-size=1920,1080"
      ]
      args << "--headless=new" if @headless
      # Prevent Chrome from exposing automation signals (navigator.webdriver,
      # window.chrome.csi, etc.) that captcha systems fingerprint.
      args << "--disable-blink-features=AutomationControlled"
      # Suppress the warning info bar that --disable-blink-features triggers —
      # captcha systems can detect it in the DOM.
      args << "--test-type"
      if @no_sandbox
        args << "--no-sandbox"
        args << "--disable-dev-shm-usage"
        args << "--disable-gpu"
      end
      args << url if url

      @pid = Process.spawn(*args, out: "/dev/null", err: "/dev/null")
      Process.detach(@pid)
      :launched
    end

    def self.wait_for_chrome_ready(timeout: 45)
      deadline = Time.now + timeout
      while Time.now < deadline
        return true if debug_port_open?
        print "."
        sleep 1
      end
      false
    end

    # Ask Chrome to close via CDP and wait for it to exit on its own. Chrome
    # needs time to flush SQLite journals (Cookies, DIPS, etc.) and clean up
    # temp files in the profile. Only fall back to signals if it doesn't
    # exit on its own within the grace period.
    def self.close_gracefully(session)
      return true unless @pid
      session&.send_command("Browser.close") rescue nil
      return finalize_chrome_exit if wait_for_chrome_exit(timeout: 10)

      Process.kill("TERM", @pid) rescue nil
      return finalize_chrome_exit if wait_for_chrome_exit(timeout: 5)

      Process.kill("KILL", @pid) rescue nil
      wait_for_chrome_exit(timeout: 2)
      finalize_chrome_exit
    end

    def self.kill_chrome
      return unless @pid
      Process.kill("TERM", @pid) rescue nil
      return finalize_chrome_exit if wait_for_chrome_exit(timeout: 6)

      Process.kill("KILL", @pid) rescue nil
      wait_for_chrome_exit(timeout: 2)
      finalize_chrome_exit
    end

    def self.wait_for_chrome_exit(timeout:)
      return true unless @pid
      deadline = Time.now + timeout
      while Time.now < deadline
        begin
          Process.kill(0, @pid)
        rescue Errno::ESRCH
          return true
        end
        sleep 0.2
      end
      false
    end

    def self.finalize_chrome_exit
      @pid = nil
      cleanup_isolated_profile!
      true
    end

    def self.chrome_process_running?
      return false unless @pid
      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH
      false
    end

    def self.cleanup_isolated_profile!
      if @isolated && @profile_dir && Dir.exist?(@profile_dir)
        FileUtils.rm_rf(@profile_dir)
        @profile_dir = nil
      end
    end

    # ─── CDP target discovery ───

    def self.get_targets
      body = Net::HTTP.get(URI("http://127.0.0.1:#{@port}/json"))
      JSON.parse(body)
    end

    def self.find_target_by_url(substring, wait: 0)
      deadline = Time.now + wait
      loop do
        targets = get_targets
        match = targets.find { |t| t["type"] == "page" && t["url"].to_s.include?(substring) }
        return match["webSocketDebuggerUrl"] if match
        break if Time.now >= deadline
        sleep 0.5
      end

      $stderr.puts "  Available page targets:"
      get_targets.select { |t| t["type"] == "page" }.each do |t|
        $stderr.puts "    - #{t['url']}"
      end
      abort "No tab matching #{substring.inspect} found after #{wait}s."
    end

    def self.find_first_page_target
      targets = get_targets
      page = targets.find { |t| t["type"] == "page" }
      abort "No page targets in Chrome" unless page
      page["webSocketDebuggerUrl"]
    end

    # ─── Minimal WebSocket client (RFC 6455) ───

    def self.ws_connect(ws_url)
      uri = URI(ws_url)
      socket = TCPSocket.new(uri.host, uri.port)
      ws_handshake(socket, uri)
      socket
    end

    def self.ws_handshake(socket, uri)
      key = Base64.strict_encode64(SecureRandom.bytes(16))
      request = [
        "GET #{uri.request_uri} HTTP/1.1",
        "Host: #{uri.host}:#{uri.port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}",
        "Sec-WebSocket-Version: 13",
        "", ""
      ].join("\r\n")
      socket.write(request)

      status_line = socket.gets
      abort "WebSocket upgrade failed: #{status_line.inspect}" unless status_line&.start_with?("HTTP/1.1 101")
      while (line = socket.gets) && line != "\r\n"; end
    end

    def self.ws_send_text(socket, text)
      payload = text.b
      bytes = []
      bytes << 0x81

      len = payload.bytesize
      if len < 126
        bytes << (0x80 | len)
      elsif len < 65_536
        bytes << (0x80 | 126)
        bytes << ((len >> 8) & 0xff)
        bytes << (len & 0xff)
      else
        bytes << (0x80 | 127)
        8.times { |i| bytes << ((len >> ((7 - i) * 8)) & 0xff) }
      end

      mask = Array.new(4) { rand(256) }
      bytes.concat(mask)
      payload.each_byte.with_index { |b, i| bytes << (b ^ mask[i % 4]) }
      socket.write(bytes.pack("C*"))
    end

    def self.ws_read_text(socket, timeout: 30)
      buffer = String.new
      loop do
        ready = IO.select([socket], nil, nil, timeout)
        raise "WebSocket read timed out after #{timeout}s" unless ready

        header = socket.read(2)
        raise "WebSocket closed unexpectedly" unless header && header.bytesize == 2
        b1, b2 = header.bytes
        fin = (b1 & 0x80) != 0
        opcode = b1 & 0x0f
        masked = (b2 & 0x80) != 0
        len = b2 & 0x7f

        if len == 126
          len = socket.read(2).unpack1("n")
        elsif len == 127
          len = socket.read(8).unpack1("Q>")
        end

        mask_key = masked ? socket.read(4).bytes : nil
        payload = len.positive? ? socket.read(len) : ""
        if mask_key
          payload = payload.each_byte.with_index.map { |b, i| (b ^ mask_key[i % 4]).chr }.join
        end

        case opcode
        when 0x1, 0x0 then buffer << payload
        when 0x8 then raise "WebSocket closed by server"
        when 0x9 then next
        end

        return buffer if fin
      end
    end

    # ─── CDP session wrapper ───

    class Session
      attr_reader :pending_events, :socket

      def initialize(socket)
        @socket = socket
        @next_id = 0
        @pending_events = []
      end

      def send_command(method, params = {}, timeout: 30)
        @next_id += 1
        id = @next_id
        msg = { id: id, method: method }
        msg[:params] = params unless params.empty?
        ChromeCdp.ws_send_text(@socket, JSON.generate(msg))

        deadline = Time.now + timeout
        while Time.now < deadline
          remaining = [deadline - Time.now, 0.1].max
          raw = ChromeCdp.ws_read_text(@socket, timeout: remaining)
          parsed = JSON.parse(raw)
          if parsed["id"] == id
            if parsed["error"]
              raise "CDP error on #{method}: #{parsed['error']['message']} (code #{parsed['error']['code']})"
            end
            return parsed["result"] || {}
          end
          @pending_events << parsed if parsed["method"]
        end
        raise "No CDP response for #{method} after #{timeout}s"
      end

      def wait_for_event(method, timeout: 30, &filter)
        deadline = Time.now + timeout
        @pending_events.reject! do |ev|
          if ev["method"] == method && (filter.nil? || filter.call(ev["params"]))
            return ev["params"]
          end
          false
        end
        while Time.now < deadline
          raw = ChromeCdp.ws_read_text(@socket, timeout: [deadline - Time.now, 1].max)
          parsed = JSON.parse(raw)
          if parsed["method"] == method && (filter.nil? || filter.call(parsed["params"]))
            return parsed["params"]
          end
          @pending_events << parsed if parsed["method"]
        end
        raise "Timed out waiting for event #{method}"
      end

      def close
        @socket.close rescue nil
      end
    end

    def self.open_session(ws_url)
      socket = ws_connect(ws_url)
      Session.new(socket)
    end

    # ─── Cookie reading ───

    def self.get_all_cookies(session)
      session.send_command("Network.enable")
      result = session.send_command("Network.getAllCookies")
      result["cookies"] || []
    end

    # ─── RFC 6265 cookie matching ───

    def self.cookie_domain_matches?(cookie, host)
      domain = cookie["domain"].to_s.sub(/^\./, "")
      return false if domain.empty?
      host == domain || host.end_with?(".#{domain}")
    end

    def self.cookie_path_matches?(cookie, request_path)
      cp = cookie["path"] || "/"
      return true if cp == "/"
      request_path == cp || request_path.start_with?("#{cp}/") || request_path.start_with?(cp)
    end

    def self.applicable_cookies(cookies, host:, path: "/")
      cookies.select { |c| cookie_domain_matches?(c, host) && cookie_path_matches?(c, path) }
    end

    def self.dedupe_cookies(cookies)
      by_name = {}
      cookies.each do |c|
        existing = by_name[c["name"]]
        if existing.nil? ||
           (c["path"]&.length || 0) > (existing["path"]&.length || 0) ||
           ((c["path"]&.length || 0) == (existing["path"]&.length || 0) &&
            c["domain"].sub(/^\./, "").length > existing["domain"].sub(/^\./, "").length)
          by_name[c["name"]] = c
        end
      end
      by_name.values
    end

    def self.format_cookie_header(cookies)
      cookies.map { |c| "#{c['name']}=#{c['value']}" }.join("; ")
    end
  end
end
