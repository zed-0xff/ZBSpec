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
          run_mp_versions(discovery, spec_files, config_overrides, opts)
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
        versions = versions.first(1) if opts[:first_version_only]
        versions.map(&:to_s).uniq
      end

      # Yields (version, overrides, run_verbosity) and expects a harness.
      # section_prefix: string "SP "/"MP " or proc(version) -> string for section name prefix.
      def run_with_versions(versions, base_overrides, opts, parallel_label:, section_prefix: nil, &block)
        if versions.size <= 1
          overrides = base_overrides.merge('game_version' => versions.first)
          run_verbosity = opts[:verbosity]
          harness = yield(versions.first, overrides, run_verbosity)
          harness.run
          return
        end

        puts "📦 Running #{parallel_label} on #{versions.size} versions in parallel: #{versions.join(', ')}"
        run_verbosity = -1  # only show merged compact view
        threads = versions.map do |version|
          Thread.new do
            overrides = base_overrides.merge('game_version' => version)
            harness = yield(version, overrides, run_verbosity)
            [version, harness.run_without_exit]
          end
        end
        version_results = threads.map(&:value)
        combined = merge_results(version_results, section_prefix: section_prefix)
        TestReporter.new(combined, verbosity: 0).display  # compact only
        exit(combined.failed? ? 1 : 0)
      end

      def run_sp(opts, discovery, spec_files, base, config_overrides)
        puts "\n🎮 Singleplayer mode"
        versions = resolve_versions(opts, config_overrides)
        sp_specs = spec_files || discovery.specs_for(:sp)
        run_with_versions(versions, config_overrides, opts, parallel_label: 'specs', section_prefix: 'SP ') do |_version, overrides, run_verbosity|
          Harness.new(**base.merge(spec_files: sp_specs, config_overrides: overrides, verbosity: run_verbosity))
        end
      end

      def versions_for_mp(versions)
        versions.reject { |v| SP_ONLY_VERSIONS.include?(v.to_s) }
      end

      def run_server_versions(discovery, spec_files, base, config_overrides, opts)
        versions = versions_for_mp(resolve_versions(opts, config_overrides))
        if versions.empty?
          puts "No server versions to run (game_versions are SP-only: #{SP_ONLY_VERSIONS.join(', ')})"
          return
        end
        server_overrides = config_overrides.merge('server_mode' => true)
        server_specs = spec_files || discovery.specs_for(:server)
        run_with_versions(versions, server_overrides, opts, parallel_label: 'server specs', section_prefix: 'MP ') do |_version, overrides, run_verbosity|
          Harness.new(**base.merge(spec_files: server_specs, config_overrides: overrides, verbosity: run_verbosity))
        end
      end

      def run_client_versions(discovery, spec_files, base, config_overrides, opts)
        versions = versions_for_mp(resolve_versions(opts, config_overrides))
        if versions.empty?
          puts "No client versions to run (game_versions are SP-only: #{SP_ONLY_VERSIONS.join(', ')})"
          return
        end
        client_specs = spec_files || discovery.specs_for(:client)
        run_with_versions(versions, config_overrides, opts, parallel_label: 'client specs', section_prefix: 'MP ') do |_version, overrides, run_verbosity|
          MPHarness.new(config_path: opts[:config], spec_files: client_specs, verbosity: run_verbosity, client_only: true, config_overrides: overrides)
        end
      end

      def run_mp_versions(discovery, spec_files, config_overrides, opts)
        versions = versions_for_mp(resolve_versions(opts, config_overrides))
        if versions.empty?
          puts "No MP versions to run (game_versions in config are SP-only: #{SP_ONLY_VERSIONS.join(', ')})"
          return
        end
        run_with_versions(versions, config_overrides, opts, parallel_label: 'MP specs', section_prefix: 'MP ') do |_version, overrides, run_verbosity|
          MPHarness.new(config_path: opts[:config], spec_files: spec_files, verbosity: run_verbosity, config_overrides: overrides)
        end
      end

      def merge_results(version_results, section_prefix: nil)
        combined = TestResults.new
        version_results.each do |version, results|
          name = if section_prefix.nil?
            "game_version #{version}"
          elsif section_prefix.respond_to?(:call)
            "#{section_prefix.call(version)}#{version}"
          else
            "#{section_prefix}#{version}"
          end
          combined.add_section(name, results.all_tests)
        end
        combined
      end

      SP_ONLY_VERSIONS = ['42.12'].freeze

      def run_both_phases(discovery, spec_files, base, opts)
        versions = resolve_versions(opts, base[:config_overrides])
        sp_files = spec_files || discovery.specs_for(:sp)
        sp_files = sp_files.empty? ? nil : sp_files

        if versions.size <= 1
          version = versions.first
          overrides = base[:config_overrides].merge('game_version' => version)
          puts "\n" + "=" * 50 + "\n🎮 Phase 1: Singleplayer mode\n" + "=" * 50
          Harness.new(**base.merge(spec_files: sp_files, config_overrides: overrides)).run_without_exit
          unless SP_ONLY_VERSIONS.include?(version.to_s)
            puts "\n" + "=" * 50 + "\n🎮 Phase 2: Multiplayer mode\n" + "=" * 50
            MPHarness.new(config_path: opts[:config], spec_files: spec_files, verbosity: opts[:verbosity], config_overrides: overrides).run
          end
          return
        end

        puts "📦 Running SP + MP on #{versions.size} versions in parallel: #{versions.join(', ')}"
        run_verbosity = -1  # only show merged compact view
        version_results = versions.map do |version|
          overrides = base[:config_overrides].merge('game_version' => version)
          sp_harness = Harness.new(**base.merge(spec_files: sp_files, config_overrides: overrides, verbosity: run_verbosity))
          sp_results = sp_harness.run_without_exit
          mp_results = unless SP_ONLY_VERSIONS.include?(version.to_s)
            mp_harness = MPHarness.new(config_path: opts[:config], spec_files: spec_files, verbosity: run_verbosity, config_overrides: overrides)
            mp_harness.run_without_exit
          end
          [version, sp_results, mp_results]
        end
        combined = TestResults.new
        version_results.each do |version, sp_res, mp_res|
          combined.add_section("SP #{version}", sp_res.all_tests)
          combined.add_section("MP #{version}", mp_res.all_tests) if mp_res
        end
        TestReporter.new(combined, verbosity: 0).display  # compact only
        exit(combined.failed? ? 1 : 0)
      end
    end
  end
end
