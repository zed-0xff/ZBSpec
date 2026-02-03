# frozen_string_literal: true

require 'zbspec'
require 'rspec'
require 'timeout'
require 'tempfile'

RSpec.describe ZBSpec::APIClient do
  let(:client) { ZBSpec::APIClient.new(port: 4445) }

  describe '#discover_port' do
    let(:temp_port_file) { Tempfile.new(['zbLuaAPI', '.txt']) }
    let(:client_with_file) { ZBSpec::APIClient.new(port_file: temp_port_file.path) }

    after do
      temp_port_file.unlink
    end

    context 'when port file exists with valid port' do
      it 'reads port and sets up base URI' do
        temp_port_file.write('12345')
        temp_port_file.close
        
        expect(client_with_file.discover_port(timeout: 5)).to eq(12345)
        expect(client_with_file.port).to eq(12345)
        expect(client_with_file.base_uri.to_s).to include('12345')
      end
    end

    context 'when port file does not exist yet' do
      it 'waits for file to appear' do
        Thread.new do
          sleep 1
          temp_port_file.write('54321')
          temp_port_file.close
        end
        
        expect(client_with_file.discover_port(timeout: 5)).to eq(54321)
      end
    end

    context 'when port is already set' do
      it 'skips discovery' do
        client_already_set = ZBSpec::APIClient.new(port: 4445)
        expect(client_already_set.discover_port).to be_nil
        expect(client_already_set.port).to eq(4445)
      end
    end

    context 'when file never appears' do
      it 'raises APIError after timeout' do
        expect {
          client_with_file.discover_port(timeout: 2)
        }.to raise_error(ZBSpec::APIError, /Could not discover API port after 2s/)
      end
    end
  end

  describe '#wait_for_player' do
    context 'when player spawns immediately' do
      it 'returns true without waiting' do
        allow(client).to receive(:execute).with('return getPlayer() ~= nil').and_return(true)
        
        expect(client.wait_for_player(timeout: 5)).to be true
      end
    end

    context 'when player spawns after a delay' do
      it 'polls until player is available' do
        call_count = 0
        allow(client).to receive(:execute).with('return getPlayer() ~= nil') do
          call_count += 1
          call_count >= 3 # Return true on 3rd call
        end
        
        expect(client.wait_for_player(timeout: 10)).to be true
        expect(call_count).to be >= 3
      end
    end

    context 'when player never spawns' do
      it 'raises APIError after timeout' do
        allow(client).to receive(:execute).with('return getPlayer() ~= nil').and_return(false, nil)
        
        expect {
          client.wait_for_player(timeout: 2)
        }.to raise_error(ZBSpec::APIError, /Player not spawned after 2s timeout/)
      end
    end

    context 'when API returns nil' do
      it 'continues polling' do
        call_count = 0
        allow(client).to receive(:execute).with('return getPlayer() ~= nil') do
          call_count += 1
          call_count >= 4 ? true : nil
        end
        
        expect(client.wait_for_player(timeout: 10)).to be true
      end
    end
  end
end
