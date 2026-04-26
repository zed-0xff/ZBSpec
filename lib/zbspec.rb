# frozen_string_literal: true

require 'json'
require 'yaml'
require 'net/http'
require 'uri'
require 'timeout'
require 'fileutils'

require_relative 'zbspec/version'

# Main ZBSpec module
module ZBSpec
  class Error < StandardError; end
  class ConfigError < Error; end
  class APIError < Error; end
  class GameLaunchError < Error; end

  def self.root
    File.expand_path('..', __dir__)
  end

  RESET = "\e[0m"
  GREEN = "\e[32m"
  RED = "\e[31m"
  YELLOW = "\e[33m"
  CYAN = "\e[36m"
  BOLD = "\e[1m"
end

# Load all components
require_relative 'zbspec/config'
require_relative 'zbspec/api_client'
require_relative 'zbspec/app_factory'
require_relative 'zbspec/game_launcher'
require_relative 'zbspec/test_case'
require_relative 'zbspec/test_results'
require_relative 'zbspec/test_runner'
require_relative 'zbspec/test_reporter'
require_relative 'zbspec/spec_discovery'
require_relative 'zbspec/harness'
require_relative 'zbspec/mp_harness'
require_relative 'zbspec/cli'