-- Pure-Lua behavior for one underwater fish entity.
-- World owns storage, activity, collision resolution, and removal; this module
-- only selects an FSM state and asks World to move the entity.
local Math = require("Ocean.Math")
local Config = require("Ocean.Config")
local StateMachine = require("FSM.StateMachine")

---@class OceanFishPoint
---@field x number
---@field y number

---@class OceanFishEntity: SeaEntity
---@field surfaceDepth number 视觉上浮进度，范围 0..1
---@field riseRemaining number 视觉上浮剩余时间（秒）

---@class FishBehavior
---@field world table
---@field entity OceanFishEntity
---@field speciesData table
---@field rng fun(): number
---@field state string
---@field wanderRemaining number
---@field wanderTargetAngle number
---@field preyId string?
---@field lastPreyPosition OceanFishPoint?
---@field lostPreyTime number
---@field fleeJitterRemaining number
---@field fleeJitterRadians number
---@field wasFleeing boolean
---@field surfaceRiseDuration number?
---@field predationCooldownUntil number
---@field fsm table
local Fish = {}
Fish.__index = Fish

local TWO_PI = math.pi * 2
-- Keep tested sea decisions/movement intact; the shared FSM supplies state callbacks and scheduling.
---@type table<string, table>
local STATES = {}
for _, name in ipairs({ "Wander", "Attracted", "Flee", "Chase", "Avoid" }) do
    STATES[name] = {
        enter = function(owner)
            owner.state = name
            owner.entity.state = name
            if name == "Flee" then owner:_beginSurfaceRise() end
        end,
        exit = function(owner)
            if name == "Flee" then owner:_clearSurfaceRise() end
        end,
        update = function(owner, dt) owner:Update(dt) end,
    }
end

local function normalizeAngle(angle)
    return (angle + math.pi) % TWO_PI - math.pi
end

local function angleOf(x, y)
    return math.atan(y, x)
end

local function effectOf(entity)
    local payload = entity.payload
    if type(payload) == "table" and type(payload.worldEffect) == "string" then
        return payload.worldEffect
    end
    if type(entity.worldEffect) == "string" then return entity.worldEffect end
    return nil
end

local function isLive(entity)
    return entity ~= nil and not entity.removed
end

local function configuredSurfaceRiseDuration()
    local signals = Config and Config.surfaceSignals
    if type(signals) == "table" and signals.enabled == false then return nil end
    local duration = type(signals) == "table" and signals.riseSeconds or nil
    if type(duration) ~= "number" or duration <= 0 or duration ~= duration
        or duration == math.huge or duration == -math.huge then
        return nil
    end
    return duration
end

local function directionFromAngle(angle)
    return math.cos(angle), math.sin(angle)
end

local function lengthSquared(x, y)
    return x * x + y * y
end

---@param world table
---@param entity table
---@param speciesData table
---@param rng fun(): number
---@return FishBehavior
function Fish.New(world, entity, speciesData, rng)
    assert(type(world) == "table", "Fish.New requires a world")
    assert(type(entity) == "table" and type(entity.position) == "table", "Fish.New requires an entity with a position")
    assert(type(speciesData) == "table", "Fish.New requires species data")
    assert(type(rng) == "function", "Fish.New requires an independent rng function")

    local self = setmetatable({}, Fish)
    self:Init(world, entity, speciesData, rng)
    return self
end

---@param world table
---@param entity table
---@param speciesData table
---@param rng fun(): number
function Fish:Init(world, entity, speciesData, rng)
    local initialRotation = entity.rotation
    if type(initialRotation) ~= "number" then
        local direction = entity.direction
        if type(direction) == "table" and type(direction.x) == "number" and type(direction.y) == "number" then
            initialRotation = angleOf(direction.x, direction.y)
        else
            initialRotation = 0
        end
        entity.rotation = initialRotation
    end

    self.world = world
    self.entity = entity
    self.speciesData = speciesData
    self.rng = rng
    self.state = "Wander"
    self.wanderRemaining = 0
    self.wanderTargetAngle = initialRotation
    self.preyId = nil
    self.lastPreyPosition = nil
    self.lostPreyTime = 0
    self.fleeJitterRemaining = 0
    self.fleeJitterRadians = 0
    self.wasFleeing = false
    self.surfaceRiseDuration = nil
    self.predationCooldownUntil = 0

    entity.surfaceDepth = 0
    entity.riseRemaining = 0
    entity.state = self.state
    self.fsm = StateMachine.New(STATES, "Wander", self)
    entity.fsm = self.fsm
end

function Fish:_beginSurfaceRise()
    local duration = configuredSurfaceRiseDuration()
    self.surfaceRiseDuration = duration
    self.entity.surfaceDepth = 0
    self.entity.riseRemaining = duration or 0
end

function Fish:_clearSurfaceRise()
    self.surfaceRiseDuration = nil
    self.entity.surfaceDepth = 0
    self.entity.riseRemaining = 0
end

---@param dt number
function Fish:_advanceSurfaceRise(dt)
    local duration = self.surfaceRiseDuration
    if type(duration) ~= "number" or duration <= 0 then return end

    local remaining = Math.clamp(self.entity.riseRemaining - dt, 0, duration)
    self.entity.riseRemaining = remaining
    self.entity.surfaceDepth = Math.clamp(1 - remaining / duration, 0, 1)
end

function Fish:_random()
    local value = self.rng()
    assert(type(value) == "number", "fish rng must return a number")
    return Math.clamp(value, 0, 1)
end

function Fish:_chooseWander()
    local minSec = self.speciesData.wanderMinSec or 0
    local maxSec = self.speciesData.wanderMaxSec or minSec
    if maxSec < minSec then maxSec = minSec end
    self.wanderRemaining = minSec + self:_random() * (maxSec - minSec)
    self.wanderTargetAngle = self:_random() * TWO_PI - math.pi
end

---@param radius number
---@param filter fun(candidate: table): boolean
---@return table? nearest
---@return number nearestDistanceSquared
function Fish:_nearestEntity(radius, filter)
    local matches = self.world:queryEntitiesInRadius(self.entity.position, radius, filter)
    ---@type table?
    local nearest = nil
    local nearestDistanceSquared = math.huge
    for _, candidate in pairs(matches or {}) do
        if isLive(candidate) and candidate.id ~= self.entity.id then
            local distanceSquared = Math.distanceSquared(self.entity.position, candidate.position)
            if distanceSquared < nearestDistanceSquared then
                nearest = candidate
                nearestDistanceSquared = distanceSquared
            end
        end
    end
    return nearest, nearestDistanceSquared
end

---@return table? danger
function Fish:_findDanger()
    local species = self.speciesData.dangerSpecies
    local radius = self.speciesData.dangerRadius
    if type(species) ~= "string" or type(radius) ~= "number" or radius <= 0 then return nil end

    return self:_nearestEntity(radius, function(candidate)
        return candidate.entityType == "fish" and candidate.species == species and not candidate.removed
    end)
end

---@return table? attraction
function Fish:_findAttraction()
    local data = self.speciesData
    local radius = data.attractRadius
    local speed = data.attractedSpeed
    if type(data.attractEffect) ~= "string" or type(radius) ~= "number" or radius <= 0
        or type(speed) ~= "number" or speed <= 0 then
        -- Missing/nonpositive species tuning disables attraction without discarding
        -- the effect payload. Official tuna tuning is supplied by FishData.
        return nil
    end

    return self:_nearestEntity(radius, function(candidate)
        return effectOf(candidate) == data.attractEffect and not candidate.removed
    end)
end

---@param candidate table?
---@return boolean
function Fish:_isUsablePrey(candidate)
    return candidate ~= nil and isLive(candidate)
        and candidate.captureLocked ~= true
        and candidate.entityType == "fish"
        and candidate.species == self.speciesData.preySpecies
        and candidate.id ~= self.entity.id
end

---@return table? prey
function Fish:_findPrey()
    local species = self.speciesData.preySpecies
    local radius = self.speciesData.preyRadius
    if type(species) ~= "string" or type(radius) ~= "number" or radius <= 0 then return nil end

    return self:_nearestEntity(radius, function(candidate)
        return self:_isUsablePrey(candidate)
    end)
end

function Fish:_clearPrey()
    self.preyId = nil
    self.lastPreyPosition = nil
    self.lostPreyTime = 0
end

function Fish:_tryEat(prey)
    if self.world:remove(prey.id, "eaten") then
        self.predationCooldownUntil = self.world.time + Config.predation.cooldownSeconds
        self:_clearPrey()
        return true
    end
    return false
end

---@param dt number
---@return OceanFishPoint? targetPosition
function Fish:_getChaseTarget(dt)
    if self.world.time < self.predationCooldownUntil then
        self:_clearPrey()
        return nil
    end
    local data = self.speciesData
    ---@type table?
    local prey = self.preyId and self.world:get(self.preyId) or nil
    local preyRadius = data.preyRadius or 0
    -- A lock is an explicit invalidation, not ordinary lost-sight grace.
    if prey and prey.captureLocked then self:_clearPrey(); prey = nil end

    if prey ~= nil and self:_isUsablePrey(prey)
        and Math.distanceSquared(self.entity.position, prey.position) <= preyRadius * preyRadius then
        local distanceSquared = Math.distanceSquared(self.entity.position, prey.position)
        if distanceSquared <= (data.eatRadius or 0) * (data.eatRadius or 0) then
            if self:_tryEat(prey) then return nil end
        end

        self.lastPreyPosition = Math.copy(prey.position)
        self.lostPreyTime = 0
        return prey.position
    end

    ---@type table?
    local replacement = self:_findPrey()
    if replacement then
        self.preyId = replacement.id
        self.lastPreyPosition = Math.copy(replacement.position)
        self.lostPreyTime = 0
        local distanceSquared = Math.distanceSquared(self.entity.position, replacement.position)
        if distanceSquared <= (data.eatRadius or 0) * (data.eatRadius or 0) then
            if self:_tryEat(replacement) then return nil end
        end
        return replacement.position
    end

    if self.preyId ~= nil and self.lastPreyPosition ~= nil then
        self.lostPreyTime = self.lostPreyTime + dt
        if self.lostPreyTime <= (data.lostPreySec or 0) then
            return self.lastPreyPosition
        end
    end

    self.preyId = nil
    self.lastPreyPosition = nil
    self.lostPreyTime = 0
    return nil
end

function Fish:_updateFleeJitter(dt)
    local data = self.speciesData
    local interval = data.fleeJitterSec or 0
    if not self.wasFleeing then
        self.fleeJitterRemaining = 0
        self.wasFleeing = true
    end

    if interval <= 0 then
        self.fleeJitterRadians = 0
        return
    end

    self.fleeJitterRemaining = self.fleeJitterRemaining - dt
    while self.fleeJitterRemaining <= 0 do
        local jitterDeg = data.fleeJitterDeg or 0
        self.fleeJitterRadians = math.rad((self:_random() * 2 - 1) * jitterDeg)
        self.fleeJitterRemaining = self.fleeJitterRemaining + interval
    end
end

---@param targetAngle number
---@param dt number
function Fish:_turnToward(targetAngle, dt)
    local rotation = self.entity.rotation or 0
    local maxRadians = math.rad(self.speciesData.turnDegPerSec or 0) * dt
    self.entity.rotation = normalizeAngle(Math.turn(rotation, targetAngle, maxRadians))
end

---@param directionX number
---@param directionY number
---@param speed number
---@param dt number
function Fish:_move(directionX, directionY, speed, dt)
    local moveX, moveY = Math.normal(directionX, directionY)
    self.entity.direction = { x = moveX, y = moveY }
    self.world:moveEntity(self.entity, moveX * speed * dt, moveY * speed * dt)
end

---@param speed number
---@param dt number
---@param targetX number
---@param targetY number
function Fish:_moveTowardTarget(speed, dt, targetX, targetY)
    -- Chase and attraction movement follow the already capped turn, not the
    -- requested target bearing. Cap travel at the target distance while
    -- moving toward it so a large timestep cannot step past the target.
    local moveX, moveY = directionFromAngle(self.entity.rotation or 0)
    local targetDirX, targetDirY = Math.normal(targetX, targetY)
    local travelDistance = speed * dt
    if targetDirX == 0 and targetDirY == 0 then
        travelDistance = 0
    elseif moveX * targetDirX + moveY * targetDirY > 0 then
        travelDistance = math.min(travelDistance, math.sqrt(lengthSquared(targetX, targetY)))
    end

    self.entity.direction = { x = moveX, y = moveY }
    self.world:moveEntity(self.entity, moveX * travelDistance, moveY * travelDistance)
end

function Fish:_fleeDirection(awayX, awayY)
    -- The visual heading may still be turning toward the escape bearing.
    -- While its forward vector points into the threat hemisphere, blend it
    -- with the away vector so actual displacement always retains an away
    -- component during the turn (including a 180-degree turnaround).
    local facingX, facingY = directionFromAngle(self.entity.rotation or 0)
    local awayDot = facingX * awayX + facingY * awayY
    if awayDot > 0 then return facingX, facingY end

    local blendedX, blendedY = Math.normal(facingX + awayX, facingY + awayY)
    if blendedX * awayX + blendedY * awayY <= 0 then return awayX, awayY end
    return blendedX, blendedY
end

function Fish:_steeredDirection(targetX, targetY)
    local targetDirX, targetDirY = Math.normal(targetX, targetY)
    if targetDirX == 0 and targetDirY == 0 then
        return directionFromAngle(self.entity.rotation or 0)
    end

    local facingX, facingY = directionFromAngle(self.entity.rotation or 0)
    local dot = facingX * targetDirX + facingY * targetDirY
    if dot >= 0 then return facingX, facingY end

    local blendedX, blendedY = Math.normal(facingX + targetDirX, facingY + targetDirY)
    if blendedX == 0 and blendedY == 0 then
        -- At an exact 180-degree reversal, use a tangent on the same side as
        -- the capped turn. This avoids instant movement reversals that would
        -- erase the species' configured turn-speed difference.
        local rotation = self.entity.rotation or 0
        local delta = normalizeAngle(angleOf(targetDirX, targetDirY) - rotation)
        local side = delta < 0 and -1 or 1
        return -facingY * side, facingX * side
    end
    return blendedX, blendedY
end

---@param dt number
---@return string state
function Fish:Update(dt)
    if not isLive(self.entity) or self.entity.active == false or self.entity.frozen == true
        or self.entity.captureLocked == true then
        return self.state
    end

    dt = math.max(0, dt or 0)
    local data = self.speciesData
    ---@type string?
    local nextState = nil
    ---@type number?
    local targetAngle = nil
    local speed = 0
    ---@type number?
    local avoidX = nil
    ---@type number?
    local avoidY = nil
    ---@type number?
    local fleeAwayX = nil
    ---@type number?
    local fleeAwayY = nil
    ---@type number?
    local targetX = nil
    ---@type number?
    local targetY = nil

    avoidX, avoidY = self.world:getAvoidance(self.entity, data.avoidMargin or 0)
    if avoidX ~= nil and avoidY ~= nil and lengthSquared(avoidX, avoidY) > 0 then
        avoidX, avoidY = Math.normal(avoidX, avoidY)
        nextState = "Avoid"
        targetAngle = angleOf(avoidX, avoidY)
        speed = data.wanderSpeed or 0
        self.wasFleeing = false
    else
        local danger = self:_findDanger()
        if danger then
            local awayX, awayY = Math.normal(
                self.entity.position.x - danger.position.x,
                self.entity.position.y - danger.position.y
            )
            if awayX == 0 and awayY == 0 then
                local randomAngle = self:_random() * TWO_PI - math.pi
                awayX, awayY = directionFromAngle(randomAngle)
            end

            self:_updateFleeJitter(dt)
            local jitter = self.fleeJitterRadians
            local cosine, sine = math.cos(jitter), math.sin(jitter)
            local jitteredX = awayX * cosine - awayY * sine
            local jitteredY = awayX * sine + awayY * cosine
            nextState = "Flee"
            targetAngle = angleOf(jitteredX, jitteredY)
            speed = data.fleeSpeed or 0
            fleeAwayX, fleeAwayY = awayX, awayY
        else
            self.wasFleeing = false
            ---@type OceanFishPoint?
            local preyPosition = data.preySpecies and self:_getChaseTarget(dt) or nil
            local attraction = not preyPosition and self:_findAttraction() or nil
            if preyPosition then
                local dx = preyPosition.x - self.entity.position.x
                local dy = preyPosition.y - self.entity.position.y
                nextState = "Chase"
                targetAngle = angleOf(dx, dy)
                speed = data.chaseSpeed or 0
                targetX, targetY = dx, dy
            elseif attraction then
                local dx = attraction.position.x - self.entity.position.x
                local dy = attraction.position.y - self.entity.position.y
                nextState = "Attracted"
                targetAngle = angleOf(dx, dy)
                speed = data.attractedSpeed or 0
                targetX, targetY = dx, dy
            end

            if not nextState then
                nextState = "Wander"
                if self.state ~= "Wander" then self.wanderRemaining = 0 end
                if self.wanderRemaining <= 0 then self:_chooseWander() end
                self.wanderRemaining = self.wanderRemaining - dt
                targetAngle = self.wanderTargetAngle
                speed = data.wanderSpeed or 0
            end
        end
    end

    if self.state == "Flee" and nextState ~= "Flee" then self.wasFleeing = false end
    self.fsm:Change(nextState)
    if nextState == "Flee" then self:_advanceSurfaceRise(dt) end

    self:_turnToward(targetAngle or (self.entity.rotation or 0), dt)

    if nextState == "Flee" then
        local moveX, moveY = self:_fleeDirection(fleeAwayX or 0, fleeAwayY or 0)
        self:_move(moveX, moveY, speed, dt)
    elseif nextState == "Avoid" then
        local moveX, moveY = self:_steeredDirection(avoidX or 0, avoidY or 0)
        self:_move(moveX, moveY, speed, dt)
    elseif nextState == "Chase" or nextState == "Attracted" then
        self:_moveTowardTarget(speed, dt, targetX or 0, targetY or 0)
    else
        local moveX, moveY = directionFromAngle(self.entity.rotation or 0)
        self:_move(moveX, moveY, speed, dt)
    end
    return self.state
end

return Fish
