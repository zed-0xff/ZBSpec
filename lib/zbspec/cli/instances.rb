# frozen_string_literal: true

module ZBSpec
  module CLI
    module Instances
      module_function

      def stop_instances(cache_dirs)
        found = false
        cache_dirs.each do |cache_dir|
          pid_file = File.join(cache_dir, 'pz.pid')
          next unless File.exist?(pid_file)
          found = true
          stop_one(cache_dir, pid_file)
          api_file = File.join(cache_dir, 'zbLuaAPI.txt')
          File.delete(api_file) if File.exist?(api_file)
        end
        puts "  No running instances found" unless found
      end

      def stop_one(cache_dir, pid_file)
        pid = File.read(pid_file).strip.to_i
        name = File.basename(cache_dir)
        Process.kill(0, pid)
        puts "  Stopping #{name} (PID: #{pid})..."
        Process.kill('TERM', pid)
        sleep 0.5
        Process.kill('KILL', pid) if process_alive?(pid)
        puts "  ✓ Stopped #{name}"
      rescue Errno::ESRCH
        puts "  ⚠️  #{name} already stopped (stale PID file)"
      ensure
        File.delete(pid_file)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      def discover_cache_dirs(mode, game_version: nil)
        all = Dir.glob('tmp/cache_*').select { |d| File.directory?(d) }.sort
        filter = { sp: 'cache_sp_', server: 'cache_server_', client: 'cache_client_' }
        dirs = case mode
        when :sp then all.select { |d| d.include?(filter[:sp]) }
        when :server then all.select { |d| d.include?(filter[:server]) }
        when :client then all.select { |d| d.include?(filter[:client]) }
        when :mp, :both then all.select { |d| d.include?(filter[:server]) || d.include?(filter[:client]) }
        else all
        end
        return dirs if game_version.nil? || game_version.to_s.empty?

        v = game_version.to_s
        dirs.select do |d|
          base = File.basename(d)
          case mode
          when :sp then base == "cache_sp_#{v}"
          when :server then base == "cache_server_#{v}"
          when :client then base == "cache_client_#{v}"
          when :mp, :both then base == "cache_server_#{v}" || base == "cache_client_#{v}"
          when :auto then base == "cache_sp_#{v}" || base == "cache_server_#{v}" || base == "cache_client_#{v}"
          else true
          end
        end
      end

      def discover_interactive_clients(mode, verbosity: 0, game_version: nil, sandbox: nil, timeout: nil)
        discover_cache_dirs(mode, game_version: game_version).each_with_object({}) do |cache_dir, out|
          port_file = File.join(cache_dir, 'zbLuaAPI.txt')
          next unless File.exist?(port_file)
          port = File.read(port_file).strip.to_i
          next if port <= 0
          name = File.basename(cache_dir).sub('cache_', '')
          client = APIClient.new(port: port, verbosity: verbosity, sandbox: sandbox, timeout: timeout)
          out[name] = { client: client, port: port } if client.ready?
        end
      end
    end
  end
end
