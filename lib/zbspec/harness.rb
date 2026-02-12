# frozen_string_literal: true

module ZBSpec
  # Main test harness orchestrator
  class Harness
    attr_reader :config, :launcher, :api_client, :test_runner, :verbosity

    def initialize(config_path: nil, test_runner_class: nil, spec_files: nil, verbosity: 0, config_overrides: {})
      @config = Config.new(config_path)
      config_overrides.each { |k, v| @config[k] = v }
      @verbosity = verbosity
      @launcher = GameLauncher.new(@config, verbosity: verbosity)
      
      # Create API client with port file path for discovery
      # Use the same cache dir logic as the launcher
      port_file = File.join(@launcher.get_cache_dir, 'zbLuaAPI.txt')
      label = @config['server_mode'] ? 'server' : 'sp'
      @api_client = APIClient.new(port_file: port_file, label: label, verbosity: verbosity)
      
      # Use provided test runner class or default
      runner_class = test_runner_class || TestRunner
      @test_runner = runner_class.new(@api_client, @config, spec_files: spec_files, verbosity: verbosity)
    end

    def run
      results = run_without_exit
      exit(results.failed? ? 1 : 0)
    end

    def run_without_exit
      if verbosity > 0
        puts '🚀 PZ Spec Harness Starting'
        puts '=' * 50
      end

      # Launch game (if not already running)
      launch_game_if_needed

      # Discover API port (from file if using random port)
      api_client.discover_port(timeout: startup_timeout, process_pid: launcher.pid)

      # Wait for API to be ready
      api_client.wait_for_ready(timeout: startup_timeout, process_pid: launcher.pid)
      
      # Sanity check: verify instance is running in expected mode
      if config['server_mode']
        is_server = api_client.execute('return isServer()')
        raise "Instance should be server but isServer()=#{is_server}" unless is_server
        puts "✓ Server ready" if verbosity > 0
      elsif config['server_ip']
        is_client = api_client.execute('return isClient()')
        raise "Instance should be client but isClient()=#{is_client}" unless is_client
        puts "✓ Client ready" if verbosity > 0
        api_client.wait_for_player(timeout: startup_timeout, process_pid: launcher.pid)
      else
        # SP mode: should be neither client nor server
        is_client = api_client.execute('return isClient()')
        is_server = api_client.execute('return isServer()')
        if is_client || is_server
          raise "SP instance should be neither client nor server, but isClient=#{is_client}, isServer=#{is_server}"
        end
        puts "✓ SP ready" if verbosity > 0
        api_client.wait_for_player(timeout: startup_timeout, process_pid: launcher.pid)
      end

      # Run all specs
      puts "\n🧪 Running Specs" if verbosity > 0
      results = test_runner.run_all

      # Report results
      reporter = TestReporter.new(results, verbosity: verbosity)
      reporter.display

      # Shutdown (if configured)
      launcher.stop if config['auto_shutdown']

      results
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
      launcher.start
    end

    def handle_error(error)
      puts "\n❌ Fatal error: #{error.message}"
      if launcher && error.message.include?('terminated before API')
        std_log = File.join(launcher.get_cache_dir, 'std.log')
        if File.exist?(std_log)
          lines = File.readlines(std_log).last(50)
          puts "\n--- Last 50 lines of #{std_log} ---"
          puts lines.join
        end
      else
        puts error.backtrace.first(5)
      end
      launcher.stop if launcher&.running?
      exit 1
    end
  end
end
