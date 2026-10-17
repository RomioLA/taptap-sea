-- Read-only 2.5D sea presentation. All interaction ranges stay in world meters.
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.Draw")
local Art = require("Ocean.SeaViewArt")
local Geometry = require("Ocean.ProjectedGeometry")
local Presentation = require("Ocean.SeaPresentation")
local Atmosphere = require("Ocean.SeaAtmosphere")
local ImageArt = require("Ocean.ImageArt")
local PerfProbe = require("Ocean.PerfProbe")
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

-- Keep the existing vector silhouettes, projecting each meter-space path
-- through the same surface and height occlusion as islands and water.
local function groundFrame(ctx, movement, point, altitude, callback, extentMeters)
    if not movement:WorldToScreen(point, altitude) then return end
    callback(1, Geometry.ArtAPI(ctx, movement, point, altitude))
end

local function worldLine(ctx, movement, a, b, tint, width)
    Geometry.WorldLine(ctx, movement, a, b, tint, width)
end

local function drawFloat(ctx, movement, entity, outlineOnly, recognized, time)
    local point, radius = entity.position, entity.radius or 1
    -- 只缩小木桶的视觉尺寸，原radius/识别/交互/阻挡边界不变。
    local visualRadius = radius * 0.65
    ImageArt.ContactRipple(ctx, movement, point, time, visualRadius)
    if not outlineOnly and ImageArt.Plane(ctx, "barrel", movement, point,
        visualRadius * 2 / 0.88, visualRadius * 2 / 0.88, 0, 0) then return end
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
    drawFloat(ctx, runtime.movement, entity, not recognized, recognized, runtime.time)
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
    groundFrame(ctx, movement, entity.position, 0, function(scale, api)
        Draw.WorldFish(ctx, 0, 0, scale, entity, time, api)
    end, (FishData[entity.species].renderLength or 1) * 1.2)
end

-- Ocean validates fixed identity and visibility; Gameplay contributes only the
-- read-only marked bit used for the small completion glyph.
local function drawFixedTreasure(ctx, runtime, entity, marked)
    if entity.kind ~= "fixed" or entity.entityType ~= "treasure"
        or entity.layer ~= "underwater" or entity.contentId ~= "underwater_treasure_01"
        or type(runtime.GetFixedContentGeneration) ~= "function"
        or type(runtime.GetWorldContent) ~= "function" then return end
    local generationOk, generation = pcall(runtime.GetFixedContentGeneration, runtime)
    if not generationOk or type(generation) ~= "number" then return end
    local snapshotOk, snapshot = pcall(runtime.GetWorldContent, runtime, entity.contentId)
    if not snapshotOk or type(snapshot) ~= "table" or snapshot.entityId ~= entity.id
        or snapshot.generation ~= generation or snapshot.layer ~= "underwater"
        or type(snapshot.position) ~= "table" or not finite(snapshot.position.x)
        or not finite(snapshot.position.y) then return end
    marked = marked == true
    local point = snapshot.position
    local radius = math.max(0.75, (snapshot.radius or 0.5) * 1.5)
    local ink = marked and { 255, 218, 150, 235 } or { 113, 232, 220, 220 }
    local glow = marked and { 255, 202, 116, 45 } or { 105, 230, 222, 38 }
    local diamond = {
        { x = point.x, y = point.y + radius },
        { x = point.x + radius * 0.68, y = point.y },
        { x = point.x, y = point.y - radius },
        { x = point.x - radius * 0.68, y = point.y },
    }
    Presentation.Draw(ctx, runtime.movement, point, radius * 2.2, -0.8, function()
        Geometry.WorldCircle(ctx, runtime.movement, point, radius * 1.75, glow, ink, 1.2)
        Geometry.WorldPolygon(ctx, runtime.movement, diamond, glow, ink, 1.5)
        if marked then
            worldLine(ctx, runtime.movement,
                { x = point.x - radius * 0.35, y = point.y },
                { x = point.x - radius * 0.08, y = point.y - radius * 0.28 }, ink, 1.8)
            worldLine(ctx, runtime.movement,
                { x = point.x - radius * 0.08, y = point.y - radius * 0.28 },
                { x = point.x + radius * 0.38, y = point.y + radius * 0.3 }, ink, 1.8)
        else
            Geometry.WorldCircle(ctx, runtime.movement, point, radius * 0.2, ink, nil, 0)
        end
    end)
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
    local world = runtime.world
    if not world then return {} end
    -- The authoritative collection is shared with gameplay. Per-object height
    -- and footprint bounds are evaluated by Presentation, with no distant-type
    -- whitelist or fixed extension that could hide a newly registered object.
    return world.entities
end

-- Place a three-bird commuter formation on the current screen edge along the
-- live ship-to-island bearing. It is presentation only; no World entity or
-- authored route is created.
local function commuterFlockLayout(runtime, width, height, isLocationRecognized)
    if type(isLocationRecognized) ~= "function" then return nil end
    local movement = runtime and runtime.movement
    if not movement or movement.viewportReady ~= true or type(runtime.GetTrace) ~= "function" then return nil end
    local trace = runtime:GetTrace("flock_commute")
    if not trace or trace.valid ~= true or trace.sourceContentId ~= "island_02"
        or trace.birdCount ~= 3 or trace.dives ~= false or trace.circlesFish ~= false
        or not finite(trace.distance) or trace.distance <= Config.interaction.recognitionDistance
        or not finite(trace.bearingRadians) then
        return nil
    end
    local recognizedOk, recognized = pcall(isLocationRecognized, "island_02")
    if not recognizedOk or recognized == true then return nil end

    local ship = movement.ship
    if not ship or type(ship.position) ~= "table" then return nil end
    local altitude = Config.visual.projection.birdAltitude
    local originX, originY = movement:WorldToScreen(ship.position, altitude)
    if not finite(originX) or not finite(originY) then return nil end
    local lookAhead = {
        x = ship.position.x + math.cos(trace.bearingRadians) * 8,
        y = ship.position.y + math.sin(trace.bearingRadians) * 8,
    }
    local aheadX, aheadY = movement:WorldToScreen(lookAhead, altitude)
    if not finite(aheadX) or not finite(aheadY) then return nil end
    local dx, dy = aheadX - originX, aheadY - originY
    local length = math.sqrt(dx * dx + dy * dy)
    if not finite(length) or length <= 1e-6 then return nil end
    dx, dy = dx / length, dy / length

    local margin = math.min(28, width * 0.08, height * 0.08)
    local t = math.huge
    if dx > 1e-6 then t = math.min(t, (width - margin - originX) / dx)
    elseif dx < -1e-6 then t = math.min(t, (margin - originX) / dx) end
    if dy > 1e-6 then t = math.min(t, (height - margin - originY) / dy)
    elseif dy < -1e-6 then t = math.min(t, (margin - originY) / dy) end
    if not finite(t) or t <= 0 then return nil end

    local edgeX, edgeY = originX + dx * t, originY + dy * t
    local perpendicularX, perpendicularY = -dy, dx
    local elapsed = finite(runtime.time) and math.max(0, runtime.time) or 0
    local flowOffset = -64 + ((elapsed * 0.2) % 1) * 48
    return {
        bearingRadians = trace.bearingRadians,
        screenDirection = { x = dx, y = dy },
        birds = {
            { x = edgeX + dx * (flowOffset - 10), y = edgeY + dy * (flowOffset - 10) },
            { x = edgeX + dx * (flowOffset - 34) + perpendicularX * 15,
                y = edgeY + dy * (flowOffset - 34) + perpendicularY * 15 },
            { x = edgeX + dx * (flowOffset - 34) - perpendicularX * 15,
                y = edgeY + dy * (flowOffset - 34) - perpendicularY * 15 },
        },
    }
end

local function drawCommuterFlock(ctx, width, height, runtime, isLocationRecognized)
    local layout = commuterFlockLayout(runtime, width, height, isLocationRecognized)
    if not layout then return 0 end
    for _, bird in ipairs(layout.birds) do
        Draw.WorldSeabird(ctx, bird.x, bird.y, 14, layout.bearingRadians, 0)
    end
    return #layout.birds
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
            groundFrame(ctx, movement, center, 0, function(scale, api)
                Draw.WorldSplash(ctx, 0, 0, scale, lifetime - age, lifetime, 0, 0, api)
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
---@param isWorldContentMarked (fun(contentId: string): boolean)? Read-only Gameplay progress query.
function SeaDraw.Scene(ctx, width, height, runtime, clock, fishingView, isLocationRecognized, isWorldContentMarked)
    if not ctx or width <= 0 or height <= 0 or not runtime or not runtime.movement then return end
    local movement, world, time = runtime.movement, runtime.world, runtime.time or 0
    -- T3 帧耗时探针：全帧对照基准（岛分项见 SeaViewArt）。
    local probeSceneStop = PerfProbe.Timer()
    PerfProbe.Frame()
    local horizon = movement:GetHorizonY()
    Art.Backdrop(ctx, width, height, time, clock, movement)
    Art.Surface(ctx, movement, time)
    -- T5（2026-10-06 美术审核确认）：昼夜色罩移到世界实体之后统一染色——
    -- 旧层级（实体前）导致 PNG 船/岛/木桶等贴图实体夜间不被染暗。
    -- 层级：天空海面 → 世界实体 → 昼夜罩 → 雾/港口标记/功能信号（保持可读）。
    nvgSave(ctx)
    Atmosphere.CloudShadows(ctx, movement, time, runtime.daySeed)
    local flags, entities = runtime.debug or Config.debug, nearbyEntities(runtime)
    local scope = world and type(world.GetScopeView) == "function" and world:GetScopeView() or nil
    if scope then
        Geometry.WorldSector(ctx, movement, scope.center, scope.radius, scope.heading, scope.halfAngle,
            { 172, 232, 224, 24 }, { 197, 243, 226, 130 }, 1.2)
    end
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.species and entity.layer == "underwater" and isVisible(world, entity) then
            Presentation.Draw(ctx, movement, entity.position, FishData[entity.species].renderLength, 0,
                function() drawFish(ctx, movement, entity, flags.showActivity, time) end)
        elseif not entity.removed and entity.layer == "underwater" and entity.entityType == "treasure"
            and entity.contentId == "underwater_treasure_01" then
            local marked = false
            if type(isWorldContentMarked) == "function" then
                local queryOk, value = pcall(isWorldContentMarked, entity.contentId)
                marked = queryOk and value == true
            end
            -- Once Gameplay marks this fixed treasure, keep that known map glyph
            -- visible with the scope closed. This is presentation only; action
            -- eligibility still uses Runtime:IsWorldContentInScope.
            if marked or isVisible(world, entity) then
                drawFixedTreasure(ctx, runtime, entity, marked)
            end
        end
    end
    Art.Wake(ctx, movement, movement.wake)
    local snapshot = type(runtime.GetFixedBarrel) == "function" and runtime:GetFixedBarrel() or nil
    for _, entry in ipairs(surfaceEntries(runtime, entities)) do
        local entity, point = entry.entity, entry.position
        local speciesData = entity and entity.species and FishData[entity.species]
        local radius = entity and (entity.species
            and ((speciesData and speciesData.renderLength) or entity.radius or 1)
            or (entity.radius or 1)) or math.max(3, entry.length or 0)
        local altitude = entry.kind == "entity" and entity.entityType == "island" and 5.4
            or entry.kind == "bird" and Config.visual.projection.birdAltitude or 0
        if entry.kind == "ship" then
            Art.Boat(ctx, movement, entity, time)
        else
            Presentation.Draw(ctx, movement, point, radius, altitude, function(appearance)
                if entry.kind == "entity" then
                    if entity.entityType == "island" then
                        Art.Island(ctx, movement, entity, time, appearance and appearance.airMix or 0)
                    elseif entity.entityType == "float" then
                        if world and entity == world.fixedBarrel then
                            drawFixedBarrel(ctx, runtime, entity, snapshot, isLocationRecognized)
                        else drawFloat(ctx, movement, entity, false, false, time) end
                    elseif entity.entityType == "droppedItem" then drawDroppedItem(ctx, movement, entity)
                    elseif entity.species then drawFish(ctx, movement, entity, flags.showActivity, time) end
                elseif entry.kind == "rise" then
                    groundFrame(ctx, movement, point, 0,
                        function(scale, api) Draw.WorldRise(ctx, 0, 0, scale, entity, time, api) end,
                        (FishData[entity.species].renderLength or 1) * 1.5)
                elseif entry.kind == "splash" then
                    groundFrame(ctx, movement, point, 0, function(scale, api)
                        Draw.WorldSplash(ctx, 0, 0, scale, entry.remaining, entry.lifetime, entry.heading, entry.length, api)
                    end, math.max(3, entry.length))
                elseif entry.kind == "bird" then
                    local birdAltitude = Config.visual.projection.birdAltitude * (1 - (entry.dive or 0))
                    local flapScale = 1 + math.sin(time * 3.2) * 0.035
                    if not ImageArt.Plane(ctx, "gull", movement, point, 3.2,
                        3.2 * (1 - 0.62 * (entry.dive or 0)) * flapScale, entry.heading, birdAltitude) then
                        groundFrame(ctx, movement, point, birdAltitude, function(scale, api)
                            Draw.WorldSeabird(ctx, 0, 0, scale, entry.heading, entry.dive, api)
                        end)
                    end
                end
            end)
        end
    end
    drawCommuterFlock(ctx, width, height, runtime, isLocationRecognized)
    -- T5：世界实体（岛/船/木桶/浮标/海鸟）绘制完毕后统一染夜色。
    if clock and clock.phase == "night" then Draw.NightOverlay(ctx, width, height, clock) end
    Atmosphere.Fog(ctx, movement, time, runtime.daySeed)
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
    PerfProbe.Sample("scene", probeSceneStop())
end

-- Read-only screen-edge view used by Scene and the headless presentation tests.
SeaDraw.BuildCommuterFlockLayout = commuterFlockLayout

return SeaDraw
