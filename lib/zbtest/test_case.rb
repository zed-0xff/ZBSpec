# frozen_string_literal: true

module ZBTest
  # Represents a single test case result
  class TestCase
    attr_reader :name, :passed, :error

    def initialize(name, passed, error: nil)
      @name = name
      @passed = passed
      @error = error
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
