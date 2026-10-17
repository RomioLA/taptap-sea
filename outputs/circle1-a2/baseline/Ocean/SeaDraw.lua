-- Sea Runtime V1 prototype world renderer. It draws shapes only; UI owns all text.
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.Draw")

local SeaDraw = {}

local function nvgColor(color, fallback)
    local value = color or fallback or { 255, 255, 255, 255 }
    return nvgRGBA(value[1] or 255, value[2] or 255, value[3] or 255, value[4] or 255)
end

local function project(runtime, position)
    local movement = runtime and runtime.movement
    if not movement or type(movement.WorldToScreen) ~= "function" or not position then
        return nil, nil
    end
    local x, y = movement:WorldToScreen(position)
    if type(x) == "table" then
        return x.x, x.y
    end
    return x, y
end

local function isVisible(world, entity)
    if world and type(world.isVisible) == "function" then
        return world:isVisible(entity)
    end
    return entity.layer ~= "underwater"
end

local function drawFloat(ctx, x, y, radius, pixelsPerUnit)
    local size = math.max(3, radius * pixelsPerUnit)
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, size + 2)
    nvgStrokeColor(ctx, nvgRGBA(225, 203, 156, 160))
    nvgStrokeWidth(ctx, 1.5)
    nvgStroke(ctx)
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, size)
    nvgFillColor(ctx, nvgColor(Config.visual.float))
    nvgFill(ctx)
end

local function drawDroppedItem(ctx, entity, x, y, pixelsPerUnit)
    local size = math.max(3, (entity.radius or 0.7) * pixelsPerUnit)
    local color = entity.worldEffect and entity.worldEffect ~= "NONE"
        and Config.visual.effect or Config.visual.float
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, x, y - size)
    nvgLineTo(ctx, x + size, y)
    nvgLineTo(ctx, x, y + size)
    nvgLineTo(ctx, x - size, y)
    nvgClosePath(ctx)
    nvgFillColor(ctx, nvgColor(color))
    nvgFill(ctx)
    nvgStrokeColor(ctx, nvgRGBA(255, 238, 192, 210))
    nvgStrokeWidth(ctx, 1)
    nvgStroke(ctx)

    if entity.worldEffect == "ATTRACT_SMALL_FISH" then
        local fishConfig = FishData.sardine
        local ringRadius = (fishConfig and fishConfig.attractRadius or 0) * pixelsPerUnit
        if ringRadius > 0 then
            nvgBeginPath(ctx)
            nvgCircle(ctx, x, y, ringRadius)
            nvgStrokeColor(ctx, nvgRGBA(255, 204, 111, 48))
            nvgStrokeWidth(ctx, 1)
            nvgStroke(ctx)
        end
    end
end

local function drawFish(ctx, entity, x, y, pixelsPerUnit, showActivity, time)
    local fishConfig = FishData[entity.species]
    if not fishConfig then return end
    local radius = entity.radius or fishConfig.radius or 0.6
    local size = math.max(2.5, radius * pixelsPerUnit)

    if showActivity then
        nvgBeginPath(ctx)
        nvgCircle(ctx, x, y, size + 2)
        if entity.frozen then
            nvgStrokeColor(ctx, nvgRGBA(179, 190, 202, 180))
        elseif entity.active then
            nvgStrokeColor(ctx, nvgRGBA(120, 232, 166, 210))
        else
            nvgStrokeColor(ctx, nvgRGBA(202, 169, 122, 170))
        end
        nvgStrokeWidth(ctx, 1.3)
        nvgStroke(ctx)
    end

    Draw.WorldFish(ctx, x, y, pixelsPerUnit, entity, time)
end

local function drawPerception(ctx, entity, x, y, pixelsPerUnit)
    local fishConfig = FishData[entity.species]
    if not fishConfig then return end
    local function circle(radius, color)
        if not radius or radius == false or radius <= 0 then return end
        nvgBeginPath(ctx)
        nvgCircle(ctx, x, y, radius * pixelsPerUnit)
        nvgStrokeColor(ctx, nvgColor(color))
        nvgStrokeWidth(ctx, 1.2)
        nvgStroke(ctx)
    end
    if entity.species == "sardine" then
        circle(fishConfig.dangerRadius, { 246, 104, 119, 100 })
        circle(fishConfig.attractRadius, { 255, 207, 111, 100 })
    elseif entity.species == "tuna" then
        circle(fishConfig.preyRadius, { 103, 192, 255, 96 })
    end
end

local function drawTarget(ctx, runtime)
    local movement = runtime.movement
    if not movement then return end
    local target = movement.targetPosition or movement.destination or movement.target
    if type(movement.GetTarget) == "function" then
        local candidate = movement:GetTarget()
        if candidate then target = candidate end
    end
    if type(target) == "table" and target.position then target = target.position end
    if type(target) ~= "table" or type(target.x) ~= "number" or type(target.y) ~= "number" then return end
    if movement.hasTarget == false or movement.targetActive == false then return end
    local x, y = project(runtime, target)
    if not x or not y then return end
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, 8)
    nvgStrokeColor(ctx, nvgColor(Config.visual.target))
    nvgStrokeWidth(ctx, 1.5)
    nvgStroke(ctx)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, x - 12, y)
    nvgLineTo(ctx, x + 12, y)
    nvgMoveTo(ctx, x, y - 12)
    nvgLineTo(ctx, x, y + 12)
    nvgStrokeColor(ctx, nvgColor(Config.visual.target))
    nvgStrokeWidth(ctx, 1)
    nvgStroke(ctx)
end

local function drawBounds(ctx, runtime)
    local half = Config.world.halfSize
    local corners = {
        { x = -half, y = -half },
        { x = half, y = -half },
        { x = half, y = half },
        { x = -half, y = half },
    }
    nvgBeginPath(ctx)
    for index, point in ipairs(corners) do
        local x, y = project(runtime, point)
        if not x or not y then return end
        if index == 1 then nvgMoveTo(ctx, x, y) else nvgLineTo(ctx, x, y) end
    end
    local firstX, firstY = project(runtime, corners[1])
    if not firstX or not firstY then return end
    nvgLineTo(ctx, firstX, firstY)
    nvgStrokeColor(ctx, nvgColor(Config.visual.bound))
    nvgStrokeWidth(ctx, 1.2)
    nvgStroke(ctx)
end

local function drawIslandBounds(ctx, entities, runtime, pixelsPerUnit, world)
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.entityType == "island" and isVisible(world, entity) then
            local x, y = project(runtime, entity.position)
            local radius = (entity.radius or 1) * pixelsPerUnit
            if x and y and radius > 0 then
                nvgBeginPath(ctx)
                nvgCircle(ctx, x, y, radius)
                nvgStrokeColor(ctx, nvgColor(Config.visual.bound))
                nvgStrokeWidth(ctx, 1.2)
                nvgStroke(ctx)
            end
        end
    end
end

local function nearbyEntities(runtime, width, height)
    local world = runtime.world
    if not world or type(world.queryEntitiesInRadius) ~= "function" then
        return world and world.entities or {}
    end
    local movement = runtime.movement
    local center = movement and movement.camera or (runtime.ship and runtime.ship.position)
    if not center then return world.entities or {} end
    local viewHeight = movement and movement.viewHeight or Config.camera.viewHeight
    local viewWidth = movement and movement.viewWidth or viewHeight * width / math.max(height, 1)
    local radiusSquared = (viewWidth * 0.5) ^ 2 + (viewHeight * 0.5) ^ 2
    local padding = 0
    for _, object in ipairs(Config.world.fixedObjects or {}) do
        padding = math.max(padding, object.radius or 0)
    end
    for _, fish in pairs(FishData) do
        padding = math.max(padding, fish.radius or 0)
        padding = math.max(padding, fish.dangerRadius or 0, fish.attractRadius or 0, fish.preyRadius or 0)
    end
    return world:queryEntitiesInRadius(center, math.sqrt(radiusSquared) + padding)
end

--- Draw one frame inside the NanoVG frame owned by the caller.
---@param ctx NVGContextWrapper
---@param width number Logical screen width in the caller's NanoVG mode B.
---@param height number Logical screen height in the caller's NanoVG mode B.
---@param runtime table
---@param clock table? Read-only reference to the existing Gameplay clock.
function SeaDraw.Scene(ctx, width, height, runtime, clock)
    if not ctx or width <= 0 or height <= 0 then return end
    runtime = runtime or {}
    local viewHeight = runtime.movement and runtime.movement.viewHeight or Config.camera.viewHeight
    local pixelsPerUnit = height / math.max(1, viewHeight)
    local ship = runtime.ship
    local shipPosition = ship and ship.position
    if not shipPosition then shipPosition = { x = 0, y = 0 } end
    local shipX, shipY = project(runtime, shipPosition)
    if not shipX or not shipY then
        shipX, shipY = width * 0.5, height * (Config.camera.anchorY or 0.6)
    end
    Draw.SceneBackdrop(ctx, width, height, runtime.time or 0)

    local world = runtime.world
    local entities = nearbyEntities(runtime, width, height)
    local debugFlags = runtime.debug or Config.debug
    local horizonY = height * (Config.layers.waves or 0.32)

    -- Keep projected world entities in the water region; backdrop birds remain untouched.
    nvgSave(ctx)
    nvgScissor(ctx, 0, horizonY, width, math.max(0, height - horizonY))

    -- Water objects are filtered solely by World:isVisible; this never grants interactions.
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.species and entity.layer == "underwater" and isVisible(world, entity) then
            local x, y = project(runtime, entity.position)
            if x and y then drawFish(ctx, entity, x, y, pixelsPerUnit, debugFlags.showActivity, runtime.time or 0) end
        end
    end

    for _, entity in ipairs(entities) do
        if not entity.removed and not entity.species and isVisible(world, entity) then
            local x, y = project(runtime, entity.position)
            if x and y then
                if entity.entityType == "island" then
                    Draw.WorldIsland(ctx, x, y, pixelsPerUnit, entity, runtime.time or 0)
                elseif entity.entityType == "float" then
                    drawFloat(ctx, x, y, entity.radius or 1, pixelsPerUnit)
                elseif entity.entityType == "droppedItem" then
                    drawDroppedItem(ctx, entity, x, y, pixelsPerUnit)
                end
            end
        end
    end

    for _, entity in ipairs(entities) do
        if not entity.removed and entity.species and entity.layer ~= "underwater" and isVisible(world, entity) then
            local x, y = project(runtime, entity.position)
            if x and y then drawFish(ctx, entity, x, y, pixelsPerUnit, debugFlags.showActivity, runtime.time or 0) end
        end
    end

    -- Surface hints read actual fish state without revealing every underwater fish.
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.active ~= false and not entity.frozen
            and entity.species == "sardine" and (entity.surfaceDepth or 0) > 0 then
            local x, y = project(runtime, entity.position)
            if x and y then Draw.WorldRise(ctx, x, y, pixelsPerUnit, entity, runtime.time or 0) end
        end
    end
    local signals = runtime.surfaceSignals
    if signals then
        for _, splash in ipairs(signals:GetSplashes()) do
            local x, y = project(runtime, splash.position)
            if x and y then
                Draw.WorldSplash(ctx, x, y, pixelsPerUnit, splash.remaining, splash.lifetime,
                    splash.heading or 0, splash.trailLength or 2)
            end
        end
        for _, bird in ipairs(signals:GetBirds()) do
            local x, y = project(runtime, bird.position)
            if x and y then
                Draw.WorldSeabird(ctx, x, y, pixelsPerUnit, bird.heading or 0, bird.diveProgress)
            end
        end
    end

    if clock and clock.phase == "night" then
        -- Tint the full backdrop and sea, then restore the water clip for the boat.
        -- The boat, navigation/debug marks and UI remain above the night tint.
        nvgRestore(ctx)
        Draw.NightOverlay(ctx, width, height, clock)
        nvgSave(ctx)
        nvgScissor(ctx, 0, horizonY, width, math.max(0, height - horizonY))
    end

    if ship and ship.position then
        local x, y = project(runtime, ship.position)
        if x and y then Draw.WorldBoat(ctx, x, y, pixelsPerUnit, ship, runtime.time or 0) end
    end

    if debugFlags.showPerception then
        for _, entity in ipairs(entities) do
            if not entity.removed and entity.species and isVisible(world, entity) then
                local x, y = project(runtime, entity.position)
                if x and y then drawPerception(ctx, entity, x, y, pixelsPerUnit) end
            end
        end
    end

    drawTarget(ctx, runtime)
    if debugFlags.showBounds then
        drawBounds(ctx, runtime)
        drawIslandBounds(ctx, entities, runtime, pixelsPerUnit, world)
    end
    nvgRestore(ctx)
end

return SeaDraw
