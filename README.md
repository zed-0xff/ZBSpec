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
api_port: 4445
startup_timeout: 120
use_running_game: true
spec_glob: spec/**/*_spec.lua

mods:
  - YourModName
```

### 2. Write a spec

Create `spec/example_spec.lua`:

```lua
require "ZBSpec"

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
require "ZBSpec"

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
assert.equals(expected, actual)  -- alias
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
require "ZBSpec"
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

## Configuration

Full `zbspec.yml` options:

```yaml
# API port (ZombieBuddy)
api_port: 4445

# Timeout for game startup (seconds)
startup_timeout: 120

# Use already-running game instead of launching
use_running_game: true

# Auto-shutdown game after specs
auto_shutdown: false

# Path to PZ (for auto-launch on macOS)
game_path: /Applications/Project Zomboid.app

# Launch as server
server_mode: false

# Enable debug mode
debug: true

# Spec file pattern
spec_glob: spec/**/*_spec.lua

# Mods to load (ZombieBuddy and ZBSpec added automatically)
mods:
  - YourModName
```

## CLI Options

```
Usage: zbspec [options] [spec_files...]

    -c, --config PATH    Path to config file (default: spec/zbspec.yml)
    -m, --mod-dir PATH   Path to mod directory
    -v, --verbose        Show verbose output (including health checks)
    -h, --help           Show help
        --version        Show version
```

## Example Output

```
🚀 PZ Spec Harness Starting
==================================================
✓ Using already-running game
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
