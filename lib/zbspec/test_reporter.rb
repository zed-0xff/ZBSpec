# frozen_string_literal: true

module ZBSpec
  # Formats and displays test results
  class TestReporter
    RESET = "\e[0m"
    GREEN = "\e[32m"
    RED = "\e[31m"
    YELLOW = "\e[33m"
    CYAN = "\e[36m"
    BOLD = "\e[1m"
    COMPACT_NAME_WIDTH = 12  # "SP "/"MP " + version name

    attr_reader :results, :verbosity

    def initialize(results, verbosity: 0)
      @results = results
      @verbosity = verbosity
    end

    def display
      return if verbosity < 0  # multi-version: only merged compact view is shown

      puts "\n#{BOLD}#{CYAN}Spec Results#{RESET}"
      puts '=' * 50

      multiple_instances = results.sections.size > 1
      max_name_width = multiple_instances ? COMPACT_NAME_WIDTH : 0

      results.sections.each do |section_name, test_cases|
        display_section(section_name, test_cases, compact: multiple_instances, max_name_width: max_name_width)
      end

      display_summary(multiple_instances: multiple_instances)
    end

    def display_json
      puts results.to_json
    end

    private

    def section_display_name(name)
      # Strip legacy "game_version " prefix; section names may be "SP 41", "MP 41"
      name.to_s.sub(/\Agame_version\s+/i, '')
    end

    def display_section(name, test_cases, compact: false, max_name_width: 0)
      passed_count = test_cases.count(&:passed?)
      total_count = test_cases.size
      all_passed = passed_count == total_count
      display_name = section_display_name(name)

      # verbosity <= 0: one line per section; when failures, list failed specs below
      if verbosity <= 0
        padded = display_name.ljust(max_name_width)
        if all_passed
          puts "#{BOLD}#{padded}#{RESET} #{GREEN}#{passed_count}/#{total_count} passed#{RESET}"
        else
          failed_count = total_count - passed_count
          puts "#{BOLD}#{padded}#{RESET} #{passed_count}/#{total_count} passed#{RED} (#{failed_count} failed)#{RESET}"
          test_cases.each do |t|
            next if t.passed?
            puts "  #{RED}✗#{RESET} #{t.name}"
            display_error_details(t)
          end
        end
        return
      end

      puts "\n#{BOLD}#{display_name}:#{RESET}"

      test_cases.each do |test|
        puts "  #{test.status_color}#{test.status_icon}#{RESET} #{test.name}"
        display_error_details(test) if test.error
      end
    end

    def display_error_details(test)
      if test.test_name || test.assertion_name || test.assertion_source
        # Structured error display
        puts "      #{test.test_name}" if test.test_name
        if test.assertion_source
          puts "          #{YELLOW}#{test.assertion_source}#{RESET}"
        elsif test.assertion_name
          puts "          assert.#{test.assertion_name}"
        end
        puts "              #{RED}#{test.error}#{RESET}"
      else
        # Simple error display
        puts "    #{YELLOW}Error: #{test.error}#{RESET}"
      end
    end

    def display_summary(multiple_instances: false)
      puts '' if multiple_instances
      total = results.total_count
      passed = results.passed_count
      total_label = multiple_instances ? "TOTAL".ljust(COMPACT_NAME_WIDTH) : "TOTAL"
      if results.passed?
        puts "#{BOLD}#{total_label}#{RESET} #{GREEN}#{passed}/#{total} passed#{RESET}"
      else
        puts "#{BOLD}#{total_label}#{RESET} #{passed}/#{total} passed#{RED} (#{results.failed_count} failed)#{RESET}"
        puts "#{RED}#{BOLD}✗ Some tests failed#{RESET}"
      end
    end
  end
end
