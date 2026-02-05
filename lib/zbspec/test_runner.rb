# frozen_string_literal: true

module ZBSpec
  # Base test runner - extend this for mod-specific tests
  class TestRunner
    attr_reader :api_client, :config, :mod_namespace, :spec_files, :verbosity

    def initialize(api_client, config, mod_namespace: nil, spec_files: nil, verbosity: 0)
      @api_client = api_client
      @config = config
      @mod_namespace = mod_namespace
      @spec_files = spec_files || discover_spec_files
      @verbosity = verbosity
    end

    # Override this in subclass to define mod-specific tests
    def run_all
      results = TestResults.new

      # Health check (run silently, fail fast if not ready)
      health = api_client.health_check
      unless health[:api_responding]
        results.add_section('Specs', [test('API not responding', false, error: 'Game API not available')])
        return results
      end

      # Only continue if mod loaded
      if mod_namespace && !mod_loaded?
        return results
      end

      # Run Lua spec files
      if @spec_files.any?
        results.add_section('Specs', run_lua_specs)
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
        
        # Remember log position before test
        log_pos_before = log_file_size
        
        # Read and execute the spec file
        lua_code = File.read(spec_file)
        
        begin
          # Execute the spec file in the game with async support
          # This handles spec files that use ZBSpec.runAsync() with wait_for/sleep
          result = api_client.execute_async(lua_code, chunkname: spec_file)
          
          # Log raw response if verbosity >= 2
          if verbosity >= 2
            puts "    [raw] #{spec_file}:\n#{result.inspect}"
          end
          
          # Handle structured results from ZBSpec.runAsync()
          tests.concat(process_spec_result(spec_file, result))
        rescue ZBSpec::APIClient::LuaError => e
          # Log raw error if verbosity >= 2
          if verbosity >= 2
            puts "    [raw] #{spec_file} error:"
            if e.raw_error.is_a?(String) && e.raw_error.start_with?('{') && e.raw_error.end_with?('}')
              begin
                pp JSON.parse(e.raw_error)
              rescue JSON::ParserError
                puts e.raw_error
              end
            else
              p e.raw_error
            end
          end
          # Lua execution error - include file:line if available
          location = e.line ? "#{spec_file}:#{e.line}" : spec_file
          tests << test(location, false, 
                        error: e.error_message, 
                        test_name: e.test_name, 
                        assertion_name: e.assertion_name,
                        assertion_source: e.assertion_source)
        rescue StandardError => e
          tests << test(spec_file, false, error: "#{e.class}: #{e.message}")
        end
      end
      
      tests
    end

    # Process result from ZBSpec.runAsync() / ZBSpec.runDetailed()
    def process_spec_result(spec_file, result)
      tests = []
      
      case result
      when Hash
        # Structured result from ZBSpec.runDetailed/runAsync
        if result['errors'] && result['errors'].is_a?(Array)
          # Process errors
          result['errors'].each do |err|
            name = err['name'] || spec_file
            error_msg = err['error'] || 'Unknown error'
            tests << test(name, false, error: error_msg)
          end
        end
        
        # Count passed tests (if we have the count but not individual names)
        passed_count = result['passed'].to_i
        if passed_count > 0 && tests.empty?
          # All tests passed
          tests << test(spec_file, true)
        elsif tests.empty? && result['failed'].to_i == 0
          tests << test(spec_file, true)
        end
      when true, 'true'
        tests << test(spec_file, true)
      when nil
        tests << test(spec_file, false, error: 'No result returned')
      else
        tests << test(spec_file, false, error: result.to_s)
      end
      
      tests
    end

    def log_path
      @log_path ||= File.join(config['tmp_dir'] || 'tmp', 'logs', 'last.log')
    end

    def log_file_size
      return 0 unless File.exist?(log_path)
      File.size(log_path)
    rescue StandardError
      0
    end

    # Read log content added since given position
    def read_log_since(pos)
      return nil unless File.exist?(log_path)
      
      current_size = File.size(log_path)
      return nil if current_size <= pos
      
      File.open(log_path, 'r') do |f|
        f.seek(pos)
        content = f.read
        return nil if content.nil? || content.strip.empty?
        
        lines = content.lines.map { |line| "      #{line.rstrip}" }
        lines.join("\n")
      end
    rescue StandardError
      nil
    end

    # Helper to create a test case
    def test(name, passed, error: nil, test_name: nil, assertion_name: nil, assertion_source: nil)
      TestCase.new(name, passed, error: error, test_name: test_name, assertion_name: assertion_name, assertion_source: assertion_source)
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
