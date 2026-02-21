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
      
      # Load spec_helper.lua once if it exists
      spec_helper_code = load_spec_helper
      
      @spec_files.each do |spec_file|
        unless File.exist?(spec_file)
          tests << test("#{spec_file}", false, error: "File not found")
          next
        end
        
        # Remember log position before test
        log_pos_before = log_file_size
        
        # Use multipart format: zbspec.lua first, then optional log_events/log_packets, then spec_helper, then spec file (each with its own chunkname)
        # Format: ---FILE:filename---\ncontent\n---FILE:filename2---\ncontent2...
        zbspec_code = load_zbspec_lua
        log_events_code = load_log_events
        log_packets_code = load_log_packets
        lua_code = ''
        lua_code += "---FILE:zbspec.lua---\n#{zbspec_code}" unless zbspec_code.empty?
        lua_code += "---FILE:lua/log_events.lua---\n#{log_events_code}" unless log_events_code.empty?
        lua_code += "---FILE:lua/log_packets.lua---\n#{log_packets_code}" unless log_packets_code.empty?
        lua_code += "---FILE:spec/spec_helper.lua---\n#{spec_helper_code}" unless spec_helper_code.empty?
        spec_content = File.read(spec_file)
        warn_missing_run(spec_file) unless has_run_call?(spec_content)

        lua_code += "---FILE:#{spec_file}---\n#{spec_content}"
        
        begin
          # Execute the spec file in the game with async support
          # This handles spec files that use ZBSpec.runAsync() with wait_until/sleep
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
          # test_name comes from X-ZombieBuddy-Error-Global (errorGlobal in 500 response) when supported
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
          result['errors'].each do |err|
            name = err['name'] || spec_file
            error_msg = err['error'] || 'Unknown error'
            tests << test(name, false, error: error_msg)
          end
        end

        # Individual passed test names (so reporter can show each "it ..." with checkmark)
        if result['passed_tests'].is_a?(Array) && result['passed_tests'].any?
          result['passed_tests'].each { |name| tests << test(name, true) }
        elsif result['passed'].to_i > 0 && tests.empty?
          tests << test(spec_file, true)
        elsif tests.empty? && result['failed'].to_i == 0
          tests << test(spec_file, true)
        end
      when true, 'true'
        tests << test(spec_file, true)
      when nil
        # Empty or fully commented spec file: chunk returns nil → treat as 0 tests, pass
        tests << test(spec_file, true)
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

    # Load zbspec.lua framework (sent via multipart before spec_helper and spec file)
    def load_zbspec_lua
      path = File.join(ZBSpec.root, 'lua', 'zbspec.lua')
      return '' unless File.file?(path)
      File.read(path) + "\n"
    end

    # Check if spec file contains ZBSpec.run or ZBSpec.runAsync
    def has_run_call?(content)
      content =~ /^\s*return ZBSpec\.run(Async)?\(/
    end

    def warn_missing_run(spec_file)
      puts "#{RED}⚠️  #{spec_file}: spec file should end with 'return ZBSpec.runAsync()' or 'return ZBSpec.run()'#{RESET}"
    end

    # Load spec_helper.lua if it exists
    def load_spec_helper
      helper_path = 'spec/spec_helper.lua'
      if File.exist?(helper_path)
        puts "📦 Loading spec_helper.lua" if verbosity >= 1
        File.read(helper_path) + "\n"
      else
        ''
      end
    end

    # Load lua/log_events.lua when config log_events is true (preload before specs)
    def load_log_events
      return '' unless config['log_events']
      path = File.join(ZBSpec.root, 'lua', 'log_events.lua')
      return '' unless File.file?(path)
      puts "📦 Preloading lua/log_events.lua" if verbosity >= 1
      File.read(path) + "\n"
    end

    # Load lua/log_packets.lua when config log_packets is true (preload before specs)
    def load_log_packets
      return '' unless config['log_packets']
      path = File.join(ZBSpec.root, 'lua', 'log_packets.lua')
      return '' unless File.file?(path)
      puts "📦 Preloading lua/log_packets.lua" if verbosity >= 1
      File.read(path) + "\n"
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
