# frozen_string_literal: true

require 'zbspec'
require 'rspec'
require 'tempfile'

RSpec.describe ZBSpec::Config do
  describe 'COMMON_GAME_PATHS' do
    it 'includes common installation locations' do
      expect(ZBSpec::Config::COMMON_GAME_PATHS).to include(
        '/Applications/Project Zomboid.app'
      )
      expect(ZBSpec::Config::COMMON_GAME_PATHS).to include(
        '/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app'
      )
    end
  end

  describe 'DEFAULT_CONFIG' do
    it 'auto-detects game path' do
      expect(ZBSpec::Config::DEFAULT_CONFIG['game_path']).to be_nil
    end
  end

  describe '#detect_game_path' do
    let(:temp_config) { Tempfile.new(['zbspec', '.yml']) }
    
    before do
      temp_config.write("mods: []\n")
      temp_config.close
    end

    after do
      temp_config.unlink
    end

    it 'finds existing game installation' do
      config = ZBSpec::Config.new(temp_config.path)
      # Should either find a path or use fallback
      expect(config['game_path']).to be_a(String)
      expect(config['game_path']).not_to be_empty
    end
  end
end
