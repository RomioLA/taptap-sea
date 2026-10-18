-- Read-only surface cues derived from live sea entities.
local Config = require("Ocean.Config")

local SurfaceSignals = {}
SurfaceSignals.__index = SurfaceSignals

local TWO_PI = math.pi * 2
local SEARCH_DIRECTIONS = 32
local BIRD_PERCEPTION_RADIUS = 18

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function positive(value, fallback)
    if finite(value) and value > 0 then return value end
    return fallback
end

local function nonnegative(value, fallback)
    if finite(value) and value >= 0 then return value end
    return fallback
end

local function pointIsValid(point)
    return type(point) == "table" and finite(point.x) and finite(point.y)
end

local function copyPoint(point)
    return { x = point.x, y = point.y }
end

local function wrapAngle(angle)
    return (angle + math.pi) % TWO_PI - math.pi
end

-- Stable across runs and independent of the global random-number state.
local function angleForId(id)
    local text = tostring(id)
    local hash = 5381
    for index = 1, #text do
        hash = (hash * 33 + string.byte(text, index)) % 2147483647
    end
    return hash / 2147483647 * TWO_PI
end

local function idLess(left, right)
    return tostring(left.id) < tostring(right.id)
end

local function isLiveFish(entity, species)
    return type(entity) == "table"
        and entity.ordinaryFish == true
        and entity.species == species
        and entity.alive ~= false
        and entity.removed ~= true
        and entity.active == true
        and entity.frozen ~= true
        and pointIsValid(entity.position)
        and entity.id ~= nil
end

---@return (fun(position: table, radius: number): boolean)?
local function createWaterQuery(world, workspace)
    if type(world) ~= "table" then return nil end
    if type(world.CreateWaterQuery) == "function" then
        local query = world:CreateWaterQuery(workspace)
        if type(query) == "function" then return query end
    end
    if type(world.isPositionFree) == "function" then
        if type(workspace) == "table" then
            workspace.positionFreeFallbackWorld = world
            if type(workspace.positionFreeFallbackQuery) ~= "function" then
                workspace.positionFreeFallbackQuery = function(position, radius)
                    local currentWorld = workspace.positionFreeFallbackWorld
                    if type(currentWorld) ~= "table"
                        or type(currentWorld.isPositionFree) ~= "function" then
                        return true
                    end
                    return currentWorld:isPositionFree(position, radius)
                end
            end
            return workspace.positionFreeFallbackQuery
        end
        return function(position, radius)
            return world:isPositionFree(position, radius)
        end
    end
    return nil
end

local function isPositionLegal(world, position, radius, waterQuery)
    local query = waterQuery or createWaterQuery(world)
    if type(query) ~= "function" then return true end
    return query(position, radius or 0)
end

local function clearArray(values)
    for index = #values, 1, -1 do values[index] = nil end
end

local function clearMap(values)
    for key in pairs(values) do values[key] = nil end
end

local function syncSortedSources(cache, scratch, byId)
    local sameSources = #cache == #scratch
    if sameSources then
        -- byId is rebuilt only from scratch on membership changes. With unique
        -- world IDs, equal lengths plus every scratch reference matching its
        -- map entry proves the cache and current source set are identical.
        for _, source in ipairs(scratch) do
            if byId[source.id] ~= source then
                sameSources = false
                break
            end
        end
    end
    if sameSources then return end

    table.sort(scratch, idLess)
    clearArray(cache)
    clearMap(byId)
    for index, source in ipairs(scratch) do
        cache[index] = source
        byId[source.id] = source
    end
end

local function currentLiveFish(world, id, species, waterQuery)
    if type(world) ~= "table" then return nil end
    local getter = world.get or world.GetEntity
    ---@type table?
    local source = nil
    if type(getter) == "function" then
        source = getter(world, id)
    else
        -- Compatibility with simple test/embedding worlds that only expose entities.
        for _, candidate in ipairs(world.entities or {}) do
            if candidate.id == id then
                source = candidate
                break
            end
        end
    end
    if not isLiveFish(source, species) or source.captureLocked == true
        or not isPositionLegal(world, source.position, source.radius, waterQuery) then
        return nil
    end
    return source
end

local function isBirdGroupCurrent(source, group, offset, radius, waterQuery)
    if not pointIsValid(group.center) or type(waterQuery) ~= "function"
        or not waterQuery(group.center, radius) then
        return false
    end
    local centerDx = group.center.x - source.position.x
    local centerDy = group.center.y - source.position.y
    local centerDistanceSquared = centerDx * centerDx + centerDy * centerDy
    local minCenterDistance = offset - 0.001
    if minCenterDistance < 0 then minCenterDistance = 0 end
    local maxCenterDistance = offset + 0.001
    if centerDistanceSquared < minCenterDistance * minCenterDistance
        or centerDistanceSquared > maxCenterDistance * maxCenterDistance then
        return false
    end

    local maxFishDistanceSquared = BIRD_PERCEPTION_RADIUS * BIRD_PERCEPTION_RADIUS
    local maxRingDistance = radius + 0.001
    local maxRingDistanceSquared = maxRingDistance * maxRingDistance
    for _, bird in ipairs(group.birds) do
        if not pointIsValid(bird.position) then return false end
        local fishDx = bird.position.x - source.position.x
        local fishDy = bird.position.y - source.position.y
        if fishDx * fishDx + fishDy * fishDy > maxFishDistanceSquared then
            return false
        end
        local ringDx = bird.position.x - group.center.x
        local ringDy = bird.position.y - group.center.y
        if ringDx * ringDx + ringDy * ringDy > maxRingDistanceSquared then
            return false
        end
    end
    return true
end

local function orbitCenter(source, baseAngle, offset, radius, center, waterQuery)
    if type(waterQuery) ~= "function" then return nil end
    center = center or { x = 0, y = 0 }
    for attempt = 0, SEARCH_DIRECTIONS - 1 do
        local angle = baseAngle + attempt * TWO_PI / SEARCH_DIRECTIONS
        center.x = source.position.x + math.cos(angle) * offset
        center.y = source.position.y + math.sin(angle) * offset
        -- Testing the whole orbit radius keeps every bird position in open sea.
        if waterQuery(center, radius) then return center, angle end
    end
    return nil
end

function SurfaceSignals.New(world)
    local self = setmetatable({}, SurfaceSignals)
    self:Init(world)
    return self
end

function SurfaceSignals:Init(world)
    local settings = Config.surfaceSignals
    self.world = world
    self.enabled = type(settings) == "table" and settings.enabled == true
    self.birdOffset = positive(type(settings) == "table" and settings.birdOffset, 9)
    self.birdRadius = nonnegative(type(settings) == "table" and settings.birdRadius, 3)
    self.birdsPerGroup = math.max(1, math.floor(positive(
        type(settings) == "table" and settings.birdsPerGroup, 2)))
    self.birdPollSeconds = positive(type(settings) == "table" and settings.birdPollSeconds, 0.25)
    self.birdDiveSeconds = nonnegative(type(settings) == "table" and settings.birdDiveSeconds, 1.5)
    self.birdAngularSpeed = positive(type(settings) == "table" and settings.birdAngularSpeed, 1.8)
    self.splashInterval = positive(type(settings) == "table" and settings.splashInterval, 1)
    self.chaseSplashInterval = positive(
        type(settings) == "table" and settings.chaseSplashInterval, 0.5)
    self.splashLifetime = positive(type(settings) == "table" and settings.splashLifetime, 0.6)
    self.trailLength = math.min(2, nonnegative(type(settings) == "table" and settings.trailLength, 2))
    self.birdPollRemaining = 0
    self.birdGroups = {}
    self.splashTimers = {}
    self.lastTunaPositions = {}
    self.splashes = {}
    -- Reused only as a synchronous legality-query workspace. It owns no
    -- signal timing, world registry, or animation state.
    self.waterQueryWorkspace = {}
    self.liveSardines = {}
    self.liveTuna = {}
    self.sardineScratch = {}
    self.tunaScratch = {}
    self.liveSardinesById = {}
    self.liveTunaById = {}
end

local function newBirdGroup(source, settings)
    local group = {
        sourceId = source.id,
        directionAngle = angleForId(source.id),
        phase = 0,
        diveElapsed = 0,
        center = { x = source.position.x, y = source.position.y },
        birds = {},
    }
    for index = 1, settings.birdsPerGroup do
        group.birds[index] = {
            id = tostring(source.id) .. ":bird:" .. tostring(index),
            sourceId = source.id,
            position = copyPoint(source.position),
            heading = 0,
            diveProgress = 0,
        }
    end
    return group
end

function SurfaceSignals:_collectLiveFish()
    local sardines, tuna = self.sardineScratch, self.tunaScratch
    clearArray(sardines)
    clearArray(tuna)

    local entities = type(self.world) == "table" and self.world.entities or nil
    if type(entities) == "table" then
        for _, entity in ipairs(entities) do
            if entity.ordinaryFish == true and entity.alive ~= false and entity.removed ~= true
                and entity.active == true and entity.frozen ~= true
                and entity.captureLocked ~= true and pointIsValid(entity.position)
                and entity.id ~= nil then
                if entity.species == "sardine" then
                    sardines[#sardines + 1] = entity
                elseif entity.species == "tuna" then
                    tuna[#tuna + 1] = entity
                end
            end
        end
    end

    -- Preserve the old ID order while avoiding per-frame map rebuilds and
    -- sorting when membership is stable.
    syncSortedSources(self.liveSardines, sardines, self.liveSardinesById)
    syncSortedSources(self.liveTuna, tuna, self.liveTunaById)
end

function SurfaceSignals:_refreshBirdGroups(sardines)
    for sourceId in pairs(self.birdGroups) do
        if self.liveSardinesById[sourceId] == nil then self.birdGroups[sourceId] = nil end
    end
    for _, source in ipairs(sardines) do
        if not self.birdGroups[source.id] then
            self.birdGroups[source.id] = newBirdGroup(source, self)
        end
    end
end

function SurfaceSignals:_updateBirdGroup(group, source, dt, waterQuery)
    -- Each bird remains within the sardine's confirmed 18 m bait-sense radius.
    if self.birdOffset + self.birdRadius > BIRD_PERCEPTION_RADIUS
        or not isPositionLegal(self.world, source.position, source.radius, waterQuery) then
        return false
    end
    local center, directionAngle = orbitCenter(
        source, group.directionAngle, self.birdOffset, self.birdRadius, group.center, waterQuery)
    if not center then return false end

    group.center = center
    group.directionAngle = directionAngle
    group.phase = (group.phase + self.birdAngularSpeed * dt) % TWO_PI

    local diveProgress = 0
    if self.birdDiveSeconds > 0 and group.diveElapsed < self.birdDiveSeconds then
        group.diveElapsed = math.min(self.birdDiveSeconds, group.diveElapsed + dt)
        diveProgress = group.diveElapsed / self.birdDiveSeconds
    end
    -- The initial dive bends inward within the cue ring, well away from the fish.
    local orbitRadius = self.birdRadius * (1 - 0.30 * math.sin(math.pi * diveProgress))
    for index, bird in ipairs(group.birds) do
        local angle = group.phase + (index - 1) * TWO_PI / #group.birds
        bird.position.x = center.x + math.cos(angle) * orbitRadius
        bird.position.y = center.y + math.sin(angle) * orbitRadius
        bird.heading = wrapAngle(angle + math.pi * 0.5)
        bird.diveProgress = diveProgress
    end
    return true
end

local function fishHeading(fish, previous)
    if finite(fish.rotation) then return wrapAngle(fish.rotation) end
    local direction = fish.direction
    if type(direction) == "table" and finite(direction.x) and finite(direction.y)
        and (direction.x ~= 0 or direction.y ~= 0) then
        return math.atan(direction.y, direction.x)
    end
    if pointIsValid(previous) then
        local dx, dy = fish.position.x - previous.x, fish.position.y - previous.y
        if dx ~= 0 or dy ~= 0 then return math.atan(dy, dx) end
    end
    return 0
end

function SurfaceSignals:_updateTuna(tunas, dt, waterQuery)
    for _, fish in ipairs(tunas) do
        local id = fish.id
        local timer = self.splashTimers[id]
        if timer ~= nil or isPositionLegal(self.world, fish.position, fish.radius, waterQuery) then
            local interval = fish.state == "Chase" and self.chaseSplashInterval or self.splashInterval
            if not timer then
                timer = { remaining = interval, interval = interval }
                self.splashTimers[id] = timer
            elseif timer.interval ~= interval then
                timer.remaining = math.min(timer.remaining, interval)
                timer.interval = interval
            end

            timer.remaining = timer.remaining - dt
            if timer.remaining <= 0 then
                self.splashes[#self.splashes + 1] = {
                    sourceId = id,
                    position = copyPoint(fish.position),
                    remaining = self.splashLifetime,
                    lifetime = self.splashLifetime,
                    heading = fishHeading(fish, self.lastTunaPositions[id]),
                    trailLength = self.trailLength,
                }
                local overshoot = -timer.remaining
                local phase = overshoot % interval
                timer.remaining = interval - phase
                if timer.remaining <= 0 then timer.remaining = interval end
            end

            ---@type table?
            local previous = self.lastTunaPositions[id]
            if not previous then
                previous = {}
                self.lastTunaPositions[id] = previous
            end
            previous.x, previous.y = fish.position.x, fish.position.y
        else
            self.splashTimers[id] = nil
            self.lastTunaPositions[id] = nil
        end
    end
end

function SurfaceSignals:_pruneInvalidSources(dt, waterQuery)
    for sourceId, group in pairs(self.birdGroups) do
        ---@type SeaEntity?
        local source = self.liveSardinesById[sourceId]
        if source == nil then
            self.birdGroups[sourceId] = nil
        elseif dt <= 0 then
            if not isPositionLegal(self.world, source.position, source.radius, waterQuery) then
                self.birdGroups[sourceId] = nil
            elseif not isBirdGroupCurrent(
                source, group, self.birdOffset, self.birdRadius, waterQuery) then
                self.birdGroups[sourceId] = nil
            end
        end
    end
    for fishId in pairs(self.splashTimers) do
        ---@type SeaEntity?
        local source = self.liveTunaById[fishId]
        if source == nil or not isPositionLegal(self.world, source.position, source.radius, waterQuery) then
            self.splashTimers[fishId] = nil
            self.lastTunaPositions[fishId] = nil
        end
    end

    local writeIndex = 1
    for readIndex = 1, #self.splashes do
        local splash = self.splashes[readIndex]
        if self.liveTunaById[splash.sourceId] ~= nil
            and self.splashTimers[splash.sourceId] ~= nil
            and pointIsValid(splash.position)
            and isPositionLegal(self.world, splash.position, 0, waterQuery) then
            self.splashes[writeIndex] = splash
            writeIndex = writeIndex + 1
        end
    end
    for index = writeIndex, #self.splashes do self.splashes[index] = nil end
end

function SurfaceSignals:_advanceSplashes(dt)
    local writeIndex = 1
    for readIndex = 1, #self.splashes do
        local splash = self.splashes[readIndex]
        splash.remaining = splash.remaining - dt
        if splash.remaining > 0 then
            self.splashes[writeIndex] = splash
            writeIndex = writeIndex + 1
        end
    end
    for index = writeIndex, #self.splashes do self.splashes[index] = nil end
end

function SurfaceSignals:Update(worldOrDt, maybeDt)
    local dt = maybeDt
    if type(worldOrDt) == "number" then
        dt = worldOrDt
    elseif type(worldOrDt) == "table" then
        self.world = worldOrDt
    end
    if not finite(dt) or dt < 0 then dt = 0 end

    if not self.enabled then
        self:Clear()
        return
    end

    -- One entity pass supplies both species, invalidation maps and sorted source caches.
    self:_collectLiveFish()
    local waterQuery = (#self.liveSardines > 0 or #self.liveTuna > 0)
        and createWaterQuery(self.world, self.waterQueryWorkspace) or nil
    self:_pruneInvalidSources(dt, waterQuery)
    if dt > 0 then self:_advanceSplashes(dt) end
    if dt <= 0 then return end

    self.birdPollRemaining = self.birdPollRemaining - dt
    if self.birdPollRemaining <= 0 then
        self:_refreshBirdGroups(self.liveSardines)
        self.birdPollRemaining = self.birdPollRemaining + self.birdPollSeconds
        if self.birdPollRemaining <= 0 then self.birdPollRemaining = self.birdPollSeconds end
    end

    for _, source in ipairs(self.liveSardines) do
        local group = self.birdGroups[source.id]
        if group and not self:_updateBirdGroup(group, source, dt, waterQuery) then
            self.birdGroups[source.id] = nil
        end
    end
    self:_updateTuna(self.liveTuna, dt, waterQuery)
end

function SurfaceSignals:GetBirds()
    if not self.enabled then return {} end
    local result = {}
    if next(self.birdGroups) == nil then return result end
    local waterQuery = createWaterQuery(self.world, self.waterQueryWorkspace)
    for _, source in ipairs(self.liveSardines) do
        local current = currentLiveFish(self.world, source.id, "sardine", waterQuery)
        local group = self.birdGroups[source.id]
        if current == source and self.liveSardinesById[source.id] == source and group
            and isBirdGroupCurrent(current, group, self.birdOffset, self.birdRadius, waterQuery) then
            for _, bird in ipairs(group.birds) do
                result[#result + 1] = {
                    id = bird.id,
                    sourceId = bird.sourceId,
                    position = copyPoint(bird.position),
                    heading = bird.heading,
                    diveProgress = bird.diveProgress,
                }
            end
        end
    end
    return result
end

-- Visit live cues with scalar arguments so renderers can read the current
-- state without allocating detached records. The callback receives no mutable
-- signal or position tables.
function SurfaceSignals:VisitBirds(visitor)
    if not self.enabled or type(visitor) ~= "function" or #self.liveSardines == 0 then return 0 end
    local count = 0
    local waterQuery = createWaterQuery(self.world, self.waterQueryWorkspace)
    for _, source in ipairs(self.liveSardines) do
        local current = currentLiveFish(self.world, source.id, "sardine", waterQuery)
        local group = self.birdGroups[source.id]
        if current == source and self.liveSardinesById[source.id] == source and group
            and isBirdGroupCurrent(current, group, self.birdOffset, self.birdRadius, waterQuery) then
            for _, bird in ipairs(group.birds) do
                visitor(bird.position.x, bird.position.y, bird.heading, bird.diveProgress,
                    bird.id, bird.sourceId)
                count = count + 1
            end
        end
    end
    return count
end

function SurfaceSignals:GetSplashes()
    if not self.enabled then return {} end
    local result = {}
    if #self.splashes == 0 then return result end
    local waterQuery = createWaterQuery(self.world, self.waterQueryWorkspace)
    for _, splash in ipairs(self.splashes) do
        local source = currentLiveFish(self.world, splash.sourceId, "tuna", waterQuery)
        if splash.remaining > 0 and source ~= nil
            and pointIsValid(splash.position)
            and isPositionLegal(self.world, splash.position, 0, waterQuery)
            and self.liveTunaById[splash.sourceId] == source then
            result[#result + 1] = {
                sourceId = splash.sourceId,
                position = copyPoint(splash.position),
                remaining = splash.remaining,
                lifetime = splash.lifetime,
                heading = splash.heading,
                trailLength = splash.trailLength,
            }
        end
    end
    return result
end

function SurfaceSignals:VisitSplashes(visitor)
    if not self.enabled or type(visitor) ~= "function" or #self.splashes == 0 then return 0 end
    local count = 0
    local waterQuery = createWaterQuery(self.world, self.waterQueryWorkspace)
    for _, splash in ipairs(self.splashes) do
        local source = currentLiveFish(self.world, splash.sourceId, "tuna", waterQuery)
        if splash.remaining > 0 and source ~= nil
            and pointIsValid(splash.position)
            and isPositionLegal(self.world, splash.position, 0, waterQuery)
            and self.liveTunaById[splash.sourceId] == source then
            visitor(splash.position.x, splash.position.y, splash.remaining, splash.lifetime,
                splash.heading, splash.trailLength, splash.sourceId)
            count = count + 1
        end
    end
    return count
end

local function removeSourceSplashes(splashes, id)
    local writeIndex = 1
    for readIndex = 1, #splashes do
        local splash = splashes[readIndex]
        if splash.sourceId ~= id then
            splashes[writeIndex] = splash
            writeIndex = writeIndex + 1
        end
    end
    for index = writeIndex, #splashes do splashes[index] = nil end
end

function SurfaceSignals:OnCaptureLocked(id)
    if id == nil then return end
    self.birdGroups[id] = nil
    self.splashTimers[id] = nil
    self.lastTunaPositions[id] = nil
    removeSourceSplashes(self.splashes, id)
end

function SurfaceSignals:OnRemoved(id)
    if id == nil then return end
    self.birdGroups[id] = nil
    self.splashTimers[id] = nil
    self.lastTunaPositions[id] = nil
    removeSourceSplashes(self.splashes, id)
end

function SurfaceSignals:Clear()
    self.birdPollRemaining = 0
    self.birdGroups = {}
    self.splashTimers = {}
    self.lastTunaPositions = {}
    self.splashes = {}
    self.liveSardines = {}
    self.liveTuna = {}
    self.sardineScratch = {}
    self.tunaScratch = {}
    self.liveSardinesById = {}
    self.liveTunaById = {}
    local workspace = self.waterQueryWorkspace
    if type(workspace) == "table" then
        if type(workspace.blockers) == "table" then clearArray(workspace.blockers) end
        workspace.world = nil
        workspace.usePublicPredicate = nil
        workspace.positionFreeFallbackWorld = nil
    end
end

-- Detach a retired world's signal object so external references to the signal
-- system cannot keep the old world alive.
function SurfaceSignals:DetachWorld()
    self:Clear()
    self.world = nil
    local workspace = self.waterQueryWorkspace
    if type(workspace) == "table" then
        workspace.world = nil
        workspace.usePublicPredicate = nil
        workspace.positionFreeFallbackWorld = nil
        if type(workspace.blockers) == "table" then clearArray(workspace.blockers) end
    end
end

return SurfaceSignals
