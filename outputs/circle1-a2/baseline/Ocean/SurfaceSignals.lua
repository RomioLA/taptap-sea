-- Read-only surface cues derived from live sea entities.
local Config = require("Ocean.Config")

local SurfaceSignals = {}
SurfaceSignals.__index = SurfaceSignals

local TWO_PI = math.pi * 2
local SEARCH_DIRECTIONS = 32

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
        and entity.removed ~= true
        and entity.active == true
        and entity.frozen ~= true
        and pointIsValid(entity.position)
        and entity.id ~= nil
end

local function listLiveFish(world, species, allowCaptureLocked)
    local result = {}
    if type(world) ~= "table" or type(world.entities) ~= "table" then return result end
    for _, entity in ipairs(world.entities) do
        if isLiveFish(entity, species)
            and (allowCaptureLocked or entity.captureLocked ~= true) then
            result[#result + 1] = entity
        end
    end
    table.sort(result, idLess)
    return result
end

local function orbitCenter(world, source, baseAngle, offset, radius)
    if type(world) ~= "table" or type(world.isPositionFree) ~= "function" then return nil end
    for attempt = 0, SEARCH_DIRECTIONS - 1 do
        local angle = baseAngle + attempt * TWO_PI / SEARCH_DIRECTIONS
        local center = {
            x = source.position.x + math.cos(angle) * offset,
            y = source.position.y + math.sin(angle) * offset,
        }
        -- Testing the whole orbit radius keeps every bird position in open sea.
        if world:isPositionFree(center, radius) then return center, angle end
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

function SurfaceSignals:_refreshBirdGroups(sardines)
    local present = {}
    for _, source in ipairs(sardines) do
        present[source.id] = true
        if not self.birdGroups[source.id] then
            self.birdGroups[source.id] = newBirdGroup(source, self)
        end
    end
    for sourceId in pairs(self.birdGroups) do
        if not present[sourceId] then self.birdGroups[sourceId] = nil end
    end
end

function SurfaceSignals:_updateBirdGroup(group, source, dt)
    local center, directionAngle = orbitCenter(
        self.world, source, group.directionAngle, self.birdOffset, self.birdRadius)
    if not center then return false end

    group.center = center
    group.directionAngle = directionAngle
    group.phase = (group.phase + self.birdAngularSpeed * dt) % TWO_PI

    local diveProgress = 0
    if self.birdDiveSeconds > 0 and group.diveElapsed < self.birdDiveSeconds then
        group.diveElapsed = group.diveElapsed + dt
        diveProgress = math.min(1, group.diveElapsed / self.birdDiveSeconds)
    end
    -- The initial dive bends inward within the cue ring, well away from the fish.
    local orbitRadius = self.birdRadius * (1 - 0.30 * math.sin(math.pi * diveProgress))
    for index, bird in ipairs(group.birds) do
        local angle = group.phase + (index - 1) * TWO_PI / #group.birds
        bird.position = {
            x = center.x + math.cos(angle) * orbitRadius,
            y = center.y + math.sin(angle) * orbitRadius,
        }
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

function SurfaceSignals:_updateTuna(tunas, dt)
    local present = {}
    for _, fish in ipairs(tunas) do
        local id = fish.id
        present[id] = true
        local interval = fish.state == "Chase" and self.chaseSplashInterval or self.splashInterval
        local timer = self.splashTimers[id]
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
        self.lastTunaPositions[id] = copyPoint(fish.position)
    end
    for id in pairs(self.splashTimers) do
        if not present[id] then
            self.splashTimers[id] = nil
            self.lastTunaPositions[id] = nil
        end
    end
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

    local sardines = listLiveFish(self.world, "sardine", false)
    local tuna = listLiveFish(self.world, "tuna", true)
    local liveSardines, liveTuna = {}, {}
    for _, fish in ipairs(sardines) do liveSardines[fish.id] = true end
    for _, fish in ipairs(tuna) do liveTuna[fish.id] = true end

    -- Prune invalid sources on every call, including Update(0).
    for sourceId in pairs(self.birdGroups) do
        if not liveSardines[sourceId] then self.birdGroups[sourceId] = nil end
    end
    for fishId in pairs(self.splashTimers) do
        if not liveTuna[fishId] then
            self.splashTimers[fishId] = nil
            self.lastTunaPositions[fishId] = nil
        end
    end

    if dt > 0 then
        for index = #self.splashes, 1, -1 do
            local splash = self.splashes[index]
            splash.remaining = splash.remaining - dt
            if splash.remaining <= 0 then table.remove(self.splashes, index) end
        end
    end
    if dt <= 0 then return end

    self.birdPollRemaining = self.birdPollRemaining - dt
    if self.birdPollRemaining <= 0 then
        self:_refreshBirdGroups(sardines)
        self.birdPollRemaining = self.birdPollRemaining + self.birdPollSeconds
        if self.birdPollRemaining <= 0 then self.birdPollRemaining = self.birdPollSeconds end
    end

    for _, source in ipairs(sardines) do
        local group = self.birdGroups[source.id]
        if group and not self:_updateBirdGroup(group, source, dt) then
            self.birdGroups[source.id] = nil
        end
    end
    self:_updateTuna(tuna, dt)
end

function SurfaceSignals:GetBirds()
    if not self.enabled then return {} end
    local result = {}
    local sources = listLiveFish(self.world, "sardine", false)
    for _, source in ipairs(sources) do
        local group = self.birdGroups[source.id]
        if group then
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

function SurfaceSignals:GetSplashes()
    if not self.enabled then return {} end
    local result = {}
    for _, splash in ipairs(self.splashes) do
        if splash.remaining > 0 then
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

function SurfaceSignals:OnCaptureLocked(id)
    self.birdGroups[id] = nil
end

function SurfaceSignals:OnRemoved(id)
    if id == nil then return end
    self.birdGroups[id] = nil
    self.splashTimers[id] = nil
    self.lastTunaPositions[id] = nil
    -- Existing splashes are independent visuals and expire on their own timer.
end

function SurfaceSignals:Clear()
    self.birdPollRemaining = 0
    self.birdGroups = {}
    self.splashTimers = {}
    self.lastTunaPositions = {}
    self.splashes = {}
end

return SurfaceSignals
