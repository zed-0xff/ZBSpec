# frozen_string_literal: true

module ZBSpec
  # Multiplayer test harness - manages both server and client
  class MPHarness
    attr_reader :config, :server_launcher, :client_launcher
    attr_reader :server_api, :client_api, :verbosity

    def initialize(config_path: nil, spec_files: nil, verbosity: 0, client_only: false)
      @config = Config.new(config_path)
      @verbosity = verbosity
      @spec_files = spec_files
      @client_only = client_only
      @discovery = SpecDiscovery.new

      # Create separate launchers for server and client
      @server_launcher = GameLauncher.new(server_config, label: 'server', verbosity: verbosity)
      @client_launcher = GameLauncher.new(client_config, label: 'client', verbosity: verbosity)

      # Create API clients for each
      @server_api = APIClient.new(port_file: server_port_file, label: 'server', verbosity: verbosity)
      @client_api = APIClient.new(port_file: client_port_file, label: 'client', verbosity: verbosity)
    end

    def run
      if @verbosity > 0
        puts '🚀 ZBSpec Multiplayer Harness Starting'
        puts '=' * 50
      end

      begin
        # Launch both instances in parallel
        launch_instances_parallel
        
        # Wait for both to be ready
        wait_for_instances

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

    def launch_instances_parallel
      puts "\n🚀 Launching instances..." if @verbosity > 0
      
      threads = []
      
      # Launch server
      unless @config['use_running_server']
        threads << Thread.new do
          @server_launcher.start
          puts "  ✓ Server started (PID: #{@server_launcher.pid})" if @verbosity > 0
        end
      end
      
      # Launch client
      unless @config['use_running_client']
        threads << Thread.new do
          @client_launcher.start
          puts "  ✓ Client started (PID: #{@client_launcher.pid})" if @verbosity > 0
        end
      end
      
      # Wait for all launches to complete
      threads.each(&:join)
    end

    def wait_for_instances
      server_timeout = @config['server_startup_timeout'] || 60
      client_timeout = @config['startup_timeout'] || 120
      
      puts "⏳ Waiting for instances..." if @verbosity > 0
      
      # Wait for both in parallel threads, but server must be ready before client can connect
      server_ready = false
      client_error = nil
      
      threads = []
      
      # Server wait thread
      unless @config['use_running_server']
        threads << Thread.new do
          @server_api.discover_port(timeout: server_timeout)
          @server_api.wait_for_ready(timeout: server_timeout)
          
          # Sanity check: verify it's actually a server
          is_server = @server_api.execute('return isServer()')
          raise "Server instance is not running as server! isServer()=#{is_server}" unless is_server
          
          server_ready = true
          puts "  ✓ Server ready" if @verbosity > 0
        end
      else
        server_ready = true
      end
      
      # Client wait thread (waits for server first)
      unless @config['use_running_client']
        threads << Thread.new do
          # Wait for server to be ready first
          sleep 0.5 until server_ready
          
          @client_api.discover_port(timeout: client_timeout)
          @client_api.wait_for_ready(timeout: client_timeout)
          @client_api.wait_for_player(timeout: client_timeout)
          
          # Sanity check: verify it's actually a client
          is_client = @client_api.execute('return isClient()')
          raise "Client instance is not running as client! isClient()=#{is_client}" unless is_client
          
          puts "  ✓ Client ready" if @verbosity > 0
        rescue => e
          client_error = e
        end
      end
      
      # Wait for all threads
      threads.each(&:join)
      
      raise client_error if client_error
    end

    def run_specs
      results = TestResults.new

      # Determine which specs to run where
      # If specific files provided, filter by folder; otherwise use discovery
      if @spec_files
        server_specs = @spec_files.select { |f| f.include?('/server/') || f.include?('/shared/') || !f.match?(%r{/(?:client|server|shared)/}) }
        client_specs = @spec_files.select { |f| f.include?('/client/') || f.include?('/shared/') || !f.match?(%r{/(?:client|server|shared)/}) }
      else
        server_specs = @discovery.specs_for(:server)
        client_specs = @discovery.specs_for(:client)
      end

      # Run specs on server (unless client_only mode)
      unless @client_only
        if server_specs.any?
          puts "\n🧪 Running Server Specs (#{server_specs.length} files)"
          puts '-' * 30
          server_runner = TestRunner.new(@server_api, server_config, spec_files: server_specs, verbosity: @verbosity)
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
        client_runner = TestRunner.new(@client_api, client_config, spec_files: client_specs, verbosity: @verbosity)
        client_results = client_runner.run_all
        results.add_section('Client Specs', extract_tests(client_results))
      else
        puts "\n⏭️  No client specs to run"
      end

      # Report combined results
      puts "\n" + '=' * 50
      reporter = TestReporter.new(results, verbosity: @verbosity)
      reporter.display

      exit(results.failed? ? 1 : 0)
    end

    def extract_tests(results)
      # Flatten sections into test list, excluding health checks
      tests = []
      results.sections.each do |name, section_tests|
        next if name == 'Health Check'
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
