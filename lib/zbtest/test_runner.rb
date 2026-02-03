# frozen_string_literal: true

module ZBTest
  # Base test runner - extend this for mod-specific tests
  class TestRunner
    attr_reader :api_client, :config, :mod_namespace

    def initialize(api_client, config, mod_namespace: nil)
      @api_client = api_client
      @config = config
      @mod_namespace = mod_namespace
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

      results
    end

    protected

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
