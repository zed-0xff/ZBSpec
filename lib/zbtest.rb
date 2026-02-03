# frozen_string_literal: true

require 'json'
require 'yaml'
require 'net/http'
require 'uri'
require 'timeout'
require 'fileutils'

# Main ZBTest module
module ZBTest
  VERSION = '1.0.0'

  class Error < StandardError; end
  class ConfigError < Error; end
  class APIError < Error; end
  class GameLaunchError < Error; end
end

# Load all components
require_relative 'zbtest/config'
require_relative 'zbtest/api_client'
require_relative 'zbtest/game_launcher'
require_relative 'zbtest/test_case'
require_relative 'zbtest/test_results'
require_relative 'zbtest/test_runner'
require_relative 'zbtest/test_reporter'
require_relative 'zbtest/harness'
