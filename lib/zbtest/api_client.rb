# frozen_string_literal: true

module ZBTest
  # API client for communicating with ZombieBuddy
  class APIClient
    API_TIMEOUT = 5

    attr_reader :port, :base_uri, :host

    def initialize(port: nil, host: '127.0.0.1', port_file: nil)
      @port = port
      @host = host
      @port_file = port_file
      @base_uri = port ? URI("http://#{host}:#{port}/lua") : nil
    end

    # Discover port from file and update base URI
    def discover_port(timeout: 30)
      return if @port && @base_uri # Port already set
      
      puts "🔍 Discovering API port from #{@port_file}..."
      
      Timeout.timeout(timeout) do
        loop do
          if File.exist?(@port_file)
            port_str = File.read(@port_file).strip
            if !port_str.empty? && port_str =~ /^\d+$/
              @port = port_str.to_i
              @base_uri = URI("http://#{@host}:#{@port}/lua")
              puts "✓ Discovered API port: #{@port}"
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
    def wait_for_ready(timeout: 120)
      puts "⏳ Waiting for API on #{host}:#{port}..."

      Timeout.timeout(timeout) do
        loop do
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

    # Execute Lua code in the game
    def execute(lua_code, depth: 5)
      uri = base_uri.dup
      uri.query = "depth=#{depth}"

      response = Net::HTTP.post(uri, lua_code, 'Content-Type' => 'text/plain')

      return nil unless response.is_a?(Net::HTTPSuccess)

      parse_response(response.body)
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      nil
    end

    # Wait for player to be available
    def wait_for_player(timeout: 120)
      puts "⏳ Waiting for player to spawn..."

      Timeout.timeout(timeout) do
        loop do
          player = execute('return getPlayer() ~= nil')
          if player
            puts "\n✓ Player spawned"
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

    def parse_response(body)
      JSON.parse(body)
    rescue JSON::ParserError
      # Simple string response, remove quotes
      body.strip.gsub(/^"|"$/, '')
    end
  end
end
