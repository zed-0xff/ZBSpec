# frozen_string_literal: true

require 'rake'
require 'rake/tasklib'
require 'zbspec'

module ZBSpec
  # Rake tasks for running ZBSpec tests
  #
  # Example usage in Rakefile:
  #   require 'zbspec/rake_task'
  #   ZBSpec::RakeTask.new
  #
  class RakeTask < ::Rake::TaskLib
    attr_accessor :name, :config, :verbosity, :mode, :spec_files

    def initialize(name = :zbspec)
      @name = name
      @config = 'spec/zbspec.yml'
      @verbosity = 0
      @mode = :auto
      @spec_files = nil

      yield self if block_given?

      desc 'Run ZBSpec tests'
      task(name) { ZBSpec::CLI.run(config: config, verbosity: verbosity, mode: mode, spec_files: spec_files) }
    end
  end
end
