# frozen_string_literal: true

module ZBTest
  # API client for communicating with ZombieBuddy
  class APIClient
    API_TIMEOUT = 5

    attr_reader :port, :base_uri, :host

    def initialize(port: 4445, host: '127.0.0.1')
      @port = port
      @host = host
      @base_uri = URI("http://#{host}:#{port}/lua")
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
