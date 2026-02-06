-- ZBSpec Server: Handles remote code execution from client
-- Used for testing in multiplayer where client needs to run code on server

local MODULE_NAME = "ZBSpec"

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE_NAME then return end
    
    if command == "exec" then
        -- Fire and forget execution, no response
        local fn, err = loadstring(args.code)
        if fn then
            local ok, result = pcall(fn)
            if not ok then
                print("[ZBSpec] server_exec error: " .. tostring(result))
            end
        else
            print("[ZBSpec] server_exec compile error: " .. tostring(err))
        end
        
    elseif command == "eval" then
        -- Execute and send result back to client
        local response = { id = args.id }
        
        local fn, err = loadstring(args.code)
        if fn then
            local ok, result = pcall(fn)
            if ok then
                response.success = true
                response.value = result
            else
                response.success = false
                response.error = tostring(result)
            end
        else
            response.success = false
            response.error = "compile error: " .. tostring(err)
        end
        
        sendServerCommand(player, MODULE_NAME, "eval_result", response)
    end
end)
