-- Compact development tools for the Sea Runtime V1 prototype.
-- Keys: F3 panel, U underwater, H fish states, P perception, J activity,
--       1 sardine, 2 tuna, C clear ordinary fish, B small-fish test lure,
--       Space pause, R reset.
local UI = require("urhox-libs/UI")
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")

local SeaDebug = {}

local function noOpController()
    return {
        refresh = function(_) end,
        handleKey = function(_) return false end,
    }
end

local function flagValue(runtime, name)
    local flags = runtime.debug or runtime.debugFlags or Config.debug
    if flags[name] == nil then return Config.debug[name] == true end
    return flags[name] == true
end

local function setFlag(runtime, name, value)
    if type(runtime.setDebugFlag) == "function" then
        runtime:setDebugFlag(name, value)
    elseif type(runtime.debug) == "table" then
        runtime.debug[name] = value
    end
end

local function shipPosition(runtime)
    local ship = runtime.ship
    if ship and ship.position and type(ship.position.x) == "number" and type(ship.position.y) == "number" then
        return { x = ship.position.x, y = ship.position.y }, ship.rotation or 0
    end
    return { x = 0, y = 0 }, 0
end

local function project(runtime, position)
    local movement = runtime.movement
    if not movement or type(movement.WorldToScreen) ~= "function" then return nil, nil end
    local x, y = movement:WorldToScreen(position)
    if type(x) == "table" then return x.x, x.y end
    return x, y
end

local function entityVisible(world, entity)
    if world and type(world.isVisible) == "function" then return world:isVisible(entity) end
    return entity.layer ~= "underwater"
end

---@class SeaDebugLabelEntry
---@field widget Label
---@field text string
---@field x number?
---@field y number?
---@field colorSpecies string?

---@class SeaFishLabelPool
---@field layer Panel?
---@field entries SeaDebugLabelEntry[]

local function spawnPosition(runtime, directionSign)
    local origin, rotation = shipPosition(runtime)
    local distance = Config.debug.spawnOffset or 12
    local species = directionSign > 0 and "sardine" or "tuna"
    local fishData = FishData[species]
    local world = runtime.world
    for turn = 0, 3 do
        local angle = rotation + directionSign * turn * (math.pi * 0.5)
        local candidate = {
            x = origin.x + math.cos(angle) * distance,
            y = origin.y + math.sin(angle) * distance,
        }
        if not world or type(world.isPositionFree) ~= "function" or world:isPositionFree(candidate, fishData.radius) then
            return candidate
        end
    end
    return nil
end

local function toggleFlag(runtime, name)
    setFlag(runtime, name, not flagValue(runtime, name))
end

---@param layer Panel
---@param pool SeaDebugLabelEntry[]
---@param index number
local function addFishLabel(layer, pool, index)
    while #pool < index do
        local label = UI.Label {
            text = "",
            width = 156,
            height = 20,
            position = "absolute",
            left = 0,
            top = 0,
            visible = false,
            paddingHorizontal = 5,
            paddingVertical = 2,
            backgroundColor = { 9, 30, 44, 196 },
            borderRadius = 4,
            fontSize = 10,
            fontColor = { 245, 249, 247, 255 },
            textAlign = "center",
            pointerEvents = "none",
        }
        layer:AddChild(label)
        pool[#pool + 1] = { widget = label, text = "", x = nil, y = nil }
    end
    return pool[index]
end

local function fishLabelText(entity, flags)
    local parts = { entity.species or "fish" }
    if flags.showStates then parts[#parts + 1] = entity.state or "?" end
    if flags.showActivity then
        if entity.frozen then
            parts[#parts + 1] = "frozen"
        elseif entity.active then
            parts[#parts + 1] = "active"
        else
            parts[#parts + 1] = "idle"
        end
    end
    return table.concat(parts, " | ")
end

local function hideUnusedLabels(pool, used)
    for index, entry in ipairs(pool) do
        if index > used and entry.widget:IsVisible() then entry.widget:SetVisible(false) end
    end
end

local function updateFishLabels(runtime, pool)
    local flags = runtime.debug or runtime.debugFlags or Config.debug
    if not flags.showStates and not flags.showActivity then
        hideUnusedLabels(pool.entries, 0)
        return
    end
    local labelLayer = pool.layer
    if not labelLayer then
        hideUnusedLabels(pool.entries, 0)
        return
    end
    local world, movement = runtime.world, runtime.movement
    if not world or not movement or type(movement.WorldToScreen) ~= "function" then
        hideUnusedLabels(pool.entries, 0)
        return
    end
    local dpr = math.max(graphics:GetDPR(), 0.1)
    local logicalWidth = graphics:GetWidth() / dpr
    local logicalHeight = graphics:GetHeight() / dpr
    local uiScale = math.max(UI.GetScale(), 0.1)
    local basePerLogical = dpr / uiScale
    local viewHeight = movement.viewHeight or Config.camera.viewHeight
    local viewWidth = movement.viewWidth or viewHeight * logicalWidth / math.max(logicalHeight, 1)
    local camera = movement.camera or (runtime.ship and runtime.ship.position)
    local candidates = world.entities or {}
    if camera and type(world.queryEntitiesInRadius) == "function" then
        -- Extra room keeps labels whose anchors are just outside the viewport from popping.
        local cornerRadius = math.sqrt((viewWidth * 0.5) ^ 2 + (viewHeight * 0.5) ^ 2)
        local labelMargin = 80 / math.max(basePerLogical, 0.1) / (logicalWidth / math.max(viewWidth, 1))
        candidates = world:queryEntitiesInRadius(camera, cornerRadius + labelMargin)
    end
    local used = 0
    for _, entity in ipairs(candidates) do
        if not entity.removed and entity.species and entity.position and entityVisible(world, entity) then
            local x, y = project(runtime, entity.position)
            if x and y and x >= -20 and x <= logicalWidth + 20 and y >= -16 and y <= logicalHeight + 16 then
                used = used + 1
                local entry = addFishLabel(labelLayer, pool.entries, used)
                local speciesData = FishData[entity.species]
                local color = speciesData and speciesData.color or { 245, 249, 247, 255 }
                local labelX = x * basePerLogical - 78
                local labelY = y * basePerLogical - 23
                local text = fishLabelText(entity, flags)
                if entry.text ~= text then
                    entry.widget:SetText(text)
                    entry.text = text
                end
                if not entry.widget:IsVisible() then entry.widget:SetVisible(true) end
                if not entry.x or math.abs(entry.x - labelX) > 1 or math.abs(entry.y - labelY) > 1 then
                    entry.widget:SetStyle({ left = labelX, top = labelY })
                    entry.x, entry.y = labelX, labelY
                end
                if entry.colorSpecies ~= entity.species then
                    entry.widget:SetFontColor(color)
                    entry.colorSpecies = entity.species
                end
            end
        end
    end
    hideUnusedLabels(pool.entries, used)
end

local function countsText(runtime)
    local world = runtime.world
    local runningCounts = world and type(world.getCounts) == "function" and world:getCounts() or {}
    local nearbyFish = {}
    local center = runtime.ship and runtime.ship.position
    if center and world and type(world.queryEntitiesInRadius) == "function" then
        nearbyFish = world:queryEntitiesInRadius(center, Config.world.activateRadius, { entityType = "fish" })
    end
    local nearbySardine, nearbyTuna = 0, 0
    for _, entity in ipairs(nearbyFish) do
        if not entity.removed then
            if entity.species == "sardine" then nearbySardine = nearbySardine + 1 end
            if entity.species == "tuna" then nearbyTuna = nearbyTuna + 1 end
        end
    end
    local sardineTarget = FishData.sardine.targetActiveCount or 0
    local tunaTarget = FishData.tuna.targetActiveCount or 0
    return string.format("Near boat: Sardine %d | Tuna %d (density reference %d/%d)",
        nearbySardine, nearbyTuna, sardineTarget, tunaTarget),
        string.format("World %d  |  dropped %d", runningCounts.total or 0, runningCounts.temp or 0),
        string.format("World active %d  |  frozen %d", runningCounts.active or 0, runningCounts.frozen or 0)
end

local function updateButtonText(button, text)
    if button and button.props.text ~= text then button:SetText(text) end
end

--- Create the development UI. UI.Init must already have been called by the caller.
---@param runtime table
---@param options {parent: Widget?, panelVisible: boolean?, expanded: boolean?, onPause: (fun())?, onReset: (fun())?}?
---@return table controller { refresh=function(dt), handleKey=function(key) }
function SeaDebug.Create(runtime, options)
    runtime = runtime or {}
    options = options or {}
    if not Config.debug.enabled then return noOpController() end

    ---@type SeaFishLabelPool
    local labelPool = { layer = nil, entries = {} }
    local state = {
        panelVisible = options.panelVisible ~= false,
        expanded = options.expanded ~= false,
        elapsed = Config.debug.refreshSec or 0.25,
    }
    local buttons = {}

    local function buildButton(id, text, onClick)
        local button = UI.Button {
            id = id,
            text = text,
            width = 112,
            height = 30,
            paddingHorizontal = 4,
            paddingVertical = 4,
            variant = "secondary",
            onClick = onClick,
        }
        buttons[id] = button
        return button
    end

    local function row(children)
        return UI.Panel { width = "100%", flexDirection = "row", gap = 8, children = children }
    end

    local function spawnFish(species, sign)
        if type(runtime.spawnFish) == "function" then
            local position = spawnPosition(runtime, sign)
            if position then runtime:spawnFish(species, position) end
        end
    end

    local function spawnTestLure()
        if type(runtime.spawnDroppedItem) ~= "function" then return end
        local origin, rotation = shipPosition(runtime)
        local distance = Config.debug.baitOffset or 8
        ---@type { x: number, y: number }?
        local position = nil
        for turn = 0, 3 do
            local angle = rotation + turn * (math.pi * 0.5)
            local candidate = {
                x = origin.x + math.cos(angle) * distance,
                y = origin.y + math.sin(angle) * distance,
            }
            local world = runtime.world
            if not world or type(world.isPositionFree) ~= "function" or world:isPositionFree(candidate, 0) then
                position = candidate
                break
            end
        end
        if not position then return end
        runtime:spawnDroppedItem({
            itemId = "debug-small-fish-lure",
            category = "debug",
            worldEffect = "ATTRACT_SMALL_FISH",
            lifetimeSec = Config.world.temporaryLifetimeSec,
        }, position)
    end

    local function toggle(name)
        toggleFlag(runtime, name)
    end

    local fishLabelLayer = UI.Panel {
        id = "seaFishLabelLayer",
        position = "absolute",
        top = 0,
        left = 0,
        right = 0,
        bottom = 0,
        pointerEvents = "none",
    }
    labelPool.layer = fishLabelLayer

    local toolContents = UI.Panel {
        id = "seaDebugContents",
        flexDirection = "column",
        gap = 6,
        children = {
            UI.Label { id = "seaDebugPopulation", text = countsText(runtime), fontSize = 10, fontColor = { 220, 237, 239, 255 } },
            UI.Label { id = "seaDebugWorldCounts", text = "World 0  |  dropped 0", fontSize = 10, fontColor = { 180, 207, 216, 255 } },
            UI.Label { id = "seaDebugActivityCounts", text = "World active 0  |  frozen 0", fontSize = 10, fontColor = { 180, 207, 216, 255 } },
            row({
                buildButton("seaDebugUnderwater", "Underwater OFF", function() toggle("showUnderwater") end),
                buildButton("seaDebugStates", "States OFF", function() toggle("showStates") end),
            }),
            row({
                buildButton("seaDebugPerception", "Perception OFF", function() toggle("showPerception") end),
                buildButton("seaDebugActivity", "Activity OFF", function() toggle("showActivity") end),
            }),
            row({
                buildButton("seaDebugSpawnSardine", "Spawn sardine", function() spawnFish("sardine", 1) end),
                buildButton("seaDebugSpawnTuna", "Spawn tuna", function() spawnFish("tuna", -1) end),
            }),
            row({
                buildButton("seaDebugClearFish", "Clear fish", function()
                    if type(runtime.clearOrdinaryFish) == "function" then runtime:clearOrdinaryFish() end
                end),
                buildButton("seaDebugTestLure", "Test small-fish lure", spawnTestLure),
            }),
            row({
                buildButton("seaDebugPause", "Pause / resume", function()
                    if options.onPause then options.onPause()
                    elseif type(runtime.TogglePause) == "function" then runtime:TogglePause() end
                end),
                buildButton("seaDebugReset", "Reset sea", function()
                    if options.onReset then options.onReset()
                    elseif type(runtime.Reset) == "function" then runtime:Reset() end
                end),
            }),
            UI.Label { text = "F3 panel | U underwater | H states | P perception", fontSize = 9, fontColor = { 156, 185, 195, 255 } },
            UI.Label { text = "J activity | 1 sardine | 2 tuna | C clear | B lure", fontSize = 9, fontColor = { 156, 185, 195, 255 } },
            UI.Label { text = "Space pause | R reset", fontSize = 9, fontColor = { 156, 185, 195, 255 } },
        },
    }

    local headerButton = UI.Button {
        id = "seaDebugHeader",
        text = state.expanded and "SEA DEBUG  [-]" or "SEA DEBUG  [+]",
        width = "100%",
        height = 32,
        variant = "primary",
        onClick = function(self)
            ---@cast self Button
            state.expanded = not state.expanded
            toolContents:SetVisible(state.expanded)
            self:SetText(state.expanded and "SEA DEBUG  [-]" or "SEA DEBUG  [+]")
        end,
    }
    local panel = UI.Panel {
        id = "seaDebugPanel",
        position = "absolute",
        top = 8,
        right = 8,
        width = 252,
        padding = 10,
        gap = 7,
        backgroundColor = { 7, 31, 45, 232 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = { 91, 160, 173, 210 },
        pointerEvents = "auto",
        children = { headerButton, toolContents },
    }
    local root = UI.Panel {
        id = "seaDebugRoot",
        position = options.parent and "absolute" or nil,
        top = 0,
        left = 0,
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            fishLabelLayer,
            UI.SafeAreaView {
                width = "100%",
                height = "100%",
                position = "absolute",
                top = 0,
                left = 0,
                right = 0,
                bottom = 0,
                pointerEvents = "box-none",
                children = { panel },
            },
        },
    }
    toolContents:SetVisible(state.expanded)
    panel:SetVisible(state.panelVisible)
    if options.parent then options.parent:AddChild(root) else UI.SetRoot(root) end

    local populationLabel = toolContents:FindById("seaDebugPopulation") --[[@as Label?]]
    local worldCountsLabel = toolContents:FindById("seaDebugWorldCounts") --[[@as Label?]]
    local activityCountsLabel = toolContents:FindById("seaDebugActivityCounts") --[[@as Label?]]

    local controller = {}
    controller.refresh = function(dt)
        state.elapsed = state.elapsed + math.max(0, dt or 0)
        local interval = Config.debug.refreshSec or 0.25
        if state.elapsed < interval then return end
        state.elapsed = 0

        local populationText, worldText, activityText = countsText(runtime)
        if populationLabel and populationLabel:GetText() ~= populationText then populationLabel:SetText(populationText) end
        if worldCountsLabel and worldCountsLabel:GetText() ~= worldText then worldCountsLabel:SetText(worldText) end
        if activityCountsLabel and activityCountsLabel:GetText() ~= activityText then activityCountsLabel:SetText(activityText) end

        updateButtonText(buttons.seaDebugUnderwater, "Underwater " .. (flagValue(runtime, "showUnderwater") and "ON" or "OFF"))
        updateButtonText(buttons.seaDebugStates, "States " .. (flagValue(runtime, "showStates") and "ON" or "OFF"))
        updateButtonText(buttons.seaDebugPerception, "Perception " .. (flagValue(runtime, "showPerception") and "ON" or "OFF"))
        updateButtonText(buttons.seaDebugActivity, "Activity " .. (flagValue(runtime, "showActivity") and "ON" or "OFF"))
        updateFishLabels(runtime, labelPool)
    end

    local function setPanelVisible(visible)
        state.panelVisible = visible
        panel:SetVisible(visible)
    end

    controller.handleKey = function(key)
        if key == KEY_F3 then
            setPanelVisible(not state.panelVisible)
        elseif key == KEY_U then
            toggle("showUnderwater")
        elseif key == KEY_H then
            toggle("showStates")
        elseif key == KEY_P then
            toggle("showPerception")
        elseif key == KEY_J then
            toggle("showActivity")
        elseif key == KEY_1 then
            spawnFish("sardine", 1)
        elseif key == KEY_2 then
            spawnFish("tuna", -1)
        elseif key == KEY_C then
            if type(runtime.clearOrdinaryFish) == "function" then runtime:clearOrdinaryFish() end
        elseif key == KEY_B then
            spawnTestLure()
        elseif key == KEY_SPACE then
            if options.onPause then options.onPause()
            elseif type(runtime.TogglePause) == "function" then runtime:TogglePause() end
        elseif key == KEY_R then
            if options.onReset then options.onReset()
            elseif type(runtime.Reset) == "function" then runtime:Reset() end
        else
            return false
        end
        return true
    end

    return controller
end

return SeaDebug
