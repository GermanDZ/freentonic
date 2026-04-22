# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

require_relative "crypto"
require_relative "http"

module Freentonic
  module Simplefin
    # Cookie-session admin UI. One password (the bearer token used by the
    # admin API). On login we mint a random cookie value that we store as a
    # PBKDF2 hash in memory keyed by its cookie value — the password never
    # touches the wire after login.
    #
    # Sessions are in-memory, so a restart logs everyone out (fine for a
    # single-tenant self-hosted deployment).
    class AdminUi
      SESSION_COOKIE  = "freentonic_simplefin_session"
      SESSION_TTL_SEC = 24 * 3600

      def initialize(feature:, asset_dir:)
        @feature    = feature
        @asset_dir  = asset_dir
        @sessions   = {}
        @session_mu = Mutex.new
      end

      def dispatch(client, method, path, request)
        pathname, _params = Http.split_query(path)

        case
        when pathname == "/admin/login" && method == "GET"
          render_login(client, message: nil)
        when pathname == "/admin/login" && method == "POST"
          handle_login(client, request)
        when pathname == "/admin/logout" && method == "POST"
          handle_logout(client, request)
        when pathname == "/admin" || pathname == "/admin/"
          return render_login(client, message: nil) unless authenticated?(request)
          serve_asset(client, "index.html")
        when pathname.start_with?("/admin/assets/")
          rel = pathname.sub(%r{\A/admin/assets/}, "")
          return render_login(client, message: nil) unless authenticated?(request)
          serve_asset(client, rel)
        else
          Http.write_json(client, 404, { "error" => "not found" })
        end
      end

      # API-style handler: accepts Bearer admin password OR a valid session
      # cookie. Used by the /admin/api/* endpoints as a fallback so the UI
      # can call them with cookie auth without having to restore the
      # password on every page load.
      def session_authenticated?(request)
        authenticated?(request)
      end

      private

      def render_login(client, message:)
        message_html = message ? "<p class=\"err\">#{html_escape(message)}</p>" : ""
        html = <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>Freentonic — Admin</title>
            <link rel="stylesheet" href="/admin/assets/styles.css">
          </head>
          <body class="login">
            <main>
              <h1>Freentonic</h1>
              <p class="sub">SimpleFIN bridge — admin sign-in</p>
              #{message_html}
              <form method="post" action="/admin/login">
                <label>Admin password
                  <input type="password" name="password" autofocus required>
                </label>
                <button type="submit">Sign in</button>
              </form>
            </main>
          </body>
          </html>
        HTML
        Http.write_html(client, 200, html)
      end

      def handle_login(client, request)
        form = Http.parse_form(request.body)
        password = form["password"].to_s
        if Crypto.secure_compare(password, @feature.admin_password) && !password.empty?
          cookie_value = mint_session
          Http.write_redirect(client, "/admin/", status: 303,
            headers: {
              "Set-Cookie" => build_cookie(cookie_value)
            })
        else
          render_login(client, message: "Incorrect password")
        end
      end

      def handle_logout(client, request)
        cookie = cookie_value_from(request)
        @session_mu.synchronize { @sessions.delete(cookie) if cookie }
        Http.write_redirect(client, "/admin/login", status: 303,
          headers: { "Set-Cookie" => build_cookie("", max_age: 0) })
      end

      def mint_session
        token = Crypto.random_token(bytes: 32)
        @session_mu.synchronize do
          @sessions[token] = Time.now.to_i + SESSION_TTL_SEC
        end
        expire_stale
        token
      end

      def expire_stale
        now = Time.now.to_i
        @session_mu.synchronize do
          @sessions.delete_if { |_, expiry| expiry < now }
        end
      end

      def authenticated?(request)
        return true if bearer_ok?(request)
        cookie = cookie_value_from(request)
        return false if cookie.nil? || cookie.empty?
        @session_mu.synchronize do
          expiry = @sessions[cookie]
          return false if expiry.nil?
          return false if expiry < Time.now.to_i
          true
        end
      end

      def bearer_ok?(request)
        token = Http.bearer_token(request.headers["authorization"])
        return false unless token
        Crypto.secure_compare(token, @feature.admin_password)
      end

      def cookie_value_from(request)
        raw = request.headers["cookie"]
        return nil unless raw.is_a?(String)
        raw.split(/;\s*/).each do |pair|
          k, v = pair.split("=", 2)
          return v if k == SESSION_COOKIE
        end
        nil
      end

      def build_cookie(value, max_age: SESSION_TTL_SEC)
        attrs = [
          "#{SESSION_COOKIE}=#{value}",
          "Path=/",
          "HttpOnly",
          "SameSite=Strict",
          "Max-Age=#{max_age}"
        ]
        attrs.join("; ")
      end

      ASSET_MIME = {
        ".html" => "text/html; charset=utf-8",
        ".js"   => "application/javascript; charset=utf-8",
        ".css"  => "text/css; charset=utf-8",
        ".svg"  => "image/svg+xml"
      }.freeze

      # Serve a file from the bundled UI directory. Traversal-safe: the
      # resolved path must be a real file under the asset root.
      def serve_asset(client, rel)
        return not_found(client) if rel.include?("\0")
        candidate = File.expand_path(File.join(@asset_dir, rel))
        unless candidate.start_with?(File.expand_path(@asset_dir) + File::SEPARATOR) || candidate == File.expand_path(@asset_dir)
          return not_found(client)
        end
        return not_found(client) unless File.file?(candidate)

        body = File.binread(candidate)
        ext  = File.extname(candidate).downcase
        mime = ASSET_MIME[ext] || "application/octet-stream"
        Http.write(client, status: 200, body: body, headers: { "Content-Type" => mime })
      end

      def not_found(client)
        Http.write(client, status: 404, body: "not found")
      end

      def html_escape(str)
        str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
          .gsub('"', "&quot;").gsub("'", "&#39;")
      end
    end
  end
end
