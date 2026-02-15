--- Hooks methods on an object by wrapping them with custom functions.
-- @param obj table Object whose methods will be hooked (e.g. a class or instance).
-- @param hooks table Map of methodName (string) -> wrapper (function). For each key that
--   names an existing function on obj, replaces it with a function that calls
--   wrapper(orig, ...) where orig is the original function and ... are the call arguments.
--   When the method is called as obj:methodName(...), the wrapper receives (orig, obj, ...).
--   The wrapper should call orig(...) to invoke the original and may return its return value(s).
function zbsHook(obj, hooks)
    if not obj or not hooks then return end

    for methodName, wrapper in pairs(hooks) do
        local orig = obj[methodName]
        if type(orig) == "function" then
            if type(wrapper) == "function" then
                obj[methodName] = function(...)
                    return wrapper(orig, ...)
                end
            else
                print("[!] zbsHook: " .. tostring(methodName) .. " has no wrapper, but " .. tostring(type(wrapper)))
            end
        else
            print("[?] zbsHook: " .. tostring(methodName) .. " is not a function, but " .. tostring(type(orig)))
        end
    end
end
