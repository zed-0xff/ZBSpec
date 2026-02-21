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
      sandbox = @config['sandbox'] != false
      @api_client = APIClient.new(port_file: port_file, label: label, verbosity: verbosity, sandbox: sandbox)
      
      # Use provided test runner class or default
      runner_class = test_runner_class || TestRunner
      @test_runner = runner_class.new(@api_client, @config, spec_files: spec_files, verbosity: verbosity)
    end

    def run
      results = run_without_exit
      exit(results.failed? ? 1 : 0)
    end

    def run_without_exit
      print_startup_banner
      boot_instance_api
      validate_instance_mode
      wait_for_ready_condition
      results = run_specs_and_report
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

    def print_startup_banner
      return unless verbosity > 0
      puts '🚀 PZ Spec Harness Starting'
      puts '=' * 50
    end

    def boot_instance_api
      launch_game_if_needed
      api_client.discover_port(timeout: startup_timeout, process_pid: launcher.pid)
      api_client.wait_for_ready(timeout: startup_timeout, process_pid: launcher.pid)
    end

    def validate_instance_mode
      return validate_server_mode if config['server_mode']
      return validate_client_mode if config['server_ip']
      validate_singleplayer_mode
    end

    def validate_server_mode
      is_server = api_client.execute('return isServer()')
      raise "Instance should be server but isServer()=#{is_server}" unless is_server
      puts "✓ Server ready" if verbosity > 0
    end

    def validate_client_mode
      is_client = api_client.execute('return isClient()')
      raise "Instance should be client but isClient()=#{is_client}" unless is_client
      puts "✓ Client ready" if verbosity > 0
      api_client.wait_for_player(timeout: startup_timeout, process_pid: launcher.pid)
    end

    def validate_singleplayer_mode
      is_client = api_client.execute('return isClient()')
      is_server = api_client.execute('return isServer()')
      if is_client || is_server
        raise "SP instance should be neither client nor server, but isClient=#{is_client}, isServer=#{is_server}"
      end
      puts "✓ SP ready" if verbosity > 0
      api_client.wait_for_player(timeout: startup_timeout, process_pid: launcher.pid)
    end

    def wait_for_ready_condition
      expr = config['ready_condition']
      return if expr.to_s.strip.empty?

      api_client.wait_for_condition(expr, timeout: startup_timeout, process_pid: launcher.pid)
      puts "✓ ready_condition satisfied" if verbosity > 0
    end

    GAME_SPEED_UNPAUSE = "if getGameSpeed and getGameSpeed() == 0 and setGameSpeed then setGameSpeed(1) end".freeze
    GAME_SPEED_PAUSE   = "if setGameSpeed then setGameSpeed(0) end".freeze

    def run_specs_and_report
      puts "\n🧪 Running Specs" if verbosity > 0
      api_client.execute(GAME_SPEED_UNPAUSE) if config['unpause'] != false
      begin
        results = test_runner.run_all
        TestReporter.new(results, verbosity: verbosity).display
        results
      ensure
        api_client.execute(GAME_SPEED_PAUSE) if config['unpause'] != false
      end
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
