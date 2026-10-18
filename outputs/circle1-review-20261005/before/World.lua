-- World state is independent of rendering and future inventory/player state.
local Config = require("Ocean.Config")
local M = require("Ocean.Math")
local BaseWorld = require("Game.World")
---@class SeaEntity: OceanShip
---@field kind string
---@field entityType string
---@field layer string
---@field alive boolean
---@field removed boolean
---@field active boolean
---@field frozen boolean
---@field state string
---@field blocking boolean
---@field ordinaryFish boolean
---@field species string?
---@field itemId string?
---@field category string?
---@field worldEffect string
---@field lifetimeSec number?
---@field age number
---@field fsm table?
---@field removeReason string?
---@field surfaceDepth number?
---@field riseRemaining number?
---@field captureLocked boolean?
---@field captureOwnerToken table?
---@field contentId string?

---@class SeaWorld: GameWorld, OceanWorld
---@field surfaceSignals table?
---@field scopeShip SeaEntity?
---@field scopeEnabled boolean
---@field fixedBarrel SeaEntity?
---@field fixedBarrelGeneration integer
---@field retired boolean
local World = setmetatable({}, { __index = BaseWorld })
World.__index = World

local SCOPE_LENGTH_METERS = 20.0
local SCOPE_LENGTH_SQUARED = SCOPE_LENGTH_METERS * SCOPE_LENGTH_METERS
local SCOPE_HALF_ANGLE_RADIANS = math.rad(45.0)
local SCOPE_HALF_ANGLE_TANGENT = math.tan(SCOPE_HALF_ANGLE_RADIANS)
local VISIBILITY_EPSILON = Config.world.epsilon
-- Process-local credentials, independent of fish refreshes and day seeds.
-- A new World (including a separate Runtime.New) cannot reuse an old token.
local barrelGenerationCounter = 0

local function clearArray(values)
    for index = #values, 1, -1 do values[index] = nil end
end

local function queryWaterState(state, position, radius)
    radius = radius or 0
    if state.usePublicPredicate == true then
        local world = state.world
        if type(world) ~= "table" or type(world.isPositionFree) ~= "function" then return true end
        return world:isPositionFree(position, radius)
    end

    local bound = state.halfSize - radius
    if math.abs(position.x) > bound or math.abs(position.y) > bound then return false end
    for _, object in ipairs(state.blockers) do
        if not object.removed and object.blocking then
            local dx = position.x - object.position.x
            local dy = position.y - object.position.y
            local combined = radius + object.radius
            if dx * dx + dy * dy < combined * combined then return false end
        end
    end
    return true
end

local function waterQueryForState(state)
    if type(state.query) ~= "function" then
        state.query = function(position, radius)
            return queryWaterState(state, position, radius)
        end
    end
    return state.query
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

-- This is a visibility test against the ship's current transform. It does not
-- cache a location, so the sector follows movement while a stopped ship keeps
-- its last heading.
---@param ship SeaEntity?
---@param entity SeaEntity
local function isInsideScope(ship, entity)
    if type(ship) ~= "table" or type(entity.position) ~= "table" then return false end
    local shipPosition = ship.position
    local rotation = ship.rotation
    if type(shipPosition) ~= "table"
        or not isFiniteNumber(shipPosition.x) or not isFiniteNumber(shipPosition.y)
        or not isFiniteNumber(entity.position.x) or not isFiniteNumber(entity.position.y)
        or not isFiniteNumber(rotation) then
        return false
    end

    local dx = entity.position.x - shipPosition.x
    local dy = entity.position.y - shipPosition.y
    local distanceSquared = dx * dx + dy * dy
    if distanceSquared > SCOPE_LENGTH_SQUARED + VISIBILITY_EPSILON then return false end

    local forwardX, forwardY = math.cos(rotation), math.sin(rotation)
    local forwardDistance = dx * forwardX + dy * forwardY
    if forwardDistance < -VISIBILITY_EPSILON then return false end

    -- A 45 degree half-angle has tan(45) == 1, so the absolute side distance
    -- may not exceed the forward projection. The epsilon includes exact edges.
    local sideDistance = -dx * forwardY + dy * forwardX
    return math.abs(sideDistance) <= forwardDistance * SCOPE_HALF_ANGLE_TANGENT + VISIBILITY_EPSILON
end

---@return SeaWorld
function World.New()
    local self = setmetatable({}, World)
    self:Init()
    return self
end

function World:Init()
    BaseWorld.Init(self, { idPrefix = "sea-" })
    self.retired = false
    self.time = 0
    self.daySeed = Config.world.seed
    self.reveals = {}
    self.showUnderwater = false
    self.scopeShip = nil
    self.scopeEnabled = false
    self.overlaps = {}
    self.events = {}
    self.onOverlap = false
    for _, object in ipairs(Config.world.fixedObjects) do
        self:spawn({ entityType = object.entityType, kind = "fixed", layer = "surface",
            position = object.position, radius = object.radius, blocking = object.blocking })
    end
    barrelGenerationCounter = barrelGenerationCounter + 1
    self.fixedBarrelGeneration = barrelGenerationCounter
    local barrel = Config.world.fixedBarrel
    assert(self:isPositionFree(barrel.position, barrel.radius), "fixed barrel must be in open sea")
    -- 碰撞实体：与岛屿同一 swept-circle 阻挡（World:moveEntity 检查 blocking），
    -- 船不能穿过木桶；接触距离 1.8+2=3.8m < operateDistance 5m，抵近即可检查。
    self.fixedBarrel = self:spawn({ entityType = "float", kind = "fixed", layer = "surface",
        contentId = "driftwood_barrel", position = barrel.position, radius = barrel.radius,
        blocking = true })
end

---@return SeaEntity
function World:spawn(spec)
    assert(not self.retired, "cannot spawn into a retired sea world")
    assert(spec.position and type(spec.position.x) == "number" and type(spec.position.y) == "number", "position requires x,y")
    local entity = {
        entityType = spec.entityType or "object",
        kind = spec.kind or "dynamic", layer = spec.layer or "surface",
        position = M.copy(spec.position), rotation = spec.rotation or 0,
        direction = { x = math.cos(spec.rotation or 0), y = math.sin(spec.rotation or 0) },
        active = spec.active ~= false, frozen = spec.frozen == true, state = spec.state or "Idle",
        radius = spec.radius or 0, blocking = spec.blocking == true, removed = false,
        species = spec.species, ordinaryFish = spec.ordinaryFish == true,
        itemId = spec.itemId, category = spec.category, worldEffect = spec.worldEffect or "NONE",
        contentId = spec.contentId,
        lifetimeSec = spec.lifetimeSec, age = 0,
    }
    return self:CreateEntity(entity.kind, entity)
end

function World:get(id) return self:GetEntity(id) end

function World:remove(id, reason, ownerToken)
    local entity = self:get(id)
    if entity and entity.captureLocked then
        if reason == "eaten" then return false end
        if reason == "caught" and not rawequal(entity.captureOwnerToken, ownerToken) then return false end
    end
    if not BaseWorld.RemoveEntity(self, id, reason, true) then return false end
    entity.captureLocked, entity.captureOwnerToken = false, nil
    self.overlaps[id] = nil
    if self.surfaceSignals then self.surfaceSignals:OnRemoved(id) end
    return true
end

function World:RemoveEntity(id, reason, ownerToken) return self:remove(id, reason, ownerToken) end
function World:compact() self:Compact() end

local function matches(entity, filter)
    if filter == nil then return true end
    if type(filter) == "function" then return filter(entity) end
    for key, expected in pairs(filter) do
        if type(expected) == "table" then
            if not expected[entity[key]] then return false end
        elseif entity[key] ~= expected then return false end
    end
    return true
end

-- Visibility/frozen flags never implicitly filter this interaction query.
function World:queryEntitiesInRadius(center, radius, filter)
    assert(type(radius) == "number" and radius >= 0, "radius must be nonnegative")
    local found = {}
    for _, entity in ipairs(self.entities) do
        if not entity.removed and M.distanceSquared(center, entity.position) <= radius * radius and matches(entity, filter) then
            found[#found + 1] = entity
        end
    end
    return found
end

function World:isPositionFree(position, radius)
    local bound = Config.world.halfSize - radius
    if math.abs(position.x) > bound or math.abs(position.y) > bound then return false end
    for _, object in ipairs(self.entities) do
        if not object.removed and object.blocking and M.distanceSquared(position, object.position) < (radius + object.radius)^2 then
            return false
        end
    end
    return true
end

-- A transient query for a batch of read-only water checks (for example surface
-- cues). Consume it synchronously; it is a snapshot, not a persistent index.
-- Every blocking entity participates, including user-spawned dynamic blockers.
function World:CreateWaterQuery(workspace)
    -- Without a workspace this remains an independent snapshot, preserving
    -- existing callers that retain more than one query at a time. Surface
    -- signal getters/visitors pass their private workspace for zero-churn use.
    local state = type(workspace) == "table" and workspace or { blockers = {} }
    if type(state.blockers) ~= "table" then state.blockers = {} end
    clearArray(state.blockers)
    state.world = self
    state.halfSize = Config.world.halfSize
    state.usePublicPredicate = self.isPositionFree ~= World.isPositionFree
    if not state.usePublicPredicate then
        for _, entity in ipairs(self.entities) do
            if not entity.removed and entity.blocking then
                state.blockers[#state.blockers + 1] = entity
            end
        end
    end
    return waterQueryForState(state)
end

-- Replacing a Runtime retires its former World. Normal Clear remains a
-- same-instance reset and deliberately keeps systems registered.
function World:Retire()
    if self.retired then return false end
    self.retired = true
    self:Clear()
    self:compact()

    local signals = self.surfaceSignals
    if type(signals) == "table" then
        if type(signals.DetachWorld) == "function" then
            signals:DetachWorld()
        else
            if type(signals.Clear) == "function" then signals:Clear() end
            signals.world = nil
        end
    end
    self.surfaceSignals = nil
    self.scopeShip = nil
    self.scopeEnabled = false
    self.showUnderwater = false
    self.reveals = {}
    self.overlaps = {}
    self.events = {}
    self.fixedBarrel = nil
    self.systems = {}
    self.systemCadences = {}
    return true
end

function World:AddSystem(system, cadence)
    if self.retired then return false end
    return BaseWorld.AddSystem(self, system, cadence)
end

function World:Update(dt, cadence)
    if self.retired then return end
    BaseWorld.Update(self, dt, cadence)
end

-- Swept circle prevents tunnelling through islands even for a large caller delta.
---@param entity SeaEntity
---@param dx number
---@param dy number
function World:moveEntity(entity, dx, dy)
    if entity.captureLocked == true then return false, 0, 0 end
    local start = entity.position
    local epsilon = Config.world.epsilon
    local bound = Config.world.halfSize - entity.radius
    local first, normalX, normalY = 1, 0, 0
    local hit = false
    local function contact(t, nx, ny)
        if t >= 0 and t <= first then first, normalX, normalY, hit = t, nx, ny, true end
    end
    if dx > 0 and start.x+dx > bound then contact((bound-start.x)/dx, -1, 0) end
    if dx < 0 and start.x+dx < -bound then contact((-bound-start.x)/dx, 1, 0) end
    if dy > 0 and start.y+dy > bound then contact((bound-start.y)/dy, 0, -1) end
    if dy < 0 and start.y+dy < -bound then contact((-bound-start.y)/dy, 0, 1) end
    local a = dx*dx + dy*dy
    if a > epsilon then
        for _, object in ipairs(self.entities) do
            if not object.removed and object.blocking and object.id ~= entity.id then
                local ox, oy = start.x-object.position.x, start.y-object.position.y
                local combined = entity.radius+object.radius
                local b = 2*(ox*dx + oy*dy)
                local c = ox*ox+oy*oy-combined*combined
                local discriminant = b*b-4*a*c
                if c < -epsilon then
                    -- Permit exit from an externally supplied overlapping start.
                    if b < 0 then
                        local nx, ny = M.normal(ox, oy)
                        if nx == 0 and ny == 0 then nx, ny = M.normal(-dx, -dy) end
                        contact(0, nx, ny)
                    end
                elseif discriminant >= 0 and b < 0 then
                    local t = (-b-math.sqrt(discriminant))/(2*a)
                    local nx, ny = M.normal(ox+dx*t, oy+dy*t)
                    contact(t, nx, ny)
                end
            end
        end
    end
    local t = hit and math.max(0, first-epsilon) or 1
    local result = { x = M.clamp(start.x+dx*t, -bound, bound), y = M.clamp(start.y+dy*t, -bound, bound) }
    -- Final projection also repairs externally moved/debug entities inside a collider.
    for _, object in ipairs(self.entities) do
        if not object.removed and object.blocking and object.id ~= entity.id then
            local combined = entity.radius+object.radius
            local ox, oy = result.x-object.position.x, result.y-object.position.y
            if ox*ox+oy*oy < combined*combined then
                local nx, ny = M.normal(ox, oy)
                if nx == 0 and ny == 0 then nx, ny = 1, 0 end
                result.x, result.y = object.position.x+nx*(combined+epsilon), object.position.y+ny*(combined+epsilon)
                hit, normalX, normalY = true, nx, ny
            end
        end
    end
    result.x, result.y = M.clamp(result.x, -bound, bound), M.clamp(result.y, -bound, bound)
    entity.position = result
    return hit, normalX, normalY
end

function World:getAvoidance(entity, margin)
    local x, y = entity.position.x, entity.position.y
    local bound = Config.world.halfSize-entity.radius-margin
    local ax, ay = 0, 0
    if x >= bound then ax = ax-1 elseif x <= -bound then ax = ax+1 end
    if y >= bound then ay = ay-1 elseif y <= -bound then ay = ay+1 end
    for _, object in ipairs(self.entities) do
        if not object.removed and object.blocking and object.id ~= entity.id then
            local ox, oy = x-object.position.x, y-object.position.y
            if ox*ox+oy*oy <= (object.radius+entity.radius+margin)^2 then
                local nx, ny = M.normal(ox, oy)
                if nx == 0 and ny == 0 then nx, ny = 1, 0 end
                ax, ay = ax+nx, ay+ny
            end
        end
    end
    if ax*ax+ay*ay > Config.world.epsilon then return M.normal(ax, ay) end
    return nil
end

function World:spawnDroppedItem(payload, position)
    assert(type(payload) == "table" and type(payload.itemId) == "string", "itemId required")
    local effect = payload.worldEffect or "NONE"
    assert(effect == "NONE" or effect == "ATTRACT_SMALL_FISH" or effect == "ATTRACT_BIG_FISH", "unsupported worldEffect")
    local lifetime = payload.lifetimeSec or Config.world.temporaryLifetimeSec
    assert(type(lifetime) == "number" and lifetime > 0, "positive lifetimeSec required")
    assert(self:isPositionFree(position, 0), "drop must be inside playable sea")
    return self:spawn({ entityType = "droppedItem", kind = "temporary", layer = "surface",
        position = position, radius = Config.world.overlapRadius, itemId = payload.itemId,
        category = payload.category, worldEffect = effect, lifetimeSec = lifetime })
end

function World:updateActivity(departure)
    for _, entity in ipairs(self.entities) do
        if not entity.removed and entity.ordinaryFish then
            local distance = M.distanceSquared(entity.position, departure)
            if entity.frozen and distance <= Config.world.activateRadius^2 then
                entity.active, entity.frozen = true, false
            elseif not entity.frozen and distance > Config.world.freezeRadius^2 then
                entity.active, entity.frozen = false, true
            end
        end
    end
end

function World:updateLifecycle(dt, ship)
    self.time = self.time+dt
    self.events = {} -- bounded, per-step events; optional callback for external integration.
    for _, entity in ipairs(self.entities) do
        if not entity.removed and entity.kind == "temporary" then
            entity.age = entity.age+dt
            if entity.age >= entity.lifetimeSec then self:remove(entity.id, "expired") end
        end
        if not entity.removed and not entity.blocking and entity.layer == "surface" and entity.id ~= ship.id then
            local overlap = M.distanceSquared(ship.position, entity.position) <= (ship.radius+entity.radius)^2
            if overlap and not self.overlaps[entity.id] then
                self.events[#self.events + 1] = { type = "overlap", entityId = entity.id, shipId = ship.id }
                if self.onOverlap then self.onOverlap(entity, ship) end
            end
            -- Integration callbacks may synchronously collect/remove the entity.
            -- remove() already cleared its marker; do not reinsert a stale ID.
            self.overlaps[entity.id] = not entity.removed and overlap or nil
        end
    end
    for i = #self.reveals, 1, -1 do
        local reveal = self.reveals[i]
        reveal.remainingSec = reveal.remainingSec-dt
        if reveal.remainingSec <= 0 then table.remove(self.reveals, i) end
    end
end

function World:revealUnderwater(center, radius, durationSec)
    assert(radius >= 0 and durationSec > 0, "invalid reveal")
    self.reveals[#self.reveals + 1] = { center = M.copy(center), radius = radius, remainingSec = durationSec }
end

function World:isVisible(entity)
    if entity.removed then return false end
    if entity.layer ~= "underwater" or self.showUnderwater then return true end
    if self.scopeEnabled and isInsideScope(self.scopeShip, entity) then return true end
    for _, reveal in ipairs(self.reveals) do
        if M.distanceSquared(entity.position, reveal.center) <= reveal.radius^2 then return true end
    end
    return false
end

-- Presentation reads the very same constants as isInsideScope; it cannot
-- enlarge the sector, reveal fish, or turn on observation.
function World:GetScopeView()
    local ship = self.scopeShip
    if not self.scopeEnabled or not ship or not ship.position then return nil end
    return { center = M.copy(ship.position), heading = ship.rotation,
        radius = math.sqrt(SCOPE_LENGTH_SQUARED), halfAngle = math.atan(SCOPE_HALF_ANGLE_TANGENT) }
end

function World:clearOrdinaryFish()
    for _, entity in ipairs(self.entities) do
        if entity.ordinaryFish then self:remove(entity.id, "clearOrdinaryFish") end
    end
    self:compact()
end

function World:getCounts()
    local counts = { total = 0, active = 0, frozen = 0, sardine = 0, tuna = 0, temp = 0 }
    for _, entity in ipairs(self.entities) do
        if not entity.removed then
            counts.total = counts.total+1
            if entity.ordinaryFish then
                counts[entity.species] = counts[entity.species]+1
                local key = entity.frozen and "frozen" or "active"
                counts[key] = counts[key]+1
            elseif entity.kind == "temporary" then counts.temp = counts.temp+1 end
        end
    end
    return counts
end
return World
