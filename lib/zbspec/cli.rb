# frozen_string_literal: true

require 'amazing_print'
require 'optparse'
require 'tempfile'

require_relative 'cli/init'
require_relative 'cli/instances'
require_relative 'cli/interactive'
require_relative 'cli/start_only'
require_relative 'cli/harness_dispatch'

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
        zbspec -V 42.13           # Use game config from configs/42.13
        zbspec --sp -1             # SP with first game_version only
        zbspec --mp -1             # MP with first game_version only
        zbspec -i                 # Interactive console (all instances)
        zbspec -i --no-sandbox    # Interactive console without Lua sandbox
        zbspec -i --helper       # Interactive console and load spec/spec_helper.lua
        zbspec -i --port 4444     # Interactive console (connect to port only, no config)
        zbspec -i --script foo.lua  # Run script then interactive console
        zbspec --port 4444 --script foo.lua  # Send script to port only, then exit
        zbspec --script foo.lua   # Send script to all active instances
        echo 'return 1+1' | zbspec --port 4444   # Run stdin script on port
        echo 'return 1+1' | zbspec               # Run stdin script on all instances
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
      port: nil,
      script: nil,
      redirect_output: nil,
      restart: false,
      restart_only: false,
      game_version: nil,
      first_version_only: false,
      start_only: false,
      init: false,
      version: false,
      help: false,
      sandbox: true,
      helper: false
    }.freeze

    MODE_REASONS = {
      both: "running SP + MP",
      mp: "server + client specs found",
      server: "only server specs found"
    }.freeze

    def run(argv = ARGV)
      opts = parse_options(argv)

      return Init.run if opts[:init]
      return puts("ZBSpec v#{ZBSpec::VERSION}") if opts[:version]
      return print_help(opts) if opts[:help]
      return run_stop if opts[:mode] == :stop
      return run_stdin_script(opts) if !$stdin.tty?
      return Interactive.run_interactive_port(opts) if opts[:interactive] && opts[:port]
      return Interactive.run_script_to_port(opts) if opts[:port] && opts[:script]

      abort config_not_found_message(opts[:config]) unless File.exist?(opts[:config])

      config_overrides = build_config_overrides(opts)
      test_runner = load_test_runner(opts)

      return Interactive.run_interactive(opts) if opts[:interactive]

      discovery = SpecDiscovery.new
      opts[:mode] = discovery.recommended_mode if opts[:mode] == :auto

      # Multiple versions => compact output only; suppress discovery/mode lines
      versions = HarnessDispatch.resolve_versions(opts, config_overrides)
      opts[:verbosity] = -1 if versions.size > 1

      if opts[:verbosity] >= 0
        print_spec_summary(opts, discovery)
        print_auto_mode(opts) if opts[:mode] != :stop
      end

      maybe_restart(opts)
      return StartOnly.run(opts, config_overrides) if opts[:start_only]
      if opts[:script]
        StartOnly.run(opts, config_overrides) if opts[:restart] || Instances.discover_interactive_clients(opts[:mode], verbosity: opts[:verbosity], game_version: opts[:game_version]).empty?
        return Interactive.run_script_all_instances(opts.merge(restart: false))
      end

      HarnessDispatch.run(opts, discovery, test_runner, config_overrides)
    end

    def parse_options(argv)
      options = DEFAULT_OPTIONS.dup
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: zbspec [options] [spec_files...]'
        opts.on('-c', '--config PATH', 'Path to config file (default: spec/zbspec.yml)') { |p| options[:config] = p }
        opts.on('-m', '--mod-dir PATH', 'Path to mod directory') { |p| options[:mod_dir] = p }

        opts.on('-v', '--verbose', 'Increase verbosity (can be repeated: -vvv)') { options[:verbosity] += 1 }
        opts.on('-q', '--quiet', 'Decrease verbosity (can be repeated: -qqq)') { options[:verbosity] -= 1 }

        opts.on('-V', '--game-version VERSION', 'Use game config from configs/VERSION') { |v| options[:game_version] = v }
        opts.on('-1', 'Run only first game_version from config') { options[:first_version_only] = true }
        opts.on('--sp', 'Singleplayer only') { options[:mode] = :sp }
        opts.on('--server', 'Server only') { options[:mode] = :server }
        opts.on('--client', 'Client only (auto-start server)') { options[:mode] = :client }
        opts.on('--mp', 'Multiplayer (server + client)') { options[:mode] = :mp }
        opts.on('--start', 'Start instance(s) only, no tests') { options[:start_only] = true }
        opts.on('--stop', 'Stop all ZBSpec instances') { options[:mode] = :stop }
        opts.on('--restart', 'Restart before running specs') { options[:restart] = true }
        opts.on('--restart-only', 'Restart only, no tests') { options[:restart_only] = true }
        opts.on('-i', '--interactive', 'Interactive Lua console') { options[:interactive] = true }
        opts.on('--port PORT', Integer, 'Connect to API port (with -i: skip config and instance discovery)') { |p| options[:port] = p }
        opts.on('--script FILENAME', 'Execute Lua script: with -i run then REPL; with --port send to port only; else send to all instances') { |f| options[:script] = f }
        opts.on('--no-redirect-stdio', 'Do not redirect game stdout/stderr to std.log') { options[:redirect_output] = false }
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
        opts.on('--version', 'Show version') { options[:version] = true }
        opts.on('--init', 'Create default config and stub spec') { options[:init] = true }
        opts.on('--[no-]sandbox', 'Use sandbox for interactive Lua only (default: on)') { |v| options[:sandbox] = v }
        opts.on('--[no-]helper', 'Load spec/spec_helper.lua in interactive console (default: off)') { |v| options[:helper] = v }
      end
      parser.parse!(argv)
      options[:spec_files] = argv.dup
      options[:parser] = parser
      options
    end

    def print_help(opts)
      puts opts[:parser]
      puts HELP_FOOTER
    end

    def config_not_found_message(config_path)
      "❌ Config file not found: #{config_path}\n" \
        "   Run 'zbspec --init' to create default config and stub spec, or use --config PATH"
    end

    def build_config_overrides(opts)
      overrides = {}
      overrides['game_version'] = opts[:game_version] if opts[:game_version]
      overrides['redirect_output'] = opts[:redirect_output] unless opts[:redirect_output].nil?
      overrides
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
      Instances.stop_instances(Instances.discover_cache_dirs(:auto))
      puts "✓ Done"
      opts[:start_only] = true if opts[:restart_only]
    end

    def run_stop
      puts "🛑 Stopping all ZBSpec instances..."
      Instances.stop_instances(Instances.discover_cache_dirs(:auto))
      puts "✓ Done"
    end

    def run_stdin_script(opts)
      script = $stdin.read
      return if script.strip.empty?

      f = Tempfile.create(['zbspec_stdin', '.lua'])
      f.write(script)
      f.close
      at_exit { File.unlink(f.path) }
      opts = opts.merge(script: f.path)

      if opts[:port]
        Interactive.run_script_to_port(opts)
      else
        Interactive.run_script_all_instances(opts)
      end
    end

    def load_test_runner(opts)
      return nil unless opts[:mod_dir]
      path = [
        File.join(opts[:mod_dir], 'spec', 'framework', 'spec_runner.rb'),
        File.join(opts[:mod_dir], 'spec', 'spec_runner.rb')
      ].find { |p| File.exist?(p) }
      return nil unless path
      puts "📦 Loading mod specs from: #{path}"
      require path
      runner = ObjectSpace.each_object(Class).find { |k| k < TestRunner && k != TestRunner }
      puts "✓ Using custom spec runner: #{runner}" if runner
      runner
    end
  end
end
