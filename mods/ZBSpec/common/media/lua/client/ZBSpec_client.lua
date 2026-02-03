if debugScenarios == nil then
    debugScenarios = {}
end

UIManager.setShowLuaDebuggerOnError(false)

debugScenarios.DebugScenarioZBSpec = {
    forceLaunch = true,
    name = "ZBSpec",
    world = "Muldraugh, KY",
    startLoc = {x=8496, y=5789, z=0},
    setSandbox = function()
        SandboxVars.VehicleEasyUse = true;
        SandboxVars.Zombies = 6;
    end,
    onStart = function()
        UIManager.setShowLuaDebuggerOnError(false)
    end
}
