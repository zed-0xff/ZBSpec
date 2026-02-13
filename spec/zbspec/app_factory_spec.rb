# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe ZBSpec::AppFactory do
  around do |example|
    Dir.mktmpdir('app_factory_spec') do |tmp|
      @tmp = tmp
      example.run
    end
  end

  let(:apps_root) { @tmp }
  let(:app_path) { File.join(apps_root, 'MyApp.app') }

  describe '.create' do
    it 'returns the path to apps_root/name/Contents/MacOS/run.sh' do
      result = described_class.create(apps_root: apps_root, name: 'MyApp.app')
      expect(result).to eq(File.join(apps_root, 'MyApp.app', 'Contents', 'MacOS', 'run.sh'))
    end

    it 'creates the app directory structure at apps_root/name/Contents/...' do
      described_class.create(apps_root: apps_root, name: 'MyApp.app')

      expect(File.directory?(app_path)).to be true
      expect(File.directory?(File.join(app_path, 'Contents'))).to be true
      expect(File.directory?(File.join(app_path, 'Contents', 'MacOS'))).to be true
      expect(File.directory?(File.join(app_path, 'Contents', 'Resources'))).to be true
    end

    it 'writes Info.plist with expected keys' do
      described_class.create(apps_root: apps_root, name: 'SP 42.13.app')

      plist_path = File.join(apps_root, 'SP 42.13.app', 'Contents', 'Info.plist')
      expect(File).to exist(plist_path)
      content = File.read(plist_path)

      expect(content).to include('<key>CFBundleExecutable</key>')
      expect(content).to include('<string>run.sh</string>')
      expect(content).to include('<key>CFBundleName</key>')
      expect(content).to include('<string>SP 42.13.app</string>')
      expect(content).to include('<key>CFBundleDisplayName</key>')
      expect(content).to include('<string>SP 42.13.app</string>')
      expect(content).to include('<key>CFBundleIdentifier</key>')
      expect(content).to include('com.zbspec.sp_42.13.app')
      expect(content).to include('<key>CFBundleIconFile</key>')
      expect(content).to include('<string>icon.png</string>')
    end

    it 'escapes special characters in name for plist' do
      described_class.create(apps_root: apps_root, name: 'A & B <test>.app')

      content = File.read(File.join(apps_root, 'A & B <test>.app', 'Contents', 'Info.plist'))
      expect(content).to include('&amp;')
      expect(content).to include('&lt;test&gt;')
    end

    it 'writes run.sh launcher script with correct content and permissions' do
      exe_path = described_class.create(apps_root: apps_root, name: 'MyApp.app')

      expect(File).to exist(exe_path)
      content = File.read(exe_path)
      expect(content).to start_with('#!/bin/bash')
      expect(content).to include('JAVA="$1"')
      expect(content).to include('shift')
      expect(content).to include('"$JAVA" "$@"')

      expect(File.executable?(exe_path)).to be true
    end

    it 'generates icon.png in Resources when missing' do
      described_class.create(apps_root: apps_root, name: 'MyApp.app')

      icon_path = File.join(app_path, 'Contents', 'Resources', 'icon.png')
      expect(File).to exist(icon_path)
      expect(File.size(icon_path)).to be > 0
    end

    it 'does not overwrite existing nonzero icon.png' do
      resources_dir = File.join(app_path, 'Contents', 'Resources')
      FileUtils.mkdir_p(resources_dir)
      icon_path = File.join(resources_dir, 'icon.png')
      custom_content = "custom icon bytes #{rand(1000)}"
      File.write(icon_path, custom_content)

      described_class.create(apps_root: apps_root, name: 'MyApp.app')

      expect(File.read(icon_path)).to eq(custom_content)
    end

    it 'regenerates icon when icon.png exists but is empty' do
      resources_dir = File.join(app_path, 'Contents', 'Resources')
      FileUtils.mkdir_p(resources_dir)
      icon_path = File.join(resources_dir, 'icon.png')
      File.write(icon_path, '')

      described_class.create(apps_root: apps_root, name: 'MyApp.app')

      expect(File.size(icon_path)).to be > 0
    end

    it 'sanitizes bundle id from name' do
      described_class.create(apps_root: apps_root, name: 'SP/42.13.app')

      # name with / creates apps_root/SP/42.13.app
      content = File.read(File.join(apps_root, 'SP', '42.13.app', 'Contents', 'Info.plist'))
      expect(content).to include('com.zbspec.sp_42.13.app')
    end

    it 'overwrites existing app when called again' do
      described_class.create(apps_root: apps_root, name: 'MyApp.app')
      File.write(File.join(app_path, 'Contents', 'Info.plist'), 'custom')

      described_class.create(apps_root: apps_root, name: 'MyApp.app')

      plist = File.read(File.join(app_path, 'Contents', 'Info.plist'))
      expect(plist).to include('<key>CFBundleName</key>')
      expect(plist).to include('<string>MyApp.app</string>')
    end
  end
end
