if debugScenarios == nil then
    debugScenarios = {}
end

debugScenarios.DebugScenarioZBSpec = {
    forceLaunch = true, -- also requires DebugScenario.ForceLaunch - see below
    name = "ZBSpec",
    world = "TestMap",
    startLoc = {x=128, y=128, z=0}, -- also in servertest.ini
    setSandbox = function()
        SandboxVars.DayNightCycle = 2; -- endless day
        SandboxVars.StartTime = 2;     -- 9:00 AM
        SandboxVars.Zombies = 6;       -- no zombies
    end,
    onStart = function()
        print("[d] DebugScenarioZBSpec:onStart")
        getDebugOptions():setBoolean("DebugScenario.ForceLaunch", false) -- disarm to allow exiting to main menu
        UIManager.setShowLuaDebuggerOnError(false)

        if SurvivalGuideManager and SurvivalGuideManager.instance and SurvivalGuideManager.instance.panel then
            SurvivalGuideManager.instance.panel:setVisible(false)
        end
    end
}

-- B41 does not call setMap(scenario.world) when launching a debug scenario, so we have to hook createWorld to set the map there
if getCore():getGameVersion():getMajor() == 41 then
    zbsHook(_G, {
        createWorld = function(orig, ...)
            getWorld():setMap("TestMap")
            return orig(...)
        end
    })
end

-- start the debug scenario even when not in debug mode, to allow running the tests in a normal game
-- NB: never do this on an MP client. The client is launched with +connect, so isClient()
-- is true as soon as the connection starts; launching the SP TestMap scenario there forces
-- LoadingQueueState during the server handshake and cancels the connection
-- ("loading-queue-canceled"), dropping the client back to singleplayer.
if not getDebug() then
    if type(LoadMainScreenPanelInt) == "function" then
        local prevLoadMainScreenPanelInt = LoadMainScreenPanelInt

        LoadMainScreenPanelInt = function(ingame, ...)
            prevLoadMainScreenPanelInt(ingame, ...)

            if not ingame and not isClient() and not isServer() then
                doDebugScenarios()
            end
        end
    end
end
