function get_player()
    if isServer() then
        return getOnlinePlayers():get(0) -- XXX assumes only one player online
    else
        return getPlayer()
    end
end

function init_player(player)
    if not player then
        player = get_player()
    end
    -- Abort any action the player is currently doing
    if ISTimedActionQueue and ISTimedActionQueue.clear then
        ISTimedActionQueue.clear(get_player())
    end

    if isMultiplayer() then
        if isClient() then
            local inv = player:getInventory()
            local items = inv:getItems()
            local types = {}
            for i=0, items:size()-1 do
                types[items:get(i):getFullType()] = true
            end
            for itemType, _ in pairs(types) do
                SendCommandToServer("/removeitem " .. itemType .. " 0")
            end
        end
    end
    player:getInventory():removeAllItems()


    ZBSpec.all_exec([[
      local player = (getPlayer() or getOnlinePlayers():get(0))

      -- TODO: check on MP
      player:setGodMod(true)
      player:setInvincible(true)
      player:getBodyDamage():RestoreToFullHealth()

      -- clear inventory
      player:setPrimaryHandItem(nil)
      player:setSecondaryHandItem(nil)

      -- reset known recipes
      player:getReadLiterature():clear()
      player:forgetRecipes()

      -- reset profession
      player:getDescriptor():setCharacterProfession(CharacterProfession.UNEMPLOYED)

      -- reset stats
      player:getStats():resetStats()

      -- reset traits
      local traits = player:getCharacterTraits():getKnownTraits()
      for i=0, traits:size()-1 do
        local trait = traits:get(i)
        player:getCharacterTraits():remove(trait)
      end

      -- reset all perks except physical
      for i=1, Perks.getMaxIndex() do
        local perk = Perks.fromIndex(i)
        if perk then
            local parentPerk = perk:getParent()
            if player:getPerkLevel(perk) > 0 and parentPerk and parentPerk ~= Perks.PhysicalCategory and parentPerk ~= Perks.None then
              player:setPerkLevelDebug(perk, 0)
            end
        end
      end
    ]])
end

function set_sandbox_option(option, value)
    ZBSpec.all_exec("getSandboxOptions():getOptionByName(\"" .. option .. "\"):setValue(" .. tostring(value) .. ")")
end

function set_timed_action_instant(value)
    -- Can't use get_player() here - all_exec sends code as string to server
    -- where spec_helper functions aren't available
    ZBSpec.all_exec("(getPlayer() or getOnlinePlayers():get(0)):setTimedActionInstantCheat(" .. tostring(value) .. ")")
end

function create_item(itemFullType)
    local item = instanceItem(itemFullType)
    assert(item, "Failed to create item: " .. itemFullType)
    return item
end

function add_item(player, itemFullType)
    local item = nil
    if isClient() then
        -- MP
        SendCommandToServer("/additem \"" .. player:getDisplayName() .. "\" \"" .. itemFullType .. "\"")
        local inv = player:getInventory()
        ZBSpec.wait_for(inv.contains, inv, itemFullType)
        item = inv:getItemFromType(itemFullType, false, false)
    else
        -- SP
        item = create_item(itemFullType)
        player:getInventory():AddItem(item)
    end
    assert(item, "Failed to create item: " .. itemFullType)
    return item
end

function run_action(actionClass, player, ...)
    local action = actionClass:new(player, ...)
    ISTimedActionQueue.add(action)
    ZBSpec.wait_for_not(ISTimedActionQueue.isPlayerDoingAction, player)
end

function read_book(player, book)
    run_action(ISReadABook, player, book, 1)
end

function set_perk_level(player, perk, level)
    ZBSpec.all_exec("(getPlayer() or getOnlinePlayers():get(0)):setPerkLevelDebug(Perks." .. tostring(perk) .. ", " .. level .. ")")
end

function remove_all_non_floor(square)
    local toRemove = {}
    for i = 0, square:getSpecialObjects():size() - 1 do
        local obj = square:getSpecialObjects():get(i)
        table.insert(toRemove, obj)
    end
    for _, obj in ipairs(toRemove) do
        square:transmitRemoveItemFromSquare(obj)
    end

    local toRemove = {}
    for i = 0, square:getObjects():size() - 1 do
        local obj = square:getObjects():get(i)
        if not obj:isFloor() then
            table.insert(toRemove, obj)
        end
    end

    for _, obj in ipairs(toRemove) do
        square:transmitRemoveItemFromSquare(obj)
    end
end

function place_tile(square, name)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj:getSprite():getName() == name then
            return obj
        end
    end
    remove_all_non_floor(square)

    local obj = square:addTileObject(name)
    if isClient() then
        obj:transmitCompleteItemToServer()
    end
    if isServer() then
        obj:transmitCompleteItemToClients()
    end

    return obj
end
