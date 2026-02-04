UIManager.setShowLuaDebuggerOnError(false)

if WelcomeMessages and WelcomeMessages.doMsg then
    Events.OnGameStart.Remove(WelcomeMessages.doMsg)
end

Events.OnGameStart.Add(function()
    getPlayer():getModData().seenWelcome = true
end)

local core = getCore()
if core and core.setOptionShowSurvivalGuide then
    core:setOptionShowSurvivalGuide(false)
end

