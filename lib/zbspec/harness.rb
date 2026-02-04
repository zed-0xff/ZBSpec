# frozen_string_literal: true

module ZBSpec
  # Main test harness orchestrator
  class Harness
    attr_reader :config, :launcher, :api_client, :test_runner, :verbose

    def initialize(config_path: nil, test_runner_class: nil, spec_files: nil, verbose: false, config_overrides: {})
      @config = Config.new(config_path)
      config_overrides.each { |k, v| @config[k] = v }
      @launcher = GameLauncher.new(@config)
      @verbose = verbose
      
      # Create API client with port file path for discovery
      # Use the same cache dir logic as the launcher
      port_file = File.join(@launcher.get_cache_dir, 'zbLuaAPI.txt')
      @api_client = APIClient.new(port_file: port_file)
      
      # Use provided test runner class or default
      runner_class = test_runner_class || TestRunner
      @test_runner = runner_class.new(@api_client, @config, spec_files: spec_files)
    end

    def run
      puts '🚀 PZ Spec Harness Starting'
      puts '=' * 50

      # Launch game (if not already running)
      launch_game_if_needed

      # Discover API port (from file if using random port)
      api_client.discover_port(timeout: startup_timeout)

      # Wait for API to be ready
      api_client.wait_for_ready(timeout: startup_timeout)
      puts "\n✓ API ready\n"

      # Wait for player to spawn (skip for server mode)
      unless config['server_mode']
        api_client.wait_for_player(timeout: startup_timeout)
      end

      # Run all specs
      puts "\n🧪 Running Spec Suite"
      puts '=' * 50
      results = test_runner.run_all

      # Report results
      reporter = TestReporter.new(results, verbose: verbose)
      reporter.display

      # Shutdown (if configured)
      launcher.stop if config['auto_shutdown']

      exit(results.failed? ? 1 : 0)
    rescue StandardError => e
      handle_error(e)
    end

    private

    def startup_timeout
      if config['server_mode']
        config['server_startup_timeout'] || 60
      else
        config['startup_timeout'] || 120
      end
    end

    def launch_game_if_needed
      if config['use_running_game']
        puts '✓ Using already-running game'
      else
        launcher.start
      end
    end

    def handle_error(error)
      puts "\n❌ Fatal error: #{error.message}"
      puts error.backtrace.first(5)
      launcher.stop if launcher&.running?
      exit 1
    end
  end
end
