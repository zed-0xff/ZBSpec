UIManager.setShowLuaDebuggerOnError(false)

if WelcomeMessages and WelcomeMessages.doMsg then
    Events.OnGameStart.Remove(WelcomeMessages.doMsg)
end

local core = getCore()
if core and core.setOptionShowSurvivalGuide then
    core:setOptionShowSurvivalGuide(false)
end

Events.OnGameStart.Add(function()
    local player = getPlayer()
    player:getModData().seenWelcome = true
    player:setInvincible(true)
end)

