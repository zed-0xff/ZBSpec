# frozen_string_literal: true

require 'optparse'

module ZBSpec
  module CLI
    module_function

    HELP_FOOTER = <<~HELP
      Spec folder structure:
        spec/client/*_spec.lua  - Client-only specs (also run in SP)
        spec/server/*_spec.lua  - Server-only specs
        spec/shared/*_spec.lua  - Shared specs (run on both)
        spec/*_spec.lua         - Root specs (treated as shared)

      Modes:
        (default)   Auto-detect: SP + MP if server specs exist
        --sp        Singleplayer only
        --mp        Multiplayer only (server + client)
        --server    Dedicated server only
        --client    MP client only (auto-starts server)
        --start     Start instance(s) only (no tests, no player wait)
        --stop      Stop all running ZBSpec instances
        --restart      Stop instances then start fresh
        --restart-only Restart instances only (no tests)
        -i          Interactive Lua console

      Examples:
        zbspec                    # Auto-detect mode from spec folders
        zbspec --mp               # Force MP mode
        zbspec --sp               # Force SP mode
        zbspec --start            # Start SP instance only
        zbspec --start --mp       # Start server + client instances
        zbspec --stop             # Stop all running instances
        zbspec --restart          # Restart instances before running specs
        zbspec --restart-only     # Restart instances only (no tests)
        zbspec --init             # Create default config and stub spec
        zbspec -V 42.13           # Use game config from game_configs/42.13
        zbspec -i                 # Interactive console (all instances)
        zbspec --client -i        # Interactive console (client only)
        zbspec --server -i        # Interactive console (server only)
        zbspec spec/my_spec.lua   # Run specific spec file
    HELP

    DEFAULT_OPTIONS = {
      config: 'spec/zbspec.yml',
      mod_dir: nil,
      spec_files: [],
      verbosity: 0,
      mode: :auto,
      interactive: false,
      restart: false,
      restart_only: false,
      game_version: nil,
      start_only: false,
      init: false,
      version: false,
      help: false
    }.freeze

    MODE_REASONS = {
      both: "running SP + MP",
      mp: "server + client specs found",
      server: "only server specs found"
    }.freeze

    def run(argv = ARGV)
      opts = parse_options(argv)

      return run_init                    if opts[:init]
      return puts("ZBSpec v#{ZBSpec::VERSION}") if opts[:version]
      return print_help(opts[:parser])    if opts[:help]
      return run_stop                     if opts[:mode] == :stop

      abort config_not_found_message(opts[:config]) unless File.exist?(opts[:config])

      config_overrides = build_config_overrides(opts)
      test_runner = load_test_runner(opts[:mod_dir])

      return run_interactive(opts) if opts[:interactive]

      discovery = SpecDiscovery.new
      opts[:mode] = discovery.recommended_mode if opts[:mode] == :auto

      print_spec_summary(opts, discovery)
      print_auto_mode(opts) if opts[:mode] != :stop

      maybe_restart(opts)
      return run_start_only(opts, config_overrides) if opts[:start_only]

      FileUtils.mkdir_p('logs')
      run_harness_dispatch(opts, discovery, test_runner, config_overrides)
    end

    def parse_options(argv)
      options = DEFAULT_OPTIONS.dup
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: zbspec [options] [spec_files...]'
        opts.on('-c', '--config PATH', 'Path to config file (default: spec/zbspec.yml)') { |p| options[:config] = p }
        opts.on('-m', '--mod-dir PATH', 'Path to mod directory') { |p| options[:mod_dir] = p }
        opts.on('-v', '--verbose', 'Increase verbosity (can be repeated: -vvv)') { options[:verbosity] += 1 }
        opts.on('-V', '--game-version VERSION', 'Use game config from game_configs/VERSION') { |v| options[:game_version] = v }
        opts.on('--sp', 'Singleplayer only') { options[:mode] = :sp }
        opts.on('--server', 'Server only') { options[:mode] = :server }
        opts.on('--client', 'Client only (auto-start server)') { options[:mode] = :client }
        opts.on('--mp', 'Multiplayer (server + client)') { options[:mode] = :mp }
        opts.on('--start', 'Start instance(s) only, no tests') { options[:start_only] = true }
        opts.on('--stop', 'Stop all ZBSpec instances') { options[:mode] = :stop }
        opts.on('--restart', 'Restart before running specs') { options[:restart] = true }
        opts.on('--restart-only', 'Restart only, no tests') { options[:restart_only] = true }
        opts.on('-i', '--interactive', 'Interactive Lua console') { options[:interactive] = true }
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
        opts.on('--version', 'Show version') { options[:version] = true }
        opts.on('--init', 'Create default config and stub spec') { options[:init] = true }
      end
      parser.parse!(argv)
      options[:spec_files] = argv.dup
      options[:parser] = parser
      options
    end

    def print_help(parser)
      puts parser
      puts HELP_FOOTER
    end

    def config_not_found_message(config_path)
      "❌ Config file not found: #{config_path}\n" \
        "   Run 'zbspec --init' to create default config and stub spec, or use --config PATH"
    end

    def build_config_overrides(opts)
      opts[:game_version] ? { 'game_version' => opts[:game_version] } : {}
    end

    def print_spec_summary(opts, discovery)
      if opts[:spec_files].any?
        puts "📋 Running specified spec files: #{opts[:spec_files].join(', ')}"
      else
        puts "📋 Discovered specs: #{discovery.summary}"
      end
    end

    def print_auto_mode(opts)
      reason = MODE_REASONS[opts[:mode]] || "no server specs found"
      puts "🔍 Auto-detected mode: #{opts[:mode]} (#{reason})"
    end

    def maybe_restart(opts)
      return unless opts[:restart] || opts[:restart_only]
      puts "🔄 Restarting instances#{opts[:restart_only] ? ' (no tests)...' : '...'}"
      stop_instances(discover_cache_dirs(:auto))
      puts "✓ Done"
      opts[:start_only] = true if opts[:restart_only]
    end

    def run_stop
      puts "🛑 Stopping all ZBSpec instances..."
      stop_instances(discover_cache_dirs(:auto))
      puts "✓ Done"
    end

    # --- Init ---

    def run_init
      created = []
      FileUtils.mkdir_p('spec/shared')
      [['spec/zbspec.yml', init_config_yaml], ['spec/shared/example_spec.lua', init_stub_spec]].each do |path, content|
        if File.exist?(path)
          puts "  (existing) #{path}"
        else
          File.write(path, content)
          created << path
        end
      end
      created << ensure_workshopignore
      created.compact!

      if created.any?
        puts "✓ Created:"
        created.each { |p| puts "  #{p}" }
        puts "\nRun: zbspec"
      else
        puts "✓ spec/zbspec.yml and spec/shared/example_spec.lua already exist."
      end
    end

    def init_config_yaml
      <<~YAML
        ---
        # ZBSpec configuration (created by zbspec --init)
        startup_timeout: 120
        auto_shutdown: false
        game_path: /Applications/Project Zomboid.app
        game_versions_root: "~/projects/zomboid/versions"
        game_versions:
          - default
        debug: true
        spec_glob: spec/**/*_spec.lua
        mods:
          - YourModName
      YAML
    end

    def init_stub_spec
      <<~LUA
        -- Stub spec (created by zbspec --init)
        require "ZBSpec"
        describe("example", function()
            it("passes", function()
                assert.is_equal(4, 2 + 2)
            end)
        end)
        return ZBSpec.run()
      LUA
    end

    def ensure_workshopignore
      path = '.workshopignore'
      entries = %w[spec tmp]
      existing = File.exist?(path) ? File.read(path).lines.map { |l| l.sub(/\s*#.*/, '').strip }.reject(&:empty?) : []
      to_append = entries.reject { |e| existing.include?(e) }
      return nil if to_append.empty?
      File.open(path, 'a') do |f|
        f.puts '' if existing.any?
        f.puts '# ZBSpec' if existing.empty?
        to_append.each { |e| f.puts e }
      end
      path
    end

    # --- Stop / discover ---

    def stop_instances(cache_dirs)
      found = false
      cache_dirs.each do |cache_dir|
        pid_file = File.join(cache_dir, 'pz.pid')
        next unless File.exist?(pid_file)
        found = true
        stop_one_instance(cache_dir, pid_file)
        File.delete(File.join(cache_dir, 'zbLuaAPI.txt')) if File.exist?(File.join(cache_dir, 'zbLuaAPI.txt'))
      end
      puts "  No running instances found" unless found
    end

    def stop_one_instance(cache_dir, pid_file)
      pid = File.read(pid_file).strip.to_i
      name = File.basename(cache_dir)
      Process.kill(0, pid)
      puts "  Stopping #{name} (PID: #{pid})..."
      Process.kill('TERM', pid)
      sleep 0.5
      Process.kill('KILL', pid) if process_alive?(pid)
      puts "  ✓ Stopped #{name}"
    rescue Errno::ESRCH
      puts "  ⚠️  #{name} already stopped (stale PID file)"
    ensure
      File.delete(pid_file)
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def discover_cache_dirs(mode)
      all = Dir.glob('tmp/cache_*').select { |d| File.directory?(d) }.sort
      filter = { sp: 'cache_sp_', server: 'cache_server_', client: 'cache_client_' }
      case mode
      when :sp then all.select { |d| d.include?(filter[:sp]) }
      when :server then all.select { |d| d.include?(filter[:server]) }
      when :client then all.select { |d| d.include?(filter[:client]) }
      when :mp, :both then all.select { |d| d.include?(filter[:server]) || d.include?(filter[:client]) }
      else all
      end
    end

    # --- Test runner ---

    def load_test_runner(mod_dir)
      return nil unless mod_dir
      path = [
        File.join(mod_dir, 'spec', 'framework', 'spec_runner.rb'),
        File.join(mod_dir, 'spec', 'spec_runner.rb')
      ].find { |p| File.exist?(p) }
      return nil unless path
      puts "📦 Loading mod specs from: #{path}"
      require path
      runner = ObjectSpace.each_object(Class).find { |k| k < TestRunner && k != TestRunner }
      puts "✓ Using custom spec runner: #{runner}" if runner
      runner
    end

    # --- Interactive ---

    def run_interactive(opts)
      stop_instances(discover_cache_dirs(:auto)) if opts[:restart]
      puts "🔧 Interactive Lua Console\n" + "=" * 50

      clients = discover_interactive_clients(opts[:mode])
      if clients.empty?
        puts "\n❌ No running instances found. Start a game first with:\n   zbspec --sp    # Singleplayer\n   zbspec --mp    # Multiplayer"
        exit 1
      end

      max_len = clients.keys.map(&:length).max
      clients.each { |name, data| puts "  ✓ Connected to #{name.ljust(max_len)} (port #{data[:port]})" }
      clients.transform_values! { |data| data[:client] }
      cancel_pending_jobs(clients)
      load_spec_helper(clients)

      puts "\nType Lua code to execute on all instances.\nType 'exit' or press Ctrl+D/Ctrl+C to quit.\n\n"
      require 'readline'
      setup_readline_history
      trap('INT') { puts "\nBye!"; exit 0 }
      interactive_repl_loop(clients, opts)
      puts "Bye!"
    end

    def discover_interactive_clients(mode)
      discover_cache_dirs(mode).each_with_object({}) do |cache_dir, out|
        port_file = File.join(cache_dir, 'zbLuaAPI.txt')
        next unless File.exist?(port_file)
        port = File.read(port_file).strip.to_i
        next if port <= 0
        name = File.basename(cache_dir).sub('cache_', '')
        client = APIClient.new(port: port)
        out[name] = { client: client, port: port } if client.ready?
      end
    end

    def cancel_pending_jobs(clients)
      clients.each do |name, client|
        n = client.execute('return ZBSpec.cancelAllJobs()')
        puts "  ⚠️  Cancelled #{n} pending jobs on #{name}" if n && n > 0
      rescue
        # ZBSpec might not be loaded
      end
    end

    def load_spec_helper(clients)
      path = File.join(Dir.pwd, 'spec', 'spec_helper.lua')
      return unless File.exist?(path)
      code = File.read(path)
      clients.each do |name, client|
        client.execute(code)
      rescue => e
        puts "  ⚠️  Failed to load spec_helper on #{name}: #{e.message}"
      end
      puts "  ✓ Loaded spec/spec_helper.lua"
    end

    def setup_readline_history
      history_file = File.expand_path('~/.zbspec_history')
      File.readlines(history_file).each { |l| Readline::HISTORY.push(l.chomp) } if File.exist?(history_file)
      at_exit do
        File.open(history_file, 'w') { |f| Readline::HISTORY.to_a.last(1000).each { |l| f.puts(l) } }
      end
    end

    def interactive_repl_loop(clients, opts)
      max_len = clients.keys.map(&:length).max || 0
      while (line = Readline.readline('lua> ', true))
        line = line.strip
        break if %w[exit quit].include?(line)
        next if line.empty?
        Readline::HISTORY.pop if Readline::HISTORY.size > 1 && Readline::HISTORY[-2] == line
        lua = line.match?(/\breturn\b|;/) ? line : "return #{line}"
        clients.each { |name, client| run_lua_line(client, lua, name, max_len, clients.size > 1, opts) }
      end
    end

    def run_lua_line(client, lua, name, max_len, multi, opts)
      result = client.execute(lua)
      puts multi ? "[#{name.ljust(max_len)}] #{result.inspect}" : result.inspect
    rescue APIClient::LuaError => e
      prefix = multi ? "[#{name.ljust(max_len)}] " : ""
      puts "#{prefix}Error: #{e.error_message}"
      puts "#{prefix}  File: #{e.file}:#{e.line}" if e.file
      puts "#{prefix}  Test: #{e.test_name}" if e.test_name
      if opts[:verbosity] >= 1 && e.lua_return
        puts "#{prefix}  Raw:"
        e.lua_return['kahluaErrors']&.each { |err| err.each_line { |l| puts "#{prefix}    #{l.rstrip}" } }
      end
    rescue => e
      puts "[#{name.ljust(max_len)}] Error: #{e.class}: #{e.message}"
    end

    # --- Start only ---

    def run_start_only(opts, config_overrides)
      puts "🚀 Starting instance(s)..."
      case opts[:mode]
      when :mp, :both then start_mp_and_wait(opts, config_overrides)
      when :server then start_server_and_wait(opts, config_overrides)
      when :client then start_client_and_wait(opts, config_overrides)
      else start_sp_and_wait(opts, config_overrides)
      end
      puts "\n✓ Instance(s) started. Use 'zbspec -i' for interactive console or 'zbspec' to run tests."
    end

    def start_mp_and_wait(opts, config_overrides)
      mp = MPHarness.new(config_path: opts[:config], verbosity: opts[:verbosity], config_overrides: config_overrides)
      mp.send(:launch_instances_parallel)
      wait_apis("Server", mp.server_api, mp.config['server_startup_timeout'] || 60, mp.server_launcher.pid)
      wait_apis("Client", mp.client_api, mp.config['startup_timeout'] || 120, mp.client_launcher.pid, print_wait: false)
    end

    def start_server_and_wait(opts, config_overrides)
      config = server_config(opts[:config], config_overrides)
      launcher = GameLauncher.new(config, label: 'server', verbosity: opts[:verbosity])
      launcher.start
      api = APIClient.new(port_file: File.join(config['cache_dir'], 'zbLuaAPI.txt'), label: 'server', verbosity: opts[:verbosity])
      wait_apis("Server", api, config['server_startup_timeout'] || 60, launcher.pid)
    end

    def start_client_and_wait(opts, config_overrides)
      mp = MPHarness.new(config_path: opts[:config], verbosity: opts[:verbosity], client_only: true, config_overrides: config_overrides)
      mp.send(:launch_instances_parallel)
      wait_apis("Server", mp.server_api, mp.config['server_startup_timeout'] || 60, mp.server_launcher.pid)
      wait_apis("Client", mp.client_api, mp.config['startup_timeout'] || 120, mp.client_launcher.pid, print_wait: false)
    end

    def start_sp_and_wait(opts, config_overrides)
      config = sp_config(opts[:config], config_overrides)
      launcher = GameLauncher.new(config, verbosity: opts[:verbosity])
      launcher.start
      api = APIClient.new(port_file: File.join(config['cache_dir'], 'zbLuaAPI.txt'), label: 'sp', verbosity: opts[:verbosity])
      wait_apis("SP", api, config['startup_timeout'] || 120, launcher.pid)
    end

    def server_config(config_path, overrides)
      config = Config.new(config_path)
      overrides.each { |k, v| config[k] = v }
      config['server_mode'] = true
      v = config['game_version'] || (config['game_versions'].is_a?(Array) && config['game_versions'].first) || 'default'
      config['cache_dir'] = File.expand_path("./tmp/cache_server_#{v}")
      config
    end

    def sp_config(config_path, overrides)
      config = Config.new(config_path)
      overrides.each { |k, v| config[k] = v }
      v = config['game_version'] || (config['game_versions'].is_a?(Array) && config['game_versions'].first) || 'default'
      config['cache_dir'] = File.expand_path("./tmp/cache_sp_#{v}")
      config
    end

    def wait_apis(label, api, timeout, pid, print_wait: true)
      puts "⏳ Waiting for API..." if print_wait
      api.discover_port(timeout: timeout, process_pid: pid)
      api.wait_for_ready(timeout: timeout, process_pid: pid)
      puts "  ✓ #{label} API ready"
    end

    # --- Harness dispatch ---

    def run_harness_dispatch(opts, discovery, test_runner, config_overrides)
      spec_files = opts[:spec_files].empty? ? nil : opts[:spec_files]
      base = { config_path: opts[:config], test_runner_class: test_runner, verbosity: opts[:verbosity], config_overrides: config_overrides }

      case opts[:mode]
      when :both
        run_both_phases(opts, discovery, spec_files, base)
      when :mp
        puts "\n🎮 Multiplayer mode: running specs on server and client"
        MPHarness.new(config_path: opts[:config], spec_files: spec_files, verbosity: opts[:verbosity], config_overrides: config_overrides).run
      when :server
        puts "\n🖥️  Server mode: running specs on dedicated server"
        Harness.new(**base.merge(spec_files: spec_files || discovery.specs_for(:server), config_overrides: config_overrides.merge('server_mode' => true))).run
      when :client
        puts "\n💻 Client mode: running specs on MP client (auto-starting server)"
        MPHarness.new(config_path: opts[:config], spec_files: spec_files || discovery.specs_for(:client), verbosity: opts[:verbosity], client_only: true, config_overrides: config_overrides).run
      else
        puts "\n🎮 Singleplayer mode"
        Harness.new(**base.merge(spec_files: spec_files || discovery.specs_for(:sp))).run
      end
    end

    def run_both_phases(opts, discovery, spec_files, base)
      puts "\n" + "=" * 50 + "\n🎮 Phase 1: Singleplayer mode\n" + "=" * 50
      sp_files = spec_files || discovery.specs_for(:sp)
      Harness.new(**base.merge(spec_files: sp_files.empty? ? nil : sp_files)).run_without_exit
      puts "\n" + "=" * 50 + "\n🎮 Phase 2: Multiplayer mode\n" + "=" * 50
      MPHarness.new(config_path: opts[:config], spec_files: spec_files, verbosity: opts[:verbosity], config_overrides: base[:config_overrides]).run
    end
  end
end
