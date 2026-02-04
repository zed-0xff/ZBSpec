-- autoconnect to server
require "OptionScreens/ServerConnectPopup"

local conn_firstTime = true
local orig_setVisible = ServerConnectPopup.setVisible
print("[d] orig_setVisible =", orig_setVisible)

function ServerConnectPopup:setVisible(visible)
    print("[d] ServerConnectPopup:setVisible(", visible, ")")
    if conn_firstTime and visible then
        conn_firstTime = false
        orig_setVisible(self, true)
        self.usernameEntry:setText("admin")
        self.passwordEntry:setText("zbspec")
        self:onOptionMouseDown(self.connectBtn)
        return
    end
    orig_setVisible(self, visible)
end

-- select map
require "OptionScreens/MapSpawnSelect"

local spawn_firstTime = true
local orig_MapSpawnSelect_setVisible = MapSpawnSelect.setVisible
print("[d] orig_MapSpawnSelect_setVisible =", orig_MapSpawnSelect_setVisible)

function MapSpawnSelect:setVisible(visible)
    print("[d] MapSpawnSelect:setVisible(", visible, ")")
    if spawn_firstTime and visible then
        spawn_firstTime = false
        orig_MapSpawnSelect_setVisible(self, true)
        self:onOptionMouseDown(self.nextButton)
        return
    end
    orig_MapSpawnSelect_setVisible(self, visible)
end

-- perks/skills
require "OptionScreens/CharacterCreationProfession"

local prof_firstTime = true
local orig_CharacterCreationProfession_setVisible = CharacterCreationProfession.setVisible
print("[d] orig_CharacterCreationProfession_setVisible =", orig_CharacterCreationProfession_setVisible)

function CharacterCreationProfession:setVisible(visible)
    print("[d] CharacterCreationProfession:setVisible(", visible, ")")
    if prof_firstTime and visible then
        prof_firstTime = false
        orig_CharacterCreationProfession_setVisible(self, true)
        self:onOptionMouseDown(self.playButton)
        return
    end
    orig_CharacterCreationProfession_setVisible(self, visible)
end

-- appearance/sex
require "OptionScreens/CharacterCreationMain"

local perks_firstTime = true
local orig_CharacterCreationMain_setVisible = CharacterCreationMain.setVisible
print("[d] orig_CharacterCreationMain_setVisible =", orig_CharacterCreationMain_setVisible)

function CharacterCreationMain:setVisible(visible)
    print("[d] CharacterCreationMain:setVisible(", visible, ")")
    if perks_firstTime and visible then
        perks_firstTime = false
        orig_CharacterCreationMain_setVisible(self, true)
        self:onOptionMouseDown(self.playButton)
        return
    end
    orig_CharacterCreationMain_setVisible(self, visible)
end
