-- autoconnect to server
local firstTimeTbl = {
}

---Credentials, overridable per instance via a file in the Lua cache dir
---(written by the harness so a second client can use a distinct username).
local function readCredentials()
    local ok, reader = pcall(getFileReader, "zb_mp_credentials.txt", false)
    if not ok or not reader then return "admin", "zbspec" end
    local username = reader:readLine()
    local password = reader:readLine()
    reader:close()
    return username or "admin", password or "zbspec"
end

-- server connect
require "OptionScreens/ServerConnectPopup"

zbsHook(ServerConnectPopup, {
    setVisible = function(orig, self, visible, ...)
        print("[d] ServerConnectPopup:setVisible(", visible, ")")
        if visible and not firstTimeTbl[self] then
            firstTimeTbl[self] = true
            orig(self, visible, ...)
            local username, password = readCredentials()
            self.usernameEntry:setText(username)
            self.passwordEntry:setText(password)
            self:onOptionMouseDown(self.connectBtn)
            return
        end
        orig(self, visible, ...)
    end
})

-- select map
require "OptionScreens/MapSpawnSelect"

zbsHook(MapSpawnSelect, {
    hasChoices = function()
        return false -- skip map selection
    end,
})

-- perks/skills
require "OptionScreens/CharacterCreationProfession"

zbsHook(CharacterCreationProfession, {
    setVisible = function(orig, self, visible, ...)
        print("[d] CharacterCreationProfession:setVisible(", visible, ")")
        if visible and not firstTimeTbl[self] then
            firstTimeTbl[self] = true
            orig(self, visible, ...)
            self:onOptionMouseDown(self.playButton)
            return
        end
        orig(self, visible, ...)
    end
})

-- appearance/sex
require "OptionScreens/CharacterCreationMain"

zbsHook(CharacterCreationMain, {
    setVisible = function(orig, self, visible, ...)
        print("[d] CharacterCreationMain:setVisible(", visible, ")")
        if visible and not firstTimeTbl[self] then
            firstTimeTbl[self] = true
            orig(self, visible, ...)
            self:onOptionMouseDown(self.playButton)
            return
        end
        orig(self, visible, ...)
    end
})

-- Serve client_eval() requests from another client (relayed via the server).
-- Registered on every MP client, including clients that run no specs.
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "ZBSpec" or command ~= "eval_request" then return end
    local response = { id = args.id, origin = args.origin }
    local fn, err = loadstring(args.code)
    if fn then
        local ok, result = pcall(fn)
        if ok then response.success = true; response.value = result
        else response.success = false; response.error = tostring(result) end
    else
        response.success = false; response.error = "compile error: " .. tostring(err)
    end
    sendClientCommand("ZBSpec", "eval_response", response)
end)
