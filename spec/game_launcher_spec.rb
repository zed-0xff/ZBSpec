# frozen_string_literal: true

require 'zbtest'
require 'rspec'
require 'tempfile'

RSpec.describe ZBTest::GameLauncher do
  let(:config) do
    {
      'game_path' => '/path/to/game',
      'mods' => ['TestMod', 'AnotherMod'],
      'server_mode' => false,
      'debug' => true,
      'cache_dir' => './tmp/test_cache'
    }
  end
  
  let(:launcher) { described_class.new(config) }
  let(:pid_file) { File.join('tmp', 'zbtest.pid') }

  before do
    # Clean up any existing PID file
    File.delete(pid_file) if File.exist?(pid_file)
  end

  after do
    # Clean up PID file after tests
    File.delete(pid_file) if File.exist?(pid_file)
  end

  describe '#start with PID file management' do
    context 'when no PID file exists' do
      it 'starts a new process and creates PID file' do
        allow(launcher).to receive(:find_executable).and_return('/fake/game')
        allow(launcher).to receive(:spawn).and_return(12345)
        
        launcher.start
        
        expect(File.exist?(pid_file)).to be true
        expect(File.read(pid_file).strip).to eq('12345')
        expect(launcher.pid).to eq(12345)
      end
    end

    context 'when PID file exists with running process' do
      it 'reuses the existing process' do
        # Write a PID file with the current process (which is alive)
        FileUtils.mkdir_p('tmp')
        File.write(pid_file, Process.pid.to_s)
        
        expect(launcher).not_to receive(:spawn)
        
        launcher.start
        
        expect(launcher.pid).to eq(Process.pid)
      end
    end

    context 'when PID file exists with dead process' do
      it 'removes stale PID file and starts new process' do
        # Write a PID file with a process that doesn't exist
        FileUtils.mkdir_p('tmp')
        File.write(pid_file, '999999')
        
        allow(launcher).to receive(:find_executable).and_return('/fake/game')
        allow(launcher).to receive(:spawn).and_return(12345)
        
        launcher.start
        
        expect(File.read(pid_file).strip).to eq('12345')
        expect(launcher.pid).to eq(12345)
      end
    end
  end

  describe '#stop' do
    it 'removes PID file when stopping' do
      # Create a PID file
      FileUtils.mkdir_p('tmp')
      File.write(pid_file, '12345')
      launcher.instance_variable_set(:@pid, 12345)
      launcher.instance_variable_set(:@running, true)
      
      allow(Process).to receive(:kill)
      allow(Process).to receive(:wait)
      
      launcher.stop
      
      expect(File.exist?(pid_file)).to be false
    end
  end

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
