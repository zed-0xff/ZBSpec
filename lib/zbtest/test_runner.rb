# frozen_string_literal: true

module ZBTest
  # Base test runner - extend this for mod-specific tests
  class TestRunner
    attr_reader :api_client, :config, :mod_namespace, :test_files

    def initialize(api_client, config, mod_namespace: nil, test_files: nil)
      @api_client = api_client
      @config = config
      @mod_namespace = mod_namespace
      @test_files = test_files || discover_test_files
    end

    # Override this in subclass to define mod-specific tests
    def run_all
      results = TestResults.new

      # Health check (always run)
      health = api_client.health_check
      results.add_section('Health Check', run_health_check(health))

      # Only continue if mod loaded
      if mod_namespace && !mod_loaded?
        return results
      end

      # Run Lua test files
      if @test_files.any?
        results.add_section('Lua Tests', run_lua_tests)
      end

      results
    end

    protected

    # Discover test files using glob pattern
    def discover_test_files
      glob_pattern = config['test_glob'] || 'test/**/*_test.lua'
      files = Dir.glob(glob_pattern).sort
      
      if files.empty?
        puts "⚠️  No test files found matching: #{glob_pattern}"
      else
        puts "📋 Found #{files.length} test file(s):"
        files.each { |f| puts "   - #{f}" }
      end
      
      files
    end

    # Run Lua test files
    def run_lua_tests
      tests = []
      
      @test_files.each do |test_file|
        unless File.exist?(test_file)
          tests << test("#{test_file}", false, error: "File not found")
          next
        end
        
        # Read and execute the test file
        lua_code = File.read(test_file)
        
        begin
          # Execute the test file in the game
          result = api_client.execute(lua_code)
          
          # Test files should return true on success, false or error on failure
          passed = result == true || result == 'true'
          tests << test(test_file, passed, error: passed ? nil : "Test returned: #{result.inspect}")
        rescue StandardError => e
          tests << test(test_file, false, error: e.message)
        end
      end
      
      tests
    end

    # Helper to create a test case
    def test(name, passed, error: nil)
      TestCase.new(name, passed, error: error)
    end

    # Check if mod is loaded
    def mod_loaded?
      return true unless mod_namespace

      api_client.execute("return #{mod_namespace} ~= nil")
    end

    # Run health check tests
    def run_health_check(health)
      tests = [
        test('API responding', health[:api_responding]),
        test('Events API available', health[:events_available]),
        test('Perks API available', health[:perks_available])
      ]

      if mod_namespace
        mod_check = api_client.execute("return #{mod_namespace} ~= nil")
        tests << test("#{mod_namespace} mod loaded", mod_check)
      end

      tests
    end
  end
end
