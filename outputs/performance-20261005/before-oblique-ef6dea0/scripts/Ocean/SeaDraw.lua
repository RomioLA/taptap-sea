-- Sea Runtime V1 prototype world renderer. It draws shapes only; UI owns all text.
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.Draw")

local SeaDraw = {}
local FIXED_BARREL_CONTENT_ID = "driftwood_barrel"
local PORT_MARK_RADIUS = 16

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- Conservative screen envelopes include strokes; culling never changes world activity.
local function onScreen(x, y, margin, width, height, horizonY)
    return finite(x) and finite(y) and x + margin >= 0 and x - margin <= width
        and y + margin >= horizonY and y - margin <= height
end

local function fishMargin(entity, pixelsPerUnit)
    local data = FishData[entity.species]
    -- The 67-unit silhouette fits a full renderLength, including the rise scale.
    return math.max(8, (data and (data.renderLength or data.radius) or 1) * pixelsPerUnit * 1.2 + 4)
end

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

local function drawBarrelOutline(ctx, x, y, radius, pixelsPerUnit)
    local size = math.max(3, radius * pixelsPerUnit)
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, size + 2)
    nvgStrokeColor(ctx, nvgRGBA(225, 203, 156, 160))
    nvgStrokeWidth(ctx, 1.5)
    nvgStroke(ctx)
end

local function drawRecognizedBarrel(ctx, x, y, radius, pixelsPerUnit)
    local size = math.max(3, radius * pixelsPerUnit)
    local rim = nvgRGBA(225, 203, 156, 210)
    drawFloat(ctx, x, y, radius, pixelsPerUnit)

    -- A second rim and simple stave marks make the existing float read as a
    -- wooden barrel at close range, while retaining its original float color.
    nvgBeginPath(ctx)
    nvgEllipse(ctx, x, y, size * 0.72, size * 0.62)
    nvgStrokeColor(ctx, rim)
    nvgStrokeWidth(ctx, 1.3)
    nvgStroke(ctx)

    nvgBeginPath(ctx)
    nvgMoveTo(ctx, x - size * 0.46, y - size * 0.18)
    nvgLineTo(ctx, x + size * 0.46, y - size * 0.18)
    nvgMoveTo(ctx, x - size * 0.46, y + size * 0.18)
    nvgLineTo(ctx, x + size * 0.46, y + size * 0.18)
    nvgMoveTo(ctx, x, y - size * 0.56)
    nvgLineTo(ctx, x, y + size * 0.56)
    nvgStrokeColor(ctx, rim)
    nvgStrokeWidth(ctx, 1.1)
    nvgStroke(ctx)
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

local function drawPortMark(ctx, runtime, width, height, horizonY)
    if type(runtime.GetPortPosition) ~= "function" then return end
    local port = runtime:GetPortPosition()
    if type(port) ~= "table" or not finite(port.x) or not finite(port.y) then return end

    local x, y = project(runtime, port)
    if not onScreen(x, y, PORT_MARK_RADIUS + 2, width, height, horizonY) then return end

    local portColor = nvgColor(Config.visual.ship)
    local outlineColor = nvgRGBA(12, 42, 52, 235)
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, PORT_MARK_RADIUS)
    nvgStrokeColor(ctx, outlineColor)
    nvgStrokeWidth(ctx, 5)
    nvgStroke(ctx)

    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, PORT_MARK_RADIUS)
    nvgStrokeColor(ctx, portColor)
    nvgStrokeWidth(ctx, 2)
    nvgStroke(ctx)

    local function drawAnchor()
        nvgMoveTo(ctx, x, y - 8)
        nvgLineTo(ctx, x, y + 5)
        nvgMoveTo(ctx, x - 8, y - 2)
        nvgLineTo(ctx, x + 8, y - 2)
        nvgMoveTo(ctx, x - 8, y + 3)
        nvgLineTo(ctx, x - 6, y + 8)
        nvgLineTo(ctx, x, y + 10)
        nvgLineTo(ctx, x + 6, y + 8)
        nvgLineTo(ctx, x + 8, y + 3)
    end

    nvgBeginPath(ctx)
    drawAnchor()
    nvgCircle(ctx, x, y - 9, 2)
    nvgStrokeColor(ctx, outlineColor)
    nvgStrokeWidth(ctx, 4)
    nvgStroke(ctx)

    nvgBeginPath(ctx)
    drawAnchor()
    nvgCircle(ctx, x, y - 9, 2)
    nvgStrokeColor(ctx, portColor)
    nvgStrokeWidth(ctx, 1.6)
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

local function matchesFixedBarrel(world, entity, snapshot)
    return world and entity == world.fixedBarrel
        and entity.entityType == "float" and entity.kind == "fixed" and entity.layer == "surface"
        and entity.contentId == FIXED_BARREL_CONTENT_ID
        and type(snapshot) == "table" and snapshot.id == entity.id
        and snapshot.contentId == FIXED_BARREL_CONTENT_ID
        and snapshot.generation == world.fixedBarrelGeneration
        and type(snapshot.position) == "table"
        and finite(snapshot.position.x) and finite(snapshot.position.y)
end

local function drawFixedBarrel(ctx, runtime, world, entity, snapshot, pixelsPerUnit, width, height, horizonY,
    isLocationRecognized)
    if not matchesFixedBarrel(world, entity, snapshot) then return end
    local shipPosition = runtime.ship and runtime.ship.position
    if not shipPosition or not finite(shipPosition.x) or not finite(shipPosition.y) then return end

    local interaction = Config.interaction
    local outlineDistance = interaction and interaction.outlineDistance
    local recognitionDistance = interaction and interaction.recognitionDistance
    if not finite(outlineDistance) or outlineDistance < 0
        or not finite(recognitionDistance) or recognitionDistance < 0 then return end

    local dx = shipPosition.x - snapshot.position.x
    local dy = shipPosition.y - snapshot.position.y
    local distanceSquared = dx * dx + dy * dy
    if not finite(distanceSquared) or distanceSquared > outlineDistance * outlineDistance then return end

    local radius = entity.radius or 1
    if not finite(radius) or radius <= 0 or not finite(pixelsPerUnit) or pixelsPerUnit <= 0 then return end
    local x, y = project(runtime, snapshot.position)
    local size = math.max(3, radius * pixelsPerUnit)
    if not onScreen(x, y, size + 4, width, height, horizonY) then return end

    -- Gameplay owns recognition, including save/load and new-game clearing.
    -- Read it only for the stable, visible content identity; never retain progress here.
    local recognized = type(isLocationRecognized) == "function"
        and isLocationRecognized(snapshot.contentId) == true
    if distanceSquared <= recognitionDistance * recognitionDistance or recognized then
        drawRecognizedBarrel(ctx, x, y, radius, pixelsPerUnit)
    else
        drawBarrelOutline(ctx, x, y, radius, pixelsPerUnit)
    end
end

-- Presentation only. Phase and world elapsed time are owned by Gameplay/B.
-- No phase transitions, target selection, charges or completion happen in drawing.
local function drawFishing(ctx, runtime, view, pixelsPerUnit, width, height, horizonY)
    if type(view) ~= "table" or type(view.center) ~= "table"
        or not finite(view.center.x) or not finite(view.center.y) then return end
    local phase = view.phase
    if phase ~= "aim" and phase ~= "casting" and phase ~= "reeling" then return end
    local elapsed = view.elapsedSec
    if not finite(elapsed) or elapsed < 0 then return end
    local x, y = project(runtime, view.center)
    if not finite(x) or not finite(y) then return end
    ---@type number
    local radius = Config.fishing.netRadius * pixelsPerUnit
    local sx, sy = project(runtime, runtime.ship and runtime.ship.position)
    -- Confirmed visual landing time; does not start/finish any gameplay stage.
    local landingSec = 0.5
    if phase == "casting" and elapsed < landingSec then
        if not finite(sx) or not finite(sy) then return end
        local progress = elapsed / landingSec
        local flightX = sx + (x - sx) * progress
        local flightY = sy + (y - sy) * progress - radius * math.sin(math.pi * progress)
        local flightRadius = radius * progress
        if not onScreen(flightX, flightY, flightRadius + 3, width, height, horizonY) then return end
        nvgBeginPath(ctx)
        nvgCircle(ctx, flightX, flightY, math.max(3, flightRadius))
        nvgStrokeColor(ctx, nvgRGBA(255, 236, 183, 210))
        nvgStrokeWidth(ctx, 1.8)
        nvgStroke(ctx)
        return
    end
    -- Cosmetic contraction uses only the confirmed .5..4s interval.
    local reelingProgress = phase == "reeling" and math.max(0, math.min(1,
        (elapsed - landingSec) / (Config.fishing.durationSec - landingSec))) or 0
    local netRadius = radius * (1 - reelingProgress)
    if onScreen(x, y, netRadius + 3, width, height, horizonY) then
        nvgBeginPath(ctx)
        nvgCircle(ctx, x, y, netRadius)
        nvgStrokeColor(ctx, nvgRGBA(255, 236, 183, phase == "aim" and 150 or 220))
        nvgStrokeWidth(ctx, phase == "aim" and 1.4 or 2)
        nvgStroke(ctx)
        if phase == "aim" then
            nvgBeginPath(ctx)
            nvgMoveTo(ctx, x - 5, y)
            nvgLineTo(ctx, x + 5, y)
            nvgMoveTo(ctx, x, y - 5)
            nvgLineTo(ctx, x, y + 5)
            nvgStrokeWidth(ctx, 1.4)
            nvgStroke(ctx)
        else
            -- Simple cross mesh is clipped analytically to the circular net.
            nvgBeginPath(ctx)
            for index = -2, 2 do
                local offset = netRadius * index / 3
                local chord = math.sqrt(math.max(0, netRadius * netRadius - offset * offset))
                nvgMoveTo(ctx, x + offset, y - chord)
                nvgLineTo(ctx, x + offset, y + chord)
                nvgMoveTo(ctx, x - chord, y + offset)
                nvgLineTo(ctx, x + chord, y + offset)
            end
            nvgStrokeColor(ctx, nvgRGBA(255, 236, 183, 90))
            nvgStrokeWidth(ctx, 1)
            nvgStroke(ctx)
        end
    end
    if phase == "casting" then
        local lifetime = Config.surfaceSignals.splashLifetime
        local age = elapsed - landingSec
        if age >= 0 and age < lifetime
            and onScreen(x, y, 4 * pixelsPerUnit + 3, width, height, horizonY) then
            Draw.WorldSplash(ctx, x, y, pixelsPerUnit, lifetime - age, lifetime, 0, 0)
        end
    elseif phase == "reeling" and finite(sx) and finite(sy) then
        -- A line can cross the viewport even when its endpoint lies outside it.
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, sx, sy)
        nvgLineTo(ctx, x, y)
        nvgStrokeColor(ctx, nvgRGBA(255, 236, 183, 170))
        nvgStrokeWidth(ctx, 1.5)
        nvgStroke(ctx)
    end
end

--- Draw one frame inside the NanoVG frame owned by the caller.
---@param ctx NVGContextWrapper
---@param width number Logical screen width in the caller's NanoVG mode B.
---@param height number Logical screen height in the caller's NanoVG mode B.
---@param runtime table
---@param clock table? Read-only reference to the existing Gameplay clock.
---@param fishingView table? Read-only Gameplay snapshot; optional sixth argument.
---@param isLocationRecognized (fun(contentId: string): boolean)? Read-only Gameplay query.
function SeaDraw.Scene(ctx, width, height, runtime, clock, fishingView, isLocationRecognized)
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
    ---@type OceanFixedBarrelSnapshot?
    local fixedBarrelSnapshot
    if type(runtime.GetFixedBarrel) == "function" then
        fixedBarrelSnapshot = runtime:GetFixedBarrel()
    end
    local debugFlags = runtime.debug or Config.debug
    local horizonY = height * (Config.layers.waves or 0.32)

    -- Keep projected world entities in the water region; backdrop birds remain untouched.
    nvgSave(ctx)
    nvgScissor(ctx, 0, horizonY, width, math.max(0, height - horizonY))

    -- Water objects are filtered solely by World:isVisible; this never grants interactions.
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.species and entity.layer == "underwater" and isVisible(world, entity) then
            local x, y = project(runtime, entity.position)
            if onScreen(x, y, fishMargin(entity, pixelsPerUnit), width, height, horizonY) then
                drawFish(ctx, entity, x, y, pixelsPerUnit, debugFlags.showActivity, runtime.time or 0)
            end
        end
    end

    for _, entity in ipairs(entities) do
        if not entity.removed and not entity.species and isVisible(world, entity) then
            local x, y = project(runtime, entity.position)
            if x and y then
                if entity.entityType == "island" then
                    Draw.WorldIsland(ctx, x, y, pixelsPerUnit, entity, runtime.time or 0)
                elseif entity.entityType == "float" then
                    if world and entity == world.fixedBarrel then
                        drawFixedBarrel(ctx, runtime, world, entity, fixedBarrelSnapshot,
                            pixelsPerUnit, width, height, horizonY, isLocationRecognized)
                    else
                        drawFloat(ctx, x, y, entity.radius or 1, pixelsPerUnit)
                    end
                elseif entity.entityType == "droppedItem" then
                    drawDroppedItem(ctx, entity, x, y, pixelsPerUnit)
                end
            end
        end
    end

    for _, entity in ipairs(entities) do
        if not entity.removed and entity.species and entity.layer ~= "underwater" and isVisible(world, entity) then
            local x, y = project(runtime, entity.position)
            if onScreen(x, y, fishMargin(entity, pixelsPerUnit), width, height, horizonY) then
                drawFish(ctx, entity, x, y, pixelsPerUnit, debugFlags.showActivity, runtime.time or 0)
            end
        end
    end

    -- Surface hints read actual fish state without revealing every underwater fish.
    for _, entity in ipairs(entities) do
        if not entity.removed and not entity.captureLocked and entity.active ~= false and not entity.frozen
            and entity.species == "sardine" and (entity.surfaceDepth or 0) > 0 then
            local x, y = project(runtime, entity.position)
            if onScreen(x, y, math.max(fishMargin(entity, pixelsPerUnit), 1.5 * pixelsPerUnit + 3), width, height, horizonY) then
                Draw.WorldRise(ctx, x, y, pixelsPerUnit, entity, runtime.time or 0)
            end
        end
    end
    local signals = runtime.surfaceSignals
    if signals then
        -- Scalar visits preserve current-source checks without allocating a
        -- detached record and position for every cue in every rendered frame.
        local point = { x = 0, y = 0 }
        local function drawSplash(px, py, remaining, lifetime, heading, trailLength)
            point.x, point.y = px, py
            local x, y = project(runtime, point)
            if onScreen(x, y, 4 * pixelsPerUnit + 3, width, height, horizonY) then
                Draw.WorldSplash(ctx, x, y, pixelsPerUnit, remaining, lifetime,
                    heading or 0, trailLength or 2)
            end
        end
        local function drawBird(px, py, heading, diveProgress)
            point.x, point.y = px, py
            local x, y = project(runtime, point)
            if onScreen(x, y, pixelsPerUnit + 3, width, height, horizonY) then
                Draw.WorldSeabird(ctx, x, y, pixelsPerUnit, heading or 0, diveProgress)
            end
        end
        if type(signals.VisitSplashes) == "function" then
            signals:VisitSplashes(drawSplash)
        else
            for _, splash in ipairs(signals:GetSplashes()) do
                drawSplash(splash.position.x, splash.position.y, splash.remaining, splash.lifetime,
                    splash.heading, splash.trailLength)
            end
        end
        if type(signals.VisitBirds) == "function" then
            signals:VisitBirds(drawBird)
        else
            for _, bird in ipairs(signals:GetBirds()) do
                drawBird(bird.position.x, bird.position.y, bird.heading, bird.diveProgress)
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

    drawPortMark(ctx, runtime, width, height, horizonY)

    if debugFlags.showPerception then
        for _, entity in ipairs(entities) do
            if not entity.removed and entity.species and isVisible(world, entity) then
                local x, y = project(runtime, entity.position)
                if x and y then drawPerception(ctx, entity, x, y, pixelsPerUnit) end
            end
        end
    end

    drawFishing(ctx, runtime, fishingView, pixelsPerUnit, width, height, horizonY)
    drawTarget(ctx, runtime)
    if debugFlags.showBounds then
        drawBounds(ctx, runtime)
        drawIslandBounds(ctx, entities, runtime, pixelsPerUnit, world)
    end
    nvgRestore(ctx)
end

return SeaDraw
