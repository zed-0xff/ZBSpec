require 'zbsHook'

if debugScenarios == nil then
    debugScenarios = {}
end

debugScenarios.DebugScenarioZBSpec = {
    forceLaunch = true, -- also requires DebugScenario.ForceLaunch - see below
    name = "ZBSpec",
    world = "TestMap",
    startLoc = {x=128, y=128, z=0}, -- also in servertest.ini
    setSandbox = function()
        SandboxVars.VehicleEasyUse = true;
        SandboxVars.Zombies = 6;
    end,
    onStart = function()
        getDebugOptions():setBoolean("DebugScenario.ForceLaunch", false) -- disarm to allow exiting to main menu
        print("[d] DebugScenarioZBSpec:onStart")
        UIManager.setShowLuaDebuggerOnError(false)
        if SurvivalGuideManager.instance then
            SurvivalGuideManager.instance.panel:setVisible(false)
        end
    end
}

-- select world
--require "OptionScreens/WorldSelect"
--zbsHook(WorldSelect, {
--    hasChoices = function()
--        return false -- skip world selection
--    end
--})

