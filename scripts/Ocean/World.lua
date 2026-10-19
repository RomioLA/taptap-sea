-- World state is independent of rendering and future inventory/player state.
local Config = require("Ocean.Config")
local M = require("Ocean.Math")
local BaseWorld = require("Game.World")
local Content = require("data.content")
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
---@field fixedContentEntities table<string, SeaEntity>
---@field fixedContentGeneration integer
---@field retired boolean
local World = setmetatable({}, { __index = BaseWorld })
World.__index = World

local SCOPE_LENGTH_METERS = 20.0
local SCOPE_LENGTH_SQUARED = SCOPE_LENGTH_METERS * SCOPE_LENGTH_METERS
local SCOPE_HALF_ANGLE_RADIANS = math.rad(45.0)
local SCOPE_HALF_ANGLE_TANGENT = math.tan(SCOPE_HALF_ANGLE_RADIANS)
local VISIBILITY_EPSILON = Config.world.epsilon
local EVENT_QUEUE_LIMIT = 256
local EVENT_TYPES = {
    observation_recorded = true,
    hypothesis_confirmed = true,
    content_marked = true,
    trace_expired = true,
}
-- Process-local credentials, independent of fish refreshes and day seeds.
-- A new World (including a separate Runtime.New) cannot reuse an old token.
local barrelGenerationCounter = 0
local fixedContentGenerationCounter = 0

local function clearArray(values)
    for index = #values, 1, -1 do values[index] = nil end
end

local function copyEvent(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copyEvent(child) end
    return result
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

local FIXED_CONTENT_ENTITY_TYPES = {
    island = true, treasure = true, wreck = true, reef = true, coral = true,
    -- V2.8 第一批/第二批固定海上节点
    debris = true, bottle = true, bones = true, vortex = true, net = true, kelp = true,
}

local function isFinitePoint(point)
    return type(point) == "table" and isFiniteNumber(point.x) and isFiniteNumber(point.y)
end

local function resolveFixedContentPosition(world, definition)
    local hasPosition = definition.position ~= nil
    local hasContainer = definition.at ~= nil
    if hasPosition == hasContainer then return nil, "invalid_content_location" end

    if hasPosition then
        if not isFinitePoint(definition.position) or definition.localOffset ~= nil then
            return nil, "invalid_content_location"
        end
        return M.copy(definition.position)
    end

    if definition.entityType ~= "treasure" or type(definition.at) ~= "table"
        or (definition.at.kind ~= "island" and definition.at.kind ~= "wreck")
        or type(definition.at.contentId) ~= "string" then
        return nil, "invalid_content_container"
    end
    local container = world.fixedContentEntities[definition.at.contentId]
    if not container or container.kind ~= "fixed" or container.entityType ~= definition.at.kind
        or container.removed or container.alive == false then
        return nil, "content_container_unavailable"
    end

    local offset = definition.localOffset
    if offset == nil then offset = { x = 0, y = 0 } end
    if not isFinitePoint(offset) then return nil, "invalid_content_offset" end
    return { x = container.position.x + offset.x, y = container.position.y + offset.y }
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
    self.pendingEvents = {}
    self.eventQueueDiagnostics = { overflowCount = 0, staleCount = 0 }
    self.onDiagnostic = nil
    self.onOverlap = false
    fixedContentGenerationCounter = fixedContentGenerationCounter + 1
    self.fixedContentGeneration = fixedContentGenerationCounter
    self.fixedContentEntities = {}
    self.fixedContentIds = {}
    local fixedTreasureCount = 0
    for _, object in ipairs(Content.fixed) do
        if object.entityType == "treasure" then
            fixedTreasureCount = fixedTreasureCount + 1
            assert(object.contentId == "underwater_treasure_01" and object.layer == "underwater"
                and object.blocking == false, "existing treasure contract changed")
        end
        local entity, reason = self:RegisterFixedContent(object)
        assert(entity, reason or "invalid authored fixed content")
        if object.entityType == "treasure" and object.contentId == "underwater_treasure_01" then
            assert(self:isPositionFree(entity.position, entity.radius), "fixed treasure must be in open sea")
        end
    end
    assert(fixedTreasureCount == 1, "the existing fixed treasure is the only production treasure")
    -- V2.8：固定阻塞节点（礁石/破渔网）也必须落在可航行海域，且彼此不重叠。
    for _, object in ipairs(Content.fixed) do
        if object.kind == "fixed" and object.blocking == true then
            local entity = assert(self.fixedContentEntities[object.contentId])
            local others = 0
            for _, other in ipairs(self.blockingList) do
                if other ~= entity and not other.removed then
                    local dx, dy = entity.position.x - other.position.x, entity.position.y - other.position.y
                    if dx * dx + dy * dy < (entity.radius + other.radius) ^ 2 then
                        others = others + 1
                    end
                end
            end
            assert(others == 0, "fixed blocking content overlaps: " .. tostring(object.contentId))
        end
    end
    barrelGenerationCounter = barrelGenerationCounter + 1
    self.fixedBarrelGeneration = barrelGenerationCounter
    local barrel = Config.world.fixedBarrel
    assert(self:isPositionFree(barrel.position, barrel.radius), "fixed barrel must be in open sea")
    -- 真机反馈 #6（2026-10-04 用户验收）：木桶应和岛屿一样拥有碰撞实体。
    -- 固定身份与5米检查范围独立于碰撞；blocking 只影响航行阻挡。
    -- 注：B 侧 v2.2 曾改回 blocking=false，此处按用户显式反馈恢复，已同步适配测试。
    -- V2.8：临时诱饵可在 payload 里声明更大的感知半径（海眼 60m 吸小鱼 / 90m 吸大鱼）。
    -- World 维护“当前生效最大半径”索引，Fish 常规路径仍只做一次全表查询。
    self.attractBoostRadius = {}
    self.fixedBarrel = self:spawn({ entityType = "float", kind = "fixed", layer = "surface",
        contentId = "driftwood_barrel", position = barrel.position, radius = barrel.radius,
        blocking = true })
    -- C2（2026-10-17）：主场景组件放置（OceanComponents：海面 oblique 组件 + 海底沉船）。
    -- kind="scenery" 是有意的新种类：不进 fixedObjects 冻结集、不进 kind=="fixed" 实体
    -- 计数（Circle1A2BarrelTests 守护），也不进 blockingList（非阻挡，航行零影响）；
    -- contentId 仍登记进 fixedContentEntities 防重复放置。仅 SeaDraw 消费，纯展示。
    for _, component in ipairs(Config.world.fixedComponents or {}) do
        assert(type(component.contentId) == "string", "fixed component contentId required")
        assert(self.fixedContentEntities[component.contentId] == nil, "duplicate fixed contentId")
        assert(self:isPositionFree(component.position, component.radius),
            "fixed component " .. component.contentId .. " must be in open sea")
        local entity = self:spawn({ entityType = component.entityType, kind = "scenery", layer = "surface",
            contentId = component.contentId, position = component.position,
            radius = component.radius, blocking = false })
        self.fixedContentEntities[component.contentId] = entity
    end
    for _, wreck in ipairs(Config.world.fixedWrecks or {}) do
        assert(type(wreck.contentId) == "string", "fixed wreck contentId required")
        assert(self.fixedContentEntities[wreck.contentId] == nil, "duplicate fixed contentId")
        assert(self:isPositionFree(wreck.position, wreck.radius),
            "fixed wreck " .. wreck.contentId .. " must be in open sea")
        local entity = self:spawn({ entityType = wreck.entityType, kind = "scenery", layer = "underwater",
            contentId = wreck.contentId, position = wreck.position,
            radius = wreck.radius, blocking = false })
        self.fixedContentEntities[wreck.contentId] = entity
    end
    -- 2026-10-18：6 座新岛屿变体放置（OceanIslands）。与 fixedComponents 同构：
    -- kind="scenery"（entityType="island" 复用 SeaViewArt.Island 绘制入口，
    -- contentId 命中 ISLAND_VARIANTS）；不进冻结集/fixed 计数；contentId 登记
    -- 进 fixedContentEntities 防重复；isPositionFree 断言。2026-10-18 晚改
    -- blocking=true（用户「实体体积」）：进 blockingList，船不可穿越（A2 冻结
    -- 契约数 kind=="fixed" 不受影响；岛也不应再触发 surface overlap 交互）。
    for _, island in ipairs(Config.world.fixedIslands or {}) do
        assert(type(island.contentId) == "string", "fixed island contentId required")
        assert(self.fixedContentEntities[island.contentId] == nil, "duplicate fixed contentId")
        assert(self:isPositionFree(island.position, island.radius),
            "fixed island " .. island.contentId .. " must be in open sea")
        local entity = self:spawn({ entityType = island.entityType, kind = "scenery", layer = "surface",
            contentId = island.contentId, position = island.position,
            radius = island.radius, blocking = island.blocking == true })
        self.fixedContentEntities[island.contentId] = entity
    end
end

---Register one authored fixed content item in stable registration order.
---@param definition table
---@return SeaEntity?, string?
function World:RegisterFixedContent(definition)
    if self.retired then return nil, "world_retired" end
    if type(definition) ~= "table" or type(definition.contentId) ~= "string"
        or definition.contentId == "" or definition.kind ~= "fixed"
        or not FIXED_CONTENT_ENTITY_TYPES[definition.entityType]
        or not isFiniteNumber(definition.radius) or definition.radius < 0
        or (definition.layer ~= "surface" and definition.layer ~= "underwater")
        or type(definition.blocking) ~= "boolean" then
        return nil, "invalid_authored_fixed_content"
    end
    if self.fixedContentEntities[definition.contentId] ~= nil then
        return nil, "duplicate_content_id"
    end

    local position, positionError = resolveFixedContentPosition(self, definition)
    if not position then return nil, positionError end
    local entity = self:spawn({ entityType = definition.entityType, kind = definition.kind,
        layer = definition.layer, contentId = definition.contentId, position = position,
        radius = definition.radius, blocking = definition.blocking })
    self.fixedContentEntities[definition.contentId] = entity
    self.fixedContentIds[#self.fixedContentIds + 1] = definition.contentId
    return entity
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
    if type(entity.attractRadius) == "number" then self:refreshAttractBoostRadius(entity.worldEffect) end
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
-- S1-c（2026-10-15 卡顿排查）：可选 out 参数。Fish 行为树每鱼每步 3 次查询
-- （danger/attract/prey），此前每次调用分配新结果表；热调用方（Fish:_nearestEntity）
-- 改传复用的 scratch 表，零分配。不传 out 时行为与原先完全一致。
function World:queryEntitiesInRadius(center, radius, filter, out)
    assert(type(radius) == "number" and radius >= 0, "radius must be nonnegative")
    local found = out or {}
    if out then clearArray(out) end
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
    -- S1-b：blockingList 只含未移除的 blocking 实体（CreateEntity 入/RemoveEntity 摘）。
    for _, object in ipairs(self.blockingList) do
        if M.distanceSquared(position, object.position) < (radius + object.radius)^2 then
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
        -- S1-b：快照源改 blockingList（与 isPositionFree 同源，语义不变）。
        for _, entity in ipairs(self.blockingList) do
            state.blockers[#state.blockers + 1] = entity
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
    self.pendingEvents = {}
    self.fixedBarrel = nil
    self.fixedContentEntities = {}
    self.fixedContentIds = {}
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

local function reportEventQueueOverflow(self)
    local diagnostics = self.eventQueueDiagnostics
    diagnostics.overflowCount = diagnostics.overflowCount + 1
    if type(self.onDiagnostic) == "function" then
        pcall(self.onDiagnostic, self, "world_event_queue_overflow", {
            limit = EVENT_QUEUE_LIMIT, droppedCount = diagnostics.overflowCount,
        })
    end
    local logger = (type(log) == "table" or type(log) == "userdata") and log or nil
    if logger and type(logger.Write) == "function" and type(LOG_WARNING) == "number" then
        pcall(function()
            logger:Write(LOG_WARNING, "[Ocean.World] bounded event queue overflow; dropped oldest event")
        end)
    end
end

---Queue a small cross-system event on this World instance only.
---@param event table
---@return boolean, string?
function World:Emit(event)
    if self.retired then return false, "world_retired" end
    if type(event) ~= "table" then return false, "invalid_event" end
    local eventType = rawget(event, "type")
    if type(eventType) ~= "string" or not EVENT_TYPES[eventType] then
        return false, "invalid_event_type"
    end
    local generation = rawget(event, "generation")
    if generation ~= nil and generation ~= self.fixedContentGeneration then
        return false, "stale_generation"
    end
    local queue = self.pendingEvents
    if #queue >= EVENT_QUEUE_LIMIT then
        table.remove(queue, 1)
        reportEventQueueOverflow(self)
    end
    local queued = copyEvent(event)
    queued.generation = self.fixedContentGeneration
    queue[#queue + 1] = queued
    return true
end

---Drain queued events FIFO and discard entries from another World generation.
---@return table[]
function World:DrainEvents()
    local queued = self.pendingEvents or {}
    self.pendingEvents = {}
    local drained = {}
    if self.retired then return drained end
    for _, event in ipairs(queued) do
        if event.generation == self.fixedContentGeneration then
            drained[#drained + 1] = event
        else
            self.eventQueueDiagnostics.staleCount = self.eventQueueDiagnostics.staleCount + 1
        end
    end
    return drained
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
        -- S1-e（2026-10-16 卡顿排查续）：swept 检测只关心 blocking 实体，
        -- 直接遍历 blockingList（CreateEntity 入/RemoveEntity 摘，只含未移除的
        -- blocking 实体），不再全表扫描 entities（船每步移动 + 每鱼每步都走这里）。
        for _, object in ipairs(self.blockingList) do
            if object.id ~= entity.id then
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
    for _, object in ipairs(self.blockingList) do
        if object.id ~= entity.id then
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
    for _, object in ipairs(self.blockingList) do
        if object.id ~= entity.id then
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
    local entity = self:spawn({ entityType = "droppedItem", kind = "temporary", layer = "surface",
        position = position, radius = Config.world.overlapRadius, itemId = payload.itemId,
        category = payload.category, worldEffect = effect, lifetimeSec = lifetime })
    -- V2.8 海眼：临时诱饵可显式声明更大的感知半径（60m/90m），
    -- 由 Fish 查询时读取；诱饵过期/移除后索引自动回落。
    local attractRadius = payload.attractRadius
    if type(attractRadius) == "number" and attractRadius > 0 and attractRadius < math.huge then
        entity.payload = { worldEffect = effect, attractRadius = attractRadius,
            vortexBoost = payload.vortexBoost == true, source = payload.source }
        entity.attractRadius = attractRadius
        self:refreshAttractBoostRadius(effect)
    end
    return entity
end

-- 按 worldEffect 维护“当前生效最大感知半径”，避免 Fish 每次感知都全表扫描两遍。
-- 只有携带更大半径的临时诱饵会抬高索引；诱饵过期后按剩余实体重算。
function World:refreshAttractBoostRadius(effect)
    local boost = self.attractBoostRadius or {}
    self.attractBoostRadius = boost
    if effect ~= nil and effect ~= "ATTRACT_SMALL_FISH" and effect ~= "ATTRACT_BIG_FISH" then
        boost[effect] = nil
        return
    end
    local effects = effect and { effect } or { "ATTRACT_SMALL_FISH", "ATTRACT_BIG_FISH" }
    for _, key in ipairs(effects) do
        local maximum = nil
        for _, entity in ipairs(self.entities) do
            if not entity.removed and entity.kind == "temporary" and entity.worldEffect == key
                and type(entity.attractRadius) == "number" then
                if not maximum or entity.attractRadius > maximum then maximum = entity.attractRadius end
            end
        end
        boost[key] = maximum
    end
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

-- Use the live authorization wedge, never debug/reveal visibility.
function World:IsEntityInScope(entity)
    if self.retired or self.scopeEnabled ~= true then return false end
    if type(entity) ~= "table" or entity.id == nil
        or self:get(entity.id) ~= entity or entity.removed or entity.alive == false then
        return nil, "content_unavailable"
    end
    return isInsideScope(self.scopeShip, entity)
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
