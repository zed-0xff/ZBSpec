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
          Harness.new(**base.merge(spec_files: spec_files || discovery.specs_for(:server), config_overrides: config_overrides.merge('server_mode' => true))).run
        when :client
          puts "\n💻 Client mode: running specs on MP client (auto-starting server)"
          MPHarness.new(config_path: opts[:config], spec_files: spec_files || discovery.specs_for(:client), verbosity: opts[:verbosity], client_only: true, config_overrides: config_overrides).run
        else
          puts "\n🎮 Singleplayer mode"
          Harness.new(**base.merge(spec_files: spec_files || discovery.specs_for(:sp))).run
        end
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
