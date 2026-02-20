# frozen_string_literal: true

module ZBSpec
  # Multiplayer test harness - manages both server and client
  class MPHarness
    attr_reader :config, :server_launcher, :client_launcher
    attr_reader :server_api, :client_api, :verbosity

    def initialize(config_path: nil, spec_files: nil, verbosity: 0, client_only: false, config_overrides: {})
      @config = Config.new(config_path)
      config_overrides.each { |k, v| @config[k] = v }
      @verbosity = verbosity
      @spec_files = spec_files
      @client_only = client_only
      @discovery = SpecDiscovery.new

      # Create separate launchers for server and client
      @server_launcher = GameLauncher.new(server_config, label: 'server', verbosity: verbosity)
      @client_launcher = GameLauncher.new(client_config, label: 'client', verbosity: verbosity)

      # Create API clients for each (sandbox from config: false => send sandbox=false on requests)
      sandbox = @config['sandbox'] != false
      @server_api = APIClient.new(port_file: server_port_file, label: 'server', verbosity: verbosity, sandbox: sandbox)
      @client_api = APIClient.new(port_file: client_port_file, label: 'client', verbosity: verbosity, sandbox: sandbox)
    end

    def run
      results = run_without_exit
      exit(results.failed? ? 1 : 0)
    rescue StandardError => e
      handle_error(e)
    end

    def run_without_exit
      print_startup_banner
      launch_instances_parallel
      wait_for_instances
      wait_for_ready_condition
      run_specs
    rescue StandardError => e
      handle_error(e)
    ensure
      shutdown_if_needed
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
      File.expand_path("./tmp/cache_server_#{game_version_name}")
    end

    def client_cache_dir
      File.expand_path("./tmp/cache_client_#{game_version_name}")
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
      threads << Thread.new do
        @server_launcher.start
        puts "  ✓ Server started (PID: #{@server_launcher.pid})" if @verbosity > 0
      end
      threads << Thread.new do
        @client_launcher.start
        puts "  ✓ Client started (PID: #{@client_launcher.pid})" if @verbosity > 0
      end
      threads.each(&:join)
    end

    def print_startup_banner
      return unless @verbosity > 0
      puts '🚀 ZBSpec Multiplayer Harness Starting'
      puts '=' * 50
    end

    def game_version_name
      GameLauncher.game_version_name_from_config(@config)
    end

    def wait_for_instances
      server_timeout = @config['server_startup_timeout'] || 60
      client_timeout = @config['startup_timeout'] || 120
      
      puts "⏳ Waiting for instances..." if @verbosity > 0
      
      server_ready = false
      client_error = nil
      
      threads = []
      threads << Thread.new do
        @server_api.discover_port(timeout: server_timeout, process_pid: @server_launcher.pid)
        @server_api.wait_for_ready(timeout: server_timeout, process_pid: @server_launcher.pid)
        is_server = @server_api.execute('return isServer()')
        raise "Server instance is not running as server! isServer()=#{is_server}" unless is_server
        server_ready = true
        puts "  ✓ Server ready" if @verbosity > 0
      end
      threads << Thread.new do
        sleep 0.5 until server_ready
        @client_api.discover_port(timeout: client_timeout, process_pid: @client_launcher.pid)
        @client_api.wait_for_ready(timeout: client_timeout, process_pid: @client_launcher.pid)
        @client_api.wait_for_player(timeout: client_timeout, process_pid: @client_launcher.pid)
        is_client = @client_api.execute('return isClient()')
        raise "Client instance is not running as client! isClient()=#{is_client}" unless is_client
        puts "  ✓ Client ready" if @verbosity > 0
      rescue => e
        client_error = e
      end
      
      threads.each(&:join)
      raise client_error if client_error
    end

    def wait_for_ready_condition
      expr = @config['ready_condition']
      return if expr.to_s.strip.empty?

      server_timeout = @config['server_startup_timeout'] || 60
      client_timeout = @config['startup_timeout'] || 120
      unless @client_only
        @server_api.wait_for_condition(expr, timeout: server_timeout, process_pid: @server_launcher.pid)
      end
      @client_api.wait_for_condition(expr, timeout: client_timeout, process_pid: @client_launcher.pid)
      puts "  ✓ ready_condition satisfied" if @verbosity > 0
    end

    GAME_SPEED_UNPAUSE = "if setGameSpeed then setGameSpeed(1) end".freeze
    GAME_SPEED_PAUSE   = "if setGameSpeed then setGameSpeed(0) end".freeze

    def run_specs
      results = TestResults.new

      [@server_api, @client_api].each { |api| api.execute(GAME_SPEED_UNPAUSE) } if @config['unpause'] != false

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
          puts "\n🧪 Running Server Specs (#{server_specs.length} files)\n" + '-' * 30 if @verbosity >= 0
          server_runner = TestRunner.new(@server_api, server_config, spec_files: server_specs, verbosity: @verbosity)
          server_results = server_runner.run_all
          results.add_section('Server Specs', extract_tests(server_results))
        else
          puts "\n⏭️  No server specs to run" if @verbosity >= 0
        end
      end

      # Run specs on client
      if client_specs.any?
        puts "\n🧪 Running Client Specs (#{client_specs.length} files)\n" + '-' * 30 if @verbosity >= 0
        client_runner = TestRunner.new(@client_api, client_config, spec_files: client_specs, verbosity: @verbosity)
        client_results = client_runner.run_all
        results.add_section('Client Specs', extract_tests(client_results))
      else
        puts "\n⏭️  No client specs to run" if @verbosity >= 0
      end

      # Report combined results (caller may merge for multi-version)
      puts "\n" + '=' * 50 if @verbosity >= 0
      reporter = TestReporter.new(results, verbosity: @verbosity)
      reporter.display

      results
    ensure
      [@server_api, @client_api].each { |api| api.execute(GAME_SPEED_PAUSE) } if @config['unpause'] != false
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
      if error.message.include?('terminated before API')
        [@server_launcher, @client_launcher].compact.each do |launcher|
          std_log = File.join(launcher.get_cache_dir, 'std.log')
          next unless File.exist?(std_log)
          lines = File.readlines(std_log).last(50)
          puts "\n--- Last 50 lines of #{std_log} ---"
          puts lines.join
        end
      else
        puts error.backtrace.first(10)
      end
      @client_launcher.stop if @client_launcher&.running?
      @server_launcher.stop if @server_launcher&.running?
      exit 1
    end
  end
end
