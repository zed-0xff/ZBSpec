-- ZBSpec Server: Handles remote code execution from client
-- Used for testing in multiplayer where client needs to run code on server

local MODULE_NAME = "ZBSpec"

local function findPlayer(username)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 1, players:size() do
        local pl = players:get(i - 1)
        if pl and pl:getUsername() == username then return pl end
    end
    return nil
end

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

    elseif command == "eval_on_client" then
        -- Forward a Lua eval to another client, remembering who asked.
        local target = findPlayer(args.target)
        if target then
            sendServerCommand(target, MODULE_NAME, "eval_request",
                { code = args.code, id = args.id, origin = player:getUsername() })
        else
            sendServerCommand(player, MODULE_NAME, "eval_result",
                { id = args.id, success = false, error = "target not found: " .. tostring(args.target) })
        end

    elseif command == "eval_response" then
        -- Forward a target client's result back to the requesting client.
        local origin = findPlayer(args.origin)
        if origin then
            sendServerCommand(origin, MODULE_NAME, "eval_result",
                { id = args.id, success = args.success, value = args.value, error = args.error })
        end
    end
end)
