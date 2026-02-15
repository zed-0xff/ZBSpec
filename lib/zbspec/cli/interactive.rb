# frozen_string_literal: true

module ZBSpec
  module CLI
    module Interactive
      module_function

      def run_interactive_port(opts)
        port, client = connect_port_client(opts)
        puts "🔧 Interactive Lua Console (port #{port})\n" + "=" * 50
        puts "  ✓ Connected to port #{port}"

        clients = one_client_hash(port, client)
        load_spec_helper(clients) if opts[:helper]

        execute_script_on_clients(clients, opts[:script], exit_on_error: true) if opts[:script]

        run_session(clients, opts, "\nType Lua code to execute. Type 'exit' or press Ctrl+D/Ctrl+C to quit.\n\n")
      end

      def run_script_to_port(opts)
        port, client = connect_port_client(opts)
        abort "❌ Script file not found: #{opts[:script]}" unless File.file?(opts[:script])

        clients = one_client_hash(port, client)
        execute_script_on_clients(clients, opts[:script], exit_on_error: true)
      end

      def run_interactive(opts)
        Instances.stop_instances(Instances.discover_cache_dirs(:auto)) if opts[:restart]
        puts "🔧 Interactive Lua Console\n" + "=" * 50

        clients = Instances.discover_interactive_clients(opts[:mode], verbosity: opts[:verbosity], game_version: opts[:game_version], sandbox: opts[:sandbox])
        if clients.empty?
          puts "\n❌ No running instances found. Start a game first with:\n   zbspec --sp    # Singleplayer\n   zbspec --mp    # Multiplayer"
          exit 1
        end

        max_len = clients.keys.map(&:length).max
        clients.each { |name, data| puts "  ✓ Connected to #{name.ljust(max_len)} (port #{data[:port]})" }
        clients.transform_values! { |data| data[:client] }
        load_spec_helper(clients) if opts[:helper]

        execute_script_on_clients(clients, opts[:script], exit_on_error: false) if opts[:script]

        run_session(clients, opts, "\nType Lua code to execute on all instances.\nType 'exit' or press Ctrl+D/Ctrl+C to quit.\n\n")
      end

      def run_script_all_instances(opts)
        path = opts[:script]
        abort "❌ Script file not found: #{path}" unless File.file?(path)

        mode = opts[:mode] == :auto ? :auto : opts[:mode]
        clients = Instances.discover_interactive_clients(mode, verbosity: opts[:verbosity], game_version: opts[:game_version])
        if clients.empty?
          abort "❌ No running instances found. Start a game first (e.g. zbspec --sp)."
        end

        max_len = clients.keys.map(&:length).max
        clients.each { |name, data| puts "  ✓ #{name.ljust(max_len)} (port #{data[:port]})" }
        clients.transform_values! { |data| data[:client] }

        execute_script_on_clients(clients, path, exit_on_error: true)
      end

      def execute_script_on_clients(clients, path, exit_on_error: false)
        code = File.read(path)
        multi = clients.size > 1
        max_len = clients.keys.map(&:length).max || 0
        clients.each do |name, client|
          result = client.execute(code)
          puts multi ? "[#{name.ljust(max_len)}] #{result.inspect}" : result.inspect
        rescue APIClient::LuaError => e
          prefix = multi ? "[#{name.ljust(max_len)}] " : ""
          puts "#{prefix}Error: #{e.error_message}"
          puts "#{prefix}  File: #{e.file}:#{e.line}" if e.file
          exit 1 if exit_on_error
        rescue StandardError => e
          puts (multi ? "[#{name.ljust(max_len)}] " : "") + "Error: #{e.class}: #{e.message}"
          exit 1 if exit_on_error
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

      def connect_port_client(opts)
        port = opts[:port].to_i
        abort "❌ Invalid port: #{opts[:port]}" if port <= 0 || port > 65_535
        sandbox = opts[:interactive] ? opts[:sandbox] : true
        client = APIClient.new(port: port, verbosity: opts[:verbosity], sandbox: sandbox)
        unless client.ready?
          abort "❌ Cannot connect to port #{port}. Is the game running with ZombieBuddy?"
        end
        [port, client]
      end

      def one_client_hash(port, client)
        { ":#{port}" => client }
      end

      def run_session(clients, opts, intro_text)
        puts intro_text
        require 'readline'
        setup_readline_history
        trap('INT') { puts "\nBye!"; exit 0 }
        repl_loop(clients, opts)
        puts "Bye!"
      end

      def setup_readline_history
        history_file = File.expand_path('~/.zbspec_history')
        File.readlines(history_file).each { |l| Readline::HISTORY.push(l.chomp) } if File.exist?(history_file)
        at_exit do
          File.open(history_file, 'w') { |f| Readline::HISTORY.to_a.last(1000).each { |l| f.puts(l) } }
        end
      end

      def repl_loop(clients, opts)
        max_len = clients.keys.map(&:length).max || 0
        while (line = Readline.readline('lua> ', true))
          line = line.strip
          break if %w[exit quit].include?(line)
          next if line.empty?
          Readline::HISTORY.pop if Readline::HISTORY.size > 1 && Readline::HISTORY[-2] == line
          lua = line.match?(/\breturn\b|;|=/) ? line : "return #{line}" # XXX implicit return
          clients.each { |name, client| run_lua_line(client, lua, name, max_len, clients.size > 1, opts) }
        end
      end

      def run_lua_line(client, lua, name, max_len, multi, opts)
        result = client.execute(lua)
        ires = result.ai(max_depth: 2) # amazing_print
        if multi
          puts ires.gsub(/^/, "[#{name.ljust(max_len)}] ")
        else
          puts ires
        end
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
    end
  end
end
