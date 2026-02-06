# frozen_string_literal: true

require_relative 'lib/zbspec/version'

Gem::Specification.new do |spec|
  spec.name          = 'zbspec'
  spec.version       = ZBSpec::VERSION
  spec.authors       = ['Andrey "Zed" Zaikin']
  spec.email         = ['zed.0xff@gmail.com']

  spec.summary       = 'Testing framework for Project Zomboid mods'
  spec.description   = 'ZBSpec is a BDD-style testing framework for Project Zomboid Lua mods. ' \
                       'It provides a familiar RSpec-like syntax and supports both singleplayer and multiplayer testing.'
  spec.homepage      = 'https://github.com/zed-0xff/ZBSpec'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 2.7.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?('spec/', 'test/', 'features/', '.git', '.github', 'tmp/')
    end
  end

  spec.bindir        = 'bin'
  spec.executables   = ['zbspec']
  spec.require_paths = ['lib']

  # Runtime dependencies
  # (none - uses only stdlib)

  # Development dependencies
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
end
