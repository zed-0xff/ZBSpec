# frozen_string_literal: true

module ZBSpec
  # Configuration management for PZ test harness
  class Config
    # Common Project Zomboid installation paths
    COMMON_GAME_PATHS = [
      '/Applications/Project Zomboid.app',
      '/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app',
      File.expand_path('~/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app'),
      'C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid',
      'C:/Program Files/Steam/steamapps/common/ProjectZomboid',
      File.expand_path('~/.steam/steam/steamapps/common/ProjectZomboid')
    ].freeze

    DEFAULT_CONFIG = {
      'startup_timeout' => 120,         # Client/SP startup timeout
      'server_startup_timeout' => 60,   # Server startup timeout (faster)
      'auto_shutdown' => false,
      'game_path' => nil,  # Auto-detect by default
      'debug' => true,
      'mods' => [],
      'spec_glob' => 'spec/**/*_spec.lua'
    }.freeze

    attr_reader :data

    def initialize(config_path = nil)
      if config_path
        @data = load_config(config_path)
        detect_game_path if @data['game_path'].nil?
      else
        # Allow creating empty config for programmatic use
        @data = DEFAULT_CONFIG.dup
      end
    end

    def [](key)
      @data[key]
    end

    def []=(key, value)
      @data[key] = value
    end

    def merge!(hash)
      @data.merge!(hash)
    end

    def to_h
      @data.dup
    end

    private

    def detect_game_path
      path = COMMON_GAME_PATHS.find { |p| File.exist?(p) }
      
      if path
        @data['game_path'] = path
        puts "✓ Auto-detected game at: #{path}"
      else
        warn "⚠️  Could not auto-detect Project Zomboid installation"
        warn "   Checked locations:"
        COMMON_GAME_PATHS.each { |p| warn "   - #{p}" }
        raise ConfigError, "Project Zomboid not found. Specify game_path in config."
      end
    end

    def load_config(path)
      unless File.exist?(path)
        raise ConfigError, "Config file not found: #{path}"
      end

      # Support both YAML and JSON
      config = if path.end_with?('.yml', '.yaml')
                 YAML.load_file(path)
               elsif path.end_with?('.json')
                 JSON.parse(File.read(path))
               else
                 # Try YAML first, then JSON
                 begin
                   YAML.load_file(path)
                 rescue Psych::SyntaxError
                   JSON.parse(File.read(path))
                 end
               end

      DEFAULT_CONFIG.merge(config)
    rescue Psych::SyntaxError => e
      raise ConfigError, "Invalid YAML in config file: #{e.message}"
    rescue JSON::ParserError => e
      raise ConfigError, "Invalid JSON in config file: #{e.message}"
    end
  end
end
