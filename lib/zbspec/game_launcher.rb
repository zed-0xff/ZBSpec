# frozen_string_literal: true
require 'fileutils'
require 'erb'

module ZBSpec
  # Handles launching and stopping the game
  class GameLauncher
    LABEL_WIDTH = 8
    attr_reader :config, :pid, :label
    attr_accessor :verbosity

    def initialize(config, label: nil, verbosity: 0)
      @config = config
      @label = label || (config['server_mode'] ? 'server' : 'sp')
      @verbosity = verbosity
      @pid = nil
      @running = false
    end

    def log(msg)
      return unless @verbosity > 0
      puts "[#{@label.ljust(6)}] #{msg}"
    end

    def pid_file
      @pid_file ||= File.join(get_cache_dir, 'pz.pid')
    end

    # Read server's game port from cache_server_<ver>/Server/servertest.ini (DefaultPort=...)
    def read_server_game_port
      ini_path = File.join(server_cache_dir_for_version(game_version_name), 'Server', 'servertest.ini')
      5.times do
        break if File.exist?(ini_path)
        sleep 0.2
      end
      return nil unless File.exist?(ini_path)
      content = File.read(ini_path)
      m = content.match(/DefaultPort=\s*(\d+)/)
      m ? m[1].to_i : nil
    end

    def start
      # Check for existing PID file
      if File.exist?(pid_file)
        existing_pid = File.read(pid_file).strip.to_i
        if process_alive?(existing_pid)
          log "✓ Game already running (PID: #{existing_pid})"
          @pid = existing_pid
          @running = true
          return
        else
          log "⚠️  Stale PID file found, removing..."
          File.delete(pid_file)
        end
      end

      if running?
        log '✓ Game already running'
        return
      end

      # Clean up stale port file from previous session
      clean_port_file

      log '🎮 Launching Project Zomboid...'

      redirect_output = config['redirect_output']
      redirect_output = true if redirect_output.nil?
      log_file = redirect_output ? setup_log_file : nil

      args = build_launch_args(log_file: log_file)

      log "game root: #{@mac_game_root}"
      if args.is_a?(Hash) && args.key?(:app)
        log "Launching #{args[:app].name} via app bundle"
        @pid = args[:app].start!
      else
        spawn_opts = { chdir: @mac_game_root }
        spawn_opts[:out] = spawn_opts[:err] = log_file if log_file
        log "Launching with args: #{args.inspect}"
        @pid = spawn(*args, **spawn_opts)
      end
      @running = true

      # Write PID file
      write_pid_file

      if @verbosity > 0
        log "PID: #{@pid}"
        log "Log: #{log_file}" if log_file
        log "Mods: #{config['mods'].join(', ')}" if config['mods']
      end
    rescue StandardError => e
      raise GameLaunchError, "Failed to launch game: #{e.message}"
    end

    def stop
      return unless running?

      puts "\n🛑 Stopping game (PID: #{@pid})..."
      Process.kill('TERM', @pid)
      Process.wait(@pid, Process::WNOHANG)
      @running = false
      @pid = nil
      
      # Remove PID file
      File.delete(pid_file) if File.exist?(pid_file)
    rescue Errno::ESRCH
      # Process already dead
      @running = false
      File.delete(pid_file) if File.exist?(pid_file)
    end

    def running?
      return false unless @pid

      process_alive?(@pid)
    end

    def get_cache_dir
      File.expand_path(config['cache_dir'] || default_cache_dir)
    end

    private

    def process_alive?(pid)
      return false unless pid && pid > 0
      
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def write_pid_file
      FileUtils.mkdir_p(get_cache_dir)
      File.write(pid_file, @pid.to_s)
      log "PID file: #{File.expand_path(pid_file)}"
    end

    def clean_port_file
      cache_dir = get_cache_dir
      port_file = File.join(cache_dir, 'zbLuaAPI.txt')
      
      if File.exist?(port_file)
        File.delete(port_file)
        log "Cleaned stale port file: #{port_file}"
      end
    end

    def setup_log_file
      cache_dir = get_cache_dir
      FileUtils.mkdir_p(cache_dir)
      File.join(cache_dir, 'std.log')
    end

    def build_launch_args(log_file: nil)
      @mac_java_home, @mac_game_root = resolve_mac_paths if mac?
      game_exe = find_executable

      if mac?
        build_mac_launch_args(game_exe, log_file: log_file)
      else
        build_other_launch_args(game_exe)
      end
    end

    def build_mac_launch_args(java_bin, log_file: nil)
      cache_dir = File.expand_path(config['cache_dir'] || default_cache_dir)
      init_cachedir(cache_dir)

      argv = build_java_argv(java_bin, cache_dir)
      app_display_name = config['window_title'].to_s.strip.empty? ? default_window_title : config['window_title']
      pid_file = File.join(cache_dir, 'pz.pid')

      app = AppFactory.create(
        apps_root: cache_dir,
        name: app_display_name,
        chdir: @mac_game_root,
        argv: argv,
        pid_file: pid_file,
        log_file: log_file
      )

      { app: app }
    end

    # argv for run.sh: first = java binary, rest = JVM + game args
    def build_java_argv(java_bin, cache_dir)
      jars = Dir[File.join(@mac_game_root, '*.jar')].map { |f| File.basename(f) }
      classpath = (jars + ['.']).join(':')

      argv = [
        java_bin,
        '--enable-native-access=ALL-UNNAMED',
        '-Djava.awt.headless=true',
        '-XstartOnFirstThread',
        '-Dzomboid.steam=0',
        '-Dzomboid.znetlog=1',
        '-Xmx3072m',
        '-XX:+UseZGC',
        '-XX:-OmitStackTraceInFastThrow',
        "-Djava.library.path=.:#{File.join(@mac_java_home, 'lib')}",
        javaagent_arg,
        '-classpath', classpath
      ]

      argv << (config['server_mode'] ? 'zombie.network.GameServer' : 'zombie.gameStates.MainScreenState')
      argv << '--'
      argv << "-cachedir=#{cache_dir}"

      if config['server_mode']
        server_name = config['server_name'] || 'ZBSpecServer'
        argv << server_name << '-nosteam' << '-adminpassword' << (config['admin_password'] || 'zbspec')
      else
        argv.concat(['-novoip', '-nosound', '-nosteam', '-no-worldgen', '-no-foraging', '-no-attachments'])
        if config['server_ip']
          ip = config['server_ip']
          port = config['server_port'] || read_server_game_port || 16261
          password = config['password'] || ''
          argv << '+connect' << "#{ip}:#{port}"
          argv << '+password' << password unless password.empty?
        else
          argv << '-debug' if config['debug']
        end
      end
      argv
    end

    def build_other_launch_args(game_exe)
      args = [game_exe, javaagent_arg]
      args << 'zombie.network.GameServer' if config['server_mode']
      args << '--'
      cache_dir = File.expand_path(config['cache_dir'] || default_cache_dir)
      init_cachedir(cache_dir)
      args << "-cachedir=#{cache_dir}"
      if config['server_mode']
        args << (config['server_name'] || 'ZBSpecServer') << '-nosteam' << '-adminpassword' << (config['admin_password'] || 'zbspec')
      else
        args.concat(['-novoip', '-nosound', '-nosteam', '-no-worldgen', '-no-foraging', '-no-attachments'])
        if config['server_ip']
          ip, port = config['server_ip'], config['server_port'] || read_server_game_port || 16261
          args << '+connect' << "#{ip}:#{port}"
          args << '+password' << (config['password'] || '') unless (config['password'] || '').empty?
        else
          args << '-debug' if config['debug']
        end
      end
      args
    end

    def javaagent_arg
      agent_parts = [
        'experimental',
        'lua_server_port=random',
        'expose_classes=me.zed_0xff.zombie_buddy.Accessor,me.zed_0xff.zombie_buddy.Exposer'
      ]
      title = config['window_title']
      title = default_window_title if title.nil? || title.empty?
      if title && !title.empty?
        encoded_title = URI.encode_www_form_component(title)
        agent_parts << "window_title=#{encoded_title}"
      end
      "-javaagent:#{zombiebuddy_jar}=#{agent_parts.join(',')}"
    end

    def default_window_title
      version = game_version_name
      case @label
      when 'server'
        "MP #{version} server"
      when 'client'
        "MP #{version} client"
      else
        "SP #{version}"
      end
    end

    def zombiebuddy_jar
      @zombiebuddy_jar ||= begin
        candidates = [
          File.expand_path('~/projects/zomboid/mods/ZombieBuddy/libs/ZombieBuddy.jar'),
          File.expand_path('~/Library/Application Support/Steam/steamapps/workshop/content/108600/3619862853/mods/ZombieBuddy/libs/ZombieBuddy.jar')
        ]
        path = candidates.find { |p| File.file?(p) }
        unless path
          raise GameLaunchError, "ZombieBuddy.jar not found. Checked:\n  #{candidates.join("\n  ")}"
        end
        path
      end
    end

    # ZombieBuddy mod root (parent of the directory containing the JAR, e.g. .../ZombieBuddy)
    def zombiebuddy_mod_dir
      File.expand_path(File.join(File.dirname(zombiebuddy_jar), '..'))
    end

    def default_cache_dir
      v = game_version_name
      if config['server_mode']
        "./tmp/cache_server_#{v}"
      elsif config['server_ip']
        "./tmp/cache_client_#{v}"
      else
        "./tmp/cache_sp_#{v}"
      end
    end

    def server_cache_dir_for_version(version_name)
      File.expand_path("./tmp/cache_server_#{version_name}")
    end

    def game_versions_root
      File.expand_path(config['game_versions_root'] || '~/projects/zomboid/versions')
    end

    def self.game_version_name_from_config(cfg)
      name = cfg['game_version']
      name ||= cfg['game_versions'].is_a?(Array) && cfg['game_versions'].first
      name ||= cfg['game_versions'].is_a?(Hash) && cfg['game_versions'].keys.first
      name&.to_s || 'default'
    end

    def game_version_name
      self.class.game_version_name_from_config(config)
    end

    def game_config_dir
      base = File.join(ZBSpec.root, 'configs')
      name = game_version_name
      dir = File.join(base, name)
      unless File.directory?(dir)
        log "⚠️  Game config dir not found: #{dir} (game_version=#{name.inspect}), using default"
        dir = File.join(base, 'default')
        raise GameLaunchError, "Game config dir not found: #{dir}" unless File.directory?(dir)
      end
      dir
    end

    def init_cachedir(cache_dir)
      mods_dir = File.join(cache_dir, 'mods')
      FileUtils.mkdir_p(mods_dir)

      # Copy ini and lua files from configs/<game_version>, preserving structure
      config_dir = game_config_dir
      mods       = build_mod_list
      game_port  = config['server_mode'] ? rand(20000..50000) : nil

      Dir[File.join(config_dir, '**/*.{ini,lua,txt,erb}')].each do |src|
        next unless File.file?(src)
        next if File.basename(File.dirname(src)).downcase == 'server' && !config['server_mode']

        relative_path = src.sub("#{config_dir}/", '').sub(%r{\A/}, '')
        dest_path = File.join(cache_dir, relative_path)
        dest_path = dest_path.sub(/\.erb\z/, '') if relative_path.end_with?('.erb')
        FileUtils.mkdir_p(File.dirname(dest_path))
        if src.end_with?('.erb')
          template = ERB.new(File.read(src), trim_mode: '-')
          File.write(dest_path, template.result_with_hash(
            game_port: game_port,
            mods: mods,
          ))
        else
          FileUtils.cp(src, dest_path)
        end
      end

      # Create symlinks for mods (no default "this" symlink; use mods: [{ id: "YourMod", path: "." }] to link CWD)
      zbspec_link = File.join(mods_dir, 'ZBSpec')
      FileUtils.ln_s(File.join(ZBSpec.root, 'mods', 'ZBSpec'), zbspec_link, target_directory: false, force: true)

      zombiebuddy_link = File.join(mods_dir, 'ZombieBuddy')
      FileUtils.ln_s(zombiebuddy_mod_dir, zombiebuddy_link, target_directory: false, force: true)

      # Symlink mods: path (explicit), Steam workshop (steam_id), or ~/Zomboid/Mods/
      user_mods_dir = File.expand_path('~/Zomboid/Mods')
      config_mod_entries.each do |entry|
        mod = entry['name']
        next if mod == 'ZBSpec' # ZBSpec is handled above
        mod_link = File.join(mods_dir, mod)
        if entry['path']
          src = File.expand_path(entry['path'])
          raise GameLaunchError, "Mod path not found: #{entry['path']} (resolved: #{src})" unless File.exist?(src)
          FileUtils.ln_s(src, mod_link, target_directory: false, force: true)
        elsif (steam_id = entry['steam_id'])
          src = steam_workshop_mod_path(steam_id, mod)
          unless File.exist?(src)
            raise GameLaunchError, "Steam workshop mod not installed: #{mod} (steam_id=#{steam_id}). Expected: #{src}"
          end
          FileUtils.ln_s(src, mod_link, target_directory: false, force: true)
        else
          user_mod_path = File.join(user_mods_dir, mod)
          FileUtils.ln_s(user_mod_path, mod_link, target_directory: false, force: true) if File.exist?(user_mod_path)
        end
      end

    end

    def steam_workshop_mod_path(steam_id, mod_name)
      File.expand_path(
        "~/Library/Application Support/Steam/steamapps/workshop/content/108600/#{steam_id}/mods/#{mod_name}"
      )
    end

    # Config mods as list of hashes with 'id' (or 'name'), optional 'steam_id', optional 'path'
    def config_mod_entries
      @config_mod_entries ||= Array(config['mods']).map do |entry|
        if entry.is_a?(Hash)
          mod_id = (entry['id'] || entry['name']).to_s
          { 'name' => mod_id, 'steam_id' => entry['steam_id'], 'path' => entry['path'] }
        else
          { 'name' => entry.to_s, 'steam_id' => nil, 'path' => nil }
        end
      end
    end

    def build_mod_list
      mods = []
      mods << 'ZombieBuddy'
      mods << 'ZBSpec'
      config_mod_entries.each { |e| mods << e['name'] }
      mods.uniq
    end

    def find_executable
      version_dir = File.join(game_versions_root, game_version_name)
      game_path = File.directory?(version_dir) ? version_dir : config['game_path']
      
      if mac?
        # macOS: use Java from resolved JAVA_HOME
        java_home = @mac_java_home
        raise "JAVA_HOME not resolved. resolve_mac_paths should have been called." unless java_home
        java_bin = File.join(java_home, 'bin', 'java')
        raise "Java executable not found: #{java_bin}" unless File.exist?(java_bin)
        java_bin
      else
        # Windows/Linux
        raise "TBD"
      end
    end

    # macOS: resolve JAVA_HOME and GAME_ROOT paths
    def resolve_mac_paths
      version_dir = File.join(game_versions_root, game_version_name)
      game_path = File.directory?(version_dir) ? version_dir : config['game_path']
      return [nil, nil] unless game_path
      app_dir = resolve_mac_app_dir(game_path)
      java_home = mac_java_home(app_dir)
      game_root = mac_game_root(app_dir)
      [java_home, game_root]
    end

    # macOS: resolve app dir as "Project Zomboid.app" or "osx/Project Zomboid.app" under game_path
    def resolve_mac_app_dir(game_path)
      base = File.expand_path(game_path.to_s)
      return base if base.end_with?('.app') && File.directory?(base)
      candidates = [
        File.join(base, 'Project Zomboid.app'),
        File.join(base, 'osx', 'Project Zomboid.app')
      ]
      app_dir = candidates.find { |d| File.directory?(d) }
      raise "Could not find app dir. Checked:\n#{candidates.map { |p| "  - #{p}" }.join("\n")}" unless app_dir
      app_dir
    end

    # macOS: JAVA_HOME from app's bundled JRE (prefer arch-matched, then zulu)
    def mac_java_home(app_dir)
      arch = mac_arch
      jre_candidates = [
        File.join(app_dir, 'Contents', 'PlugIns', "jre-#{arch}", 'Contents', 'Home'),
        File.join(app_dir, 'Contents', 'PlugIns', 'zulu-17.jre', 'Contents', 'Home')
      ]
      jre_candidates.find { |d| File.directory?(d) }
    end

    def mac_arch
      RUBY_PLATFORM.include?('aarch64') ? 'aarch64' : 'x86_64'
    end

    # macOS: GAME_ROOT = app_dir/Contents/Java
    def mac_game_root(app_dir)
      File.join(app_dir, 'Contents', 'Java')
    end

    def mac?
      RUBY_PLATFORM.include?('darwin')
    end

    def windows?
      RUBY_PLATFORM.include?('mingw') || RUBY_PLATFORM.include?('mswin')
    end
  end
end
