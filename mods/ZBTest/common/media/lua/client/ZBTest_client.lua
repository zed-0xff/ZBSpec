if debugScenarios == nil then
    debugScenarios = {}
end

UIManager.setShowLuaDebuggerOnError(false)

debugScenarios.DebugScenarioTGreen = {
    forceLaunch = true, -- XXX
    name = "Turbo Green Test",
    world = "Muldraugh, KY",
    startLoc = {x=8496, y=5789, z=0},
    setSandbox = function()
        SandboxVars.VehicleEasyUse = true;
        SandboxVars.Zombies = 6;
    end,
    onStart = function()
    end
}
