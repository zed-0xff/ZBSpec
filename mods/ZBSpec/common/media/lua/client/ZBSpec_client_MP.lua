-- autoconnect to server
require "zbsHook"

local firstTimeTbl = {
}

-- server connect
require "OptionScreens/ServerConnectPopup"

zbsHook(ServerConnectPopup, {
    setVisible = function(orig, self, visible, ...)
        print("[d] ServerConnectPopup:setVisible(", visible, ")")
        if visible and not firstTimeTbl[self] then
            firstTimeTbl[self] = true
            orig(self, visible, ...)
            self.usernameEntry:setText("admin")
            self.passwordEntry:setText("zbspec")
            self:onOptionMouseDown(self.connectBtn)
            return
        end
        orig(self, visible, ...)
    end
})

-- select world
require "OptionScreens/WorldSelect"
zbsHook(WorldSelect, {
    hasChoices = function()
        return false -- skip world selection
    end
})

-- select map
require "OptionScreens/MapSpawnSelect"

zbsHook(MapSpawnSelect, {
    hasChoices = function()
        return false -- skip map selection
    end,

--    setVisible = function(orig, self, visible, ...)
--        print("[d] MapSpawnSelect:setVisible(", visible, ")")
--        if visible and not firstTimeTbl[self] then
--            firstTimeTbl[self] = true
--            orig(self, visible, ...)
--            self:onOptionMouseDown(self.nextButton)
--            return
--        end
--        orig(self, visible, ...)
--    end
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
