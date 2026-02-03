# frozen_string_literal: true
require 'fileutils'

module ZBSpec
  # Handles launching and stopping the game
  class GameLauncher
    attr_reader :config, :pid

    def initialize(config)
      @config = config
      @pid = nil
      @running = false
      @pid_file = File.join('tmp', 'zbspec.pid')
    end

    def start
      # Check for existing PID file
      if File.exist?(@pid_file)
        existing_pid = File.read(@pid_file).strip.to_i
        if process_alive?(existing_pid)
          puts "✓ Game already running (PID: #{existing_pid})"
          @pid = existing_pid
          @running = true
          return
        else
          puts "⚠️  Stale PID file found, removing..."
          File.delete(@pid_file)
        end
      end

      if running?
        puts '✓ Game already running'
        return
      end

      # Clean up stale port file from previous session
      clean_port_file

      puts '🎮 Launching Project Zomboid...'

      # Prepare launch arguments
      args = build_launch_args

      # Setup log file for game output
      log_file = setup_log_file

      # Launch game in background with redirected output
      puts "Launching game with args: #{args.inspect}"
      @pid = spawn(*args, out: log_file, err: log_file)
      @running = true

      # Write PID file
      write_pid_file

      puts "  PID: #{@pid}"
      puts "  Log: #{log_file}"
      puts "  Mods: #{config['mods'].join(', ')}" if config['mods']
      puts '  Waiting for startup...'
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
      File.delete(@pid_file) if File.exist?(@pid_file)
    rescue Errno::ESRCH
      # Process already dead
      @running = false
      File.delete(@pid_file) if File.exist?(@pid_file)
    end

    def running?
      return false unless @pid

      process_alive?(@pid)
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
      FileUtils.mkdir_p('tmp')
      File.write(@pid_file, @pid.to_s)
      puts "  PID file: #{File.expand_path(@pid_file)}"
    end

    def clean_port_file
      cache_dir = File.expand_path(config['cache_dir'] || './tmp/cache')
      port_file = File.join(cache_dir, 'zbLuaAPI.txt')
      
      if File.exist?(port_file)
        File.delete(port_file)
        puts "  Cleaned stale port file: #{port_file}"
      end
    end

    def setup_log_file
      FileUtils.mkdir_p('tmp/logs')
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      log_file = File.expand_path("tmp/logs/#{timestamp}.log")
      
      # Create symlink to latest log
      latest_link = File.expand_path('tmp/logs/last.log')
      File.delete(latest_link) if File.exist?(latest_link) || File.symlink?(latest_link)
      File.symlink(File.basename(log_file), latest_link)
      
      log_file
    end

    def build_launch_args
      game_exe = find_executable

      args = [game_exe]
      args << "-javaagent:ZombieBuddy.jar=lua_server_port=random"
      args << '--'
      args << '-Dzomboid' if mac?
      cache_dir = File.expand_path(config['cache_dir'] || './tmp/cache')
      init_cachedir(cache_dir)

      args << "-cachedir=#{cache_dir}"
      
      args.concat(['-novoip', '-nosound', '-nosteam', '-no-worldgen', '-no-foraging', '-no-attachments'])
      args << '-server' if config['server_mode']
      args << '-debug' if config['debug']
      args
    end

    def get_cache_dir
      File.expand_path(config['cache_dir'] || './tmp/cache')
    end

    def init_cachedir(cache_dir)
      mods_dir = File.join(cache_dir, 'mods')
      FileUtils.mkdir_p(mods_dir)
      Dir[File.join(__dir__, '../../config/*.ini')].each do |ini_fname|
        FileUtils.cp(ini_fname, cache_dir)
      end
      FileUtils.touch(File.join(mods_dir, 'reset-mods-42_00.txt'))

      # Create symlinks only if they don't exist
      this_link = File.join(mods_dir, 'this')
      FileUtils.ln_sf(File.expand_path(Dir.pwd), this_link) unless File.exist?(this_link)
      
      zbspec_link = File.join(mods_dir, 'ZBSpec')
      FileUtils.ln_sf(File.join(ZBSpec.root, 'mods', 'ZBSpec'), zbspec_link) unless File.exist?(zbspec_link)

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
