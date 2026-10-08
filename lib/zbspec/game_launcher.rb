# frozen_string_literal: true
require 'fileutils'
require 'erb'
require 'shellwords'

module ZBSpec
  # Handles launching and stopping the game
  class GameLauncher
    LABEL_WIDTH = 8

    ARCH = RUBY_PLATFORM.include?('aarch64') ? 'aarch64' : 'x86_64'

    attr_reader :config, :pid, :label
    attr_accessor :verbosity

    def initialize(config, label: nil, verbosity: 0)
      @config = config
      @label = label || (config['server_mode'] ? 'server' : 'sp')
      @verbosity = verbosity
      @pid = nil
      @running = false
    end

    def log(msg)
      return unless @verbosity > 0
      puts "[#{@label.ljust(6)}] #{msg}"
    end

    def pid_file
      @pid_file ||= File.join(get_cache_dir, 'pz.pid')
    end

    # Read server's game port from cache_server_<ver>/Server/servertest.ini (DefaultPort=...)
    def read_server_game_port
      ini_path = File.join(server_cache_dir_for_version(game_version_name), 'Server', 'servertest.ini')
      5.times do
        break if File.exist?(ini_path)
        sleep 0.2
      end
      return nil unless File.exist?(ini_path)
      content = File.read(ini_path)
      m = content.match(/DefaultPort=\s*(\d+)/)
      m ? m[1].to_i : nil
    end

    # In non-Steam mode the RakNet listener is bound to UDPPort (DefaultPort+1);
    # DefaultPort is only the Steam connection port. Direct `+connect` clients
    # must therefore target UDPPort.
    def read_server_udp_port
      ini_path = File.join(server_cache_dir_for_version(game_version_name), 'Server', 'servertest.ini')
      5.times do
        break if File.exist?(ini_path)
        sleep 0.2
      end
      return nil unless File.exist?(ini_path)
      content = File.read(ini_path)
      m = content.match(/UDPPort=\s*(\d+)/)
      m ? m[1].to_i : nil
    end

    # Port a direct `+connect` client should dial. Respects an explicit config
    # override, then the server's DefaultPort (the port RakNet binds in
    # non-Steam mode), then UDPPort as a fallback.
    def server_connect_port
      return config['server_connect_port'] if config['server_connect_port']
      read_server_game_port || read_server_udp_port
    end

    # The server picks and persists a random DefaultPort before starting. The
    # client may launch in parallel, so prefer the persisted value (avoids a
    # race on the generated servertest.ini).
    def server_persisted_port
      read_persisted_game_port(server_cache_dir_for_version(game_version_name))
    end

    def start
      # Check for existing PID file
      if File.exist?(pid_file)
        existing_pid = File.read(pid_file).strip.to_i
        if process_alive?(existing_pid)
          log "✓ Game already running (PID: #{existing_pid})"
          @pid = existing_pid
          @running = true
          return
        else
          log "⚠️  Stale PID file found, removing..."
          File.delete(pid_file)
        end
      end

      if running?
        log '✓ Game already running'
        return
      end

      # Clean up stale port file from previous session
      clean_port_file

      log '🎮 Launching Project Zomboid...'

      redirect_output = config['redirect_output']
      redirect_output = true if redirect_output.nil?
      log_file = redirect_output ? setup_log_file : nil

      args = build_launch_args(log_file: log_file)

      log "game root: #{game_root}"
      if args.is_a?(Hash) && args.key?(:app)
        log "Launching #{args[:app].name} via app bundle"
        @pid = args[:app].start!
      else
        spawn_opts = { chdir: launch_chdir }
        spawn_opts[:out] = spawn_opts[:err] = log_file if log_file
        log format_argv_multiline(args) if @verbosity > 0
        log "Launching with args: #{args.inspect}" if @verbosity <= 0
        @launch_env = (@launch_env || {}).merge(stringified_env)
        @pid = spawn(@launch_env, *args, **spawn_opts)
      end
      @running = true

      # Write PID file
      write_pid_file

      if @verbosity > 0
        log "PID: #{@pid}"
        log "Log: #{log_file}" if log_file
        log "Mods: #{config['mods'].join(', ')}" if config['mods']
      end
    rescue StandardError => e
      raise GameLaunchError, "Failed to launch game: #{e.message}"
    end

    def stop
      return unless running?

      puts "\n🛑 Stopping game (PID: #{@pid})..."
      terminate_process(@pid)
      begin
        Process.wait(@pid, Process::WNOHANG)
      rescue Errno::ECHILD
        # PID is not our child (e.g. reused from previous run)
      end
      @running = false
      @pid = nil

      # Remove PID file
      File.delete(pid_file) if File.exist?(pid_file)
    rescue Errno::ESRCH
      # Process already dead
      @running = false
      File.delete(pid_file) if File.exist?(pid_file)
    end

    def running?
      return false unless @pid

      process_alive?(@pid)
    end

    def get_cache_dir
      File.expand_path(config['cache_dir'] || default_cache_dir)
    end

    private

    def process_alive?(pid)
      return false unless pid && pid > 0

      if windows?
        # Ruby on Windows does not support Process.kill(0, pid); use tasklist.
        out = `tasklist /FI "PID eq #{pid}" /NH /FO CSV 2>NUL`
        out.include?(pid.to_s)
      else
        Process.kill(0, pid)
        true
      end
    rescue Errno::ESRCH, Errno::EINVAL
      false
    end

    def terminate_process(pid)
      if windows?
        system('taskkill', '/PID', pid.to_s, '/T', '/F', out: File::NULL, err: File::NULL)
      else
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH
          return
        end
        sleep 0.5
        begin
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
          # already gone
        end
      end
    end

    # Root of the game install (macOS app bundle contents Java dir, or the
    # folder containing the launcher on Windows/Linux).
    def game_root
      @game_root || @mac_game_root
    end

    # Working directory for the launched process. On Linux/macOS the shell
    # wrapper cds into the nested `projectzomboid/` folder, which is where the
    # relative classpath (`.:projectzomboid.jar`) resolves.
    def launch_chdir
      if mac?
        @mac_game_root
      elsif windows?
        game_root
      else
        unix_install_dir
      end
    end

    def resolve_game_root
      if config['server_mode'] && (server_path = config['server_path']).to_s.strip != ''
        return File.expand_path(server_path.to_s)
      end
      version_dir = File.join(game_versions_root, game_version_name)
      base = File.directory?(version_dir) ? version_dir : config['game_path']
      raise GameLaunchError, 'Project Zomboid path not configured. Set game_path in spec/zbspec.yml.' unless base
      File.expand_path(base.to_s)
    end

    def write_pid_file
      FileUtils.mkdir_p(get_cache_dir)
      File.write(pid_file, @pid.to_s)
      log "PID file: #{File.expand_path(pid_file)}"
    end

    def clean_port_file
      cache_dir = get_cache_dir
      port_file = File.join(cache_dir, 'zbLuaAPI.txt')
      
      if File.exist?(port_file)
        File.delete(port_file)
        log "Cleaned stale port file: #{port_file}"
      end
    end

    def setup_log_file
      cache_dir = get_cache_dir
      FileUtils.mkdir_p(cache_dir)
      File.join(cache_dir, 'std.log')
    end

    # Format argv as readable multiline (one argument per line with \ continuation)
    def format_argv_multiline(argv)
      return '' unless argv.is_a?(Array) && argv.any?
      quoted = argv.map { |a| "'#{a.to_s.gsub("'", "'\\\\''")}'" }
      quoted.each_with_index.map { |arg, i| i.zero? ? "exec #{arg}" : "  #{arg}" }.join(" \\\n")
    end

    def build_launch_args(log_file: nil)
      if mac?
        @mac_java_home, @mac_game_root = resolve_mac_paths
      else
        @game_root = resolve_game_root
      end

      return build_custom_launch_args(log_file: log_file) if custom_launch?

      game_exe = find_executable
      if mac?
        config['same_console'] ? build_mac_direct_args(game_exe) : build_mac_launch_args(game_exe, log_file: log_file)
      else
        build_other_launch_args(game_exe)
      end
    end

    # True when the config replaces the built-in argv with a literal command or
    # a wrapper script/binary.
    def custom_launch?
      !Array(config['launch_command']).empty? || config['launcher'].to_s.strip != ''
    end

    # Config-driven launch: either a full argv (`launch_command`, with
    # placeholders) or a wrapper script/binary (`launcher`). Mods are still
    # linked into the cache dir and the ZombieBuddy agent must be injected by the
    # caller via ${AGENT} (launch_command) — a `launcher` script manages its own.
    def build_custom_launch_args(log_file: nil)
      cache_dir = File.expand_path(config['cache_dir'] || default_cache_dir)
      init_cachedir(cache_dir)
      @launch_env = stringified_env

      argv =
        if config['launcher'].to_s.strip != ''
          launcher_command(config['launcher'])
        else
          expand_launch_placeholders(launch_command_argv, cache_dir)
        end

      log format_argv_multiline(argv) if @verbosity > 0
      argv
    end

    def launch_command_argv
      cmd = config['launch_command']
      return cmd.map(&:to_s) if cmd.is_a?(Array)
      Shellwords.split(cmd.to_s)
    end

    def launcher_command(launcher)
      path = File.expand_path(launcher.to_s, game_root.to_s)
      extra = Array(config['server_mode'] ? config['server_args'] : config['client_args']).map(&:to_s)
      if windows? && path.match?(/\.(bat|cmd)\z/i)
        ['cmd', '/c', path, *extra]
      else
        [path, *extra]
      end
    end

    # Replace ${NAME} placeholders in every argument. Unknown placeholders are
    # left untouched so typos surface in the logged command.
    def expand_launch_placeholders(argv, cache_dir)
      vars = {
        'JAVA' => bundled_java_path,
        'GAME' => launch_chdir.to_s,
        'CACHEDIR' => cache_dir.to_s,
        'SERVERNAME' => (config['server_name'] || 'ZBSpecServer').to_s,
        'ADMINPASSWORD' => (config['admin_password'] || 'zbspec').to_s,
        'PORT' => config['server_port'].to_s,
        'AGENT' => agent_option.to_s
      }
      argv.map do |arg|
        arg.gsub(/\$\{(\w+)\}/) { vars[Regexp.last_match(1)] || Regexp.last_match(0) }
      end
    end

    # Bundled JVM used by the built-in launcher, for the ${JAVA} placeholder.
    def bundled_java_path
      return File.join(@mac_java_home.to_s, 'bin', 'java') if mac?
      exe = windows? ? 'java.exe' : 'java'
      File.join(unix_install_dir, 'jre64', 'bin', exe)
    end

    def build_mac_launch_args(java_bin, log_file: nil)
      cache_dir = File.expand_path(config['cache_dir'] || default_cache_dir)
      init_cachedir(cache_dir)

      argv = build_java_argv(java_bin, cache_dir)
      log format_argv_multiline(argv) if @verbosity > 0
      app_display_name = config['window_title'].to_s.strip.empty? ? default_window_title : config['window_title']
      pid_file = File.join(cache_dir, 'pz.pid')

      app = AppFactory.create(
        apps_root: cache_dir,
        name: app_display_name,
        chdir: @mac_game_root,
        argv: argv,
        pid_file: pid_file,
        log_file: log_file
      )

      { app: app }
    end

    def build_mac_direct_args(java_bin)
      cache_dir = File.expand_path(config['cache_dir'] || default_cache_dir)
      init_cachedir(cache_dir)
      build_java_argv(java_bin, cache_dir)
    end

    # argv for run.sh: first = java binary, rest = JVM + game args
    def build_java_argv(java_bin, cache_dir)
      jars = Dir[File.join(@mac_game_root, '*.jar')].map { |f| File.basename(f) }
      classpath = classpath_override((jars + ['.']).join(':'))

      java_lib_paths = [
        ".",
        File.join(@mac_java_home, 'lib'),
        File.join(@mac_game_root, "mac-#{ARCH}"),
      ]

      argv = [
        java_bin,
        '--enable-native-access=ALL-UNNAMED',
        '-Djava.awt.headless=true',
        '-XstartOnFirstThread',
        "-Dzomboid.steam=#{steam? ? 1 : 0}",
        '-Dzomboid.znetlog=1',
        '-Xmx3072m',
        '-XX:+UseZGC',
        '-XX:-OmitStackTraceInFastThrow',
        *Array(config['jvm_args']).map(&:to_s),
        "-Djava.library.path=#{java_lib_paths.join(':')}",
        "-Dzb.config_dir=#{cache_dir}/.zombie_buddy",
        agent_option,
        '-classpath', classpath
      ]
      argv << '-Ddebug=1' if config['debug'] != false && config['debug_jvm']

      main_class = effective_main_class(nil)
      argv << main_class
      argv << '--'
      argv << "-cachedir=#{cache_dir}"

      if config['server_mode']
        server_name = config['server_name'] || 'ZBSpecServer'
        argv << server_name
        argv << '-nosteam' unless steam?
        argv << '-adminpassword' << (config['admin_password'] || 'zbspec')
        argv.concat(Array(config['server_args']).map(&:to_s))
      else
        argv.concat(['-novoip', '-nosound'])
        argv << '-nosteam' unless steam?
        argv.concat(['-no-worldgen', '-no-foraging', '-no-attachments'])
        argv << '-debug' unless config['debug'] == false
        argv.concat(Array(config['client_args']).map(&:to_s))
        if config['server_ip']
          ip = config['server_ip']
          port = config['server_port'] || read_server_game_port || 16261
          password = config['password'] || ''
          argv << '+connect' << "#{ip}:#{port}"
          argv << '+password' << password unless password.empty?
        end
      end
      argv
    end

    # Windows / Linux launch path.
    #
    # Windows: the native launcher (ProjectZomboid64.exe) forwards JVM options
    # placed before `--`, so the agent is passed directly.
    #
    # Linux/macOS: the shell wrappers do not forward JVM options, and setting
    # _JAVA_OPTIONS breaks their `java -version` health probe (the agent fails
    # before game classes are loaded). We therefore invoke the bundled JVM
    # directly, replicating the wrapper's environment, so the -javaagent is
    # applied only to the real game process.
    def build_other_launch_args(game_exe)
      cache_dir = File.expand_path(config['cache_dir'] || default_cache_dir)
      init_cachedir(cache_dir)

      if windows?
        build_windows_launch_args(game_exe, cache_dir)
      else
        build_unix_launch_args(game_exe, cache_dir)
      end
    end

    def build_windows_launch_args(game_exe, cache_dir)
      if config['server_mode']
        jvm = Array(config['jvm_args']).map(&:to_s)
        jvm << '-Ddebug=1' if config['debug'] != false && config['debug_jvm']
        @launch_env = jvm_options_env([agent_option] + jvm)
        server_name = config['server_name'] || 'ZBSpecServer'
        args = [game_exe, "-cachedir=#{cache_dir}", server_name]
        args << '-nosteam' unless steam?
        args.concat(['-adminpassword', (config['admin_password'] || 'zbspec')])
        args.concat(Array(config['server_args']).map(&:to_s))
        return args
      end

      jvm = Array(config['jvm_args']).map(&:to_s)
      jvm << '-Ddebug=1' if config['debug'] != false && config['debug_jvm']
      args = [game_exe, "-Dzb.config_dir=#{cache_dir}/.zombie_buddy", agent_option, *jvm, '--',
              "-cachedir=#{cache_dir}"]
      args.concat(['-novoip', '-nosound'])
      args << '-nosteam' unless steam?
      args.concat(['-no-worldgen', '-no-foraging', '-no-attachments'])
      args << '-debug' unless config['debug'] == false
      args.concat(Array(config['client_args']).map(&:to_s))
      append_client_connect_args(args)
      args
    end

    def build_unix_launch_args(_game_exe, cache_dir)
      install_dir = unix_install_dir
      java_bin = File.join(install_dir, 'jre64', 'bin', 'java')
      raise GameLaunchError, "Bundled java not found: #{java_bin}" unless File.exist?(java_bin)

      vm_args, classpath, json_main_class = read_pzexe_config(install_dir)
      classpath = classpath_override(classpath)
      # Force offline/test-friendly properties regardless of the JSON defaults.
      vm_args.reject! { |a| a.start_with?('-Dzomboid.steam=', '-Djava.awt.headless=') }
      vm_args << "-Dzomboid.steam=#{steam? ? 1 : 0}"
      vm_args << "-Djava.awt.headless=#{headless?}"
      vm_args << '-Ddebug=1' if config['debug'] != false && config['debug_jvm']
      vm_args << "-Dzb.config_dir=#{cache_dir}/.zombie_buddy"
      vm_args << agent_option
      vm_args.concat(Array(config['jvm_args']).map(&:to_s))
      main_class = effective_main_class(json_main_class)

      # Mirror the official wrapper's native library environment. The native
      # dir differs between the client (`natives/`) and the dedicated server
      # (`linux64/` / `win64/`).
      natives = native_lib_dir(install_dir)
      lib_paths = [natives, install_dir, File.join(install_dir, 'jre64', 'lib')]
      @launch_env = {
        'LD_LIBRARY_PATH' => (lib_paths + [ENV['LD_LIBRARY_PATH']]).compact.reject(&:empty?).join(':'),
        'XMODIFIERS' => '',
      }
      preload = ['libjsig.so', 'libPZXInitThreads64.so']
      preload << ENV['LD_PRELOAD'] if ENV['LD_PRELOAD'] && !ENV['LD_PRELOAD'].empty?
      @launch_env['LD_PRELOAD'] = preload.join(':')

      args = [java_bin] + vm_args + ['-classpath', classpath, main_class, '--']
      if config['server_mode']
        server_name = config['server_name'] || 'ZBSpecServer'
        args.concat(["-cachedir=#{cache_dir}", server_name])
        args << '-nosteam' unless steam?
        args.concat(['-adminpassword', (config['admin_password'] || 'zbspec')])
        args.concat(Array(config['server_args']).map(&:to_s))
        return args
      end

      args << "-cachedir=#{cache_dir}"
      args.concat(['-novoip', '-nosound'])
      args << '-nosteam' unless steam?
      args.concat(['-no-worldgen', '-no-foraging', '-no-attachments'])
      args << '-debug' unless config['debug'] == false
      args.concat(Array(config['client_args']).map(&:to_s))
      append_client_connect_args(args)
      args
    end

    # Directory containing the bundled JVM / game jars. The user-facing
    # game_path may point at the outer Steam folder whose `projectzomboid/`
    # subfolder holds the actual install.
    def unix_install_dir
      nested = File.join(game_root, 'projectzomboid')
      return nested if File.exist?(File.join(nested, 'jre64', 'bin', 'java'))
      game_root
    end

    # Read mainClass/classpath/vmArgs from ProjectZomboid64.json. Falls back to
    # sensible defaults if the file is missing.
    def read_pzexe_config(install_dir)
      path = File.join(install_dir, 'ProjectZomboid64.json')
      if File.exist?(path)
        data = JSON.parse(File.read(path))
        return [Array(data['vmArgs']).dup, Array(data['classpath']).join(':'), data['mainClass'].to_s]
      end
      [['-Djava.awt.headless=true', '-Xmx3072m'], '.:projectzomboid.jar', 'zombie/gameStates/MainScreenState']
    rescue JSON::ParserError
      [['-Djava.awt.headless=true', '-Xmx3072m'], '.:projectzomboid.jar', 'zombie/gameStates/MainScreenState']
    end

    def append_client_connect_args(args)
      return unless config['server_ip']
      ip = config['server_ip']
      port = config['server_port'] || server_persisted_port || server_connect_port || 16261
      password = config['password'] || ''
      args << '+connect' << "#{ip}:#{port}"
      args << '+password' << password unless password.empty?
    end

    # Merge options into _JAVA_OPTIONS without clobbering a user value.
    def jvm_options_env(options)
      existing = ENV['_JAVA_OPTIONS'].to_s.strip
      merged = ([existing] + options).reject(&:empty?).join(' ')
      { '_JAVA_OPTIONS' => merged }
    end

    # Non-Steam mode is the default (matches the built-in test launch); set
    # `steam: true` to pass -Dzomboid.steam=1 and drop -nosteam.
    def steam?
      config['steam'] == true
    end

    # Dedicated servers are headless; clients need a display. Overridable.
    def headless?
      return config['headless'] unless config['headless'].nil?
      !!config['server_mode']
    end

    # Native library directory, which differs by install type: the client ships
    # `natives/`, the dedicated server `linux64/` (or `win64/`).
    def native_lib_dir(install_dir)
      explicit = config['natives_dir'].to_s.strip
      return File.join(install_dir, explicit) unless explicit.empty?
      %w[natives linux64 win64].each do |name|
        dir = File.join(install_dir, name)
        return dir if File.directory?(dir)
      end
      File.join(install_dir, 'natives')
    end

    def classpath_override(fallback)
      cp = config['classpath']
      return fallback if cp.nil?
      return cp if cp.is_a?(String)
      Array(cp).join(':')
    end

    def effective_main_class(json_main_class)
      override = config['main_class'].to_s.strip
      return override unless override.empty?
      return 'zombie.network.GameServer' if config['server_mode']
      json_main_class.to_s.empty? ? 'zombie.gameStates.MainScreenState' : json_main_class
    end

    def stringified_env
      (config['env'] || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
    end

    def agent_option
      agent_parts = [
        'experimental',
        'lua_server_port=random',
        'prop_prefix=zb',
        'expose_classes=me.zed_0xff.zombie_buddy.Reflect,me.zed_0xff.zombie_buddy.Exposer'
      ]
      if @verbosity > 0
        agent_parts << "verbosity=#{@verbosity}"
      end
      if (timeout_sec = config['lua_task_timeout']) && timeout_sec.to_i > 0
        agent_parts << "lua_task_timeout=#{timeout_sec.to_i * 1000}"
      end
      title = config['window_title']
      title = default_window_title if title.nil? || title.empty?
      if title && !title.empty?
        encoded_title = URI.encode_www_form_component(title)
        agent_parts << "window_title=#{encoded_title}"
      end
      # Extra raw agent key=value pairs from config (e.g. policy=allow-all).
      Array(config['zb_agent_args']).each { |part| agent_parts << part.to_s }

      if windows?
        # Native agent: zbNative.dll loads ZombieBuddy.jar from the game folder.
        "-agentlib:zbNative=#{agent_parts.join(',')}"
      else
        "-javaagent:#{zombiebuddy_jar}=#{agent_parts.join(',')}"
      end
    end

    def default_window_title
      version = game_version_name
      case @label
      when 'server'
        "MP #{version} server"
      when 'client'
        "MP #{version} client"
      else
        "SP #{version}"
      end
    end

    def zombiebuddy_jar
      @zombiebuddy_jar ||= begin
        candidates = [
          # Next to the game launcher (recommended install location on Win/Linux).
          game_root && File.join(game_root, 'ZombieBuddy.jar'),
          game_root && File.join(game_root, 'projectzomboid', 'ZombieBuddy.jar'),
          # When the server launches from a separate server_path, fall back to
          # the client install's ZombieBuddy.
          game_path_jar_candidates,
          File.expand_path('~/projects/zomboid/mods/ZombieBuddy/libs/ZombieBuddy.jar'),
          File.expand_path('~/Zomboid/mods/ZombieBuddy/libs/ZombieBuddy.jar'),
          File.expand_path('~/Library/Application Support/Steam/steamapps/workshop/content/108600/3619862853/mods/ZombieBuddy/libs/ZombieBuddy.jar'),
          steam_workshop_jar_path,
        ].flatten.compact
        path = candidates.find { |p| File.file?(p) }
        unless path
          raise GameLaunchError, "ZombieBuddy.jar not found. Checked:\n  #{candidates.join("\n  ")}"
        end
        path
      end
    end

    # ZombieBuddy JAR inside the Steam Workshop content folder, per platform.
    def steam_workshop_jar_path
      mods_path = steam_workshop_mods_path('3619862853')
      return nil unless mods_path
      File.join(mods_path, 'ZombieBuddy', 'libs', 'ZombieBuddy.jar')
    end

    # ZombieBuddy.jar next to the client install's launcher, used when the
    # server runs from a separate server_path.
    def game_path_jar_candidates
      base = config['game_path'].to_s.strip
      return [] if base.empty?
      base = File.expand_path(base)
      [
        File.join(base, 'ZombieBuddy.jar'),
        File.join(base, 'projectzomboid', 'ZombieBuddy.jar')
      ]
    end

    # ZombieBuddy mod root (parent of the directory containing the JAR, e.g. .../ZombieBuddy)
    def zombiebuddy_mod_dir
      File.expand_path(File.join(File.dirname(zombiebuddy_jar), '..'))
    end

    def default_cache_dir
      v = game_version_name
      kind = if config['server_mode']
               'server'
             elsif config['server_ip']
               'client'
             else
               'sp'
             end
      root = config['cache_root']
      if root && !root.to_s.strip.empty?
        File.join(File.expand_path(root.to_s), "cache_#{kind}_#{v}")
      else
        "./tmp/cache_#{kind}_#{v}"
      end
    end

    def server_cache_dir_for_version(version_name)
      root = config['cache_root']
      if root && !root.to_s.strip.empty?
        File.join(File.expand_path(root.to_s), "cache_server_#{version_name}")
      else
        File.expand_path("./tmp/cache_server_#{version_name}")
      end
    end

    def game_versions_root
      File.expand_path(config['game_versions_root'] || '~/projects/zomboid/versions')
    end

    def self.game_version_name_from_config(cfg)
      name = cfg['game_version']
      name ||= cfg['game_versions'].is_a?(Array) && cfg['game_versions'].first
      name ||= cfg['game_versions'].is_a?(Hash) && cfg['game_versions'].keys.first
      name&.to_s || 'default'
    end

    def game_version_name
      self.class.game_version_name_from_config(config)
    end

    def game_config_dir
      base = File.join(ZBSpec.root, 'configs')
      name = game_version_name
      dir = File.join(base, name)
      unless File.directory?(dir)
        log "⚠️  Game config dir not found: #{dir} (game_version=#{name.inspect}), using default"
        dir = File.join(base, 'default')
        raise GameLaunchError, "Game config dir not found: #{dir}" unless File.directory?(dir)
      end
      dir
    end

    def game_port_file(cache_dir)
      File.join(cache_dir, '.game_port')
    end

    def read_persisted_game_port(cache_dir)
      path = game_port_file(cache_dir)
      return nil unless File.exist?(path)
      port = File.read(path).strip.to_i
      (20000..50000).cover?(port) ? port : nil
    end

    def write_game_port(cache_dir, port)
      File.write(game_port_file(cache_dir), port.to_s)
    end

    def resolve_game_port(cache_dir)
      port = read_persisted_game_port(cache_dir)
      if port.nil?
        port = rand(20000..50000)
        write_game_port(cache_dir, port)
      end
      port
    end

    def init_cachedir(cache_dir)
      mods_dir = File.join(cache_dir, 'mods')
      FileUtils.mkdir_p(mods_dir)

      # Copy ini and lua files from configs/<game_version>, preserving structure
      config_dir = game_config_dir
      mods       = build_mod_list
      game_port  = config['server_mode'] ? resolve_game_port(cache_dir) : nil

      Dir.glob(File.join(config_dir,'**/*.{ini,json,lua,txt,erb}'), File::FNM_DOTMATCH).each do |src|
        next unless File.file?(src)
        next if File.basename(File.dirname(src)).downcase == 'server' && !config['server_mode']

        relative_path = src.sub(/^#{Regexp.escape(config_dir)}/, '').sub(%r{\A/}, '')
        raise if relative_path == src

        dest_path = File.join(cache_dir, relative_path)
        dest_path = dest_path.sub(/\.erb\z/, '') if relative_path.end_with?('.erb')
        FileUtils.mkdir_p(File.dirname(dest_path))
        if src.end_with?('.erb')
          template = ERB.new(File.read(src), trim_mode: '-')
          File.write(dest_path, template.result_with_hash(
            game_port: game_port,
            mods: mods,
          ))
        else
          FileUtils.cp(src, dest_path)
        end
      end

      # Link mods into the cachedir (junction on Windows, symlink elsewhere,
      # copy as a last resort).
      zbspec_link = File.join(mods_dir, 'ZBSpec')
      link_dir(File.join(ZBSpec.root, 'mods', 'ZBSpec'), zbspec_link)

      zombiebuddy_link = File.join(mods_dir, 'ZombieBuddy')
      link_dir(zombiebuddy_mod_dir, zombiebuddy_link)

      # Link mods: path (explicit), Steam workshop (steam_id), or ~/Zomboid/mods/
      user_mods_dir = File.expand_path('~/Zomboid/mods')
      config_mod_entries.each do |entry|
        mod = entry['name']
        next if mod == 'ZBSpec' # ZBSpec is handled above
        mod_link = File.join(mods_dir, mod)
        if entry['path']
          src = File.expand_path(entry['path'])
          raise GameLaunchError, "Mod path not found: #{entry['path']} (resolved: #{src})" unless File.exist?(src)
          link_mod_dir(src, mod_link)
        elsif (steam_id = entry['steam_id'])
          mod_mods_path = steam_workshop_mods_path(steam_id)
          unless File.exist?(mod_mods_path)
            raise GameLaunchError, "Steam workshop mod #{entry.inspect} not installed in #{mod_mods_path.inspect}"
          end
          Dir[File.join(mod_mods_path, '*')].each do |dirname|
            if File.directory?(dirname)
              link_dir(dirname, File.join(mods_dir, File.basename(dirname)))
            end
          end
        else
          user_mod_path = File.join(user_mods_dir, mod)
          link_dir(user_mod_path, mod_link) if File.exist?(user_mod_path)
        end
      end

    end

    # Link a directory as a link at +dst+. Uses a directory junction on Windows
    # (no admin required) and a symlink elsewhere, falling back to a copy.
    def link_dir(src, dst)
      src = File.expand_path(src.to_s)
      FileUtils.rm_rf(dst)
      FileUtils.mkdir_p(File.dirname(dst))

      if windows?
        linked = system('cmd', '/c', 'mklink', '/J', dst.tr('/', '\\'), src.tr('/', '\\'),
                        out: File::NULL, err: File::NULL)
        FileUtils.cp_r(src, dst) unless linked
      else
        begin
          FileUtils.ln_s(src, dst)
        rescue StandardError
          FileUtils.cp_r(src, dst)
        end
      end
    end

    # Non-mod entries that must never be linked into the cache mod dir.
    MOD_LINK_EXCLUDE = %w[.git .github .vscode .opencode dev_stuff tests graphify-out node_modules tmp].freeze

    # Copy a mod's *content* into +dst+, excluding non-mod directories (tmp,
    # .git, ...). We copy rather than symlink: PZ's ScriptManager mis-resolves
    # script paths through symlinked content dirs (it builds a bogus absolute
    # path and prepends the mods dir), so item/clothing scripts never load.
    # Excluding tmp/.git also avoids the cache-in-mod-directory symlink loop.
    def link_mod_dir(src, dst)
      src = File.expand_path(src.to_s)
      FileUtils.rm_rf(dst)
      FileUtils.mkdir_p(dst)

      Dir.children(src).sort.each do |name|
        next if MOD_LINK_EXCLUDE.include?(name)

        entry_src = File.join(src, name)
        entry_dst = File.join(dst, name)
        FileUtils.cp_r(entry_src, entry_dst)
      end
    end

    def steam_workshop_mods_path(steam_id)
      if windows?
        root = ENV['ProgramFiles(x86)'] || ENV['ProgramFiles'] || 'C:/Program Files (x86)'
        File.join(root, 'Steam', 'steamapps', 'workshop', 'content', '108600', steam_id.to_s, 'mods')
      elsif mac?
        File.expand_path(
          "~/Library/Application Support/Steam/steamapps/workshop/content/108600/#{steam_id}/mods"
        )
      else
        File.expand_path("~/.steam/steam/steamapps/workshop/content/108600/#{steam_id}/mods")
      end
    end

    # Config mods as list of hashes with 'id' (or 'name'), optional 'steam_id', optional 'path'
    def config_mod_entries
      @config_mod_entries ||= Array(config['mods']).map do |entry|
        if entry.is_a?(Hash)
          mod_id = (entry['id'] || entry['name']).to_s
          { 'name' => mod_id, 'steam_id' => entry['steam_id'], 'path' => entry['path'] }
        else
          { 'name' => entry.to_s, 'steam_id' => nil, 'path' => nil }
        end
      end
    end

    def build_mod_list
      mods = []
      mods << 'ZombieBuddy'
      mods << 'ZBSpec'
      config_mod_entries.each { |e| mods << e['name'] }
      mods.uniq
    end

    def find_executable
      if mac?
        # macOS: use Java from resolved JAVA_HOME
        java_home = @mac_java_home
        raise "JAVA_HOME not resolved. resolve_mac_paths should have been called." unless java_home
        java_bin = File.join(java_home, 'bin', 'java')
        raise "Java executable not found: #{java_bin}" unless File.exist?(java_bin)
        java_bin
      else
        find_native_executable
      end
    end

    # Windows/Linux launcher discovery. Searches the game root and, on Linux,
    # the nested `projectzomboid/` folder that holds the dedicated-server script.
    def find_native_executable
      names =
        if config['server_mode']
          windows? ? %w[StartServer64.bat StartServer64_nosteam.bat] : %w[start-server.sh start-server-nosteam.sh start-server-nosteam-custom.sh]
        elsif windows?
          %w[ProjectZomboid64.exe ProjectZomboid64.bat ProjectZomboid32.exe]
        else
          %w[projectzomboid_debug_nosteam.sh projectzomboid.sh]
        end

      dirs = [game_root, File.join(game_root, 'projectzomboid')]
      exe = names.flat_map { |name| dirs.map { |dir| File.join(dir, name) } }.find { |path| File.file?(path) }
      unless exe
        raise GameLaunchError,
              "Could not find a Project Zomboid launcher under #{game_root} " \
              "(looked for #{names.join(', ')}). Set game_path in spec/zbspec.yml."
      end
      exe
    end

    # macOS: resolve JAVA_HOME and GAME_ROOT paths
    def resolve_mac_paths
      version_dir = File.join(game_versions_root, game_version_name)
      game_path = File.directory?(version_dir) ? version_dir : config['game_path']
      return [nil, nil] unless game_path
      app_dir = resolve_mac_app_dir(game_path)
      java_home = mac_java_home(app_dir)
      game_root = mac_game_root(app_dir)
      [java_home, game_root]
    end

    # macOS: resolve app dir as "Project Zomboid.app" or "osx/Project Zomboid.app" under game_path
    def resolve_mac_app_dir(game_path)
      base = File.expand_path(game_path.to_s)
      return base if base.end_with?('.app') && File.directory?(base)
      candidates = [
        File.join(base, 'Project Zomboid.app'),
        File.join(base, 'osx', 'Project Zomboid.app')
      ]
      app_dir = candidates.find { |d| File.directory?(d) }
      raise "Could not find app dir. Checked:\n#{candidates.map { |p| "  - #{p}" }.join("\n")}" unless app_dir
      app_dir
    end

    # macOS: JAVA_HOME from app's bundled JRE (prefer arch-matched, then zulu)
    def mac_java_home(app_dir)
      jre_candidates = [
        File.join(app_dir, 'Contents', 'PlugIns', "jre-#{ARCH}", 'Contents', 'Home'),
        File.join(app_dir, 'Contents', 'PlugIns', 'zulu-17.jre', 'Contents', 'Home')
      ]
      jre_candidates.find { |d| File.directory?(d) }
    end

    # macOS: GAME_ROOT = app_dir/Contents/Java
    def mac_game_root(app_dir)
      File.join(app_dir, 'Contents', 'Java')
    end

    def mac?
      RUBY_PLATFORM.include?('darwin')
    end

    def windows?
      RUBY_PLATFORM.include?('mingw') || RUBY_PLATFORM.include?('mswin')
    end
  end
end
