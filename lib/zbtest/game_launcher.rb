# frozen_string_literal: true
require 'fileutils'

module ZBTest
  # Handles launching and stopping the game
  class GameLauncher
    attr_reader :config, :pid

    def initialize(config)
      @config = config
      @pid = nil
      @running = false
    end

    def start
      if running?
        puts '✓ Game already running'
        return
      end

      puts '🎮 Launching Project Zomboid...'

      # Prepare launch arguments
      args = build_launch_args

      # Launch game in background
      puts "Launching game with args: #{args.inspect}"
      @pid = spawn(*args)
      @running = true

      puts "  PID: #{@pid}"
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
    rescue Errno::ESRCH
      # Process already dead
      @running = false
    end

    def running?
      return false unless @pid

      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH
      false
    end

    private

    def build_launch_args
      game_exe = find_executable

      args = [game_exe]
      args << "-javaagent:ZombieBuddy.jar=lua_server_port=#{config['api_port']}"
      args << '--'
      args << '-Dzomboid' if mac?
      cache_dir = File.expand_path(config['cache_dir'] || './tmp/cache')
      init_cachedir(cache_dir)

      args << "-cachedir=#{cache_dir}"
      # args << "-modfolders" << File.join(ZBTest.root, 'mods')
      
      args.concat(['-novoip', '-nosound', '-nosteam', '-no-worldgen', '-no-foraging', '-no-attachments'])
      args << '-server' if config['server_mode']
      args << '-debug' if config['debug']
      args
    end

    def init_cachedir(cache_dir)
      mods_dir = File.join(cache_dir, 'mods')
      FileUtils.mkdir_p(mods_dir)
      Dir[File.join(__dir__, '../../config/*.ini')].each do |ini_fname|
        FileUtils.cp(ini_fname, cache_dir)
      end
      FileUtils.touch(File.join(mods_dir, 'reset-mods-42_00.txt'))

      FileUtils.ln_sf(File.expand_path(Dir.pwd),                File.join(mods_dir, 'this'))
      FileUtils.ln_sf(File.join(ZBTest.root, 'mods', 'ZBTest'), File.join(mods_dir, 'ZBTest'))

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
      mods << 'ZBTest'
      
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
