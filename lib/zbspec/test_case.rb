# frozen_string_literal: true

module ZBSpec
  # Represents a single test case result
  class TestCase
    attr_reader :name, :passed, :error, :test_name, :assertion_name, :assertion_source

    def initialize(name, passed, error: nil, test_name: nil, assertion_name: nil, assertion_source: nil, skipped: false)
      @name = name
      @passed = passed
      @error = error
      @test_name = test_name
      @assertion_name = assertion_name
      @assertion_source = assertion_source
      @skipped = skipped
    end

    def passed?
      @passed == true && !skipped?
    end

    def failed?
      !passed? && !skipped?
    end

    def skipped?
      @skipped == true
    end

    def status_icon
      return '○' if skipped?

      passed? ? '✓' : '✗'
    end

    def status_color
      return "\e[33m" if skipped?

      passed? ? "\e[32m" : "\e[31m"
    end

    def to_h
      {
        name: name,
        passed: passed?,
        skipped: skipped?,
        error: error
      }
    end
  end
end
