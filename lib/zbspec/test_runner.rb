# frozen_string_literal: true

module ZBSpec
  # Base test runner - extend this for mod-specific tests
  class TestRunner
    attr_reader :api_client, :config, :mod_namespace, :spec_files

    def initialize(api_client, config, mod_namespace: nil, spec_files: nil)
      @api_client = api_client
      @config = config
      @mod_namespace = mod_namespace
      @spec_files = spec_files || discover_spec_files
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

      # Run Lua spec files
      if @spec_files.any?
        results.add_section('Lua Specs', run_lua_specs)
      end

      results
    end

    protected

    # Discover spec files using glob pattern
    def discover_spec_files
      glob_pattern = config['spec_glob'] || 'spec/**/*_spec.lua'
      files = Dir.glob(glob_pattern).sort
      
      if files.empty?
        puts "⚠️  No spec files found matching: #{glob_pattern}"
      else
        puts "📋 Found #{files.length} spec file(s):"
        files.each { |f| puts "   - #{f}" }
      end
      
      files
    end

    # Run Lua spec files
    def run_lua_specs
      tests = []
      
      @spec_files.each do |spec_file|
        unless File.exist?(spec_file)
          tests << test("#{spec_file}", false, error: "File not found")
          next
        end
        
        # Read and execute the spec file
        lua_code = File.read(spec_file)
        
        begin
          # Execute the spec file in the game
          result = api_client.execute(lua_code)
          
          # Spec files should return true on success, false or error on failure
          passed = result == true || result == 'true'
          tests << test(spec_file, passed, error: passed ? nil : "Spec returned: #{result.inspect}")
        rescue StandardError => e
          tests << test(spec_file, false, error: e.message)
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
