# frozen_string_literal: true

module Freentonic
  # Single source of truth for the X display geometry. The container
  # entrypoint launches `Xvfb -screen 0 ${FREENTONIC_XVFB_GEOMETRY}`
  # (default 1280x800x24); Chrome's `--window-size` and the CDP
  # `setDeviceMetricsOverride` viewport must match, or Chrome opens a
  # window larger than the display and either clips or fails to launch
  # cleanly (the operator sees the noVNC iframe flash and then die).
  #
  # Format mirrors the Xvfb -screen flag: `<width>x<height>x<depth>`.
  # Depth is ignored here — Chrome cares only about width and height.
  module DisplayGeometry
    DEFAULT_WIDTH  = 1280
    DEFAULT_HEIGHT = 800

    module_function

    # Returns [width, height] as integers. Falls back to the defaults
    # on missing/malformed env so a typo doesn't take Chrome out.
    def call
      raw = ENV["FREENTONIC_XVFB_GEOMETRY"].to_s.strip
      return [DEFAULT_WIDTH, DEFAULT_HEIGHT] if raw.empty?
      m = raw.match(/\A(\d+)x(\d+)(?:x\d+)?\z/)
      return [DEFAULT_WIDTH, DEFAULT_HEIGHT] unless m
      w = m[1].to_i
      h = m[2].to_i
      return [DEFAULT_WIDTH, DEFAULT_HEIGHT] if w <= 0 || h <= 0
      [w, h]
    end

    def width;  call.first;  end
    def height; call.last;   end
  end
end
