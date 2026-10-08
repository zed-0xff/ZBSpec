# frozen_string_literal: true

require 'fileutils'

module ZBSpec
  # Multiplayer test harness - manages both server and client
  class MPHarness
    attr_reader :config, :server_launcher, :client_launcher, :client2_launcher
    attr_reader :server_api, :client_api, :client2_api, :verbosity

    def initialize(config_path: nil, spec_files: nil, verbosity: 0, client_only: false, config_overrides: {})
      @config = Config.new(config_path)
      config_overrides.each { |k, v| @config[k] = v }
      @verbosity = verbosity
      @spec_files = spec_files
      @client_only = client_only
      @discovery = SpecDiscovery.new(spec_dir: @config['spec_dir'] || 'spec')

      # Create separate launchers for server and client
      @server_launcher = GameLauncher.new(server_config, label: 'server', verbosity: verbosity)
      @client_launcher = GameLauncher.new(client_config, label: 'client', verbosity: verbosity)
      @client2_launcher = GameLauncher.new(client2_config, label: 'client2', verbosity: verbosity) if two_clients?

      # Create API clients for each
      sandbox = @config['sandbox']
      @server_api = APIClient.new(port_file: server_port_file, label: 'server', verbosity: verbosity, sandbox: sandbox)
      @client_api = APIClient.new(port_file: client_port_file, label: 'client', verbosity: verbosity, sandbox: sandbox)
      @client2_api = APIClient.new(port_file: client2_port_file, label: 'client2', verbosity: verbosity, sandbox: sandbox) if two_clients?
    end

    # Launch a second MP client when `mp_clients: 2` is configured (for
    # surgeon<->patient relay tests). Defaults to a single client.
    def two_clients?
      @config['mp_clients'].to_i > 1
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
      @last_results = run_specs
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
      client_config_for('client')
    end

    def client2_config
      client_config_for('client2')
    end

    def client_config_for(kind)
      cfg = @config.to_h.dup
      cfg['server_mode'] = false
      cfg['cache_dir'] = cache_dir_for(kind)
      cfg['instance_name'] = kind
      # Client connects to localhost
      cfg['server_ip'] = '127.0.0.1'
      # PZ 42.21 ConnectToServerState.TestTCP() force-disconnects a client that
      # runs with `-debug` when the server-assigned role lacks the
      # ConnectWithDebug capability (message "connect-debug-used"). The default
      # "user" role does not grant it, so a test client launched with -debug is
      # rejected. The MP client does not need debug mode, so never pass -debug.
      cfg['debug'] = false
      Config.new(nil).tap { |c| c.merge!(cfg) }
    end

    def server_cache_dir
      cache_dir_for('server')
    end

    def client_cache_dir
      cache_dir_for('client')
    end

    def client2_cache_dir
      cache_dir_for('client2')
    end

    # Cache dirs live outside the mod directory when `cache_root` is configured.
    # Keeping them under ./tmp (inside the mod, which itself sits in
    # ~/Zomboid/mods) makes PZ's mod scanner pick up the cached mod copy and
    # build bogus script paths.
    def cache_dir_for(kind)
      root = @config['cache_root']
      if root && !root.to_s.strip.empty?
        File.join(File.expand_path(root.to_s), "cache_#{kind}_#{game_version_name}")
      else
        File.expand_path("./tmp/cache_#{kind}_#{game_version_name}")
      end
    end

    def server_port_file
      File.join(server_cache_dir, 'zbLuaAPI.txt')
    end

    def client_port_file
      File.join(client_cache_dir, 'zbLuaAPI.txt')
    end

    def client2_port_file
      File.join(client2_cache_dir, 'zbLuaAPI.txt')
    end

    def launch_instances_parallel
      puts "\n🚀 Launching instances..." if @verbosity > 0

      # A previous run that failed under `shutdown: auto` (or was killed) can
      # leave the games running. Reusing a stale server while we delete its
      # API-port file below would hang, and the stale world is not what we want
      # to test, so stop anything recorded in the cache pid files first.
      stop_stale_instances

      # Remove the previous run's ZombieBuddy API-port file *before* the server
      # starts, otherwise wait_for_server_ready below would see the stale file
      # and release the client before the server has even booted.
      remove_stale_api_port_file

      # The server picks and persists its game port while launching, and the
      # client must dial that exact port. Starting the server first (and waiting
      # for its persisted port) removes the race where the client would fall
      # back to a default port.
      server_thread = Thread.new do
        @server_launcher.start
        puts "  ✓ Server started (PID: #{@server_launcher.pid})" if @verbosity > 0
      end

      wait_for_server_port(server_thread)

      # The persisted game-port file is written before the server process boots,
      # so on a slow server start the client could autoconnect (a single,
      # non-retried attempt made the instant PZ shows the connect popup) before
      # RakNet has bound -> "connection-attempt-failed", no player, hard timeout.
      # The ZombieBuddy API-port file is written at onGameInitComplete, just
      # before RakNet binds, so wait for it (file poll, not an API call, to avoid
      # depending on the server's Lua thread) and let the listener settle.
      wait_for_server_ready(server_thread)

      # Per-instance login credentials (a second client must use a distinct
      # username or the server rejects it as "AlreadyConnected").
      write_client_credentials(client_cache_dir, 'admin', 'zbspec')
      @client_launcher.start
      puts "  ✓ Client started (PID: #{@client_launcher.pid})" if @verbosity > 0

      if two_clients?
        write_client_credentials(client2_cache_dir, 'zbspec2', 'zbspec')
        @client2_launcher.start
        puts "  ✓ Client2 started (PID: #{@client2_launcher.pid})" if @verbosity > 0
      end

      server_thread.join
    end

    # Write the credentials the MP autoconnect mod reads from the Lua cache dir.
    def write_client_credentials(cache_dir, username, password)
      lua_dir = File.join(cache_dir, 'Lua')
      FileUtils.mkdir_p(lua_dir)
      File.write(File.join(lua_dir, 'zb_mp_credentials.txt'), "#{username}\n#{password}\n")
    end

    def remove_stale_api_port_file
      path = File.join(server_cache_dir, 'zbLuaAPI.txt')
      File.delete(path) if File.exist?(path)
    rescue StandardError
      nil
    end

    # Kill any game processes recorded in the server/client cache pid files.
    def stop_stale_instances
      [@server_launcher, @client_launcher, @client2_launcher].compact.each do |launcher|
        begin
          pid_file = launcher.pid_file
          next unless File.exist?(pid_file)

          pid = File.read(pid_file).strip.to_i
          if pid.positive? && launcher.send(:process_alive?, pid)
            puts "  ⚠ Stopping stale instance (PID: #{pid})" if @verbosity > 0
            launcher.send(:terminate_process, pid)
            sleep 0.5
          end
          File.delete(pid_file) if File.exist?(pid_file)
        rescue StandardError
          nil
        end
      end
    end

    # Wait until the server has persisted its game port (or it failed to start).
    def wait_for_server_port(server_thread, timeout: 30)
      deadline = Time.now + timeout
      while Time.now < deadline
        break unless server_thread.alive?
        port = @server_launcher.send(:server_persisted_port)
        break if port
        sleep 0.2
      end
    end

    # Block until the server's ZombieBuddy API-port file is (re)written (at
    # onGameInitComplete, immediately before RakNet binds), then give the RakNet
    # listener a moment to bind. The stale file is removed before launch, so its
    # (re)appearance means the server has booted. Polling the file keeps this
    # independent of the server's Lua thread, which is not necessarily
    # responsive during boot.
    def wait_for_server_ready(_server_thread, timeout: nil)
      timeout ||= @config['server_startup_timeout'] || 60
      path = File.join(server_cache_dir, 'zbLuaAPI.txt')
      deadline = Time.now + timeout
      loop do
        if File.exist?(path) && File.read(path).strip =~ /^\d+$/
          sleep 1.5
          return
        end
        raise "Server API port not written after #{timeout}s (file: #{path})" if Time.now > deadline
        sleep 0.2
      end
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

      if two_clients?
        threads << Thread.new do
          sleep 0.5 until server_ready
          @client2_api.discover_port(timeout: client_timeout, process_pid: @client2_launcher.pid)
          @client2_api.wait_for_ready(timeout: client_timeout, process_pid: @client2_launcher.pid)
          @client2_api.wait_for_player(timeout: client_timeout, process_pid: @client2_launcher.pid)
          is_client = @client2_api.execute('return isClient()')
          raise "Client2 instance is not running as client! isClient()=#{is_client}" unless is_client
          puts "  ✓ Client2 ready" if @verbosity > 0
        rescue => e
          client_error = e
        end
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

    GAME_SPEED_UNPAUSE = "if getGameSpeed and getGameSpeed() == 0 and setGameSpeed then setGameSpeed(1) end".freeze
    GAME_SPEED_PAUSE   = "if setGameSpeed then setGameSpeed(0) end".freeze

    def run_specs
      results = TestResults.new

      [@server_api, @client_api, @client2_api].compact.each { |api| api.execute(GAME_SPEED_UNPAUSE) } if @config['unpause'] != false
      wait_for_ready_condition

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
        # Let the server settle after the server specs before the client drives
        # it (the first client->server eval can otherwise be slow).
        sleep 3
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
      [@server_api, @client_api, @client2_api].compact.each { |api| api.execute(GAME_SPEED_PAUSE) } if @config['pause'] != false
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
      shutdown_val = @config['shutdown']
      should_stop = shutdown_val == 'always' || (shutdown_val == 'auto' && @last_results && !@last_results.failed?)
      return unless should_stop
      puts "\n🛑 Shutting down..."
      @client2_launcher.stop if @client2_launcher&.running?
      @client_launcher.stop if @client_launcher&.running?
      @server_launcher.stop if @server_launcher&.running?
    end

    def handle_error(error)
      puts "\n❌ Fatal error: #{error.message}"
      if error.message.include?('terminated before API')
        [@server_launcher, @client_launcher, @client2_launcher].compact.each do |launcher|
          std_log = File.join(launcher.get_cache_dir, 'std.log')
          next unless File.exist?(std_log)
          lines = File.readlines(std_log).last(50)
          puts "\n--- Last 50 lines of #{std_log} ---"
          puts lines.join
        end
      else
        puts error.backtrace.first(10)
      end
      @client2_launcher.stop if @client2_launcher&.running?
      @client_launcher.stop if @client_launcher&.running?
      @server_launcher.stop if @server_launcher&.running?
      exit 1
    end
  end
end
