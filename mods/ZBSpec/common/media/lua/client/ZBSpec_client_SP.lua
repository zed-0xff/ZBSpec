if debugScenarios == nil then
    debugScenarios = {}
end

debugScenarios.DebugScenarioZBSpec = {
    forceLaunch = true,
    name = "ZBSpec",
    world = "Muldraugh, KY",
    startLoc = {x=8496, y=5789, z=0}, -- also in servertest.ini
    setSandbox = function()
        SandboxVars.VehicleEasyUse = true;
        SandboxVars.Zombies = 6;
    end,
    onStart = function()
        print("[d] DebugScenarioZBSpec:onStart")
        UIManager.setShowLuaDebuggerOnError(false)
        if SurvivalGuideManager.instance then
            SurvivalGuideManager.instance.panel:setVisible(false)
        end
    end
}
