-- Standalone Sea Runtime. No PlayerState, item database, inventory or day clock dependency.
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local M = require("Ocean.Math")
local World = require("Ocean.World")
local Movement = require("Ocean.Movement")
local Fish = require("Ocean.Fish")
local DefaultStrategy = require("Ocean.SpawnStrategy")
local Runtime = {}
Runtime.__index = Runtime

function Runtime.New(options)
    local self = setmetatable({}, Runtime)
    self:Init(options or {})
    return self
end

function Runtime:Init(options)
    self.world = World.New()
    self.ship = self.world:spawn({ entityType = "ship", kind = "dynamic", layer = "surface",
        position = options.departure or Config.ship.start, radius = Config.ship.radius })
    assert(self.world:isPositionFree(self.ship.position, self.ship.radius), "invalid ship departure")
    self.movement = Movement.New(self.world, self.ship)
    if options.shipLevel ~= nil then self:SetShipLevel(options.shipLevel) end
    ---@type table<string, FishBehavior>
    self.behaviors = {}
    self.initializedRegions = {}
    self.strategy = options.strategy or DefaultStrategy
    self.departure = M.copy(self.ship.position)
    self.daySeed = options.daySeed or Config.world.seed
    self.spawnSequence = 0
    self.time = 0
    self.paused = false
    self.debug = {}
    for key, value in pairs(Config.debug) do self.debug[key] = value end
    self.world.showUnderwater = self.debug.enabled and self.debug.showUnderwater
    self.initializeRegions = options.initializeRegions ~= false
    if self.initializeRegions then self:ensureNearbyRegions() end
end

function Runtime:spawnFish(species, position, rotation)
    local data = assert(FishData[species], "unsupported fish species")
    assert(self.world:isPositionFree(position, data.radius), "fish spawn must be in free sea")
    self.spawnSequence = self.spawnSequence+1
    local entity = self.world:spawn({ entityType = "fish", kind = "dynamic", layer = "underwater",
        species = species, ordinaryFish = true, position = position, rotation = rotation or 0,
        radius = data.radius, state = "Wander", active = false, frozen = true })
    self.behaviors[entity.id] = Fish.New(self.world, entity, data, M.rng(self.daySeed+self.spawnSequence))
    self.world:updateActivity(self.ship.position)
    return entity
end

function Runtime:ensureNearbyRegions()
    local size, half = Config.world.regionSize, Config.world.halfSize
    local radius = Config.world.activateRadius
    local pos = self.ship.position
    local lastIndex = math.ceil(Config.world.mapSize/size)-1
    local minX = math.max(0, math.floor((pos.x-radius+half)/size))
    local maxX = math.min(lastIndex, math.floor((pos.x+radius+half)/size))
    local minY = math.max(0, math.floor((pos.y-radius+half)/size))
    local maxY = math.min(lastIndex, math.floor((pos.y+radius+half)/size))
    for ix = minX, maxX do
        for iy = minY, maxY do
            local loX, loY = -half+ix*size, -half+iy*size
            local hiX, hiY = math.min(half, loX+size), math.min(half, loY+size)
            local nearest = { x = M.clamp(pos.x, loX, hiX), y = M.clamp(pos.y, loY, hiY) }
            local key = ix .. ":" .. iy
            if not self.initializedRegions[key] and M.distanceSquared(pos, nearest) <= radius*radius then
                local placements = self.strategy.GenerateRegion(self.world, self.daySeed, ix, iy, self.departure, FishData, pos)
                for _, placement in ipairs(placements) do
                    self:spawnFish(placement.species, placement.position, placement.rotation)
                end
                self.initializedRegions[key] = true
            end
        end
    end
end

function Runtime:clearOrdinaryFish()
    self.world:clearOrdinaryFish()
    ---@type table<string, FishBehavior>
    self.behaviors = {}
    -- Region markers stay: clearing/catching fish never causes immediate replenishment.
end

function Runtime:refreshOrdinaryFish(daySeed, departure)
    assert(type(daySeed) == "number", "numeric daySeed required")
    local start = departure or self.ship.position
    assert(self.world:isPositionFree(start, self.ship.radius), "invalid daily departure")
    self:clearOrdinaryFish()
    for _, entity in ipairs(self.world.entities) do
        if entity.kind == "temporary" then self.world:remove(entity.id, "newDay") end
    end
    self.world:compact()
    self.world.reveals = {}
    self.daySeed, self.world.daySeed = daySeed, daySeed
    self.departure = M.copy(start)
    self.spawnSequence = 0
    self.initializedRegions = {}
    if self.initializeRegions then self:ensureNearbyRegions() end
    -- Does not move the player, advance a day clock, reset fixed entities, or settle a day.
end

function Runtime:spawnDroppedItem(payload, position)
    if M.distanceSquared(self.ship.position, position) > Config.interaction.maxThrowDistance^2 then
        return nil, "throw_out_of_range"
    end
    if not self.world:isPositionFree(position, 0) then return nil, "invalid_drop_position" end
    return self.world:spawnDroppedItem(payload, position)
end

function Runtime:queryEntitiesInRadius(center, radius, filter)
    return self.world:queryEntitiesInRadius(center, radius, filter)
end

function Runtime:SetShipLevel(level)
    return self.movement:SetLevel(level)
end

-- World-side selection only: one nearest live fish or nil, including hidden/frozen fish.
-- Config owns net radius; the future action completes before removal of this one selected ID.
function Runtime:canCastNet(center)
    return self.world:isPositionFree(center, 0)
        and M.distanceSquared(self.ship.position, center) <= Config.fishing.maxCastDistance^2
end

function Runtime:selectFishingTarget(center, radius, filter)
    if not self:canCastNet(center) then return nil, "cast_out_of_range_or_invalid" end
    -- Old explicit-radius callers must use the one authoritative V1 net radius.
    assert(radius == nil or radius == Config.fishing.netRadius, "use Config.fishing.netRadius")
    local candidates = self:queryEntitiesInRadius(center, Config.fishing.netRadius, filter)
    ---@type table?
    local nearest = nil
    local distance = math.huge
    for _, entity in ipairs(candidates) do
        if entity.entityType == "fish" and FishData[entity.species] then
            local candidateDistance = M.distanceSquared(center, entity.position)
            if candidateDistance < distance then
                nearest, distance = entity, candidateDistance
            end
        end
    end
    return nearest
end

function Runtime:revealWithScope(center, durationSec)
    return self.world:revealUnderwater(center, Config.interaction.revealRadius, durationSec)
end

function Runtime:setDebugFlag(name, value)
    if not self.debug.enabled then return false end
    assert(type(Config.debug[name]) == "boolean" and name ~= "enabled", "unsupported debug flag")
    self.debug[name] = value == true
    if name == "showUnderwater" then self.world.showUnderwater = self.debug[name] end
    return true
end

function Runtime:TogglePause() self.paused = not self.paused end
function Runtime:Reset()
    local seed, strategy = self.daySeed, self.strategy
    self:Init({ daySeed = seed, strategy = strategy, initializeRegions = self.initializeRegions,
        shipLevel = self.movement.level })
end

function Runtime:Update(dt, axisX, axisY)
    if self.paused then return end
    local remaining = M.clamp(dt, 0, Config.world.maxFrameSec)
    while remaining > Config.world.epsilon do
        local step = math.min(remaining, Config.world.maxStepSec)
        self.time = self.time+step
        self.movement:Update(step, axisX or 0, axisY or 0)
        if self.initializeRegions then self:ensureNearbyRegions() end
        self.world:updateActivity(self.ship.position)
        self.world:updateLifecycle(step, self.ship)
        for _, entity in ipairs(self.world.entities) do
            if entity.ordinaryFish and not entity.removed and entity.active and not entity.frozen then
                local behavior = self.behaviors[entity.id]
                if behavior then behavior:Update(step) end
            end
        end
        for id in pairs(self.behaviors) do
            if not self.world:get(id) then self.behaviors[id] = nil end
        end
        self.world:compact()
        remaining = remaining-step
    end
end
return Runtime
