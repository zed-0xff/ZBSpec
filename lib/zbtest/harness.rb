# frozen_string_literal: true

module ZBTest
  # Main test harness orchestrator
  class Harness
    attr_reader :config, :launcher, :api_client, :test_runner

    def initialize(config_path: nil, test_runner_class: nil)
      @config = Config.new(config_path)
      @launcher = GameLauncher.new(@config)
      @api_client = APIClient.new(port: @config['api_port'])
      
      # Use provided test runner class or default
      runner_class = test_runner_class || TestRunner
      @test_runner = runner_class.new(@api_client, @config)
    end

    def run
      puts '🚀 PZ Test Harness Starting'
      puts '=' * 50

      # Launch game (if not already running)
      launch_game_if_needed

      # Wait for API to be ready
      api_client.wait_for_ready(timeout: config['startup_timeout'])
      puts "\n✓ API ready\n"

      # Run all tests
      puts "\n🧪 Running Test Suite"
      puts '=' * 50
      results = test_runner.run_all

      # Report results
      reporter = TestReporter.new(results)
      reporter.display

      # Shutdown (if configured)
      launcher.stop if config['auto_shutdown']

      exit(results.failed? ? 1 : 0)
    rescue StandardError => e
      handle_error(e)
    end

    private

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
