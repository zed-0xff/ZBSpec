# frozen_string_literal: true

module ZBSpec
  # Discovers spec files and determines run mode based on folder structure
  class SpecDiscovery
    SPEC_FOLDERS = {
      client: 'spec/client',
      server: 'spec/server',
      shared: 'spec/shared'
    }.freeze

    attr_reader :client_specs, :server_specs, :shared_specs

    def initialize(base_dir: '.')
      @base_dir = base_dir
      @client_specs = discover_specs(:client)
      @server_specs = discover_specs(:server)
      @shared_specs = discover_specs(:shared) + discover_root_specs
    end

    def has_client_specs?
      @client_specs.any?
    end

    def has_server_specs?
      @server_specs.any?
    end

    def has_shared_specs?
      @shared_specs.any?
    end

    def needs_server?
      has_server_specs? || has_shared_specs?
    end

    def needs_client?
      has_client_specs? || has_shared_specs?
    end

    def needs_mp?
      needs_server? && needs_client?
    end

    # Determine the best mode based on available specs
    def recommended_mode
      if needs_server? && needs_client?
        :both  # Run SP first, then MP
      elsif needs_server?
        :server
      else
        :sp
      end
    end

    # Get specs for a specific context
    def specs_for(context)
      case context
      when :server
        @server_specs + @shared_specs
      when :client
        @client_specs + @shared_specs
      when :sp
        # SP runs everything (it's both server and client)
        @client_specs + @server_specs + @shared_specs
      else
        all_specs
      end
    end

    def all_specs
      (@client_specs + @server_specs + @shared_specs).uniq
    end

    def summary
      parts = []
      parts << "#{@client_specs.length} client" if @client_specs.any?
      parts << "#{@server_specs.length} server" if @server_specs.any?
      parts << "#{@shared_specs.length} shared" if @shared_specs.any?
      parts.join(', ')
    end

    private

    def discover_specs(folder_key)
      folder = File.join(@base_dir, SPEC_FOLDERS[folder_key])
      return [] unless File.directory?(folder)

      Dir.glob(File.join(folder, '**/*_spec.lua')).sort
    end

    def discover_root_specs
      # Specs directly in spec/ folder (not in subfolders)
      Dir.glob(File.join(@base_dir, 'spec/*_spec.lua')).sort
    end
  end
end
