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
      server_port_file = File.expand_path('./tmp/cache_server/game_port.txt')
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
      log "Launching with args: #{args.inspect}"
      @pid = spawn(*args, out: log_file, err: log_file)
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
      FileUtils.mkdir_p('tmp/logs')
      instance = config['instance_name'] || 'default'
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      log_file = File.expand_path("tmp/logs/#{instance}_#{timestamp}.log")
      
      # Create symlink to latest log for this instance
      latest_link = File.expand_path("tmp/logs/#{instance}.log")
      FileUtils.rm_f(latest_link)
      FileUtils.ln_sf(File.basename(log_file), latest_link)
      
      log_file
    end

    def build_launch_args
      game_exe = find_executable

      args = [game_exe]
      args << "-javaagent:ZombieBuddy.jar=lua_server_port=random"
      
      if config['server_mode']
        # Dedicated server uses different main class
        args << 'zombie.network.GameServer'
      end
      
      args << '--'
      
      cache_dir = File.expand_path(config['cache_dir'] || default_cache_dir)
      init_cachedir(cache_dir)

      args << "-cachedir=#{cache_dir}"
      
      if config['server_mode']
        # Server-specific options
        server_name = config['server_name'] || 'ZBSpecServer'
        args << server_name
        args << '-nosteam'
        args << '-adminpassword'
        args << (config['admin_password'] || 'zbspec')
      else
        # Client/SP-specific options
        args.concat(['-novoip', '-nosound', '-nosteam', '-no-worldgen', '-no-foraging', '-no-attachments'])
        
        if config['server_ip']
          # Client connecting to server (+connect and value are separate args)
          ip = config['server_ip']
          port = config['server_port'] || read_server_game_port || 16261
          password = config['password'] || ''
          args << '+connect'
          args << "#{ip}:#{port}"
          unless password.empty?
            args << '+password'
            args << password
          end
        else
          # SP only - debug mode
          args << '-debug' if config['debug']
        end
      end
      
      args
    end

    def default_cache_dir
      if config['server_mode']
        './tmp/cache_server'
      elsif config['server_ip']
        './tmp/cache_client'
      else
        './tmp/cache_sp'
      end
    end

    def init_cachedir(cache_dir)
      mods_dir = File.join(cache_dir, 'mods')
      FileUtils.mkdir_p(mods_dir)
      # Copy ini files from config dir, preserving subdirectory structure
      config_dir = File.join(__dir__, '../../config')
      Dir[File.join(config_dir, '**/*.ini')].each do |ini_fname|
        relative_path = ini_fname.sub("#{config_dir}/", '')
        dest_path = File.join(cache_dir, relative_path)
        FileUtils.mkdir_p(File.dirname(dest_path))
        FileUtils.cp(ini_fname, dest_path)
      end
      FileUtils.touch(File.join(mods_dir, 'reset-mods-42_00.txt'))
      
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
      FileUtils.ln_sf(File.join(ZBSpec.root, 'mods', 'ZBSpec'), zbspec_link) unless File.exist?(zbspec_link)

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
      game_path = config['game_path']
      
      if mac?
        # macOS: Check both standalone and Steam versions
        candidates = [
          File.join(game_path, 'Contents', 'MacOS', 'ProjectZomboid'),      # Standalone
          File.join(game_path, 'Contents', 'MacOS', 'JavaAppLauncher')      # Steam
        ]
        
        executable = candidates.find { |path| File.exist?(path) }
        
        unless executable
          raise "Could not find game executable. Checked:\n#{candidates.map { |p| "  - #{p}" }.join("\n")}"
        end
        
        executable
      elsif windows?
        # Windows
        File.join(game_path, 'ProjectZomboid64.exe')
      else
        # Linux
        File.join(game_path, 'projectzomboid.sh')
      end
    end

    def mac?
      RUBY_PLATFORM.include?('darwin')
    end

    def windows?
      RUBY_PLATFORM.include?('mingw') || RUBY_PLATFORM.include?('mswin')
    end
  end
end
