-- ZBSpec: Mini test framework for Project Zomboid mods
-- Provides busted-like syntax: describe, it, assert

ZBSpec = ZBSpec or {}

local tests = {}
local errors = {}
local currentDescribe = ""

function ZBSpec.describe(name, fn)
    local prevDescribe = currentDescribe
    currentDescribe = currentDescribe ~= "" and (currentDescribe .. " " .. name) or name
    fn()
    currentDescribe = prevDescribe
end

function ZBSpec.it(name, fn)
    local fullName = currentDescribe ~= "" and (currentDescribe .. " " .. name) or name
    table.insert(tests, { name = fullName, fn = fn })
end

function ZBSpec.context(name, fn)
    ZBSpec.describe(name, fn)
end

function ZBSpec.test(name, fn)
    ZBSpec.it(name, fn)
end

-- Assertions
ZBSpec.assert = {}

function ZBSpec.assert.is_equal(expected, actual)
    if expected ~= actual then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)))
    end
end

function ZBSpec.assert.equals(expected, actual)
    ZBSpec.assert.is_equal(expected, actual)
end

function ZBSpec.assert.is_true(value, msg)
    if not value then
        error(msg or "expected true, got false")
    end
end

function ZBSpec.assert.is_false(value, msg)
    if value then
        error(msg or "expected false, got true")
    end
end

function ZBSpec.assert.is_nil(value)
    if value ~= nil then
        error(string.format("expected nil, got %s", tostring(value)))
    end
end

function ZBSpec.assert.is_not_nil(value)
    if value == nil then
        error("expected non-nil value")
    end
end

function ZBSpec.assert.is_table(value)
    if type(value) ~= "table" then
        error(string.format("expected table, got %s", type(value)))
    end
end

function ZBSpec.assert.is_number(value)
    if type(value) ~= "number" then
        error(string.format("expected number, got %s", type(value)))
    end
end

function ZBSpec.assert.is_string(value)
    if type(value) ~= "string" then
        error(string.format("expected string, got %s", type(value)))
    end
end

function ZBSpec.assert.is_function(value)
    if type(value) ~= "function" then
        error(string.format("expected function, got %s", type(value)))
    end
end

function ZBSpec.assert.is_boolean(value)
    if type(value) ~= "boolean" then
        error(string.format("expected boolean, got %s", type(value)))
    end
end

function ZBSpec.assert.greater_than(threshold, actual)
    if not (actual > threshold) then
        error(string.format("expected %s > %s", tostring(actual), tostring(threshold)))
    end
end

function ZBSpec.assert.less_than(threshold, actual)
    if not (actual < threshold) then
        error(string.format("expected %s < %s", tostring(actual), tostring(threshold)))
    end
end

function ZBSpec.assert.matches(pattern, str)
    if type(str) ~= "string" then
        error(string.format("expected string, got %s", type(str)))
    end
    if not string.match(str, pattern) then
        error(string.format("'%s' does not match pattern '%s'", str, pattern))
    end
end

function ZBSpec.assert.contains(needle, haystack)
    if type(haystack) == "string" then
        if not string.find(haystack, needle, 1, true) then
            error(string.format("'%s' does not contain '%s'", haystack, needle))
        end
    elseif type(haystack) == "table" then
        for _, v in pairs(haystack) do
            if v == needle then return end
        end
        error(string.format("table does not contain %s", tostring(needle)))
    else
        error(string.format("expected string or table, got %s", type(haystack)))
    end
end

function ZBSpec.assert.has_key(key, tbl)
    if type(tbl) ~= "table" then
        error(string.format("expected table, got %s", type(tbl)))
    end
    if tbl[key] == nil then
        error(string.format("table does not have key '%s'", tostring(key)))
    end
end

function ZBSpec.assert.throws(fn, expected_msg)
    local ok, err = pcall(fn)
    if ok then
        error("expected function to throw, but it did not")
    end
    if expected_msg and not string.find(tostring(err), expected_msg, 1, true) then
        error(string.format("expected error containing '%s', got '%s'", expected_msg, tostring(err)))
    end
end

-- Run all tests and return zbspec-compatible result
function ZBSpec.run()
    errors = {}
    
    for _, test in ipairs(tests) do
        local ok, err = pcall(test.fn)
        if not ok then
            table.insert(errors, test.name .. ": " .. tostring(err))
        end
    end
    
    -- Reset for next run
    tests = {}
    
    if #errors > 0 then
        return table.concat(errors, "\n")
    end
    return true
end

-- Reset state (useful between spec files)
function ZBSpec.reset()
    tests = {}
    errors = {}
    currentDescribe = ""
end

-- Aliases for convenience
describe = ZBSpec.describe
context = ZBSpec.context
it = ZBSpec.it
test = ZBSpec.test
assert = ZBSpec.assert

return ZBSpec
