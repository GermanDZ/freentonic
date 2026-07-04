# frozen_string_literal: true

module Freentonic
  # Shared containment for provider-supplied ruby paths (extract:/normalize:
  # ruby, api_client.ext.file). Workflows are trusted code by design, but
  # these file references should stay inside the workflow's own directory
  # subtree — the documented "ship code alongside your YAML" pattern — so a
  # workflow can't require a ruby file the operator dropped elsewhere on the
  # box (e.g. an export artifact named foo.rb in a writable run dir).
  module PathConfinement
    module_function

    # Resolve `path` (already expanded) and require its realpath to sit within
    # `base_dir`. Returns the realpath. Raises UserError when the file is
    # missing or escapes the subtree (including via symlink).
    def resolve_within!(path, base_dir, label:)
      root = File.realpath(File.expand_path(base_dir))

      resolved =
        begin
          File.realpath(path)
        rescue Errno::ENOENT
          raise UserError, "#{label}: file not found: #{path}"
        end

      unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
        raise UserError,
              "#{label}: #{path} resolves outside the workflow directory (#{root}) — " \
              "provider ruby must live alongside the workflow YAML"
      end

      resolved
    end
  end
end
