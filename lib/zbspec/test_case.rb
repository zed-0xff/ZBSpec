# frozen_string_literal: true

module ZBSpec
  # Represents a single test case result
  class TestCase
    attr_reader :name, :passed, :error, :test_name, :assertion_name

    def initialize(name, passed, error: nil, test_name: nil, assertion_name: nil)
      @name = name
      @passed = passed
      @error = error
      @test_name = test_name
      @assertion_name = assertion_name
    end

    def passed?
      @passed == true
    end

    def failed?
      !passed?
    end

    def status_icon
      passed? ? '✓' : '✗'
    end

    def status_color
      passed? ? "\e[32m" : "\e[31m"
    end

    def to_h
      {
        name: name,
        passed: passed?,
        error: error
      }
    end
  end
end
