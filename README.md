# ZBSpec

A testing framework for Project Zomboid mods. Write specs in Lua with familiar `describe`/`it`/`assert` syntax, run them inside the actual game.

## Features

- **BDD-style syntax** - `describe`, `it`, `context` blocks
- **Rich assertions** - type checks, comparisons, pattern matching
- **In-game execution** - tests run in the actual PZ environment
- **Auto-discovery** - finds `*_spec.lua` files automatically
- **Log capture** - shows relevant game logs on test failure
- **CI-friendly** - exit codes and structured output

## Requirements

- Ruby 2.7+
- Project Zomboid
- [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) mod (provides the Lua API)

## Installation

1. Clone or copy ZBSpec to your mods folder:
   ```
   mods/ZBSpec/
   ```

2. Add ZBSpec to your mod's dependencies (or enable both mods)

## Quick Start

### 1. Create config file

Create `spec/zbspec.yml` in your mod directory:

```yaml
startup_timeout: 120
spec_glob: spec/**/*_spec.lua

mods:
  - YourModName
```

### 2. Write a spec

Create `spec/example_spec.lua`:

```lua
describe("my feature", function()
    it("works correctly", function()
        assert.is_equal(4, 2 + 2)
    end)
    
    it("handles nil", function()
        assert.is_nil(nil)
        assert.is_not_nil("hello")
    end)
end)

return ZBSpec.run()
```

### 3. Run specs

```bash
# From your mod directory
zbspec

# Or specify files
zbspec spec/my_spec.lua

# With verbose output (shows health checks)
zbspec -v
```

## Writing Specs

### Structure

```lua
-- Optional: require your mod's files
require "MyMod_Data"

describe("ModuleName", function()
    describe("nested context", function()
        it("does something", function()
            -- assertions here
        end)
    end)
end)

-- IMPORTANT: Always end with this
return ZBSpec.run()
```

### Assertions

#### Equality
```lua
assert.is_equal(expected, actual)
```

#### Boolean
```lua
assert.is_true(value)
assert.is_true(value, "custom message")
assert.is_false(value)
```

#### Nil checks
```lua
assert.is_nil(value)
assert.is_not_nil(value)
```

#### Type checks
```lua
assert.is_table(value)
assert.is_number(value)
assert.is_string(value)
assert.is_function(value)
assert.is_boolean(value)
```

#### Comparisons
```lua
assert.greater_than(threshold, actual)  -- actual > threshold
assert.less_than(threshold, actual)     -- actual < threshold
```

#### String/Table
```lua
assert.matches("^Base%.", itemType)           -- Lua pattern
assert.contains("needle", "haystackneedle")   -- substring
assert.contains("value", {"value", "other"})  -- table contains
assert.has_key("key", {key = "value"})        -- table has key
```

#### Errors
```lua
assert.throws(function()
    error("boom")
end)

assert.throws(function()
    error("specific error")
end, "specific")  -- error must contain this string
```

### Testing with Game State

```lua
require "MyMod"

local player = getPlayer()
if not player then
    return "getPlayer() returned nil - player not loaded"
end

describe("inventory", function()
    it("can create items", function()
        local item = instanceItem("Base.Axe")
        assert.is_not_nil(item)
    end)
    
    it("tracks player data", function()
        player:getModData().testValue = 42
        assert.is_equal(42, player:getModData().testValue)
    end)
end)

return ZBSpec.run()
```

### Client/Server Support

ZBSpec supports running the same spec files in singleplayer, multiplayer client, and server contexts. Use context-specific describe blocks to write tests that work everywhere.

#### Pending Tests

Mark tests as pending (not implemented yet):

```lua
pending("future feature", function()
    -- This won't run, just recorded as pending
end)
```

## Configuration

Full `zbspec.yml` options:

```yaml
# Timeout for game startup (seconds)
startup_timeout: 120

# Shutdown game after specs: never | always | auto (only when all specs pass)
shutdown: auto

# Path to PZ (for auto-launch on macOS)
game_path: /Applications/Project Zomboid.app

# Root dir for versioned game configs (default: ~/projects/zomboid/versions)
game_versions_root: "~/projects/zomboid/versions"

# Version names (subdirs under game_versions_root); first is default
game_versions:
  - 41
  - 42.12
  - 42.13
  - unstable

# Enable debug mode
debug: true

# Spec file pattern
spec_glob: spec/**/*_spec.lua

# Mods to load (ZombieBuddy and ZBSpec added automatically)
mods:
  - YourModName

# Multiplayer settings (for --mp and --client modes)
server_name: ZBSpecServer
server_ip: 127.0.0.1
server_port: 16261
username: ZBSpecPlayer
password: ""
```

### Launch overrides

The built-in launcher works out of the box, but every value it hard-codes can be
overridden, so a hand-written start script (custom `.bat`/`.sh`) can be replaced
by configuration. All keys are optional and default to the built-in behavior.

```yaml
# Dedicated-server install used in server mode (defaults to game_path)
server_path: "~/path/to/Project Zomboid Dedicated Server"

steam: false          # true => -Dzomboid.steam=1 (and no -nosteam)
debug_jvm: false      # true => also pass -Ddebug=1 (the custom .bat style)
headless:             # -Djava.awt.headless; default: true for server, false for client

jvm_args: ["-Xms4g", "-Xmx4g"]                  # extra JVM args
server_args: ["-servername", "MyServer", "-statistic", "0"]
client_args: []                                  # extra client args
env: { "SOME_VAR": "value" }                     # extra environment variables
main_class: "zombie.network.GameServer"          # override main class
classpath: ["java/.", "java/projectzomboid.jar"] # override classpath
natives_dir: "linux64"                            # native dir relative to install
```

For full control, `launch_command` replaces the internal argv entirely. The
placeholders below are expanded before launch (unknown ones are left as-is, so
typos show up in the logged command):

| Placeholder | Value |
| ----------- | ----- |
| `${JAVA}` | bundled JVM (`jre64/bin/java`) |
| `${GAME}` | install working dir |
| `${CACHEDIR}` | per-instance cache dir |
| `${SERVERNAME}` / `${ADMINPASSWORD}` / `${PORT}` | server values |
| `${AGENT}` | ZombieBuddy `-javaagent` (required for tests) |

```yaml
launch_command:
  - "${JAVA}"
  - "-Djava.awt.headless=true"
  - "-Dzomboid.steam=0"
  - "${AGENT}"
  - "-classpath"
  - "java/.:java/projectzomboid.jar"
  - "zombie/network/GameServer"
  - "-cachedir=${CACHEDIR}"
  - "${SERVERNAME}"
  - "-nosteam"
```

Alternatively, `launcher` runs a wrapper script/binary in the install dir
(relative paths resolve there; `.bat`/`.cmd` are wrapped in `cmd /c` on Windows)
and passes `server_args`/`client_args`:

```yaml
launcher: "start-server-nosteam-custom.sh"
```


## Spec Folder Structure

Organize specs by where they should run:

```
spec/
├── zbspec.yml           # Config file
├── data_spec.lua        # Root specs (shared, run everywhere)
├── client/
│   └── ui_spec.lua      # Client-only specs (also run in SP)
├── server/
│   └── commands_spec.lua # Server-only specs
└── shared/
    └── sync_spec.lua    # Shared specs (run on both)
```

- **`spec/client/`** - Client-only specs (also run in singleplayer)
- **`spec/server/`** - Server-only specs (dedicated server)
- **`spec/shared/`** - Shared specs (run on both client and server)
- **`spec/*_spec.lua`** - Root specs (treated as shared)

## CLI Options

```
Usage: zbspec [options] [spec_files...]

    -c, --config PATH    Path to config file (default: spec/zbspec.yml)
    -m, --mod-dir PATH   Path to mod directory
    -v, --verbose        Show verbose output (including health checks)
        --sp             Force singleplayer mode
        --server         Run specs on dedicated server only
        --client         Run specs on MP client only (server must be running)
        --mp             Run specs on both server and client
    -h, --help           Show help
        --version        Show version
```

### Auto-Detection

By default, ZBSpec auto-detects the run mode based on spec folders:

- If `spec/server/` contains specs → runs in MP mode
- If only `spec/client/` or root specs → runs in SP mode

```bash
zbspec              # Auto-detect mode from spec folders
zbspec --sp         # Force singleplayer
zbspec --mp         # Force multiplayer (server + client)
zbspec --server     # Server specs only
zbspec --client     # Client specs only (server must be running)
```

## Example Output

```
🚀 PZ Spec Harness Starting
==================================================
✓ API ready

🧪 Running Spec Suite
==================================================

Lua Specs:
  ✓ spec/data_spec.lua
  ✓ spec/specimen_spec.lua
  ✗ spec/broken_spec.lua
    Error: Spec returned: "MyFeature does something: expected 5, got 3"

    Log during test:
      LOG: General > MyMod loaded
      ERROR: General > Something went wrong

==================================================
Passed: 2
Failed: 1
```

## Tips

1. **Early returns for missing state** - Check `getPlayer()` and return error string if nil
2. **Clean up test data** - Reset `modData` after tests that modify it
3. **Use descriptive names** - Test names appear in failure output
4. **One assertion per concept** - Makes failures easier to diagnose

## Example Projects

- [ZScienceSkill](https://github.com/zed-0xff/ZScienceSkill) - A full mod with ZBSpec tests (`spec/` directory)

## Related Projects

- [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) - Java modding framework for PZ (provides the Lua API that ZBSpec uses)

## Support

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/zed_0xff)

## License

MIT
