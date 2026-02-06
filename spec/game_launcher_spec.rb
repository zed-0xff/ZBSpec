# frozen_string_literal: true

require 'zbspec'
require 'rspec'
require 'tempfile'

RSpec.describe ZBSpec::GameLauncher do
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
  let(:cache_dir) { File.expand_path('./tmp/test_cache') }
  let(:pid_file) { File.join(cache_dir, 'pz.pid') }

  before do
    # Ensure cache dir exists and clean up any existing PID file
    FileUtils.mkdir_p(cache_dir)
    File.delete(pid_file) if File.exist?(pid_file)
  end

  after do
    # Clean up PID file after tests
    File.delete(pid_file) if File.exist?(pid_file)
  end

  describe '#start with PID file management' do
    before do
      # Mock init_cachedir to avoid file system side effects
      allow(launcher).to receive(:init_cachedir)
    end

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
        FileUtils.mkdir_p(cache_dir)
        File.write(pid_file, Process.pid.to_s)
        
        expect(launcher).not_to receive(:spawn)
        
        launcher.start
        
        expect(launcher.pid).to eq(Process.pid)
      end
    end

    context 'when PID file exists with dead process' do
      it 'removes stale PID file and starts new process' do
        # Write a PID file with a process that doesn't exist
        FileUtils.mkdir_p(cache_dir)
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
      FileUtils.mkdir_p(cache_dir)
      File.write(pid_file, '12345')
      launcher.instance_variable_set(:@pid, 12345)
      launcher.instance_variable_set(:@running, true)
      
      # Mock Process.kill for both process_alive? check (signal 0) and actual kill
      allow(Process).to receive(:kill).with(0, 12345).and_return(1)
      allow(Process).to receive(:kill).with('TERM', 12345)
      allow(Process).to receive(:wait).with(12345, Process::WNOHANG).and_return(12345)
      
      launcher.stop
      
      expect(File.exist?(pid_file)).to be false
    end
  end

  describe '#build_mod_list' do
    it 'always includes ZombieBuddy first' do
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list.first).to eq('ZombieBuddy')
    end

    it 'includes ZBetterFPS and ZBSpec after ZombieBuddy' do
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list[0]).to eq('ZombieBuddy')
      expect(mod_list[1]).to eq('ZBetterFPS')
      expect(mod_list[2]).to eq('ZBSpec')
    end

    it 'adds user mods after default mods' do
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBetterFPS', 'ZBSpec', 'TestMod', 'AnotherMod'])
    end

    it 'does not duplicate ZombieBuddy if user includes it' do
      config['mods'] = ['ZombieBuddy', 'TestMod']
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list.count('ZombieBuddy')).to eq(1)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBetterFPS', 'ZBSpec', 'TestMod'])
    end

    it 'does not duplicate ZBSpec if user includes it' do
      config['mods'] = ['ZBSpec', 'TestMod']
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list.count('ZBSpec')).to eq(1)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBetterFPS', 'ZBSpec', 'TestMod'])
    end

    it 'works with no user mods' do
      config['mods'] = []
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBetterFPS', 'ZBSpec'])
    end

    it 'works with nil mods' do
      config['mods'] = nil
      mod_list = launcher.send(:build_mod_list)
      expect(mod_list).to eq(['ZombieBuddy', 'ZBetterFPS', 'ZBSpec'])
    end
  end
end
