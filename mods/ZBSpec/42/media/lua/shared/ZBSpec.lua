-- ZBSpec: Mini test framework for Project Zomboid mods
-- Provides busted-like syntax: describe, it, assert
-- Supports both client and server contexts

ZBSpec = ZBSpec or {}

local tests = {}
local skipped = {}
local errors = {}
local currentDescribe = ""
local skipCurrentBlock = false
local skipReason = nil

-- Context detection
function ZBSpec.isClient()
    return isClient and isClient()
end

function ZBSpec.isServer()
    return isServer and isServer()
end

function ZBSpec.isMultiplayer()
    return ZBSpec.isClient() or ZBSpec.isServer()
end

function ZBSpec.isSingleplayer()
    return not ZBSpec.isMultiplayer()
end

function ZBSpec.hasPlayer()
    return getPlayer and getPlayer() ~= nil
end

function ZBSpec.getContext()
    if ZBSpec.isServer() then
        return "server"
    elseif ZBSpec.isClient() then
        return "client"
    else
        return "singleplayer"
    end
end

-- Core test functions
function ZBSpec.describe(name, fn)
    local prevDescribe = currentDescribe
    local prevSkip = skipCurrentBlock
    local prevReason = skipReason
    
    currentDescribe = currentDescribe ~= "" and (currentDescribe .. " " .. name) or name
    fn()
    
    currentDescribe = prevDescribe
    skipCurrentBlock = prevSkip
    skipReason = prevReason
end

function ZBSpec.it(name, fn)
    local fullName = currentDescribe ~= "" and (currentDescribe .. " " .. name) or name
    
    if skipCurrentBlock then
        table.insert(skipped, { name = fullName, reason = skipReason })
    else
        table.insert(tests, { name = fullName, fn = fn })
    end
end

function ZBSpec.context(name, fn)
    ZBSpec.describe(name, fn)
end

function ZBSpec.test(name, fn)
    ZBSpec.it(name, fn)
end

-- Skip helpers
function ZBSpec.skip(reason)
    skipCurrentBlock = true
    skipReason = reason or "skipped"
end

function ZBSpec.pending(name, fn)
    local fullName = currentDescribe ~= "" and (currentDescribe .. " " .. name) or name
    table.insert(skipped, { name = fullName, reason = "pending" })
end

-- Helper to create context-specific describe
local function makeContextDescribe(shouldSkip, skipReasonFn)
    return function(name, fn)
        if shouldSkip() then
            local prevSkip = skipCurrentBlock
            local prevReason = skipReason
            skipCurrentBlock = true
            skipReason = skipReasonFn()
            ZBSpec.describe(name, fn)
            skipCurrentBlock = prevSkip
            skipReason = prevReason
        else
            ZBSpec.describe(name, fn)
        end
    end
end

-- Context-specific namespaces
ZBSpec.client = {
    describe = makeContextDescribe(
        function() return ZBSpec.isServer() end,
        function() return "client only (running on server)" end
    )
}

ZBSpec.server = {
    describe = makeContextDescribe(
        function() return ZBSpec.isClient() or ZBSpec.isSingleplayer() end,
        function() return "server only (running on " .. ZBSpec.getContext() .. ")" end
    )
}

ZBSpec.player = {
    describe = makeContextDescribe(
        function() return not ZBSpec.hasPlayer() end,
        function() return "requires player (no player available)" end
    )
}

ZBSpec.sp = {
    describe = makeContextDescribe(
        function() return ZBSpec.isMultiplayer() end,
        function() return "singleplayer only (running in multiplayer)" end
    )
}

ZBSpec.mp = {
    describe = makeContextDescribe(
        function() return ZBSpec.isSingleplayer() end,
        function() return "multiplayer only (running in singleplayer)" end
    )
}

-- Assertions
ZBSpec.assert = {}

function ZBSpec.assert.is_equal(expected, actual)
    if expected ~= actual then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

function ZBSpec.assert.equals(expected, actual)
    ZBSpec.assert.is_equal(expected, actual)
end

function ZBSpec.assert.is_true(value, msg)
    if not value then
        error(msg or "expected true, got false", 2)
    end
end

function ZBSpec.assert.is_false(value, msg)
    if value then
        error(msg or "expected false, got true", 2)
    end
end

function ZBSpec.assert.is_nil(value)
    if value ~= nil then
        error(string.format("expected nil, got %s", tostring(value)), 2)
    end
end

function ZBSpec.assert.is_not_nil(value)
    if value == nil then
        error("expected non-nil value", 2)
    end
end

function ZBSpec.assert.is_table(value)
    if type(value) ~= "table" then
        error(string.format("expected table, got %s", type(value)), 2)
    end
end

function ZBSpec.assert.is_number(value)
    if type(value) ~= "number" then
        error(string.format("expected number, got %s", type(value)), 2)
    end
end

function ZBSpec.assert.is_string(value)
    if type(value) ~= "string" then
        error(string.format("expected string, got %s", type(value)), 2)
    end
end

function ZBSpec.assert.is_function(value)
    if type(value) ~= "function" then
        error(string.format("expected function, got %s", type(value)), 2)
    end
end

function ZBSpec.assert.is_boolean(value)
    if type(value) ~= "boolean" then
        error(string.format("expected boolean, got %s", type(value)), 2)
    end
end

function ZBSpec.assert.greater_than(threshold, actual)
    if not (actual > threshold) then
        error(string.format("expected %s > %s", tostring(actual), tostring(threshold)), 2)
    end
end

function ZBSpec.assert.less_than(threshold, actual)
    if not (actual < threshold) then
        error(string.format("expected %s < %s", tostring(actual), tostring(threshold)), 2)
    end
end

function ZBSpec.assert.matches(pattern, str)
    if type(str) ~= "string" then
        error(string.format("expected string, got %s", type(str)), 2)
    end
    if not string.match(str, pattern) then
        error(string.format("'%s' does not match pattern '%s'", str, pattern), 2)
    end
end

function ZBSpec.assert.contains(needle, haystack)
    if type(haystack) == "string" then
        if not string.find(haystack, needle, 1, true) then
            error(string.format("'%s' does not contain '%s'", haystack, needle), 2)
        end
    elseif type(haystack) == "table" then
        for _, v in pairs(haystack) do
            if v == needle then return end
        end
        error(string.format("table does not contain %s", tostring(needle)), 2)
    else
        error(string.format("expected string or table, got %s", type(haystack)), 2)
    end
end

function ZBSpec.assert.has_key(key, tbl)
    if type(tbl) ~= "table" then
        error(string.format("expected table, got %s", type(tbl)), 2)
    end
    if tbl[key] == nil then
        error(string.format("table does not have key '%s'", tostring(key)), 2)
    end
end

function ZBSpec.assert.throws(fn, expected_msg)
    local ok, err = pcall(fn)
    if ok then
        error("expected function to throw, but it did not", 2)
    end
    if expected_msg and not string.find(tostring(err), expected_msg, 1, true) then
        error(string.format("expected error containing '%s', got '%s'", expected_msg, tostring(err)), 2)
    end
end

-- Current test being run (for error context)
ZBSpec.currentTest = nil

-- Run all tests - no pcall, errors propagate with full info
function ZBSpec.run()
    local testList = tests
    tests = {}
    skipped = {}
    
    for _, t in ipairs(testList) do
        ZBSpec.currentTest = t.name
        t.fn()  -- Let errors propagate naturally
    end
    
    ZBSpec.currentTest = nil
    return true
end

-- Get detailed results (for advanced reporting)
function ZBSpec.runDetailed()
    errors = {}
    local passed = 0
    local failed = 0
    
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            table.insert(errors, { name = t.name, error = tostring(err) })
        end
    end
    
    local result = {
        passed = passed,
        failed = failed,
        skipped = #skipped,
        context = ZBSpec.getContext(),
        errors = errors,
        skipped_tests = skipped
    }
    
    -- Reset for next run
    tests = {}
    skipped = {}
    
    return result
end

-- Reset state (useful between spec files)
function ZBSpec.reset()
    tests = {}
    skipped = {}
    errors = {}
    currentDescribe = ""
    skipCurrentBlock = false
    skipReason = nil
end

-- Global aliases for convenience
describe = ZBSpec.describe
context = ZBSpec.context
it = ZBSpec.it
test = ZBSpec.test
assert = ZBSpec.assert
pending = ZBSpec.pending

return ZBSpec
