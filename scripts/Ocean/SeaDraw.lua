-- Read-only 2.5D sea presentation. All interaction ranges stay in world meters.
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.Draw")
local Art = require("Ocean.SeaViewArt")
local Geometry = require("Ocean.ProjectedGeometry")
local SeaDraw = {}
local FIXED_BARREL_CONTENT_ID = "driftwood_barrel"
local PORT_MARK_RADIUS = 16

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function onScreen(x, y, margin, width, height, horizon)
    return finite(x) and finite(y) and x + margin >= 0 and x - margin <= width
        and y + margin >= horizon and y - margin <= height
end

local function color(value)
    return nvgRGBA(value[1], value[2], value[3], value[4] or 255)
end

local function isVisible(world, entity)
    if world and type(world.isVisible) == "function" then return world:isVisible(entity) end
    return entity.layer ~= "underwater"
end

-- Keep the existing small vector silhouettes, applying the same projection's
-- differential, including perspective shear. Only art is transformed.
local function groundFrame(ctx, movement, point, altitude, callback, extentMeters)
    local x, y, scale = movement:WorldToScreen(point, altitude)
    if not x then return end
    local vx, vy = movement:ProjectVector(point, 0, -1)
    if not vx then return end
    local margin = math.max(8, scale * (extentMeters or 3)
        * (1 + math.abs(vx / scale) + math.abs(vy / scale)) + 4)
    if not onScreen(x, y, margin, movement.viewportWidth, movement.viewportHeight, movement:GetHorizonY()) then return end
    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    nvgTransform(ctx, 1, 0, vx / scale, vy / scale, 0, 0)
    callback(scale)
    nvgRestore(ctx)
end

local function worldLine(ctx, movement, a, b, tint, width)
    Geometry.WorldLine(ctx, movement, a, b, tint, width)
end

local function drawFloat(ctx, movement, entity, outlineOnly, recognized)
    local point, radius = entity.position, entity.radius or 1
    Geometry.WorldCircle(ctx, movement, point, radius, outlineOnly and nil or Config.visual.float,
        { 225, 203, 156, 160 }, 1.5)
    if not recognized then return end
    Geometry.WorldCircle(ctx, movement, point, radius * 0.72, nil, { 225, 203, 156, 210 }, 1.3)
    local tint = { 225, 203, 156, 210 }
    for _, offset in ipairs({ -0.3, 0.3 }) do
        worldLine(ctx, movement, { x = point.x - radius * 0.55, y = point.y + radius * offset },
            { x = point.x + radius * 0.55, y = point.y + radius * offset }, tint, 1.1)
    end
    worldLine(ctx, movement, { x = point.x, y = point.y - radius * 0.65 },
        { x = point.x, y = point.y + radius * 0.65 }, tint, 1.1)
end

local function drawFixedBarrel(ctx, runtime, entity, snapshot, recognizedQuery)
    local world = runtime.world
    if entity ~= world.fixedBarrel or entity.entityType ~= "float" or entity.kind ~= "fixed"
        or entity.layer ~= "surface" or entity.contentId ~= FIXED_BARREL_CONTENT_ID
        or type(snapshot) ~= "table" or snapshot.id ~= entity.id
        or snapshot.contentId ~= FIXED_BARREL_CONTENT_ID or snapshot.generation ~= world.fixedBarrelGeneration
        or type(snapshot.position) ~= "table" or not finite(snapshot.position.x) or not finite(snapshot.position.y) then return end
    local point = runtime.ship.position
    local dx, dy = point.x - snapshot.position.x, point.y - snapshot.position.y
    local squared = dx * dx + dy * dy
    if squared > Config.interaction.outlineDistance ^ 2 then return end
    -- Keep persistent-recognition reads behind the same visible-world geometry
    -- filter as the barrel silhouette, including partially visible shore edges.
    if #Geometry.ClipPolygon(runtime.movement,
        Geometry.SampleCircle(snapshot.position, entity.radius or 1)) < 3 then return end
    local recognized = squared <= Config.interaction.recognitionDistance ^ 2
        or type(recognizedQuery) == "function" and recognizedQuery(snapshot.contentId) == true
    drawFloat(ctx, runtime.movement, entity, not recognized, recognized)
end

local function drawDroppedItem(ctx, movement, entity)
    local point, radius = entity.position, entity.radius or 0.7
    local tint = entity.worldEffect and entity.worldEffect ~= "NONE" and Config.visual.effect or Config.visual.float
    Geometry.WorldPolygon(ctx, movement, {
        { x = point.x, y = point.y + radius }, { x = point.x + radius, y = point.y },
        { x = point.x, y = point.y - radius }, { x = point.x - radius, y = point.y },
    }, tint, { 255, 238, 192, 210 }, 1)
    if entity.worldEffect == "ATTRACT_SMALL_FISH" then
        Geometry.WorldCircle(ctx, movement, point, FishData.sardine.attractRadius,
            nil, { 255, 204, 111, 48 }, 1)
    end
end

local function drawFish(ctx, movement, entity, showActivity, time)
    if not FishData[entity.species] then return end
    if showActivity then
        local tint = entity.frozen and { 179, 190, 202, 180 }
            or entity.active and { 120, 232, 166, 210 } or { 202, 169, 122, 170 }
        Geometry.WorldCircle(ctx, movement, entity.position, entity.radius or FishData[entity.species].radius,
            nil, tint, 1.3)
    end
    groundFrame(ctx, movement, entity.position, 0, function(scale)
        Draw.WorldFish(ctx, 0, 0, scale, entity, time)
    end, (FishData[entity.species].renderLength or 1) * 1.2)
end

local function drawPerception(ctx, movement, entity)
    local data = FishData[entity.species]
    if not data then return end
    local function circle(radius, tint)
        if type(radius) == "number" and radius > 0 then
            Geometry.WorldCircle(ctx, movement, entity.position, radius, nil, tint, 1.2)
        end
    end
    if entity.species == "sardine" then
        circle(data.dangerRadius, { 246, 104, 119, 100 })
        circle(data.attractRadius, { 255, 207, 111, 100 })
    elseif entity.species == "tuna" then circle(data.preyRadius, { 103, 192, 255, 96 }) end
end

local function drawTarget(ctx, movement)
    local target = movement.target
    if not target then return end
    local x, y = movement:WorldToScreen(target)
    if not x then return end
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, 8)
    nvgMoveTo(ctx, x - 12, y)
    nvgLineTo(ctx, x + 12, y)
    nvgMoveTo(ctx, x, y - 12)
    nvgLineTo(ctx, x, y + 12)
    nvgStrokeColor(ctx, color(Config.visual.target))
    nvgStrokeWidth(ctx, 1.5)
    nvgStroke(ctx)
end

local function drawPortMark(ctx, runtime, width, height, horizon)
    if type(runtime.GetPortPosition) ~= "function" then return end
    local point = runtime:GetPortPosition()
    local x, y = runtime.movement:WorldToScreen(point)
    if not onScreen(x, y, PORT_MARK_RADIUS + 2, width, height, horizon) then return end
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, PORT_MARK_RADIUS)
    nvgStrokeColor(ctx, nvgRGBA(12, 42, 52, 235))
    nvgStrokeWidth(ctx, 5)
    nvgStroke(ctx)
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, PORT_MARK_RADIUS)
    nvgMoveTo(ctx, x, y - 8)
    nvgLineTo(ctx, x, y + 5)
    nvgMoveTo(ctx, x - 8, y - 2)
    nvgLineTo(ctx, x + 8, y - 2)
    nvgMoveTo(ctx, x - 8, y + 3)
    nvgLineTo(ctx, x - 6, y + 8)
    nvgLineTo(ctx, x, y + 10)
    nvgLineTo(ctx, x + 6, y + 8)
    nvgLineTo(ctx, x + 8, y + 3)
    nvgStrokeColor(ctx, color(Config.visual.ship))
    nvgStrokeWidth(ctx, 1.6)
    nvgStroke(ctx)
end

local function nearbyEntities(runtime)
    local world, movement = runtime.world, runtime.movement
    if not world then return {} end
    if type(world.queryEntitiesInRadius) ~= "function" then return world.entities end
    local padding = 0
    for _, object in ipairs(Config.world.fixedObjects) do padding = math.max(padding, object.radius or 0) end
    for _, data in pairs(FishData) do
        padding = math.max(padding, data.radius or 0, data.renderLength or 0,
            data.dangerRadius or 0, data.attractRadius or 0, data.preyRadius or 0)
    end
    local bounds = movement:GetViewBounds(padding)
    local center = { x = (bounds.minX + bounds.maxX) * 0.5, y = (bounds.minY + bounds.maxY) * 0.5 }
    local radius = math.sqrt((bounds.maxX - bounds.minX) ^ 2 + (bounds.maxY - bounds.minY) ^ 2) * 0.5
    return world:queryEntitiesInRadius(center, radius)
end

local function drawFishing(ctx, runtime, view)
    if type(view) ~= "table" or type(view.center) ~= "table"
        or not finite(view.center.x) or not finite(view.center.y) then return end
    local phase, elapsed = view.phase, view.elapsedSec
    if phase ~= "aim" and phase ~= "casting" and phase ~= "reeling" then return end
    if not finite(elapsed) or elapsed < 0 then return end
    local movement, center = runtime.movement, view.center
    local radius, landingSec = Config.fishing.netRadius, 0.5
    if phase == "casting" and elapsed < landingSec then
        local progress, ship = elapsed / landingSec, runtime.ship.position
        local flight = { x = ship.x + (center.x - ship.x) * progress,
            y = ship.y + (center.y - ship.y) * progress }
        Geometry.WorldCircle(ctx, movement, flight, radius * progress, nil,
            { 255, 236, 183, 210 }, 1.8, radius * math.sin(math.pi * progress))
        return
    end
    local reeling = phase == "reeling" and math.max(0, math.min(1,
        (elapsed - landingSec) / (Config.fishing.durationSec - landingSec))) or 0
    local netRadius = radius * (1 - reeling)
    Geometry.WorldCircle(ctx, movement, center, netRadius, nil,
        { 255, 236, 183, phase == "aim" and 150 or 220 }, phase == "aim" and 1.4 or 2)
    if phase ~= "aim" then
        for index = -2, 2 do
            local offset = netRadius * index / 3
            local chord = math.sqrt(math.max(0, netRadius * netRadius - offset * offset))
            worldLine(ctx, movement, { x = center.x + offset, y = center.y - chord },
                { x = center.x + offset, y = center.y + chord }, { 255, 236, 183, 90 }, 1)
            worldLine(ctx, movement, { x = center.x - chord, y = center.y + offset },
                { x = center.x + chord, y = center.y + offset }, { 255, 236, 183, 90 }, 1)
        end
    end
    if phase == "reeling" then
        worldLine(ctx, movement, runtime.ship.position, center, { 255, 236, 183, 170 }, 1.5)
    elseif phase == "casting" then
        local lifetime, age = Config.surfaceSignals.splashLifetime, elapsed - landingSec
        if age >= 0 and age < lifetime then
            groundFrame(ctx, movement, center, 0, function(scale)
                Draw.WorldSplash(ctx, 0, 0, scale, lifetime - age, lifetime, 0, 0)
            end)
        end
    end
end

-- Scalar signal visitors validate their live sources. Store only frame-local
-- presentation records and never manufacture fish cues in the distant backdrop.
local function surfaceEntries(runtime, entities)
    local entries, world, movement = {}, runtime.world, runtime.movement
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.id ~= runtime.ship.id then
            if isVisible(world, entity) and entity.layer ~= "underwater" then
                entries[#entries + 1] = { kind = "entity", position = entity.position, entity = entity }
            end
            if not entity.captureLocked and entity.active ~= false and not entity.frozen
                and entity.species == "sardine" and (entity.surfaceDepth or 0) > 0 then
                entries[#entries + 1] = { kind = "rise", position = entity.position, entity = entity }
            end
        end
    end
    entries[#entries + 1] = { kind = "ship", position = runtime.ship.position, entity = runtime.ship }
    local signals = runtime.surfaceSignals
    if signals then
        local function splash(x, y, remaining, lifetime, heading, length)
            entries[#entries + 1] = { kind = "splash", position = { x = x, y = y },
                remaining = remaining, lifetime = lifetime, heading = heading or 0, length = length or 2 }
        end
        local function bird(x, y, heading, dive)
            entries[#entries + 1] = { kind = "bird", position = { x = x, y = y },
                heading = heading or 0, dive = dive }
        end
        if type(signals.VisitSplashes) == "function" then signals:VisitSplashes(splash)
        else
            for _, cue in ipairs(signals:GetSplashes()) do
                splash(cue.position.x, cue.position.y, cue.remaining, cue.lifetime, cue.heading, cue.trailLength)
            end
        end
        if type(signals.VisitBirds) == "function" then signals:VisitBirds(bird)
        else
            for _, cue in ipairs(signals:GetBirds()) do bird(cue.position.x, cue.position.y, cue.heading, cue.diveProgress) end
        end
    end
    -- Stable painter ordering: distant ship/floats/cues go behind nearer islands.
    for index, entry in ipairs(entries) do entry.order = index end
    table.sort(entries, function(a, b)
        if a.position.y == b.position.y then return a.order < b.order end
        return a.position.y > b.position.y
    end)
    return entries
end

---@param ctx NVGContextWrapper
---@param width number Mode B logical pixels.
---@param height number Mode B logical pixels.
---@param runtime table
---@param clock table? Existing read-only Gameplay clock.
---@param fishingView table? Existing read-only Gameplay fishing view.
---@param isLocationRecognized (fun(contentId: string): boolean)?
function SeaDraw.Scene(ctx, width, height, runtime, clock, fishingView, isLocationRecognized)
    if not ctx or width <= 0 or height <= 0 or not runtime or not runtime.movement then return end
    local movement, world, time = runtime.movement, runtime.world, runtime.time or 0
    local horizon = movement:GetHorizonY()
    Art.Backdrop(ctx, width, height, time)
    Art.Surface(ctx, movement, time)
    -- Tint the water/sky before projected objects; depth ordering, ship and UI
    -- stay legible. Rendering only reads the authoritative clock.
    if clock and clock.phase == "night" then Draw.NightOverlay(ctx, width, height, clock) end
    nvgSave(ctx)
    nvgScissor(ctx, 0, horizon, width, height - horizon)
    local flags, entities = runtime.debug or Config.debug, nearbyEntities(runtime)
    local scope = world and type(world.GetScopeView) == "function" and world:GetScopeView() or nil
    if scope then
        Geometry.WorldSector(ctx, movement, scope.center, scope.radius, scope.heading, scope.halfAngle,
            { 172, 232, 224, 24 }, { 197, 243, 226, 130 }, 1.2)
    end
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.species and entity.layer == "underwater" and isVisible(world, entity) then
            drawFish(ctx, movement, entity, flags.showActivity, time)
        end
    end
    Art.Wake(ctx, movement, movement.wake)
    local snapshot = type(runtime.GetFixedBarrel) == "function" and runtime:GetFixedBarrel() or nil
    for _, entry in ipairs(surfaceEntries(runtime, entities)) do
        local entity, point = entry.entity, entry.position
        if entry.kind == "ship" then Art.Boat(ctx, movement, entity, time)
        elseif entry.kind == "entity" then
            if entity.entityType == "island" then Art.Island(ctx, movement, entity, time)
            elseif entity.entityType == "float" then
                if world and entity == world.fixedBarrel then
                    drawFixedBarrel(ctx, runtime, entity, snapshot, isLocationRecognized)
                else drawFloat(ctx, movement, entity) end
            elseif entity.entityType == "droppedItem" then drawDroppedItem(ctx, movement, entity)
            elseif entity.species then drawFish(ctx, movement, entity, flags.showActivity, time) end
        elseif entry.kind == "rise" then
            groundFrame(ctx, movement, point, 0,
                function(scale) Draw.WorldRise(ctx, 0, 0, scale, entity, time) end,
                (FishData[entity.species].renderLength or 1) * 1.5)
        elseif entry.kind == "splash" then
            groundFrame(ctx, movement, point, 0, function(scale)
                Draw.WorldSplash(ctx, 0, 0, scale, entry.remaining, entry.lifetime, entry.heading, entry.length)
            end, math.max(3, entry.length))
        elseif entry.kind == "bird" then
            local altitude = Config.visual.projection.birdAltitude * (1 - (entry.dive or 0))
            groundFrame(ctx, movement, point, altitude, function(scale)
                Draw.WorldSeabird(ctx, 0, 0, scale, entry.heading, entry.dive)
            end)
        end
    end
    drawPortMark(ctx, runtime, width, height, horizon)
    if flags.showPerception then
        for _, entity in ipairs(entities) do
            if not entity.removed and entity.species and isVisible(world, entity) then drawPerception(ctx, movement, entity) end
        end
    end
    drawFishing(ctx, runtime, fishingView)
    drawTarget(ctx, movement)
    if flags.showBounds then
        local half = Config.world.halfSize
        Geometry.WorldPolygon(ctx, movement, { { x = -half, y = -half }, { x = half, y = -half },
            { x = half, y = half }, { x = -half, y = half } }, nil, Config.visual.bound, 1.2)
        for _, entity in ipairs(entities) do
            if entity.entityType == "island" and not entity.removed and isVisible(world, entity) then
                Geometry.WorldCircle(ctx, movement, entity.position, entity.radius, nil, Config.visual.bound, 1.2)
            end
        end
    end
    nvgRestore(ctx)
end

return SeaDraw
