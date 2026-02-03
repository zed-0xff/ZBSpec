# frozen_string_literal: true

module ZBTest
  # Collection of test results organized by section
  class TestResults
    attr_reader :sections

    def initialize
      @sections = {}
    end

    def add_section(name, test_cases)
      @sections[name] = test_cases
    end

    def all_tests
      sections.values.flatten
    end

    def passed_count
      all_tests.count(&:passed?)
    end

    def failed_count
      all_tests.count(&:failed?)
    end

    def total_count
      all_tests.count
    end

    def passed?
      failed_count.zero?
    end

    def failed?
      !passed?
    end

    def to_h
      {
        total: total_count,
        passed: passed_count,
        failed: failed_count,
        sections: sections.transform_values { |tests| tests.map(&:to_h) }
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end
  end
end
