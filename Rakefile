# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

task :build do
  Dir.chdir("mods/ZBSpec/42/media/java/shared") do
    sh "rake build"
  end
end
