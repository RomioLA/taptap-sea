-- Standalone Sea Runtime. No PlayerState, item database, inventory or day clock dependency.
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local M = require("Ocean.Math")
local World = require("Ocean.World")
local Movement = require("Ocean.Movement")
local AutoNavigation = require("Ocean.AutoNavigation")
local Fish = require("Ocean.Fish")
local DefaultStrategy = require("Ocean.SpawnStrategy")
local EntityStateSystem = require("Systems.EntityStateSystem")
local TraceSystem = require("Systems.TraceSystem")
local SurfaceSignals = require("Ocean.SurfaceSignals")
local Presentation = require("Ocean.SeaPresentation")
local Runtime = {}
Runtime.__index = Runtime

function Runtime.New(options)
    local self = setmetatable({}, Runtime)
    self:Init(options or {})
    return self
end

function Runtime:Init(options)
    if self.autoNavigation then
        self.autoNavigation:Cancel("runtime_reset")
        self.autoNavigation = nil
    end
    if self.world then self.world:Retire() end
    self.fishingGeneration = (self.fishingGeneration or 0) + 1
    self.world = World.New()
    self.world:AddSystem(EntityStateSystem)
    self.surfaceSignals = SurfaceSignals.New(self.world)
    self.world.surfaceSignals = self.surfaceSignals
    self.world:AddSystem(self.surfaceSignals)
    self.ship = self.world:spawn({ entityType = "ship", kind = "dynamic", layer = "surface",
        position = options.departure or Config.ship.start, radius = Config.ship.radius })
    -- The persistent underwater sector follows the live ship transform. Keep it
    -- separate from timed circular reveals and start it disabled on every reset.
    self.world.scopeShip = self.ship
    self.world.scopeEnabled = false
    self.traceSystem = TraceSystem.New(self.world)
    self.world:AddSystem(self.traceSystem)
    assert(self.world:isPositionFree(self.ship.position, self.ship.radius), "invalid ship departure")
    self.movement = Movement.New(self.world, self.ship)
    if options.shipLevel ~= nil then self:SetShipLevel(options.shipLevel) end
    local navWorld, navShip, navMovement = self.world, self.ship, self.movement
    local adapter = {
        getPosition = function()
            return M.copy(navShip.position)
        end,
        getBlockers = function()
            local blockers = {}
            for _, entity in pairs(navWorld.entities) do
                if entity and not entity.removed and entity.blocking == true then
                    blockers[#blockers + 1] = {
                        id = tostring(entity.id),
                        position = M.copy(entity.position),
                        radius = entity.radius,
                        blocking = true,
                    }
                end
            end
            return blockers
        end,
        getTarget = function()
            return navMovement.target
        end,
        ---@param point OceanPoint?
        setTarget = function(point)
            if point == nil then
                -- AutoNavigation clears only after its target identity check.
                navMovement:Stop()
            else
                navMovement:SetTarget(point)
            end
            return navMovement.target
        end,
        isValid = function()
            return not navWorld.retired
                and navWorld:get(navShip.id) == navShip
                and navShip.alive and not navShip.removed
                and navMovement.ship == navShip
        end,
        shipRadius = navShip.radius,
        halfSize = Config.world.halfSize,
        diagnostic = options.autoReturnDiagnostic,
    }
    ---@type OceanAutoNavigation
    self.autoNavigation = AutoNavigation.New(adapter)
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

-- deferActivity=true 时跳过逐鱼活跃度刷新，由调用方在批量生成结束后
-- 统一调一次 updateActivity——逐鱼刷新是 O(N²)（新区域移动卡顿根因）。
function Runtime:spawnFish(species, position, rotation, deferActivity)
    local data = assert(FishData[species], "unsupported fish species")
    assert(self.world:isPositionFree(position, data.radius), "fish spawn must be in free sea")
    self.spawnSequence = self.spawnSequence+1
    local entity = self.world:spawn({ entityType = "fish", kind = "dynamic", layer = "underwater",
        species = species, ordinaryFish = true, position = position, rotation = rotation or 0,
        radius = data.radius, state = "Wander", active = false, frozen = true })
    self.behaviors[entity.id] = Fish.New(self.world, entity, data, M.rng(self.daySeed+self.spawnSequence))
    if not deferActivity then self.world:updateActivity(self.ship.position) end
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
                    self:spawnFish(placement.species, placement.position, placement.rotation, true)
                end
                self.initializedRegions[key] = true
                -- 区域批量生成后统一刷新一次活跃度（spawnFish 已逐条 defer）。
                self.world:updateActivity(self.ship.position)
            end
        end
    end
end

function Runtime:clearOrdinaryFish()
    self.fishingGeneration = self.fishingGeneration + 1
    self.world:clearOrdinaryFish()
    self.surfaceSignals:Clear()
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

-- Public boundary for orchestration layers; position reads never expose mutable sea state.
---@return OceanPoint
function Runtime:GetShipPosition()
    return M.copy(self.ship.position)
end

-- Config.ship.start is the authored harbor anchor. `departure` may seed a
-- particular run or day and must never redefine this port.
---@return OceanPoint
function Runtime:GetPortPosition()
    return M.copy(Config.ship.start)
end

---Fresh commuter trace snapshot; returns nil when the trace runtime is unavailable.
---@param traceId string
---@return table?, string?
function Runtime:GetTrace(traceId)
    if not self.traceSystem or type(self.traceSystem.Query) ~= "function" then
        return nil, "trace_unavailable"
    end
    return self.traceSystem:Query(traceId)
end

---Build one current-position observation event without mutating the World queue.
---@param traceId string
---@param day integer
---@param alreadyRecognized boolean
---@return table?, string?
function Runtime:BuildTraceObservation(traceId, day, alreadyRecognized)
    if not self.traceSystem or type(self.traceSystem.BuildObservation) ~= "function" then
        return nil, "trace_unavailable"
    end
    return self.traceSystem:BuildObservation(traceId, day, alreadyRecognized)
end

---@param portPosition OceanPoint?
---@return boolean, string?
function Runtime:StartAutoReturn(portPosition)
    if self.paused then return false, "runtime_paused" end
    if portPosition == nil then portPosition = self:GetPortPosition() end
    return self.autoNavigation:Start(portPosition)
end

---@param reason string?
---@return boolean
function Runtime:CancelAutoReturn(reason)
    return self.autoNavigation:Cancel(reason)
end

---@return table
function Runtime:GetAutoReturnState()
    return self.autoNavigation:GetState()
end

---@return table?
function Runtime:ConsumeAutoReturnArrival()
    return self.autoNavigation:ConsumeArrival()
end

---@param reason string
---@return boolean, string?
function Runtime:RejectAutoReturnArrival(reason)
    return self.autoNavigation:RejectArrival(reason)
end

---@return string?
function Runtime:GetAutoReturnFailure()
    return self.autoNavigation:GetFailure()
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isValidPoint(point)
    return type(point) == "table" and isFiniteNumber(point.x) and isFiniteNumber(point.y)
end

---Whether an active surface cue passes the same broad-phase gate as SeaDraw.
---This is draw eligibility, not proof that any cue pixel lands on screen.
---@param kind "bird"|"splash"
---@return boolean
function Runtime:HasSurfaceSignalInView(kind)
    if kind ~= "bird" and kind ~= "splash" then return false end
    local movement, signals = self.movement, self.surfaceSignals
    if not movement or movement.viewportReady ~= true or not signals then return false end

    local found = false
    local function inspect(x, y, length)
        if found then return end
        local point = { x = x, y = y }
        if not isValidPoint(point) then return end
        if type(length) ~= "number" or not isFiniteNumber(length) then length = nil end
        local radius, height = Presentation.SignalBounds(kind, length)
        if type(radius) ~= "number" or type(height) ~= "number" then return end
        local ok, state = pcall(Presentation.State, movement, point, radius, height)
        found = ok and type(state) == "table" and state.alpha > 0
    end

    local visit = signals[kind == "bird" and "VisitBirds" or "VisitSplashes"]
    if type(visit) == "function" then
        local ok = pcall(function()
            if kind == "bird" then
                visit(signals, function(x, y) inspect(x, y) end)
            else
                visit(signals, function(x, y, remaining, lifetime, heading, length)
                    inspect(x, y, length)
                end)
            end
        end)
        return ok and found
    end

    -- Compatibility for light test doubles and older signal providers.
    local get = signals[kind == "bird" and "GetBirds" or "GetSplashes"]
    if type(get) ~= "function" then return false end
    local ok, cues = pcall(get, signals)
    if not ok or type(cues) ~= "table" then return false end
    for _, cue in ipairs(cues) do
        if type(cue) == "table" and type(cue.position) == "table" then
            inspect(cue.position.x, cue.position.y, cue.trailLength)
        end
    end
    return found
end

-- Validate the authored anchor before delegating occupancy to the world's
-- public predicate. The runtime-owned ship is nonblocking, so it does not
-- obstruct its own reset; custom world predicates remain authoritative.
local function isPortFreeForShip(world, ship, position)
    local radius = ship and ship.radius
    if not isValidPoint(position) or not isFiniteNumber(radius) or radius < 0 then
        return false, "invalid_port_position"
    end
    local bound = Config.world.halfSize - radius
    if not isFiniteNumber(bound) or bound < 0
        or math.abs(position.x) > bound or math.abs(position.y) > bound then
        return false, "port_out_of_bounds"
    end
    if type(world.isPositionFree) ~= "function" then return false, "port_unavailable" end
    if not world:isPositionFree(position, radius) then return false, "port_blocked" end
    return true
end

-- Return the existing ship to the fixed authored harbor without rebuilding
-- Ocean.World or changing any day, player, fish, signal, or barrel state.
---@return boolean, string?
function Runtime:ResetShipAtPort()
    local world, ship, movement = self.world, self.ship, self.movement
    if not world or not ship or not movement or movement.ship ~= ship
        or world:get(ship.id) ~= ship or ship.removed or not ship.alive then
        return false, "ship_unavailable"
    end
    local port = self:GetPortPosition()
    local free, reason = isPortFreeForShip(world, ship, port)
    if not free then return false, reason end
    self.autoNavigation:Cancel("port_reset")
    movement:ResetAtPosition(port)
    return true
end

---@class OceanFixedBarrelSnapshot
---@field id string
---@field contentId string
---@field generation integer
---@field position OceanPoint

-- Fresh proxies prevent ordinary writes at both levels. Their backing tables
-- contain copied values only, never a world entity or its position table.
local function readOnlySnapshot(values)
    return setmetatable({}, {
        __index = values,
        __newindex = function() error("Ocean snapshot is read-only", 2) end,
        __pairs = function() return next, values, nil end,
        __metatable = false,
    })
end

local function validBarrelPoint(point)
    return type(point) == "table" and type(point.x) == "number" and type(point.y) == "number"
        and point.x == point.x and point.y == point.y
        and math.abs(point.x) < math.huge and math.abs(point.y) < math.huge
end

-- Match the exact registered object. Never search for a nearest float or
-- silently substitute another entity with the same content label/ID.
---@param world SeaWorld
---@return SeaEntity?
local function currentFixedBarrel(world)
    local barrel = world.fixedBarrel
    if not barrel or world:get(barrel.id) ~= barrel or barrel.removed or not barrel.alive
        or barrel.contentId ~= "driftwood_barrel" or not validBarrelPoint(barrel.position) then
        return nil
    end
    return barrel
end

---@return OceanFixedBarrelSnapshot?
function Runtime:GetFixedBarrel()
    local barrel = currentFixedBarrel(self.world)
    if not barrel then return nil end
    return readOnlySnapshot({ id = barrel.id, contentId = "driftwood_barrel",
        generation = self.world.fixedBarrelGeneration,
        position = readOnlySnapshot(M.copy(barrel.position)) })
end

local function currentFixedContent(world, contentId)
    if type(contentId) ~= "string" or not world or world.retired
        or type(world.fixedContentEntities) ~= "table" then return nil end
    local entity = world.fixedContentEntities[contentId]
    if not entity or type(world.get) ~= "function" or world:get(entity.id) ~= entity
        or entity.removed or entity.alive == false or entity.kind ~= "fixed"
        or entity.contentId ~= contentId or not validBarrelPoint(entity.position)
        or not isFiniteNumber(entity.radius) or entity.radius < 0 then
        return nil
    end
    return entity
end

---The identity changes only when a new fixed Ocean World is created.
---@return integer?
function Runtime:GetFixedContentGeneration()
    if not self.world or self.world.retired then return nil end
    local generation = self.world and self.world.fixedContentGeneration
    if type(generation) ~= "number" or generation < 1 or generation ~= math.floor(generation) then return nil end
    return generation
end

---Fresh immutable value snapshot; no entity or mutable position table escapes.
---@param contentId string
---@return table?
function Runtime:GetWorldContent(contentId)
    local entity = currentFixedContent(self.world, contentId)
    if not entity then return nil end
    return readOnlySnapshot({ id = entity.id, entityId = entity.id, contentId = contentId,
        generation = self.world.fixedContentGeneration, entityType = entity.entityType,
        layer = entity.layer, position = readOnlySnapshot(M.copy(entity.position)),
        radius = entity.radius, blocking = entity.blocking == true,
        ordinaryFish = entity.ordinaryFish == true })
end

---Register authored fixed content with this World and return its immutable snapshot.
---@param definition table
---@return table?, string?
function Runtime:RegisterWorldContent(definition)
    if not self.world or self.world.retired or type(self.world.RegisterFixedContent) ~= "function" then
        return nil, "content_unavailable"
    end
    local entity, reason = self.world:RegisterFixedContent(definition)
    if not entity then return nil, reason end
    return self:GetWorldContent(entity.contentId)
end

---Return fixed island and treasure snapshots in stable content-ID order.
---@return table
function Runtime:GetFixedWorldContentSnapshots()
    local snapshots = {}
    for _, contentId in ipairs(self.world and self.world.fixedContentIds or {}) do
        local snapshot = self:GetWorldContent(contentId)
        if snapshot then snapshots[#snapshots + 1] = snapshot end
    end
    return snapshots
end

---Ocean owns all geometry; edgeDistance is to the content edge and
---surfaceGap also accounts for the ship collision radius.
---@param contentId string
---@return table?, string?
function Runtime:GetWorldContentAccess(contentId)
    local entity = currentFixedContent(self.world, contentId)
    if not entity then return nil, "content_unavailable" end
    local ship = self.ship
    if not ship or self.world:get(ship.id) ~= ship or ship.removed or ship.alive == false
        or not validBarrelPoint(ship.position) or not isFiniteNumber(ship.radius) or ship.radius < 0 then
        return nil, "ship_unavailable"
    end
    local dx, dy = entity.position.x - ship.position.x, entity.position.y - ship.position.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if not isFiniteNumber(distance) then return nil, "invalid_content_distance" end
    local edgeDistance = math.max(0, distance - entity.radius)
    local surfaceGap = math.max(0, edgeDistance - ship.radius)
    return readOnlySnapshot({ exists = true, contentId = contentId, entityId = entity.id,
        generation = self.world.fixedContentGeneration, distance = distance,
        edgeDistance = edgeDistance, surfaceGap = surfaceGap })
end

---Use only the real scope-enabled wedge; reveal/debug visibility grants no access.
---@param contentId string
---@return boolean?, string?
function Runtime:IsWorldContentInScope(contentId)
    local entity = currentFixedContent(self.world, contentId)
    if not entity then return nil, "content_unavailable" end
    if entity.layer ~= "underwater" then return nil, "scope_not_applicable" end
    if not self.world or type(self.world.IsEntityInScope) ~= "function" then
        return nil, "scope_unavailable"
    end
    return self.world:IsEntityInScope(entity)
end

---木桶操作半径（新手教程点位按钮显隐用），权威值仍在 Config.interaction。
function Runtime:GetBarrelOperateDistance()
    return Config.interaction.operateDistance
end

---@param id string
---@param generation integer
---@return boolean, string?
function Runtime:CanInteractWithBarrel(id, generation)
    if generation ~= self.world.fixedBarrelGeneration then return false, "barrel_generation_mismatch" end
    local barrel = currentFixedBarrel(self.world)
    if not barrel then return false, "barrel_unavailable" end
    if id ~= barrel.id then return false, "barrel_identity_mismatch" end
    if not validBarrelPoint(self.ship.position) then return false, "invalid_ship_position" end
    --      boat center o -------- <= operateDistance (existing 5m) -------- O barrel
    -- Spatial eligibility only: no progress, payment, rewards, action or pause policy.
    if M.distanceSquared(self.ship.position, barrel.position) > Config.interaction.operateDistance^2 then
        return false, "barrel_out_of_range"
    end
    return true
end

function Runtime:IsPositionFree(position, radius)
    return self.world:isPositionFree(position, radius or 0)
end

function Runtime:ClearMovementTarget()
    self.autoNavigation:Cancel("movement_cleared")
    self.movement:SetTarget(nil)
end

function Runtime:RejectDroppedItem(id)
    local entity = self.world:get(id)
    if not entity or entity.kind ~= "temporary" then return false end
    local removed = self.world:remove(id, "drop_rejected")
    self.world:compact()
    return removed
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
        if entity.entityType == "fish" and FishData[entity.species] and entity.alive
            and not entity.captureLocked then
            local candidateDistance = M.distanceSquared(center, entity.position)
            if candidateDistance < distance then
                nearest, distance = entity, candidateDistance
            end
        end
    end
    return nearest
end

function Runtime:SnapshotFishingTarget(target)
    local world, runtime = self.world, self
    ---@type integer|nil
    local index
    for candidateIndex, entity in ipairs(world.entities) do
        if entity == target then index = candidateIndex; break end
    end
    return {
        world = world,
        generation = self.fishingGeneration,
        target = target,
        index = index,
        removed = target.removed,
        alive = target.alive,
        active = target.active,
        frozen = target.frozen,
        state = target.state,
        removeReason = target.removeReason,
        captureLocked = target.captureLocked,
        captureOwnerToken = target.captureOwnerToken,
        overlap = world.overlaps and world.overlaps[target.id],
        behavior = runtime.behaviors and runtime.behaviors[target.id],
    }
end

function Runtime:RestoreFishingTarget(target, snapshot)
    local world, runtime = self.world, self
    -- A rollback cannot resurrect an old-world fish or overwrite a reused ID.
    if snapshot.world ~= world or snapshot.generation ~= self.fishingGeneration
        or snapshot.target ~= target then return false end
    local current = world:get(target.id)
    if current and current ~= target then return false end
    if current and current.captureLocked and not rawequal(current.captureOwnerToken, snapshot.captureOwnerToken) then
        return false
    end
    target.removed = snapshot.removed
    target.alive = snapshot.alive
    target.active = snapshot.active
    target.frozen = snapshot.frozen
    target.state = snapshot.state
    target.removeReason = snapshot.removeReason
    target.captureLocked = snapshot.captureLocked
    target.captureOwnerToken = snapshot.captureOwnerToken
    world.byId[target.id] = target
    local present = false
    for _, entity in ipairs(world.entities) do
        if entity == target then present = true; break end
    end
    if not present then
        table.insert(world.entities, math.min(snapshot.index or (#world.entities + 1), #world.entities + 1), target)
    end
    if world.overlaps then world.overlaps[target.id] = snapshot.overlap end
    if runtime.behaviors then runtime.behaviors[target.id] = snapshot.behavior end
    if target.captureLocked then self.surfaceSignals:OnCaptureLocked(target.id) end
    return true
end

function Runtime:GetFishingTarget(id)
    return self.world:get(id)
end

function Runtime:GetFishingGeneration()
    return self.fishingGeneration
end

function Runtime:LockFishingTarget(id, ownerToken)
    if type(ownerToken) ~= "table" then return false, "invalid_capture_owner" end
    local target = self.world:get(id)
    if not target or not target.alive or target.removed or target.entityType ~= "fish"
        or not FishData[target.species] then return false, "fishing_target_expired" end
    if target.captureLocked and not rawequal(target.captureOwnerToken, ownerToken) then
        return false, "fishing_target_locked"
    end
    target.captureLocked, target.captureOwnerToken = true, ownerToken
    self.surfaceSignals:OnCaptureLocked(id)
    return true
end

function Runtime:UnlockFishingTarget(id, ownerToken)
    if type(ownerToken) ~= "table" then return false, "invalid_capture_owner" end
    local target = self.world:get(id)
    if not target or not target.captureLocked then return true end
    if not rawequal(target.captureOwnerToken, ownerToken) then return false, "capture_owner_mismatch" end
    target.captureLocked, target.captureOwnerToken = false, nil
    return true
end

function Runtime:RemoveFishingTarget(id, ownerToken)
    local target = self.world:get(id)
    -- Supplying an owner always requires an exact match, even for an unlocked
    -- replacement ID. Legacy single-argument removal remains valid when unlocked.
    if target and ((target.captureLocked and not rawequal(target.captureOwnerToken, ownerToken))
        or (ownerToken ~= nil and not rawequal(target.captureOwnerToken, ownerToken))) then
        return false, "capture_owner_mismatch"
    end
    return self.world:remove(id, "caught", ownerToken)
end

function Runtime:ForgetFishingBehavior(id)
    self.behaviors[id] = nil
end

function Runtime:revealWithScope(center, durationSec)
    -- Legacy callers get the original timed circular reveal behavior.
    return self.world:revealUnderwater(center, Config.interaction.revealRadius, durationSec)
end

-- Persistent underwater visibility only. This never pauses or advances the sea.
function Runtime:SetScopeEnabled(enabled)
    -- Fail closed for malformed inputs; only an explicit boolean true enables it.
    self.world.scopeEnabled = enabled == true
    return self.world.scopeEnabled
end

function Runtime:IsScopeEnabled()
    return self.world.scopeEnabled == true
end

function Runtime:setDebugFlag(name, value)
    if not self.debug.enabled then return false end
    assert(type(Config.debug[name]) == "boolean" and name ~= "enabled", "unsupported debug flag")
    self.debug[name] = value == true
    if name == "showUnderwater" then self.world.showUnderwater = self.debug[name] end
    return true
end

function Runtime:TogglePause()
    self.paused = not self.paused
    if self.paused then self.autoNavigation:Cancel("paused") end
end
function Runtime:Reset()
    local seed, strategy = self.daySeed, self.strategy
    self:Init({ daySeed = seed, strategy = strategy, initializeRegions = self.initializeRegions,
        shipLevel = self.movement.level })
end

function Runtime:Update(dt, axisX, axisY)
    if self.paused then
        self.autoNavigation:Cancel("paused")
        return
    end
    local inputX, inputY = axisX or 0, axisY or 0
    local hasManualInput = math.sqrt(inputX * inputX + inputY * inputY) > Config.world.epsilon
    if hasManualInput then self.autoNavigation:Cancel("manual_input") end
    local remaining = M.clamp(dt, 0, Config.world.maxFrameSec)
    while remaining > Config.world.epsilon do
        local step = math.min(remaining, Config.world.maxStepSec)
        self.time = self.time+step
        self.movement:Update(step, inputX, inputY)
        self.autoNavigation:Update(step)
        if self.initializeRegions then self:ensureNearbyRegions() end
        self.world:updateActivity(self.ship.position)
        self.world:updateLifecycle(step, self.ship)
        self.world:Update(step)
        for id in pairs(self.behaviors) do
            if not self.world:get(id) then self.behaviors[id] = nil end
        end
        self.world:compact()
        remaining = remaining-step
    end
end
return Runtime
