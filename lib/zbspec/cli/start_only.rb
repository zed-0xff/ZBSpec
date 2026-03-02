# frozen_string_literal: true

module ZBSpec
  module CLI
    module StartOnly
      module_function

      def run(opts, config_overrides)
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
        mp = launch_mp_harness(opts, config_overrides, client_only: false)
        wait_mp_apis(mp)
      end

      def start_server_and_wait(opts, config_overrides)
        config = server_config(opts[:config], config_overrides)
        launcher = GameLauncher.new(config, label: 'server', verbosity: opts[:verbosity])
        launcher.start
        api = APIClient.new(port_file: File.join(config['cache_dir'], 'zbLuaAPI.txt'), label: 'server', verbosity: opts[:verbosity])
        wait_apis("Server", api, config['server_startup_timeout'] || 60, launcher.pid)
      end

      def start_client_and_wait(opts, config_overrides)
        mp = launch_mp_harness(opts, config_overrides, client_only: true)
        wait_mp_apis(mp)
      end

      def start_sp_and_wait(opts, config_overrides)
        versions = HarnessDispatch.resolve_versions(opts, config_overrides)
        if versions.size <= 1
          config = sp_config(opts[:config], config_overrides.merge('game_version' => versions.first))
          launcher = GameLauncher.new(config, label: 'sp', verbosity: opts[:verbosity])
          launcher.start
          api = APIClient.new(port_file: File.join(config['cache_dir'], 'zbLuaAPI.txt'), label: 'sp', verbosity: opts[:verbosity])
          wait_apis("SP", api, config['startup_timeout'] || 120, launcher.pid)
          return
        end
        puts "📦 Starting #{versions.size} SP instances: #{versions.join(', ')}"
        version_results = versions.map do |version|
          Thread.new do
            overrides = config_overrides.merge('game_version' => version)
            config = sp_config(opts[:config], overrides)
            launch_one_sp(config, opts.merge(verbosity: -1))
            [version, true]
          rescue StandardError => e
            [version, e]
          end
        end
        version_results.each do |th|
          version, result = th.value
          if result.is_a?(StandardError)
            puts "  ✗ SP #{version}: #{result.message}"
            raise result
          end
          puts "  ✓ SP #{version} API ready"
        end
      end

      def launch_one_sp(config, opts)
        launcher = GameLauncher.new(config, label: 'sp', verbosity: opts[:verbosity])
        launcher.start
        api = APIClient.new(port_file: File.join(config['cache_dir'], 'zbLuaAPI.txt'), label: 'sp', verbosity: opts[:verbosity])
        api.discover_port(timeout: config['startup_timeout'] || 120, process_pid: launcher.pid)
        api.wait_for_ready(timeout: config['startup_timeout'] || 120, process_pid: launcher.pid)
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

      def launch_mp_harness(opts, config_overrides, client_only:)
        mp = MPHarness.new(
          config_path: opts[:config],
          verbosity: opts[:verbosity],
          client_only: client_only,
          config_overrides: config_overrides
        )
        mp.send(:launch_instances_parallel)
        mp
      end

      def wait_mp_apis(mp)
        wait_apis("Server", mp.server_api, mp.config['server_startup_timeout'] || 60, mp.server_launcher.pid)
        wait_apis("Client", mp.client_api, mp.config['startup_timeout'] || 120, mp.client_launcher.pid, print_wait: false)
      end
    end
  end
end
