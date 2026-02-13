# frozen_string_literal: true
require 'fileutils'
require 'sugar_png'

module ZBSpec
  # Builds minimal macOS .app bundles so the Dock shows a custom name and icon
  # instead of "java". Creates directory structure, Info.plist, launcher script,
  # and icon (generated with SugarPNG if icon.png missing or empty).
  class AppFactory
    # @param apps_root [String] Root directory for app bundles (e.g. /tmp or cache dir)
    # @param name [String] App name; bundle is created at apps_root/name/Contents/...
    # @return [String] Path to the executable (apps_root/name/Contents/MacOS/run.sh) for spawning
    def self.create(apps_root:, name:)
      new(apps_root: apps_root, name: name).create
    end

    def initialize(apps_root:, name:)
      @apps_root = File.expand_path(apps_root)
      @name = name.to_s
      @app_path = File.join(@apps_root, @name)
      @bundle_id = "com.zbspec.#{sanitize_bundle_id(@name)}"
    end

    def create
      macos_dir = File.join(@app_path, 'Contents', 'MacOS')
      resources_dir = File.join(@app_path, 'Contents', 'Resources')
      FileUtils.mkdir_p(macos_dir)
      FileUtils.mkdir_p(resources_dir)

      executable_path = File.join(macos_dir, 'run.sh')

      write_plist(resources_dir)
      write_launcher_script(executable_path)
      ensure_icon(resources_dir)

      executable_path
    end

    private

    def sanitize_bundle_id(name)
      name.gsub(/[^a-zA-Z0-9._-]/, '_').downcase
    end

    def write_plist(_resources_dir)
      plist = build_plist_xml
      plist_path = File.join(@app_path, 'Contents', 'Info.plist')
      File.write(plist_path, plist)
    end

    def build_plist_xml
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleDevelopmentRegion</key>
          <string>en</string>
          <key>CFBundleExecutable</key>
          <string>run.sh</string>
          <key>CFBundleIdentifier</key>
          <string>#{plist_escape(@bundle_id)}</string>
          <key>CFBundleName</key>
          <string>#{plist_escape(@name)}</string>
          <key>CFBundleDisplayName</key>
          <string>#{plist_escape(@name)}</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleShortVersionString</key>
          <string>1.0</string>
          <key>LSMinimumSystemVersion</key>
          <string>10.13</string>
          <key>CFBundleIconFile</key>
          <string>icon.png</string>
        </dict>
        </plist>
      PLIST
    end

    def plist_escape(s)
      s.to_s
        .gsub('&', '&amp;')
        .gsub('<', '&lt;')
        .gsub('>', '&gt;')
        .gsub('"', '&quot;')
    end

    def write_launcher_script(executable_path)
      script = <<~SCRIPT
        #!/bin/bash
        # ZBSpec app launcher. First argument = Java binary path, rest = JVM/app args.
        # Does not exec so this process stays in Dock with the app name.
        [[ $# -lt 1 ]] && exit 1
        JAVA="$1"
        shift
        "$JAVA" "$@"
        exit $?
      SCRIPT
      File.write(executable_path, script)
      File.chmod(0o755, executable_path)
    end

    def ensure_icon(resources_dir)
      target = File.join(resources_dir, 'icon.png')
      return if File.exist?(target) && File.size(target) > 0

      name = @name
      SugarPNG.new do
        text name
        save target
      end
    end
  end
end
