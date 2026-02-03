# frozen_string_literal: true

module ZBTest
  # Formats and displays test results
  class TestReporter
    RESET = "\e[0m"
    GREEN = "\e[32m"
    RED = "\e[31m"
    YELLOW = "\e[33m"
    CYAN = "\e[36m"
    BOLD = "\e[1m"

    attr_reader :results

    def initialize(results)
      @results = results
    end

    def display
      puts "\n#{BOLD}#{CYAN}Test Results#{RESET}"
      puts '=' * 50

      results.sections.each do |section_name, test_cases|
        display_section(section_name, test_cases)
      end

      display_summary
    end

    def display_json
      puts results.to_json
    end

    private

    def display_section(name, test_cases)
      puts "\n#{BOLD}#{name}:#{RESET}"

      test_cases.each do |test|
        puts "  #{test.status_color}#{test.status_icon}#{RESET} #{test.name}"
        puts "    #{YELLOW}Error: #{test.error}#{RESET}" if test.error
      end
    end

    def display_summary
      puts "\n#{'=' * 50}"
      puts "#{BOLD}Summary:#{RESET}"
      puts "  Total:  #{results.total_count}"
      puts "  #{GREEN}Passed: #{results.passed_count}#{RESET}"
      puts "  #{RED}Failed: #{results.failed_count}#{RESET}"

      if results.passed?
        puts "\n#{GREEN}#{BOLD}✓ All tests passed!#{RESET}"
      else
        puts "\n#{RED}#{BOLD}✗ Some tests failed#{RESET}"
      end
    end
  end
end
