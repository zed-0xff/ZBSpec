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
described_class = nil       -- The class/table passed to describe(), if not a string


function ZBSpec.getContext()
    if isServer and isServer() then return "server"
    elseif isClient and isClient() then return "client"
    else return "sp" end
end

-- Core test functions
function ZBSpec.describe(name, fn)
    local prevDescribe = currentDescribe
    local prevSkip = skipCurrentBlock
    local prevReason = skipReason
    local prevDescribedClass = described_class
    
    -- If name is not a string, it's the class itself
    if type(name) ~= "string" then
        described_class = name
        name = tostring(name)
    end
    -- Keep parent's described_class for nested string describes
    
    currentDescribe = currentDescribe ~= "" and (currentDescribe .. " " .. tostring(name)) or tostring(name)
    
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
    described_class = prevDescribedClass
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

-- Wait for condition to be true (or false if invert); yields between polls. Timeout 10s.
local function _wait_until(condition, invert, timeout_sec, ...)
    local args = { ... }
    local unpack = table.unpack or unpack
    timeout_sec = timeout_sec or 10
    local deadline = os.time() + timeout_sec
    while (condition(unpack(args)) == invert) do
        if os.time() >= deadline then
            error(string.format("Timeout after %ds waiting for condition", timeout_sec), 2)
        end
        coroutine.yield("pending")
    end
end
function ZBSpec.wait_for(condition, ...)
    _wait_until(condition, false, 10, ...)
end
function ZBSpec.wait_for_not(condition, ...)
    _wait_until(condition, true, 10, ...)
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

function ZBSpec.sleep(seconds)
    local start = os.time()
    while os.time() - start < seconds do
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
        ZBSpec_currentTest = t.name
        described_class = t.described_class
        local testOk, testErr = ZBSpec.run_before_hooks(t, ranBeforeAll, run_with_yield)
        if testOk then
            testOk, testErr = run_with_yield(t.fn)
        end
        
        if testOk then
            results.passed = results.passed + 1
        else
            results.failed = results.failed + 1
            table.insert(results.errors, { name = t.name, error = tostring(testErr or "unknown") })
        end
    end
    
    ZBSpec_currentTest = nil
    described_class = nil
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

function ZBSpec.poll(jobId)
    local job = pendingJobs[jobId]
    if not job then
        return { status = "error", error = "Unknown job: " .. tostring(jobId) }
    end
    if job.status ~= "pending" then
        local r = { status = job.status }
        if job.result then r.result = job.result end
        if job.error then r.error = job.error end
        pendingJobs[jobId] = nil
        return r
    end
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
    local r = { status = job.status }
    if job.result then r.result = job.result end
    if job.error then r.error = job.error end
    if job.status ~= "pending" then pendingJobs[jobId] = nil end
    return r
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
    local fullName = currentDescribe ~= "" and (currentDescribe .. " " .. tostring(name)) or tostring(name)
    
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
            describe = currentDescribe,
            described_class = described_class
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
    local fullName = currentDescribe ~= "" and (currentDescribe .. " " .. tostring(name)) or tostring(name)
    table.insert(skipped, { name = fullName, reason = "pending" })
end

-- Assertions (minimal busted-like: assert(cond, msg), assert.are.equal, assert.is_*, assert.throws)
ZBSpec.assert = {}
local function fail(msg) error(msg or "assertion failed", 2) end
local function assert_type(val, want)
    if type(val) ~= want then fail(string.format("expected %s, got %s", want, type(val))) end
end

setmetatable(ZBSpec.assert, {
    __call = function(_, condition, message) if not condition then fail(message) end end
})

function ZBSpec.assert.eq(expected, actual)
    if expected ~= actual then fail(string.format("expected %s, got %s", tostring(expected), tostring(actual))) end
end
function ZBSpec.assert.is_true(value, msg) if not value then fail(msg or "expected true, got false") end end
function ZBSpec.assert.is_false(value, msg) if value then fail(msg or "expected false, got true") end end
function ZBSpec.assert.is_nil(value) if value ~= nil then fail(string.format("expected nil, got %s", tostring(value))) end end
function ZBSpec.assert.is_not_nil(value) if value == nil then fail("expected non-nil value") end end

function ZBSpec.assert.is_string(v) assert_type(v, "string") end
function ZBSpec.assert.is_number(v) assert_type(v, "number") end
function ZBSpec.assert.is_table(v) assert_type(v, "table") end
function ZBSpec.assert.is_function(v) assert_type(v, "function") end
function ZBSpec.assert.is_boolean(v) assert_type(v, "boolean") end

function ZBSpec.assert.gt(actual, threshold) if not (actual > threshold) then fail(string.format("expected %s > %s", tostring(actual), tostring(threshold))) end end
function ZBSpec.assert.lt(actual, threshold) if not (actual < threshold) then fail(string.format("expected %s < %s", tostring(actual), tostring(threshold))) end end

function ZBSpec.assert.matches(pattern, str)
    assert_type(str, "string")
    if not string.match(str, pattern) then fail(string.format("'%s' does not match '%s'", str, pattern)) end
end

function ZBSpec.assert.contains(needle, haystack)
    if type(haystack) == "string" then
        if not string.find(haystack, needle, 1, true) then fail(string.format("'%s' does not contain '%s'", haystack, needle)) end
    elseif type(haystack) == "table" then
        for _, v in pairs(haystack) do if v == needle then return end end
        fail(string.format("table does not contain %s", tostring(needle)))
    else fail(string.format("expected string or table, got %s", type(haystack))) end
end

function ZBSpec.assert.has_key(key, tbl)
    assert_type(tbl, "table")
    if tbl[key] == nil then fail(string.format("table does not have key '%s'", tostring(key))) end
end

function ZBSpec.assert.throws(fn, expected_msg)
    local ok, err = pcall(fn)
    if ok then fail("expected function to throw, but it did not") end
    if expected_msg and not string.find(tostring(err), expected_msg, 1, true) then
        fail(string.format("expected error containing '%s', got '%s'", expected_msg, tostring(err)))
    end
end

-- Current test name; set before each test so ZombieBuddy HTTP error response can include it (X-ZombieBuddy-Error-Globals: ZBSpec_currentTest)
ZBSpec_currentTest = nil

-- Run before_all (once per describe) and before_each for test t; mutates ranBeforeAll. Optional runner(fn) returns ok, err (if absent, fn is called directly).
function ZBSpec.run_before_hooks(t, ranBeforeAll, runner)
    local function run(fn)
        if runner then return runner(fn) else fn(); return true end
    end
    if t.before_all and t.describe and not ranBeforeAll[t.describe] then
        ranBeforeAll[t.describe] = true
        for _, hook in ipairs(t.before_all) do
            local ok, err = run(hook); if not ok then return false, err end
        end
    end
    if t.before_each then
        for _, hook in ipairs(t.before_each) do
            local ok, err = run(hook); if not ok then return false, err end
        end
    end
    return true
end

function ZBSpec.run()
    local testList = tests
    tests = {}
    skipped = {}
    local ranBeforeAll = {}
    for _, t in ipairs(testList) do
        ZBSpec_currentTest = t.name
        described_class = t.described_class
        ZBSpec.run_before_hooks(t, ranBeforeAll, nil)
        t.fn()
    end
    ZBSpec_currentTest = nil
    described_class = nil
    return true
end

function ZBSpec.runDetailed()
    errors = {}
    local passed, failed = 0, 0
    local ranBeforeAll = {}
    for _, t in ipairs(tests) do
        described_class = t.described_class
        ZBSpec_currentTest = t.name
        local ok, err = pcall(function()
            ZBSpec.run_before_hooks(t, ranBeforeAll, nil)
            t.fn()
        end)
        if ok then passed = passed + 1
        else failed = failed + 1; table.insert(errors, { name = t.name, error = tostring(err) }) end
        ZBSpec_currentTest = nil
    end
    described_class = nil
    local result = { passed = passed, failed = failed, skipped = #skipped, context = ZBSpec.getContext(), errors = errors, skipped_tests = skipped }
    tests = {}
    skipped = {}
    return result
end

function ZBSpec.reset()
    tests = {}
    skipped = {}
    errors = {}
    currentDescribe = ""
    skipCurrentBlock = false
    skipReason = nil
    beforeEachStack = {}
    beforeAllStack = {}
end

---------------------------------------------
-- Remote execution (client -> server)
---------------------------------------------
local MODULE_NAME = "ZBSpec"
local evalResults = {}
local evalIdCounter = 0

-- Execute code on server, fire and forget (no return value)
function ZBSpec.server_exec(code)
    if not isClient() then
        -- On server/SP, just execute locally
        local fn, err = loadstring(code)
        if fn then
            fn()
        else
            error("server_exec compile error: " .. tostring(err))
        end
        return
    end
    
    sendClientCommand(MODULE_NAME, "exec", { code = code })
end

-- Execute code on server and wait for result (yields)
function ZBSpec.server_eval(code)
    if not isClient() then
        -- On server/SP, just execute locally
        local fn, err = loadstring(code)
        if fn then
            return fn()
        else
            error("server_eval compile error: " .. tostring(err))
        end
    end
    
    -- Generate unique ID for this request
    evalIdCounter = evalIdCounter + 1
    local id = evalIdCounter
    
    -- Send request
    sendClientCommand(MODULE_NAME, "eval", { code = code, id = id })
    
    -- Wait for response
    ZBSpec.wait_for(function()
        return evalResults[id] ~= nil
    end)
    
    -- Get and clear result
    local result = evalResults[id]
    evalResults[id] = nil
    
    if result.success then
        return result.value
    else
        error("server_eval error: " .. tostring(result.error))
    end
end

-- Execute code on both client and server
function ZBSpec.all_exec(code)
    -- Execute locally
    local fn, err = loadstring(code)
    if fn then
        fn()
    else
        error("all_exec compile error: " .. tostring(err))
    end
    
    -- Also send to server if we're a client
    if isClient and isClient() then
        sendClientCommand(MODULE_NAME, "exec", { code = code })
    end
end

-- Handle eval results from server
if isClient and isClient() then
    Events.OnServerCommand.Add(function(module, command, args)
        if module == MODULE_NAME and command == "eval_result" then
            evalResults[args.id] = args
        end
    end)
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
sleep = ZBSpec.sleep
-- Remote execution
server_exec = ZBSpec.server_exec
server_eval = ZBSpec.server_eval
all_exec = ZBSpec.all_exec

return ZBSpec
