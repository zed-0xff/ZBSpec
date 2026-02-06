# frozen_string_literal: true

require 'rake'
require 'rake/tasklib'

module ZBSpec
  # Rake tasks for running ZBSpec tests
  #
  # Example usage in Rakefile:
  #   require 'zbspec/rake_task'
  #   ZBSpec::RakeTask.new
  #
  # Or with custom options:
  #   ZBSpec::RakeTask.new(:spec) do |t|
  #     t.pattern = 'spec/**/*_spec.lua'
  #     t.verbose = true
  #   end
  #
  class RakeTask < ::Rake::TaskLib
    # Name of the task (default: :spec)
    attr_accessor :name

    # Glob pattern for spec files (default: 'spec/**/*_spec.lua')
    attr_accessor :pattern

    # Additional arguments to pass to zbspec
    attr_accessor :zbspec_args

    # Whether to show verbose output
    attr_accessor :verbose

    def initialize(name = :spec)
      @name = name
      @pattern = 'spec/**/*_spec.lua'
      @zbspec_args = []
      @verbose = false

      yield self if block_given?

      define
    end

    private

    def define
      desc 'Run ZBSpec tests'
      task name do
        args = ['zbspec']
        args << '-v' if verbose
        args.concat(zbspec_args) if zbspec_args.any?

        sh(*args)
      end
    end
  end
end
