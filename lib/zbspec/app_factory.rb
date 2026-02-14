# frozen_string_literal: true
require 'fileutils'
require 'sugar_png'

module ZBSpec
  # Builds minimal macOS .app bundles so the Dock shows a custom name and icon.
  # Creates the app only when the full command line is known; run.sh contains
  # the full launch command so the app can be started via `open` (Dock icon/title).
  class AppFactory
    # Value object for a created .app bundle.
    class App
      attr_reader :name, :path, :executable_path, :pid_file, :pid

      def initialize(name:, path:, executable_path:, pid_file: nil)
        @name = name
        @path = path
        @executable_path = executable_path
        @pid_file = pid_file
        @pid = nil
      end

      # Launch via `open` so the Dock shows the app icon and title. Waits for
      # the process to write its PID to pid_file (if set).
      # @return [Integer] PID of the launched process (from pid_file)
      def start!
        File.delete(pid_file) if pid_file && File.exist?(pid_file)
        FileUtils.touch(path) # invalidate app cache
        system('open', '-n', path)
        if pid_file
          @pid = wait_for_pid_file(pid_file, timeout_sec: 15)
          raise "Timed out waiting for #{pid_file}" unless @pid
        end
        @pid
      end

      private

      def wait_for_pid_file(path, timeout_sec:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          if File.exist?(path) && File.size(path) > 0
            return File.read(path).strip.to_i
          end
          sleep 0.1
        end
        nil
      end
    end

    # @param apps_root [String] Root directory for app bundles (e.g. cache dir)
    # @param name [String] Display name; bundle at apps_root/name.app/Contents/...
    # @param chdir [String] Working directory for the launched process
    # @param argv [Array<String>] Full command line (e.g. [java_bin, '-Xmx...', main_class, '--', '-cachedir=...])
    # @param pid_file [String, nil] If set, run.sh writes $$ here so we can discover PID after open
    # @param log_file [String, nil] If set, run.sh redirects stdout/stderr to this file
    # @return [AppFactory::App]
    def self.create(apps_root:, name:, chdir:, argv:, pid_file: nil, log_file: nil)
      new(apps_root: apps_root, name: name, chdir: chdir, argv: argv, pid_file: pid_file, log_file: log_file).create
    end

    def initialize(apps_root:, name:, chdir:, argv:, pid_file: nil, log_file: nil)
      @apps_root = File.expand_path(apps_root)
      @name = name.to_s.strip
      @app_basename = @name.end_with?('.app') ? @name : "#{@name}.app"
      @app_path = File.join(@apps_root, @app_basename)
      @bundle_id = "com.zbspec.#{sanitize_bundle_id(@name)}"
      @chdir = chdir
      @argv = argv
      @pid_file = pid_file
      @log_file = log_file
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

      App.new(name: @name, path: @app_path, executable_path: executable_path, pid_file: @pid_file)
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
      lines = ["#!/bin/bash"]
      lines << "echo $$ > #{shell_quote(@pid_file)}" if @pid_file && !@pid_file.empty?
      lines << "cd #{shell_quote(@chdir)} || exit 1"
      quoted_argv = @argv.map { |a| shell_quote(a) }.join(' ')
      if @log_file && !@log_file.empty?
        lines << "exec #{quoted_argv} >> #{shell_quote(@log_file)} 2>&1"
      else
        lines << "exec #{quoted_argv}"
      end
      File.write(executable_path, lines.join("\n") + "\n")
      File.chmod(0o755, executable_path)
    end

    def shell_quote(s)
      "'#{s.to_s.gsub("'", "'\\\\''")}'"
    end

    def ensure_icon(resources_dir)
      target = File.join(resources_dir, 'icon.png')
      return if File.exist?(target) && File.size(target) > 0

      name = @name
      SugarPNG.new do
        fg :white
        bg :black
        width 64
        height 64
        text name.split.join("\n")
        save target
      end
    end
  end
end
