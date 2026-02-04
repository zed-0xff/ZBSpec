# frozen_string_literal: true

module ZBSpec
  # Multiplayer test harness - manages both server and client
  class MPHarness
    attr_reader :config, :server_launcher, :client_launcher
    attr_reader :server_api, :client_api, :verbose

    def initialize(config_path: nil, spec_files: nil, verbose: false, client_only: false)
      @config = Config.new(config_path)
      @verbose = verbose
      @spec_files = spec_files
      @client_only = client_only
      @discovery = SpecDiscovery.new

      # Create separate launchers for server and client
      @server_launcher = GameLauncher.new(server_config)
      @client_launcher = GameLauncher.new(client_config)

      # Create API clients for each
      @server_api = APIClient.new(port_file: server_port_file)
      @client_api = APIClient.new(port_file: client_port_file)
    end

    def run
      puts '🚀 ZBSpec Multiplayer Harness Starting'
      puts '=' * 50

      begin
        # Start server first
        start_server
        
        # Then start client
        start_client

        # Run specs on both
        run_specs

      rescue StandardError => e
        handle_error(e)
      ensure
        shutdown_if_needed
      end
    end

    private

    def server_config
      cfg = @config.to_h.dup
      cfg['server_mode'] = true
      cfg['cache_dir'] = server_cache_dir
      cfg['instance_name'] = 'server'
      Config.new(nil).tap { |c| c.merge!(cfg) }
    end

    def client_config
      cfg = @config.to_h.dup
      cfg['server_mode'] = false
      cfg['cache_dir'] = client_cache_dir
      cfg['instance_name'] = 'client'
      # Client connects to localhost
      cfg['server_ip'] = '127.0.0.1'
      Config.new(nil).tap { |c| c.merge!(cfg) }
    end

    def server_cache_dir
      File.expand_path('./tmp/cache_server')
    end

    def client_cache_dir
      File.expand_path('./tmp/cache_client')
    end

    def server_port_file
      File.join(server_cache_dir, 'zbLuaAPI.txt')
    end

    def client_port_file
      File.join(client_cache_dir, 'zbLuaAPI.txt')
    end

    def start_server
      if @config['use_running_server']
        puts '✓ Using already-running server'
      else
        puts "\n🖥️  Starting Server..."
        @server_launcher.start
        
        # Wait for server API (uses shorter timeout)
        server_timeout = @config['server_startup_timeout'] || 60
        @server_api.discover_port(timeout: server_timeout)
        @server_api.wait_for_ready(timeout: server_timeout)
        puts '✓ Server API ready'
      end
    end

    def start_client
      if @config['use_running_client']
        puts '✓ Using already-running client'
      else
        puts "\n💻 Starting Client..."
        @client_launcher.start
        
        # Wait for client API (uses longer timeout)
        client_timeout = @config['startup_timeout'] || 120
        @client_api.discover_port(timeout: client_timeout)
        @client_api.wait_for_ready(timeout: client_timeout)
        @client_api.wait_for_player(timeout: client_timeout)
        puts '✓ Client API ready (player spawned)'
      end
    end

    def run_specs
      results = TestResults.new

      # Determine which specs to run where
      server_specs = @spec_files || @discovery.specs_for(:server)
      client_specs = @spec_files || @discovery.specs_for(:client)

      # Run specs on server (unless client_only mode)
      unless @client_only
        if server_specs.any?
          puts "\n🧪 Running Server Specs (#{server_specs.length} files)"
          puts '-' * 30
          server_runner = TestRunner.new(@server_api, server_config, spec_files: server_specs)
          server_results = server_runner.run_all
          results.add_section('Server Specs', extract_tests(server_results))
        else
          puts "\n⏭️  No server specs to run"
        end
      end

      # Run specs on client
      if client_specs.any?
        puts "\n🧪 Running Client Specs (#{client_specs.length} files)"
        puts '-' * 30
        client_runner = TestRunner.new(@client_api, client_config, spec_files: client_specs)
        client_results = client_runner.run_all
        results.add_section('Client Specs', extract_tests(client_results))
      else
        puts "\n⏭️  No client specs to run"
      end

      # Report combined results
      puts "\n" + '=' * 50
      reporter = TestReporter.new(results, verbose: @verbose)
      reporter.display

      exit(results.failed? ? 1 : 0)
    end

    def extract_tests(results)
      # Flatten sections into test list
      tests = []
      results.sections.each do |_name, section_tests|
        tests.concat(section_tests)
      end
      tests
    end

    def shutdown_if_needed
      if @config['auto_shutdown']
        puts "\n🛑 Shutting down..."
        @client_launcher.stop if @client_launcher&.running?
        @server_launcher.stop if @server_launcher&.running?
      end
    end

    def handle_error(error)
      puts "\n❌ Fatal error: #{error.message}"
      puts error.backtrace.first(10)
      @client_launcher.stop if @client_launcher&.running?
      @server_launcher.stop if @server_launcher&.running?
      exit 1
    end
  end
end
