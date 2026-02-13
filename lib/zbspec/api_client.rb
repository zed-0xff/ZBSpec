# frozen_string_literal: true

module ZBSpec
  # API client for communicating with ZombieBuddy
  class APIClient
    API_TIMEOUT = 5
    LABEL_WIDTH = 8  # "[server] " width

    attr_reader :port, :base_uri, :host, :label
    attr_accessor :verbosity

    def initialize(port: nil, host: '127.0.0.1', port_file: nil, label: nil, verbosity: 0)
      @port = port
      @host = host
      @port_file = port_file
      @label = label
      @verbosity = verbosity
      @base_uri = port ? URI("http://#{host}:#{port}/lua") : nil
    end

    # Discover port from file and update base URI
    # If process_pid is set and that process exits, aborts immediately instead of waiting for timeout.
    def discover_port(timeout: 120, process_pid: nil)
      return if @port && @base_uri # Port already set
      
      log "🔍 Discovering API port..."
      
      Timeout.timeout(timeout) do
        loop do
          if process_pid && !process_alive?(process_pid)
            raise APIError, "Process (PID #{process_pid}) terminated before API port was available"
          end
          if File.exist?(@port_file)
            port_str = File.read(@port_file).strip
            if !port_str.empty? && port_str =~ /^\d+$/
              @port = port_str.to_i
              @base_uri = URI("http://#{@host}:#{@port}/lua")
              log "✓ Discovered API port: #{@port}"
              return @port
            end
          end
          
          print '.'
          sleep 1
        end
      end
    rescue Timeout::Error
      raise APIError, "Could not discover API port after #{timeout}s (file: #{@port_file})"
    end

    # Wait for API to become ready
    # If process_pid is set and that process exits, aborts immediately.
    def wait_for_ready(timeout: 120, process_pid: nil)
      log "⏳ Waiting for API..."

      Timeout.timeout(timeout) do
        loop do
          if process_pid && !process_alive?(process_pid)
            raise APIError, "Process (PID #{process_pid}) terminated before API was ready"
          end
          return true if ready?

          print '.'
          sleep 2
        end
      end
    rescue Timeout::Error
      raise APIError, "API not ready after #{timeout}s timeout"
    end

    # Check if API is responding
    def ready?
      execute('return "ready"') == 'ready'
    rescue StandardError
      false
    end

    # Returns false if process has exited. Works for both child processes (we spawned) and
    # reused PIDs from a previous run (not our child). For children we use wait(WNOHANG);
    # for non-children Process.wait raises ECHILD and we fall back to kill(0, pid).
    def process_alive?(pid)
      return false unless pid && pid > 0
      reaped = Process.wait(pid, Process::WNOHANG)
      return false if reaped == pid  # our child exited
      return true if reaped.nil?     # our child still running
      # Not our child (e.g. reused PID from previous zbspec run)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::ECHILD
      # PID is from a previous run; current process is not the parent
      Process.kill(0, pid)
      true
    rescue Errno::EPERM
      # Process exists but we can't signal it; assume alive
      true
    end

    # Execute Lua code in the game
    def execute(lua_code, depth: 5, chunkname: nil, retries: 3)
      uri = base_uri.dup
      params = ["depth=#{depth}"]
      params << "chunkname=#{URI.encode_www_form_component(chunkname)}" if chunkname
      uri.query = params.join('&')

      attempts = 0
      begin
        attempts += 1
        response = Net::HTTP.post(uri, lua_code, 'Content-Type' => 'text/plain')

        # Handle error responses (500)
        if response.code == '500'
          if @verbosity > 1
            puts "[d] #{response.body}"
          end
          raise LuaError.new(response.body)
        end

        return nil unless response.is_a?(Net::HTTPSuccess)

        parse_response(response.body)
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        nil
      rescue EOFError, Net::ReadTimeout, Errno::ETIMEDOUT
        # Transient errors - retry with backoff
        if attempts < retries
          sleep 0.2 * attempts
          retry
        end
        nil  # Treat as connection failure after retries exhausted
      end
    end

    # Execute Lua code with async support (for tests that yield)
    # Returns the final result after polling is complete
    def execute_async(lua_code, depth: 5, chunkname: nil, timeout: 60, poll_interval: 0.1)
      # Execute the code - Lua manages coroutines internally
      job_id = execute(lua_code, depth: depth, chunkname: chunkname)
      
      # If it's not a job ID, it's a direct result (no async needed)
      return job_id unless job_id.is_a?(String) && job_id.start_with?('job_')

      # Poll until complete
      start_time = Time.now
      loop do
        elapsed = Time.now - start_time
        if elapsed > timeout
          raise APIError, "Async execution timed out after #{timeout}s (job: #{job_id})"
        end

        poll_result = execute("return ZBSpec.poll(\"#{job_id}\")")
        
        case poll_result
        when Hash
          case poll_result['status']
          when 'completed'
            return poll_result['result']
          when 'error'
            raise LuaError.new(poll_result['error'] || 'Unknown async error')
          when 'pending'
            # Still running, continue polling
            sleep poll_interval
          else
            raise APIError, "Unknown poll status: #{poll_result['status']}"
          end
        else
          # Unexpected response
          raise APIError, "Unexpected poll response: #{poll_result.inspect}"
        end
      end
    end

    # Custom error class for Lua execution errors
    class LuaError < StandardError
      attr_reader :raw_error, :error_message, :file, :line, :lua_return
      attr_reader :test_name, :assertion_name, :assertion_source

      def initialize(raw_error)
        @raw_error = raw_error
        parse_error(raw_error)
        super(@error_message)
      end

      private

      def parse_error(raw)
        # Try to parse as JSON first
        begin
          data = JSON.parse(raw)
          @lua_return = data['luaReturn']
          
          if @lua_return
            # Extract best error message from luaReturn fields
            @error_message = extract_message_from_lua_return(@lua_return)
            extract_location_from_lua_return(@lua_return)
          elsif data['kahluaErrors'].is_a?(Array)
            # Java exception response with kahluaErrors attached
            @lua_return = { 'kahluaErrors' => data['kahluaErrors'] }
            @error_message = extract_message_from_lua_return(@lua_return)
            extract_location_from_lua_return(@lua_return)
          elsif data['javaException'].is_a?(Hash) && data['javaException']['message']
            @error_message = data['javaException']['message']
          elsif data['error']
            @error_message = data['error']
          else
            @error_message = raw
          end
          return
        rescue JSON::ParserError
          # Not JSON, parse as plain text
        end
        
        # Plain text error parsing
        @error_message = raw.to_s
      end

      def extract_message_from_lua_return(lr)
        # kahluaErrors is now an array - first element has the exception message
        if lr['kahluaErrors'].is_a?(Array) && !lr['kahluaErrors'].empty?
          msg = lr['kahluaErrors'].first
          # Extract message after "Exception: "
          if msg =~ /Exception:\s*(.+?)(\n|$)/
            return $1.strip
          end
          return msg.split("\n").first
        end
        lr['errorString'] || lr['errorObject'] || 'Unknown Lua error'
      end

      # Parse stack trace like:
      #  "function: greater_than -- file: ZBSpec.lua line # 210 | MOD: ZBSpec\n" +
      #  "function: grants Science XP when reading science book -- file: ./spec/client/book_xp_spec.lua line # 51 | Vanilla\n" +
      #  "function: run -- file: ZBSpec.lua line # 274 | MOD: ZBSpec"
      def extract_location_from_lua_return(lr)
        text = [lr['kahluaErrors']].flatten.compact.join("\n")
        
        # Extract all "function: name -- file: path line # N" entries
        entries = text.scan(/function:\s*(.+?)\s+--\s+file:\s*(\S+)\s+line\s*#\s*(\d+)/)
        spec_entries = []

        entries.each do |name, file, line|
          if file.end_with?('_spec.lua')
            spec_entries << { name: name, file: file, line: line.to_i }
          elsif file.end_with?('ZBSpec.lua') && name != 'run'
            # This is the assertion function (e.g., greater_than, is_equal)
            @assertion_name ||= name
          end
        end

        if spec_entries.any?
          assertion_entry = spec_entries.first
          test_entry = spec_entries.last
          @assertion_file = assertion_entry[:file]
          @assertion_line = assertion_entry[:line]
          @test_name = test_entry[:name]
          @file = test_entry[:file]
          @line = test_entry[:line]
        end

        @assertion_source = extract_assertion_source(@assertion_file, @assertion_line, @assertion_name)
      end

      def extract_assertion_source(file, line, assertion_name)
        return nil unless file && assertion_name

        path = normalize_path(file)
        return nil unless path && File.exist?(path)

        lines = File.readlines(path)
        target = "assert.#{assertion_name}"
        idx = line ? line - 1 : nil

        if idx && idx >= 0 && idx < lines.length && lines[idx].include?(target)
          return lines[idx].strip
        end

        if idx
          start_idx = [idx - 5, 0].max
          end_idx = [idx + 5, lines.length - 1].min
          (start_idx..end_idx).each do |i|
            return lines[i].strip if lines[i].include?(target)
          end
        end

        nil
      end

      def normalize_path(path)
        return nil if path.nil? || path.strip.empty?
        clean = path.sub(%r{\A\./}, '')
        return clean if File.exist?(clean)
        cwd_path = File.join(Dir.pwd, clean)
        return cwd_path if File.exist?(cwd_path)
        clean
      end
    end

    # Wait for player to be available
    # If process_pid is set and that process exits, aborts immediately.
    def wait_for_player(timeout: 120, process_pid: nil)
      log "⏳ Waiting for player to spawn..."

      Timeout.timeout(timeout) do
        loop do
          if process_pid && !process_alive?(process_pid)
            raise APIError, "Process (PID #{process_pid}) terminated before player spawned"
          end
          player = execute('return getPlayer() ~= nil')
          if player
            log "✓ Player spawned"
            return true
          end

          print '.'
          sleep 1
        end
      end
    rescue Timeout::Error
      raise APIError, "Player not spawned after #{timeout}s timeout"
    end

    # Perform health check
    def health_check
      {
        api_responding: ready?,
        events_available: execute('return Events ~= nil'),
        perks_available: execute('return Perks ~= nil')
      }
    end

    private

    def log(msg)
      return unless @verbosity > 0
      prefix = @label ? "[#{@label.ljust(6)}] " : ""
      puts "#{prefix}#{msg}"
    end

    def parse_response(body)
      JSON.parse(body)
    rescue JSON::ParserError
      # Simple string response, remove quotes
      body.strip.gsub(/^"|"$/, '')
    end
  end
end
