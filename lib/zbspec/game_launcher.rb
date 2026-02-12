# frozen_string_literal: true
require 'fileutils'

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

    def game_port_file
      File.join(get_cache_dir, 'game_port.txt')
    end

    def game_port
      return nil unless File.exist?(game_port_file)
      File.read(game_port_file).strip.to_i
    end

    # Read server's game port from standard location (for client to connect)
    def read_server_game_port
      v = game_version_name
      server_port_file = File.expand_path("./tmp/cache_server_#{v}/game_port.txt")
      # Wait briefly for server to write port file (race condition with parallel launch)
      5.times do
        break if File.exist?(server_port_file)
        sleep 0.2
      end
      return nil unless File.exist?(server_port_file)
      File.read(server_port_file).strip.to_i
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

      # Prepare launch arguments
      args = build_launch_args

      # Setup log file for game output
      log_file = setup_log_file

      # Launch game in background, redirect stdout and stderr to log
      spawn_opts = { out: log_file, err: log_file }
      spawn_opts[:chdir] = @mac_game_root
      log "game root: #{@mac_game_root}"
      log "Launching with args: #{args.inspect}"
      @pid = spawn(*args, **spawn_opts)
      @running = true

      # Write PID file
      write_pid_file

      if @verbosity > 0
        log "PID: #{@pid}"
        log "Log: #{log_file}"
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

    def build_launch_args
      @mac_java_home, @mac_game_root = resolve_mac_paths if mac?
      game_exe = find_executable

      if mac?
        build_mac_launch_args(game_exe)
      else
        build_other_launch_args(game_exe)
      end
    end

    def build_mac_launch_args(java_bin)
      cache_dir = File.expand_path(config['cache_dir'] || default_cache_dir)
      init_cachedir(cache_dir)

      # Classpath: all *.jar in GAME_ROOT plus .
      jars = Dir[File.join(@mac_game_root, '*.jar')].map { |f| File.basename(f) }
      classpath = (jars + ['.']).join(':')

      args = [
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
        "-javaagent:#{zombiebuddy_jar}=experimental,lua_server_port=random",
        '-classpath', classpath
      ]

      args << (config['server_mode'] ? 'zombie.network.GameServer' : 'zombie.gameStates.MainScreenState')
      args << '--'
      args << "-cachedir=#{cache_dir}"

      if config['server_mode']
        server_name = config['server_name'] || 'ZBSpecServer'
        args << server_name << '-nosteam' << '-adminpassword' << (config['admin_password'] || 'zbspec')
      else
        args.concat(['-novoip', '-nosound', '-nosteam', '-no-worldgen', '-no-foraging', '-no-attachments'])
        if config['server_ip']
          ip = config['server_ip']
          port = config['server_port'] || read_server_game_port || 16261
          password = config['password'] || ''
          args << '+connect' << "#{ip}:#{port}"
          args << '+password' << password unless password.empty?
        else
          args << '-debug' if config['debug']
        end
      end
      args
    end

    def build_other_launch_args(game_exe)
      args = [game_exe, "-javaagent:#{zombiebuddy_jar}=experimental,lua_server_port=random"]
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

    def game_versions_root
      File.expand_path(config['game_versions_root'] || '~/projects/zomboid/versions')
    end

    def game_version_name
      name = config['game_version']
      name ||= config['game_versions'].is_a?(Array) && config['game_versions'].first
      name ||= config['game_versions'].is_a?(Hash) && config['game_versions'].keys.first
      name&.to_s || 'default'
    end

    def game_config_dir
      base = File.join(ZBSpec.root, 'game_configs')
      name = game_version_name
      dir = File.join(base, name)
      unless File.directory?(dir)
        warn "⚠️  Game config dir not found: #{dir} (game_version=#{name.inspect}), using default"
        dir = File.join(base, 'default')
        raise GameLaunchError, "Game config dir not found: #{dir}" unless File.directory?(dir)
      end
      dir
    end

    def init_cachedir(cache_dir)
      mods_dir = File.join(cache_dir, 'mods')
      FileUtils.mkdir_p(mods_dir)
      # Copy ini and lua files from game_configs/<game_version>, preserving structure
      config_dir = game_config_dir
      Dir[File.join(config_dir, '**/*.{ini,lua,txt}')].each do |src|
        next unless File.file?(src)
        relative_path = src.sub("#{config_dir}/", '').sub(%r{\A/}, '')
        dest_path = File.join(cache_dir, relative_path)
        FileUtils.mkdir_p(File.dirname(dest_path))
        FileUtils.cp(src, dest_path)
      end
      
      # Update server ini with mods list and randomize port
      server_ini = File.join(cache_dir, 'Server', 'servertest.ini')
      if File.exist?(server_ini)
        mods_str = build_mod_list.map{|m| "\\#{m}"}.join(';')
        content = File.read(server_ini)
        content.gsub!(/^Mods=.*$/, "Mods=#{mods_str}")
        
        # Randomize server port to avoid conflicts
        game_port = rand(20000..50000)
        content.gsub!(/^DefaultPort=.*$/, "DefaultPort=#{game_port}")
        content.gsub!(/^UDPPort=.*$/, "UDPPort=#{game_port + 1}")
        File.write(server_ini, content)
        
        # Write port to file so client can read it
        File.write(File.join(cache_dir, 'game_port.txt'), game_port.to_s)
      end

      # Create symlinks only if they don't exist
      this_link = File.join(mods_dir, 'this')
      FileUtils.ln_sf(File.expand_path(Dir.pwd), this_link) unless File.exist?(this_link)
      
      zbspec_link = File.join(mods_dir, 'ZBSpec')
      FileUtils.ln_s(File.join(ZBSpec.root, 'mods', 'ZBSpec'), zbspec_link, target_directory: false, force: true)

      # Symlink mods from ~/Zomboid/Mods/ if they exist there
      user_mods_dir = File.expand_path('~/Zomboid/Mods')
      build_mod_list.each do |mod|
        next if mod == 'ZBSpec' # ZBSpec is handled above
        user_mod_path = File.join(user_mods_dir, mod)
        if File.exist?(user_mod_path)
          mod_link = File.join(mods_dir, mod)
          FileUtils.ln_sf(user_mod_path, mod_link) unless File.exist?(mod_link)
        end
      end

      default_txt = []
      default_txt << "VERSION = 1,"
      default_txt << "mods"
      default_txt << "{"
      build_mod_list.each do |mod|
        default_txt << "    mod = \\#{mod},"
      end
      default_txt << "}"
      File.write(File.join(mods_dir, 'default.txt'), default_txt.join("\n"))
    end

    def build_mod_list
      mods = []
      mods << 'ZombieBuddy'
      mods << 'ZBetterFPS'
      mods << 'ZBSpec'
      
      # Add user mods
      if config['mods']&.any?
        config['mods'].each do |mod|
          mods << mod
        end
      end
      
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
