# frozen_string_literal: true

require 'zbtest'
require 'rspec'

RSpec.describe ZBTest::GameLauncher do
  let(:config) do
    {
      'game_path' => '/path/to/game',
      'mods' => ['TestMod', 'AnotherMod'],
      'server_mode' => false,
      'debug' => true
    }
  end
  
  let(:launcher) { described_class.new(config) }

  describe '#build_mod_list' do
    it 'always includes ZombieBuddy first' do
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list.first).to eq('ZombieBuddy')
    end

    it 'includes ZBTest after ZombieBuddy' do
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list[0]).to eq('ZombieBuddy')
      expect(mod_list[1]).to eq('ZBTest')
    end

    it 'adds user mods after ZombieBuddy and ZBTest' do
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBTest', 'TestMod', 'AnotherMod'])
    end

    it 'does not duplicate ZombieBuddy if user includes it' do
      config['mods'] = ['ZombieBuddy', 'TestMod']
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list.count('ZombieBuddy')).to eq(1)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBTest', 'TestMod'])
    end

    it 'does not duplicate ZBTest if user includes it' do
      config['mods'] = ['ZBTest', 'TestMod']
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list.count('ZBTest')).to eq(1)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBTest', 'TestMod'])
    end

    it 'works with no user mods' do
      config['mods'] = []
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBTest'])
    end

    it 'works with nil mods' do
      config['mods'] = nil
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBTest'])
    end
  end
end
