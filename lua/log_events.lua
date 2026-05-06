-- curl -s -X POST http://127.0.0.1:4444/lua --data-binary '@log_events.lua'

local events = {
    -- world
    "OnDeviceText",
    "OnWorldSound",

    -- player
    "OnDoTileBuilding2",
    "OnPreFillWorldObjectContextMenu",
    "OnFillWorldObjectContextMenu",
    "OnPlayerGetDamage",                  -- X_X
    "OnPlayerMove",
    "OnPlayerUpdate",
    "OnRefreshInventoryWindowContainers",

    -- render/draw
    "OnPostRender",
    "OnPostUIDraw",
    "OnPreUIDraw",
    "OnPostFloorLayerDraw",
    "RenderOpaqueObjectsInWorld",

    -- weather
    "OnWeatherPeriodStart",
    "OnWeatherPeriodStop",

    -- timers
    "EveryHours",
    "EveryOneMinute",
    "EveryTenMinutes",

    -- ticks
    "OnClimateTick",
    "OnClimateTickDebug",
    "OnFETick",
    "OnRenderTick",
    "OnSleepingTick",
    "OnTick",
    "OnTickEvenPaused",

    -- collide
    "OnCharacterCollide",
    "OnObjectCollide",

    -- ai/npc
    "OnAIStateChange",
    "OnZombieUpdate",

    -- map
    "LoadChunk",
    "LoadGridsquare",
    "ReuseGridsquare",

    -- keyboard
    "OnCustomUIKey",
    "OnCustomUIKeyPressed",
    "OnCustomUIKeyReleased",
    "OnKeyKeepPressed",
    "OnKeyPressed",
    "OnKeyStartPressed",

    -- mouse
    "OnMouseDown",
    "OnMouseMove",
    "OnMouseUp",
    "OnMouseWheel",
    "OnRightMouseDown",
    "OnRightMouseUp",
    "OnObjectLeftMouseButtonDown",
    "OnObjectLeftMouseButtonUp",
    "OnObjectRightMouseButtonDown",
    "OnObjectRightMouseButtonUp",

    -- misc
    "OnSteamServerResponded",
}
ZombieBuddy.EventLog.exclude(events)
ZombieBuddy.EventLog.enable()
