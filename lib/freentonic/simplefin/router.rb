# frozen_string_literal: true

require_relative "admin_api"
require_relative "admin_ui"
require_relative "http"
require_relative "protocol"

module Freentonic
  module Simplefin
    # Top-level path dispatcher for everything under /simplefin and /admin.
    # Returns :handled when it wrote the response itself, :not_handled when
    # the path doesn't belong here (so InvokeServer's existing dispatch can
    # keep its precedence rules).
    class Router
      def initialize(feature:, workflows_dir:, asset_dir:, runs_dir: nil)
        @protocol   = Protocol.new(feature: feature)
        @admin_api  = AdminApi.new(feature: feature, workflows_dir: workflows_dir, runs_dir: runs_dir)
        @admin_ui   = AdminUi.new(feature: feature, asset_dir: asset_dir)
      end

      # `request` is the InvokeServer::Request struct.
      # Returns :handled if the response was written; :not_handled otherwise.
      def dispatch(client, request)
        path = request.path
        pathname = path.split("?", 2).first

        if pathname.start_with?("/simplefin/")
          @protocol.dispatch(client, request.method, path, request)
          return :handled
        end

        if pathname.start_with?("/admin/api/")
          return :handled if handle_admin_api(client, request, path)
        end

        if pathname == "/admin" || pathname == "/admin/" || pathname.start_with?("/admin/")
          @admin_ui.dispatch(client, request.method, path, request)
          return :handled
        end

        :not_handled
      end

      private

      def handle_admin_api(client, request, path)
        # The admin API accepts Bearer admin_password (tests / scripting)
        # OR a valid session cookie (browser UI). We add the cookie path by
        # injecting a synthetic Authorization header when the cookie is
        # valid — keeps AdminApi's auth check simple.
        if @admin_ui.session_authenticated?(request) && !request.headers["authorization"]
          request.headers["authorization"] = "Bearer #{admin_ui_password}"
        end
        @admin_api.dispatch(client, request.method, path, request)
        true
      end

      def admin_ui_password
        # Only called when session_authenticated? was true, i.e. the cookie
        # already matched the configured password. Returning the live value
        # is safe because it never leaves the process.
        @admin_ui.instance_variable_get(:@feature).admin_password
      end
    end
  end
end
