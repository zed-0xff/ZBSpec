# frozen_string_literal: true

module ZBSpec
  module CLI
    module_function

    def run(config:, verbosity: 0, mode: :auto, spec_files: nil)
      abort "❌ Config file not found: #{config}" unless File.exist?(config)

      discovery = SpecDiscovery.new
      actual_mode = mode == :auto ? discovery.recommended_mode : mode

      puts "📋 Discovered specs: #{discovery.summary}"
      FileUtils.mkdir_p('tmp/logs')

      case actual_mode
      when :both
        run_sp(config, verbosity, spec_files || discovery.specs_for(:sp), exit_on_finish: false)
        run_mp(config, verbosity, spec_files)
      when :mp
        run_mp(config, verbosity, spec_files)
      when :server
        run_harness(config, verbosity, spec_files || discovery.specs_for(:server), server_mode: true)
      else
        run_sp(config, verbosity, spec_files || discovery.specs_for(:sp))
      end
    end

    def run_sp(config, verbosity, files, exit_on_finish: true)
      puts "\n🎮 Singleplayer mode"
      harness = Harness.new(
        config_path: config,
        spec_files: files.empty? ? nil : files,
        verbosity: verbosity
      )
      exit_on_finish ? harness.run : harness.run_without_exit
    end

    def run_mp(config, verbosity, files)
      puts "\n🎮 Multiplayer mode"
      MPHarness.new(
        config_path: config,
        spec_files: files,
        verbosity: verbosity
      ).run
    end

    def run_harness(config, verbosity, files, server_mode: false)
      Harness.new(
        config_path: config,
        spec_files: files.empty? ? nil : files,
        verbosity: verbosity,
        config_overrides: server_mode ? { 'server_mode' => true } : {}
      ).run
    end
  end
end
