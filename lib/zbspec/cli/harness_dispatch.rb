# frozen_string_literal: true

module ZBSpec
  module CLI
    module HarnessDispatch
      module_function

      def run(opts, discovery, test_runner, config_overrides)
        spec_files = opts[:spec_files].empty? ? nil : opts[:spec_files]
        base = {
          config_path: opts[:config],
          test_runner_class: test_runner,
          verbosity: opts[:verbosity],
          config_overrides: config_overrides
        }

        case opts[:mode]
        when :both
          run_both_phases(discovery, spec_files, base, opts)
        when :mp
          puts "\n🎮 Multiplayer mode: running specs on server and client"
          MPHarness.new(config_path: opts[:config], spec_files: spec_files, verbosity: opts[:verbosity], config_overrides: config_overrides).run
        when :server
          puts "\n🖥️  Server mode: running specs on dedicated server"
          run_server_versions(discovery, spec_files, base, config_overrides, opts)
        when :client
          puts "\n💻 Client mode: running specs on MP client (auto-starting server)"
          run_client_versions(discovery, spec_files, base, config_overrides, opts)
        else
          run_sp(opts, discovery, spec_files, base, config_overrides)
        end
      end

      def resolve_versions(opts, config_overrides)
        config = Config.new(opts[:config])
        config_overrides.each { |k, v| config[k] = v }
        versions = config_overrides['game_version'] ? [config_overrides['game_version']] : Array(config['game_versions'])
        versions.map(&:to_s).uniq
      end

      # Yields (version, overrides) and expects a harness. Single version: calls harness.run (exits).
      # Multiple versions: runs harness.run_without_exit per version in parallel, merges and displays.
      def run_with_versions(versions, base_overrides, opts, parallel_label:, &block)
        if versions.size <= 1
          overrides = base_overrides.merge('game_version' => versions.first)
          harness = yield(versions.first, overrides)
          harness.run
          return
        end

        puts "📦 Running #{parallel_label} on #{versions.size} versions in parallel: #{versions.join(', ')}"
        threads = versions.map do |version|
          Thread.new do
            overrides = base_overrides.merge('game_version' => version)
            harness = yield(version, overrides)
            [version, harness.run_without_exit]
          end
        end
        version_results = threads.map(&:value)
        combined = merge_results(version_results)
        TestReporter.new(combined, verbosity: opts[:verbosity]).display
        exit(combined.failed? ? 1 : 0)
      end

      def run_sp(opts, discovery, spec_files, base, config_overrides)
        puts "\n🎮 Singleplayer mode"
        versions = resolve_versions(opts, config_overrides)
        sp_specs = spec_files || discovery.specs_for(:sp)
        run_with_versions(versions, config_overrides, opts, parallel_label: 'specs') do |_version, overrides|
          Harness.new(**base.merge(spec_files: sp_specs, config_overrides: overrides))
        end
      end

      def run_server_versions(discovery, spec_files, base, config_overrides, opts)
        versions = resolve_versions(opts, config_overrides)
        server_overrides = config_overrides.merge('server_mode' => true)
        server_specs = spec_files || discovery.specs_for(:server)
        run_with_versions(versions, server_overrides, opts, parallel_label: 'server specs') do |_version, overrides|
          Harness.new(**base.merge(spec_files: server_specs, config_overrides: overrides))
        end
      end

      def run_client_versions(discovery, spec_files, base, config_overrides, opts)
        versions = resolve_versions(opts, config_overrides)
        client_specs = spec_files || discovery.specs_for(:client)
        run_with_versions(versions, config_overrides, opts, parallel_label: 'client specs') do |_version, overrides|
          MPHarness.new(config_path: opts[:config], spec_files: client_specs, verbosity: opts[:verbosity], client_only: true, config_overrides: overrides)
        end
      end

      def merge_results(version_results)
        combined = TestResults.new
        version_results.each do |version, results|
          combined.add_section("game_version #{version}", results.all_tests)
        end
        combined
      end

      def run_both_phases(discovery, spec_files, base, opts)
        puts "\n" + "=" * 50 + "\n🎮 Phase 1: Singleplayer mode\n" + "=" * 50
        sp_files = spec_files || discovery.specs_for(:sp)
        Harness.new(**base.merge(spec_files: sp_files.empty? ? nil : sp_files)).run_without_exit
        puts "\n" + "=" * 50 + "\n🎮 Phase 2: Multiplayer mode\n" + "=" * 50
        MPHarness.new(config_path: opts[:config], spec_files: spec_files, verbosity: opts[:verbosity], config_overrides: base[:config_overrides]).run
      end
    end
  end
end
