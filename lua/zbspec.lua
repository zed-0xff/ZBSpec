-- ZBSpec: Mini test framework for Project Zomboid mods
-- Only globals: ZBSpec, describe. it/assert/hooks exist only inside describe() scope via setfenv.

ZBSpec = ZBSpec or {}

-- Internal state (module scope)
local tests = {}
local skipped = {}
local errors = {}
local currentDescribe = ""
local skipCurrentBlock = false
local skipReason = nil
local beforeEachStack = {}
local beforeAllStack = {}
local afterAllStack = {}
local describePathStack = {}
local current_described_class = nil  -- set during _describe so it() can store it on test

-- Helpers (DRY)
local function flatten_scopes(stack)
    local out = {}
    for _, scope in ipairs(stack) do
        for _, hook in ipairs(scope) do table.insert(out, hook) end
    end
    return out
end
local function add_hook(stack, fn)
    if #stack > 0 then table.insert(stack[#stack], fn) end
end
local function with_runner(runner)
    return function(fn)
        if runner then return runner(fn) else fn(); return true end
    end
end

function ZBSpec.getContext()
    if isServer and isServer() then return "server"
    elseif isClient and isClient() then return "client"
    else return "sp" end
end

-- Internal: run a describe block (state push, fn(), state pop). Does not setfenv.
function ZBSpec._describe(name, fn)
    local prevDescribe = currentDescribe
    local prevSkip = skipCurrentBlock
    local prevReason = skipReason
    local prevDescribedClass = current_described_class

    local describedClass = name
    if type(name) ~= "string" then
        describedClass = name
        name = tostring(name)
    end
    current_described_class = describedClass

    currentDescribe = currentDescribe ~= "" and (currentDescribe .. " " .. tostring(name)) or tostring(name)
    table.insert(describePathStack, currentDescribe)
    for _, st in ipairs({ beforeEachStack, beforeAllStack, afterAllStack }) do
        table.insert(st, {})
    end
    fn()
    for _, st in ipairs({ beforeEachStack, beforeAllStack, afterAllStack }) do
        table.remove(st)
    end
    table.remove(describePathStack)

    currentDescribe = prevDescribe
    skipCurrentBlock = prevSkip
    skipReason = prevReason
    current_described_class = prevDescribedClass
end

-- Hooks (called from env inside describe)
function ZBSpec.before_each(fn) add_hook(beforeEachStack, fn) end
function ZBSpec.before_all(fn) add_hook(beforeAllStack, fn) end
function ZBSpec.after_all(fn) add_hook(afterAllStack, fn) end

-- Async support
local pendingJobs = {}
local jobCounter = 0

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
function ZBSpec.wait_for_this(obj, method, ...)
    if obj == nil then error("wait_for_this: object is nil", 2) end
    local fn = obj[method]
    if type(fn) ~= "function" then
        error("wait_for_this: method is not a function: " .. tostring(method), 2)
    end
    return ZBSpec.wait_for(function(...) return fn(obj, ...) end, ...)
end
function ZBSpec.sleep(seconds)
    local start = os.time()
    while os.time() - start < seconds do coroutine.yield("pending") end
end

-- Run tests (async)
function ZBSpec.runDetailedAsync()
    local results = {
        passed = 0,
        failed = 0,
        skipped = #skipped,
        context = ZBSpec.getContext(),
        errors = {},
        passed_tests = {},
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
            if not ok then return false, tostring(err) end
            if coroutine.status(co) == "dead" then return true end
            coroutine.yield("pending")
        end
    end
    local ranBeforeAll = {}
    for _, t in ipairs(testList) do
        ZBSpec_currentTest = t.name
        local testOk, testErr = ZBSpec.run_before_hooks(t, ranBeforeAll, run_with_yield)
        if testOk then testOk, testErr = run_with_yield(t.fn) end
        if testOk then
            results.passed = results.passed + 1
            table.insert(results.passed_tests, t.name)
        else
            results.failed = results.failed + 1
            table.insert(results.errors, { name = t.name, error = tostring(testErr or "unknown") })
        end
    end
    local afterOk, afterErr = ZBSpec.run_after_all_hooks(testList, run_with_yield)
    if not afterOk then
        results.failed = results.failed + 1
        table.insert(results.errors, { name = "after_all", error = tostring(afterErr or "unknown") })
    end
    ZBSpec_currentTest = nil
    results.skipped = #skippedList
    return results
end

function ZBSpec.runAsync()
    jobCounter = jobCounter + 1
    local jobId = "job_" .. jobCounter
    local job = { status = "pending", result = nil, error = nil }
    job.coroutine = coroutine.create(function()
        job.result = ZBSpec.runDetailedAsync()
        return job.result
    end)
    pendingJobs[jobId] = job
    local ok, result = coroutine.resume(job.coroutine)
    if not ok then job.status = "error"; job.error = tostring(result)
    elseif coroutine.status(job.coroutine) == "dead" then job.status = "completed" end
    return jobId
end

function ZBSpec.poll(jobId)
    local job = pendingJobs[jobId]
    if not job then return { status = "error", error = "Unknown job: " .. tostring(jobId) } end
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
        if not ok then job.status = "error"; job.error = tostring(result)
        elseif coroutine.status(co) == "dead" then job.status = "completed" end
    elseif coroutine.status(co) == "dead" then job.status = "completed" end
    local r = { status = job.status }
    if job.result then r.result = job.result end
    if job.error then r.error = job.error end
    if job.status ~= "pending" then pendingJobs[jobId] = nil end
    return r
end
function ZBSpec.cancelAllJobs()
    local count = 0
    for jobId in pairs(pendingJobs) do pendingJobs[jobId] = nil; count = count + 1 end
    return count
end

-- it (called from env inside describe)
function ZBSpec.it(name, fn)
    local fullName = currentDescribe ~= "" and (currentDescribe .. " " .. tostring(name)) or tostring(name)
    if skipCurrentBlock then
        table.insert(skipped, { name = fullName, reason = skipReason })
    else
        local beforeEachHooks = flatten_scopes(beforeEachStack)
        local beforeAllHooks = flatten_scopes(beforeAllStack)
        local afterAllByPath = {}
        for i, scope in ipairs(afterAllStack) do
            if #scope > 0 and describePathStack[i] then
                afterAllByPath[describePathStack[i]] = scope
            end
        end
        table.insert(tests, {
            name = fullName,
            fn = fn,
            before_each = beforeEachHooks,
            before_all = beforeAllHooks,
            after_all_by_path = afterAllByPath,
            describe = currentDescribe,
            described_class = current_described_class
        })
    end
end

function ZBSpec.context(name, fn)
    ZBSpec._describe(name, function() ZBSpec._run_describe_env(name, fn) end)
end

function ZBSpec.test(name, fn)
    ZBSpec.it(name, fn)
end

function ZBSpec.skip(reason)
    skipCurrentBlock = true
    skipReason = reason or "skipped"
end
function ZBSpec.pending(name, fn)
    local fullName = currentDescribe ~= "" and (currentDescribe .. " " .. tostring(name)) or tostring(name)
    table.insert(skipped, { name = fullName, reason = "pending" })
end

-- Assertions
local function fail(msg) error(msg or "assertion failed", 2) end
local function assert_type(val, want)
    if type(val) ~= want then fail(string.format("expected %s, got %s", want, type(val))) end
end
ZBSpec.assert = {}
setmetatable(ZBSpec.assert, {
    __call = function(_, condition, message) if not condition then fail(message) end end
})
function ZBSpec.assert.eq(expected, actual)
    if expected ~= actual then fail(string.format("expected %s, got %s", tostring(expected), tostring(actual))) end
end
local function deep_equal(a, b, seen)
    seen = seen or {}
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return false end
    if seen[a] and seen[a] == b then return true end
    seen[a] = b
    for k, v in pairs(a) do
        if not deep_equal(v, b[k], seen) then return false end
    end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function repr(val, seen)
    seen = seen or {}
    if val == nil then return "nil" end
    if type(val) == "boolean" then return val and "true" or "false" end
    if type(val) == "number" then return tostring(val) end
    if type(val) == "string" then return string.format("%q", val) end
    if type(val) == "table" then
        if seen[val] then return "{...}" end
        seen[val] = true
        local parts = {}
        for k, v in pairs(val) do
            local ks = type(k) == "string" and string.match(k, "^[%a_][%w_]*$") and k or ("[" .. repr(k, seen) .. "]")
            table.insert(parts, ks .. " = " .. repr(v, seen))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(val)
end
function ZBSpec.assert.same(expected, actual)
    if not deep_equal(expected, actual) then
        fail(string.format("expected same value (deep equal); expected: %s; actual: %s", repr(expected), repr(actual)))
    end
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

ZBSpec_currentTest = nil

function ZBSpec.run_before_hooks(t, ranBeforeAll, runner)
    local run = with_runner(runner)
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

function ZBSpec.run_after_all_hooks(testList, runner)
    local run = with_runner(runner)
    local seen = {}
    local describes = {}
    for _, t in ipairs(testList) do
        if t.after_all_by_path then
            for path, _ in pairs(t.after_all_by_path) do
                if path and path ~= "" and not seen[path] then seen[path] = true; table.insert(describes, path) end
            end
        end
    end
    table.sort(describes, function(a, b) return #a > #b end)
    for _, path in ipairs(describes) do
        local hooks = nil
        for _, candidate in ipairs(testList) do
            if candidate.after_all_by_path and candidate.after_all_by_path[path] then
                hooks = candidate.after_all_by_path[path]
                break
            end
        end
        if hooks then
            for _, hook in ipairs(hooks) do
                local ok, err = run(hook); if not ok then return false, err end
            end
        end
    end
    return true
end

function ZBSpec.run()
    return ZBSpec.runDetailed()
end

function ZBSpec.runDetailed()
    errors = {}
    local passed, failed = 0, 0
    local ranBeforeAll = {}
    local testList = tests
    for _, t in ipairs(testList) do
        ZBSpec_currentTest = t.name
        local ok, err = pcall(function()
            ZBSpec.run_before_hooks(t, ranBeforeAll, nil)
            t.fn()
        end)
        if ok then passed = passed + 1
        else failed = failed + 1; table.insert(errors, { name = t.name, error = tostring(err) }) end
        ZBSpec_currentTest = nil
    end
    local afterOk, afterErr = ZBSpec.run_after_all_hooks(testList, nil)
    if not afterOk then
        failed = failed + 1
        table.insert(errors, { name = "after_all", error = tostring(afterErr or "unknown") })
    end
    local passed_tests = {}
    for _, t in ipairs(testList) do
        local ok = true
        for _, e in ipairs(errors) do
            if e.name == t.name then ok = false; break end
        end
        if ok then table.insert(passed_tests, t.name) end
    end
    local result = { passed = passed, failed = failed, skipped = #skipped, context = ZBSpec.getContext(), errors = errors, passed_tests = passed_tests, skipped_tests = skipped }
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
    current_described_class = nil
    beforeEachStack = {}
    beforeAllStack = {}
    afterAllStack = {}
    describePathStack = {}
end

-- Remote execution (client -> server)
local MODULE_NAME = "ZBSpec"
local evalResults = {}
local evalIdCounter = 0
function ZBSpec.server_exec(code)
    if not (isClient and isClient()) then
        local fn, err = loadstring(code)
        if fn then fn() else error("server_exec compile error: " .. tostring(err)) end
        return
    end
    sendClientCommand(MODULE_NAME, "exec", { code = code })
end
function ZBSpec.server_eval(code)
    if not (isClient and isClient()) then
        local fn, err = loadstring(code)
        if fn then return fn() else error("server_eval compile error: " .. tostring(err)) end
    end
    evalIdCounter = evalIdCounter + 1
    local id = evalIdCounter
    sendClientCommand(MODULE_NAME, "eval", { code = code, id = id })
    ZBSpec.wait_for(function() return evalResults[id] ~= nil end)
    local result = evalResults[id]
    evalResults[id] = nil
    if result.success then return result.value
    else error("server_eval error: " .. tostring(result.error)) end
end
function ZBSpec.all_exec(code)
    local fn, err = loadstring(code)
    if fn then fn() else error("all_exec compile error: " .. tostring(err)) end
    if isClient and isClient() then sendClientCommand(MODULE_NAME, "exec", { code = code }) end
end
if isClient and isClient() then
    Events.OnServerCommand.Add(function(module, command, args)
        if module == MODULE_NAME and command == "eval_result" then evalResults[args.id] = args end
    end)
end

-- Build env for describe scope: described_class + __index = parent (or _G). Injects it, describe, assert, hooks, etc.
-- described_class: when name is a class/table, use it; in nested describe(string), keep parent's described_class if it was a class.
function ZBSpec._make_describe_env(parent_env, name)
    local described_class
    if type(name) ~= "string" then
        described_class = name
    elseif parent_env and parent_env.described_class and type(parent_env.described_class) ~= "string" then
        described_class = parent_env.described_class  -- propagate class from outer describe(Class, fn)
    else
        described_class = name
    end
    local env = setmetatable({
        described_class = described_class,
        subject = name,  -- literally the first argument passed to describe()
        it = ZBSpec.it,
        context = function(n, f)
            local inner_env = ZBSpec._make_describe_env(env, n)
            setfenv(f, inner_env)
            ZBSpec._describe(n, function() f() end)
        end,
        assert = ZBSpec.assert,
        before_each = ZBSpec.before_each,
        before_all = ZBSpec.before_all,
        after_all = ZBSpec.after_all,
        skip = ZBSpec.skip,
        pending = ZBSpec.pending,
        test = ZBSpec.test,
        wait_for = ZBSpec.wait_for,
        wait_for_not = ZBSpec.wait_for_not,
        wait_for_this = ZBSpec.wait_for_this,
        sleep = ZBSpec.sleep,
        server_exec = ZBSpec.server_exec,
        server_eval = ZBSpec.server_eval,
        all_exec = ZBSpec.all_exec,
    }, { __index = parent_env or _G })
    -- Nested describe: same env shape, parent is this env
    env.describe = function(inner_name, inner_fn)
        local inner_env = ZBSpec._make_describe_env(env, inner_name)
        setfenv(inner_fn, inner_env)
        ZBSpec._describe(inner_name, function()
            inner_fn()
        end)
    end
    return env
end

-- Global: only entry point. Creates env (described_class + __index = _G), injects it/describe/assert/etc., setfenv(fn, env), runs via ZBSpec._describe.
function describe(name, fn)
    local env = ZBSpec._make_describe_env(_G, name)
    setfenv(fn, env)
    ZBSpec._describe(name, function()
        fn()
    end)
end

return ZBSpec
