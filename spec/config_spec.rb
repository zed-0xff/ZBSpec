# frozen_string_literal: true

require 'zbtest'
require 'rspec'
require 'tempfile'

RSpec.describe ZBTest::Config do
  describe 'COMMON_GAME_PATHS' do
    it 'includes common installation locations' do
      expect(ZBTest::Config::COMMON_GAME_PATHS).to include(
        '/Applications/Project Zomboid.app'
      )
      expect(ZBTest::Config::COMMON_GAME_PATHS).to include(
        '/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app'
      )
    end
  end

  describe 'DEFAULT_CONFIG' do
    it 'uses port 4445 by default' do
      expect(ZBTest::Config::DEFAULT_CONFIG['api_port']).to eq(4445)
    end

    it 'auto-detects game path' do
      expect(ZBTest::Config::DEFAULT_CONFIG['game_path']).to be_nil
    end
  end

  describe '#detect_game_path' do
    let(:temp_config) { Tempfile.new(['zbtest', '.yml']) }
    
    before do
      temp_config.write("api_port: 4445\nmods: []\n")
      temp_config.close
    end

    after do
      temp_config.unlink
    end

    it 'finds existing game installation' do
      config = ZBTest::Config.new(temp_config.path)
      # Should either find a path or use fallback
      expect(config['game_path']).to be_a(String)
      expect(config['game_path']).not_to be_empty
    end
  end
end
