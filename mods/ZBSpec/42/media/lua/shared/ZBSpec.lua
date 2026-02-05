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
local beforeEachStack = {}  -- Stack of before_each functions for nested describes
local beforeAllStack = {}   -- Stack of before_all functions for nested describes
local beforeAllRan = {}     -- Track which describe blocks have run their before_all


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
    
    -- Push new scope for before_each and before_all
    table.insert(beforeEachStack, {})
    table.insert(beforeAllStack, {})
    
    fn()
    
    -- Pop the scopes
    table.remove(beforeEachStack)
    table.remove(beforeAllStack)
    
    currentDescribe = prevDescribe
    skipCurrentBlock = prevSkip
    skipReason = prevReason
end

function ZBSpec.before_each(fn)
    if #beforeEachStack > 0 then
        table.insert(beforeEachStack[#beforeEachStack], fn)
    end
end

function ZBSpec.before_all(fn)
    if #beforeAllStack > 0 then
        table.insert(beforeAllStack[#beforeAllStack], fn)
    end
end

-- Async support (requires ?raw=1 on HTTP calls to allow yielding)
local pendingJobs = {}
local jobCounter = 0

-- Wait for a condition to be true, yielding between polls
-- Each yield returns control to Java; next poll resumes here
-- Supports optional args for condition; timeout uses default
function ZBSpec.wait_for(condition, ...)
    local args = { ... }
    local unpackArgs = table.unpack or unpack
    local timeout = 10
    local startTime = os.time()
    
    while not condition(unpackArgs(args)) do
        local now = os.time()
        if now - startTime > timeout then
            error(string.format("Timeout after %ds waiting for condition", timeout), 2)
        end
        coroutine.yield("pending")
    end
end

-- Wait for a condition to be false, yielding between polls
-- Supports optional args for condition; timeout uses default
function ZBSpec.wait_for_not(condition, ...)
    local args = { ... }
    local unpackArgs = table.unpack or unpack
    local timeout = 10
    local startTime = os.time()
    
    while condition(unpackArgs(args)) do
        local now = os.time()
        if now - startTime > timeout then
            error(string.format("Timeout after %ds waiting for condition", timeout), 2)
        end
        coroutine.yield("pending")
    end
end

-- Wait for a method on an object to return true
-- Usage: wait_for_this(obj, "methodName", ...)
function ZBSpec.wait_for_this(obj, method, ...)
    if obj == nil then
        error("wait_for_this: object is nil", 2)
    end
    local fn = obj[method]
    if type(fn) ~= "function" then
        error("wait_for_this: method is not a function: " .. tostring(method), 2)
    end
    return ZBSpec.wait_for(function(...)
        return fn(obj, ...)
    end, ...)
end

-- Aliases for backward compatibility
ZBSpec.wait_until = ZBSpec.wait_for
ZBSpec.wait_until_not = ZBSpec.wait_for_not
ZBSpec.wait_until_this = ZBSpec.wait_for_this

-- Sleep for N seconds (yields between polls)
function ZBSpec.sleep(seconds)
    local startTime = os.time()
    local target = startTime + seconds
    
    while true do
        local now = os.time()
        if now >= target then
            return
        end
        coroutine.yield("pending")
    end
end

-- Run tests with async support (no pcall - uses nested coroutines instead)
function ZBSpec.runDetailedAsync()
    local results = {
        passed = 0,
        failed = 0,
        skipped = #skipped,
        context = ZBSpec.getContext(),
        errors = {},
        skipped_tests = skipped
    }
    
    local testList = tests
    tests = {}
    local skippedList = skipped
    skipped = {}
    results.skipped_tests = skippedList
    
    local function run_with_yield(fn)
        local co = coroutine.create(fn)
        while true do
            local ok, err = coroutine.resume(co)
            if not ok then
                return false, tostring(err)
            end
            if coroutine.status(co) == "dead" then
                return true
            end
            coroutine.yield("pending")
        end
    end

    -- Track which describe blocks have run their before_all
    local ranBeforeAll = {}
    
    for _, t in ipairs(testList) do
        ZBSpec.currentTest = t.name
        local testOk = true
        local testErr = nil
        
        -- Run before_all hooks once per describe block (can yield)
        if t.before_all and t.describe and not ranBeforeAll[t.describe] then
            ranBeforeAll[t.describe] = true
            for _, hook in ipairs(t.before_all) do
                local ok, err = run_with_yield(hook)
                if not ok then
                    testOk = false
                    testErr = tostring(err)
                    break
                end
            end
        end
        
        -- Run before_each hooks (can yield)
        if testOk and t.before_each then
            for _, hook in ipairs(t.before_each) do
                local ok, err = run_with_yield(hook)
                if not ok then
                    testOk = false
                    testErr = tostring(err)
                    break
                end
            end
        end
        
        -- Run test in its own coroutine to catch errors via resume
        if testOk then
            local ok, err = run_with_yield(t.fn)
            if not ok then
                testOk = false
                testErr = tostring(err)
            end
        end
        
        if testOk then
            results.passed = results.passed + 1
        else
            results.failed = results.failed + 1
            table.insert(results.errors, { name = t.name, error = testErr })
        end
    end
    
    ZBSpec.currentTest = nil
    results.skipped = #skippedList
    return results
end

-- Start an async spec run, returns job ID
function ZBSpec.runAsync()
    jobCounter = jobCounter + 1
    local jobId = "job_" .. jobCounter
    
    local job = {
        status = "pending",
        result = nil,
        error = nil
    }
    
    job.coroutine = coroutine.create(function()
        local results = ZBSpec.runDetailedAsync()
        job.result = results
        return results
    end)
    
    pendingJobs[jobId] = job
    
    -- First resume to start the coroutine
    local ok, result = coroutine.resume(job.coroutine)
    if not ok then
        job.status = "error"
        job.error = tostring(result)
    elseif coroutine.status(job.coroutine) == "dead" then
        job.status = "completed"
    end
    
    return jobId
end

-- Poll a job, resuming the coroutine once
-- Returns: { status = "pending|completed|error", result = ..., error = ... }
function ZBSpec.poll(jobId)
    local job = pendingJobs[jobId]
    if not job then
        return { status = "error", error = "Unknown job: " .. tostring(jobId) }
    end
    
    -- Already done?
    if job.status ~= "pending" then
        local result = { status = job.status }
        if job.result then result.result = job.result end
        if job.error then result.error = job.error end
        if job.status ~= "pending" then
            pendingJobs[jobId] = nil  -- cleanup
        end
        return result
    end
    
    -- Resume coroutine once
    local co = job.coroutine
    if coroutine.status(co) == "suspended" then
        local ok, result = coroutine.resume(co)
        if not ok then
            job.status = "error"
            job.error = tostring(result)
        elseif coroutine.status(co) == "dead" then
            job.status = "completed"
        end
    elseif coroutine.status(co) == "dead" then
        job.status = "completed"
    end
    
    local response = { status = job.status }
    if job.result then response.result = job.result end
    if job.error then response.error = job.error end
    if job.status ~= "pending" then
        pendingJobs[jobId] = nil  -- cleanup
    end
    return response
end

-- Cancel all pending async jobs (useful before interactive mode)
function ZBSpec.cancelAllJobs()
    local count = 0
    for jobId in pairs(pendingJobs) do
        pendingJobs[jobId] = nil
        count = count + 1
    end
    return count
end

function ZBSpec.it(name, fn)
    local fullName = currentDescribe ~= "" and (currentDescribe .. " " .. name) or name
    
    if skipCurrentBlock then
        table.insert(skipped, { name = fullName, reason = skipReason })
    else
        -- Capture all current before_each functions (flattened)
        local beforeEachHooks = {}
        for _, scope in ipairs(beforeEachStack) do
            for _, hook in ipairs(scope) do
                table.insert(beforeEachHooks, hook)
            end
        end
        -- Capture all current before_all functions (flattened)
        local beforeAllHooks = {}
        for _, scope in ipairs(beforeAllStack) do
            for _, hook in ipairs(scope) do
                table.insert(beforeAllHooks, hook)
            end
        end
        table.insert(tests, {
            name = fullName,
            fn = fn,
            before_each = beforeEachHooks,
            before_all = beforeAllHooks,
            describe = currentDescribe
        })
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
    
    -- Track which describe blocks have run their before_all
    local ranBeforeAll = {}
    
    for _, t in ipairs(testList) do
        ZBSpec.currentTest = t.name
        -- Run before_all hooks once per describe block
        if t.before_all and t.describe and not ranBeforeAll[t.describe] then
            ranBeforeAll[t.describe] = true
            for _, hook in ipairs(t.before_all) do
                hook()
            end
        end
        -- Run before_each hooks
        if t.before_each then
            for _, hook in ipairs(t.before_each) do
                hook()
            end
        end
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
    
    -- Track which describe blocks have run their before_all
    local ranBeforeAll = {}
    
    for _, t in ipairs(tests) do
        local ok, err = pcall(function()
            -- Run before_all hooks once per describe block
            if t.before_all and t.describe and not ranBeforeAll[t.describe] then
                ranBeforeAll[t.describe] = true
                for _, hook in ipairs(t.before_all) do
                    hook()
                end
            end
            -- Run before_each hooks
            if t.before_each then
                for _, hook in ipairs(t.before_each) do
                    hook()
                end
            end
            t.fn()
        end)
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
    beforeEachStack = {}
    beforeAllStack = {}
    -- Don't reset pendingCoroutines or tickHandlerRegistered - those are persistent
end

-- Global aliases for convenience
describe = ZBSpec.describe
context = ZBSpec.context
it = ZBSpec.it
test = ZBSpec.test
assert = ZBSpec.assert
pending = ZBSpec.pending
before_all = ZBSpec.before_all
before_each = ZBSpec.before_each
wait_for = ZBSpec.wait_for
wait_for_not = ZBSpec.wait_for_not
wait_for_this = ZBSpec.wait_for_this
-- Backward compatibility aliases
wait_until = ZBSpec.wait_for
wait_until_not = ZBSpec.wait_for_not
wait_until_this = ZBSpec.wait_for_this
sleep = ZBSpec.sleep

return ZBSpec
