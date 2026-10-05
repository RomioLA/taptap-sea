-- Circle 1B protocol tests. Require this module freely; Run() is explicit.
local GameplayConfig = require("config.gameplay")
local OceanConfig = require("Ocean.Config")
local GameWorld = require("Game.World")
local Bridge = require("Integration.Bridge")
local Progress = require("Gameplay.Circle1B2Progress")

local Tests = {}
local Runtime = {}
Runtime.__index = Runtime

local function copyPoint(point)
    return { x = point.x, y = point.y }
end

local function copyArray(values)
    local result = {}
    for index, value in ipairs(values or {}) do result[index] = value end
    return result
end

local function makeWorld(runtime)
    local world = GameWorld.New({ idPrefix = runtime.idPrefix })
    local update = world.Update
    world.frameUpdateCount = 0
    world.Update = function(self, dt, cadence)
        if cadence == "frame" then
            self.frameUpdateCount = self.frameUpdateCount + 1
            runtime.currentFrameSea = 0
        end
        local packed = table.pack(update(self, dt, cadence))
        if cadence == "frame" then
            runtime.frameSeaTotals[#runtime.frameSeaTotals + 1] = runtime.currentFrameSea
        end
        return table.unpack(packed, 1, packed.n)
    end
    return world
end

function Runtime.New(settings)
    settings = settings or {}
    local runtime = setmetatable({
        idPrefix = settings.idPrefix or "fish-",
        ship = { id = "ship-1", position = copyPoint(settings.shipPosition or { x = 0, y = 0 }), level = 1 },
        paused = true,
        generation = 1,
        time = 0,
        oceanTime = 0,
        currentFrameSea = 0,
        frameSeaTotals = {},
        updateCalls = {},
        selectCalls = 0,
        lockCalls = 0,
        unlockCalls = 0,
        removeCalls = 0,
        forgetCalls = 0,
        clearMovementCalls = 0,
        refreshCalls = 0,
        droppedItems = {},
        behaviors = {},
        faults = {},
        settings = settings,
        refreshSpawn = settings.refreshSpawn,
        movementTarget = settings.movementTarget and copyPoint(settings.movementTarget) or nil,
    }, Runtime)
    runtime.world = makeWorld(runtime)
    for name, fault in pairs(settings.faults or {}) do
        if type(fault) == "table" then
            runtime:SetFault(name, fault.mode, fault.times)
        else
            runtime:SetFault(name, fault, 1)
        end
    end
    return runtime
end

function Runtime:SetFault(name, mode, times)
    self.faults[name] = { mode = mode, remaining = times or 1 }
end

function Runtime:TakeFault(name)
    local fault = self.faults[name]
    if not fault or fault.remaining <= 0 then return nil end
    fault.remaining = fault.remaining - 1
    return fault.mode
end

function Runtime:spawnFish(species, position, options)
    options = options or {}
    local fish = self.world:CreateEntity("fish", {
        entityType = "fish",
        species = species,
        position = copyPoint(position),
        velocity = copyPoint(options.velocity or { x = 0, y = 0 }),
        state = options.state or "Swim",
        active = options.active ~= false,
        frozen = options.frozen == true,
        hidden = options.hidden == true,
    })
    self.behaviors[fish.id] = { updates = 0 }
    return fish
end

function Runtime:GetShipPosition()
    return copyPoint(self.ship.position)
end

-- B3 A spatial protocol double. Kept entirely in the player test fixture.
function Runtime:GetPortPosition()
    return copyPoint(OceanConfig.ship.start)
end

function Runtime:ResetShipAtPort()
    self.ship.position = self:GetPortPosition()
    self:ClearMovementTarget()
    return true
end

function Runtime:SetShipLevel(level)
    self.ship.level = level
    return true
end

function Runtime:ClearMovementTarget()
    self.clearMovementCalls = self.clearMovementCalls + 1
    self.movementTarget = nil
    return true
end

function Runtime:canCastNet(center)
    if type(center) ~= "table" or type(center.x) ~= "number" or type(center.y) ~= "number" then
        return false
    end
    local dx, dy = center.x - self.ship.position.x, center.y - self.ship.position.y
    return dx * dx + dy * dy <= OceanConfig.fishing.maxCastDistance ^ 2
end

function Runtime:GetFishingGeneration()
    return self.generation
end

function Runtime:selectFishingTarget(center, radius, filter)
    self.selectCalls = self.selectCalls + 1
    if self.onSelect then self.onSelect(center) end
    local fault = self:TakeFault("select")
    if fault == "throw" then error("injected select failure") end
    if fault == "empty" then return nil end
    radius = radius or OceanConfig.fishing.netRadius
    local best, bestDistance
    for _, entity in ipairs(self.world:GetEntities()) do
        if entity.entityType == "fish" and entity.kind == "fish" and entity.alive
            and not entity.removed and not entity.captureLocked
            and (type(filter) ~= "function" or filter(entity)) then
            local dx, dy = entity.position.x - center.x, entity.position.y - center.y
            local distance = dx * dx + dy * dy
            if distance <= radius * radius and (bestDistance == nil or distance < bestDistance) then
                best, bestDistance = entity, distance
            end
        end
    end
    return best
end

function Runtime:GetFishingTarget(id)
    local target = self.world:GetEntity(id)
    if target and target.entityType == "fish" and target.kind == "fish" then return target end
    return nil
end

function Runtime:LockFishingTarget(id, ownerToken)
    self.lockCalls = self.lockCalls + 1
    if type(ownerToken) ~= "table" then return false, "invalid_capture_owner" end
    local fault = self:TakeFault("lock")
    if fault == "false" then return false, "injected_lock_failure" end
    if fault == "throw" then error("injected lock failure") end
    local target = self:GetFishingTarget(id)
    if not target or not target.alive or target.removed then return false, "fishing_target_expired" end
    if target.captureLocked and target.captureOwner ~= ownerToken then
        return false, "fishing_target_locked"
    end
    target.captureLocked, target.captureOwner = true, ownerToken
    target.functionalSeagull = false
    return true
end

function Runtime:UnlockFishingTarget(id, ownerToken)
    self.unlockCalls = self.unlockCalls + 1
    if type(ownerToken) ~= "table" then return false, "invalid_capture_owner" end
    local fault = self:TakeFault("unlock")
    if fault == "false" then return false, "injected_unlock_failure" end
    if fault == "throw" then error("injected unlock failure") end
    local target = self:GetFishingTarget(id)
    if not target or not target.captureLocked then return true end
    if target.captureOwner ~= ownerToken then return false, "capture_owner_mismatch" end
    target.captureLocked, target.captureOwner = false, nil
    return true
end

function Runtime:SnapshotFishingTarget(target)
    local fault = self:TakeFault("snapshot")
    if fault == "throw" then error("injected snapshot failure") end
    if fault == "false" then return false, "injected_snapshot_failure" end
    local behavior = self.behaviors[target.id]
    return {
        position = copyPoint(target.position),
        velocity = copyPoint(target.velocity),
        state = target.state,
        active = target.active,
        frozen = target.frozen,
        hidden = target.hidden,
        alive = target.alive,
        removed = target.removed,
        captureLocked = target.captureLocked,
        captureOwner = target.captureOwner,
        functionalSeagull = target.functionalSeagull,
        behaviorUpdates = behavior and behavior.updates or 0,
    }
end

function Runtime:RestoreFishingTarget(target, snapshot)
    local fault = self:TakeFault("restore")
    if fault == "false" then return false, "injected_restore_failure" end
    if fault == "throw" then error("injected restore failure") end
    local current = self.world:GetEntity(target.id)
    if current and current ~= target then return false, "fishing_target_id_reused" end
    if not current then
        self.world.entities[#self.world.entities + 1] = target
        self.world.byId[target.id] = target
    end
    target.position = copyPoint(snapshot.position)
    target.velocity = copyPoint(snapshot.velocity)
    target.state, target.active, target.frozen, target.hidden =
        snapshot.state, snapshot.active, snapshot.frozen, snapshot.hidden
    target.alive, target.removed = snapshot.alive, snapshot.removed
    target.captureLocked, target.captureOwner = snapshot.captureLocked, snapshot.captureOwner
    target.functionalSeagull = snapshot.functionalSeagull
    self.behaviors[target.id] = { updates = snapshot.behaviorUpdates }
    return true
end

function Runtime:RemoveFishingTarget(id, ownerToken)
    self.removeCalls = self.removeCalls + 1
    local fault = self:TakeFault("remove")
    if fault == "throw" then error("injected remove failure") end
    if fault == "false" then return false, "injected_remove_failure" end
    local target = self:GetFishingTarget(id)
    if not target then return false, "fishing_target_expired" end
    if target.captureLocked and target.captureOwner ~= ownerToken then
        return false, "capture_owner_mismatch"
    end
    if target.captureLocked and type(ownerToken) ~= "table" then
        return false, "capture_owner_mismatch"
    end
    local removed = self.world:RemoveEntity(id, "caught")
    if not removed then return false, "fishing_target_expired" end
    target.captureLocked, target.captureOwner = false, nil
    if fault == "throw_after" then error("injected post-remove failure") end
    return true
end

function Runtime:ForgetFishingBehavior(id)
    self.forgetCalls = self.forgetCalls + 1
    self.behaviors[id] = nil
    return true
end

function Runtime:Update(dt, axisX, axisY)
    axisX, axisY = axisX or 0, axisY or 0
    self.updateCalls[#self.updateCalls + 1] = { dt = dt, axisX = axisX, axisY = axisY, paused = self.paused }
    if self.paused then return false end
    self.time = self.time + dt
    self.oceanTime = self.oceanTime + dt
    self.currentFrameSea = self.currentFrameSea + dt
    if axisX ~= 0 or axisY ~= 0 then
        local speed = OceanConfig.ship.speedByLevel[self.ship.level] or OceanConfig.ship.speedByLevel[1]
        self.ship.position.x = self.ship.position.x + axisX * speed * dt
        self.ship.position.y = self.ship.position.y + axisY * speed * dt
    end
    for _, fish in ipairs(self.world:GetEntities()) do
        if fish.entityType == "fish" and not fish.captureLocked and not fish.frozen then
            local behavior = self.behaviors[fish.id]
            if behavior then behavior.updates = behavior.updates + 1 end
            fish.position = {
                x = fish.position.x + fish.velocity.x * dt,
                y = fish.position.y + fish.velocity.y * dt,
            }
        end
    end
    return true
end

function Runtime:refreshOrdinaryFish(seed, departure)
    self.refreshCalls = self.refreshCalls + 1
    self.refreshSeed = seed
    self.generation = self.generation + 1
    self.world = makeWorld(self)
    self.behaviors = {}
    self.ship.position = copyPoint(departure)
    local spawns = self.refreshSpawn
    if spawns then
        if spawns.species then spawns = { spawns } end
        for _, spawn in ipairs(spawns) do self:spawnFish(spawn.species, spawn.position, spawn.options) end
    end
    return true
end

function Runtime:IsPositionFree(position)
    if self.settings.positionFree == false then return false end
    return type(position) == "table" and type(position.x) == "number" and type(position.y) == "number"
end

function Runtime:spawnDroppedItem(payload, position)
    local entity = self.world:CreateEntity("droppedItem", {
        entityType = "droppedItem",
        itemId = payload.itemId,
        position = copyPoint(position),
        age = 0,
        lifetimeSec = payload.lifetimeSec,
        category = payload.category,
        worldEffect = payload.worldEffect,
    })
    self.droppedItems[#self.droppedItems + 1] = entity
    return entity
end

function Runtime:RejectDroppedItem(id)
    return self.world:RemoveEntity(id, "rejected")
end

local function makeStore()
    local store = { writes = 0, data = nil }
    function store:Save(snapshot, done)
        self.writes = self.writes + 1
        self.data = snapshot
        if done then done(true) end
    end
    function store:Load(done) if done then done(true, self.data) end end
    return store
end

function Tests.Fixture(settings)
    settings = settings or {}
    local runtime = Runtime.New(settings)
    local store = settings.store or makeStore()
    local bridge = Bridge.New(runtime, { store = store, loadSaved = false, dropReceiver = settings.dropReceiver })
    local items = settings.items or settings.initialItems
    if items then assert(bridge.loop.player.inventory:RestoreItems(copyArray(items))) end
    return { runtime = runtime, bridge = bridge, loop = bridge.loop, store = store }
end

local function assertEqual(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assertNear(actual, expected, epsilon, label)
    assert(type(actual) == "number" and math.abs(actual - expected) <= (epsilon or 1e-8),
        (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assertItems(actual, expected, label)
    assertEqual(#actual, #expected, (label or "items") .. " count")
    for index, item in ipairs(expected) do assertEqual(actual[index], item, (label or "items") .. "[" .. index .. "]") end
end

Tests.AssertEqual = assertEqual
Tests.AssertNear = assertNear
Tests.AssertItems = assertItems
Tests.ProtocolRuntime = Runtime

local function atSea(settings)
    local fixture = Tests.Fixture(settings)
    assert(fixture.loop:Depart())
    return fixture
end

local function setFault(fixture, name, mode, times)
    fixture.runtime:SetFault(name, mode, times)
end

local function assertFrameSeaBound(runtime)
    for _, total in ipairs(runtime.frameSeaTotals) do
        assert(total <= OceanConfig.world.maxFrameSec + 1e-8,
            "one gameplay frame exceeded Ocean's maxFrameSec: " .. tostring(total))
    end
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("confirmation does not select or charge and early completion is rejected", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("tuna", { x = 1, y = 0 })
        local before = f.loop.player.inventory:GetItems()
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        assert(type(token) == "table")
        assertEqual(f.runtime.selectCalls, 0)
        assertEqual(f.loop:GetFishingState().state, "casting")
        assertEqual(f.loop.player.stamina, 100)
        assertItems(f.loop.player.inventory:GetItems(), before)
        local completed, reason = f.bridge:CompleteFishing(token)
        assertEqual(completed, false); assertEqual(reason, "fishing_not_finished")
        assert(not fish.captureLocked and not fish.removed)
    end)

    test("the 0.5 second landing selects the then-nearest fish and locks once", function()
        local f = atSea()
        local earlier = f.runtime:spawnFish("tuna", { x = 1, y = 0 }, { hidden = true, frozen = true })
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.49, 1, 1)
        assertEqual(f.runtime.selectCalls, 0)
        assertEqual(f.loop:GetFishingState().state, "casting")
        earlier.position = { x = 9, y = 0 }
        local nearest = f.runtime:spawnFish("sardine", { x = 2, y = 0 }, { hidden = true, frozen = true })
        f.bridge:Update(0.01, 1, 1)
        assertEqual(f.runtime.selectCalls, 1)
        assert(nearest.captureLocked and not earlier.captureLocked,
            "landing should select the nearest eligible fish at the boundary")
        assertEqual(f.loop:GetFishingState().state, "landed")
        assert(f.bridge:CompleteFishing(token) == false)
    end)

    test("the locked result stays fixed through four seconds and a replay cannot charge twice", function()
        local f = atSea()
        local first = f.runtime:spawnFish("tuna", { x = 1, y = 0 }, { velocity = { x = 1, y = 0 } })
        local later = f.runtime:spawnFish("sardine", { x = 2, y = 0 })
        local beforeItems = f.loop.player.inventory:GetItems()
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assert(first.captureLocked and not later.captureLocked)
        local lockedPosition = copyPoint(first.position)
        f.runtime:spawnFish("sardine", { x = 0.1, y = 0 })
        f.bridge:Update(3.499)
        assertEqual(f.runtime.selectCalls, 1)
        assertNear(first.position.x, lockedPosition.x, 1e-8, "locked fish position")
        assertEqual(f.loop.player.stamina, 100)
        assertItems(f.loop.player.inventory:GetItems(), beforeItems)
        f.bridge:Update(0.001)
        assertEqual(f.loop.player.stamina, 60)
        assert(first.removed and f.runtime:GetFishingTarget(first.id) == nil)
        assert(not later.removed)
        assertEqual(#f.loop.player.inventory:GetItems(), #beforeItems + 1)
        local replay, outcome, itemId = f.bridge:CompleteFishing(token)
        assert(replay and outcome == "caught" and itemId == "tuna")
        assertEqual(f.loop.player.stamina, 60)
        assertEqual(#f.loop.player.inventory:GetItems(), #beforeItems + 1)
    end)

    test("empty water completes for free", function()
        local f = atSea()
        local before = f.loop.player.inventory:GetItems()
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assertEqual(f.runtime.selectCalls, 1)
        assertEqual(f.runtime.lockCalls, 0)
        f.bridge:Update(3.5)
        local ok, outcome = f.bridge:CompleteFishing(token)
        assert(ok and outcome == "empty")
        assertEqual(f.loop.player.stamina, 100)
        assertItems(f.loop.player.inventory:GetItems(), before)
    end)

    test("cancel before or after landing is free and releases the owned lock", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("sardine", { x = 1, y = 0 })
        local before = f.loop.player.inventory:GetItems()
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        assert(f.bridge:CancelFishing(token))
        assert(not fish.captureLocked and not fish.removed)
        assertEqual(f.loop.player.stamina, 100)
        assertItems(f.loop.player.inventory:GetItems(), before)
        local token2 = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assert(fish.captureLocked)
        assert(f.loop:CancelFishingAction())
        assert(not fish.captureLocked and not fish.removed)
        assertEqual(f.loop:GetFishingState().state, "cancelled")
        assert(f.bridge:CancelFishing(token2))
        assertEqual(f.loop.player.stamina, 100)
        assertItems(f.loop.player.inventory:GetItems(), before)
    end)

    -- A2（2026-10-05 用户裁决）：动作中再点捕鱼键=取消，免费且解除锁定，可立即重开。
    test("A2 re-tapping the fishing dock button mid-action cancels for free", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("sardine", { x = 1, y = 0 })
        assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.2)
        assertEqual(f.loop:GetFishingState().state, "casting")
        -- 动作中再点捕鱼键 = 取消，而不是再次进入选点。
        assert(f.loop:BeginFishingSelection())
        assertEqual(f.loop:GetFishingState().state, "cancelled")
        assert(not fish.captureLocked and not fish.removed)
        assertEqual(f.loop.player.stamina, 100)
        -- 取消后同一按钮立即可重新开始选点。
        assert(f.loop:BeginFishingSelection())
        assertEqual(f.loop:GetFishingState().state, "selecting")
        assert(f.loop:CancelFishingAction())
    end)

    -- A1（2026-10-05 用户裁决）：白名单制——动作中透镜开关可用，对话/背包仍拒绝。
    test("A1 whitelist: scope toggle stays available and dialogs stay blocked mid-action", function()
        local f = atSea()
        -- 最小透镜接口桩（同 Circle1B2ScopeTests.bindScope 的生产同步契约）。
        local runtime = f.runtime
        runtime.scopeEnabled = false
        function runtime:SetScopeEnabled(enabled) self.scopeEnabled = enabled == true; return self.scopeEnabled end
        function runtime:IsScopeEnabled() return runtime.scopeEnabled end
        assert(Progress.GrantLens(f.loop.player))
        assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.2)
        assertEqual(f.loop:GetFishingState().state, "casting")
        -- 白名单内：透镜开关可用且不暂停世界。
        assert(f.loop:ToggleScope())
        assert(not f.loop.clock:IsPaused())
        assert(f.loop:ToggleScope())
        -- 白名单外：背包与老人对话在动作中仍被拒绝。
        assertEqual(f.loop:SetInventoryOpen(true), false)
        assertEqual(f.loop:SetElderOpen(true), false)
        assert(f.loop:CancelFishingAction())
    end)

    test("lock rejection is a free terminal failure and never selects a replacement", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("tuna", { x = 1, y = 0 })
        f.runtime:spawnFish("sardine", { x = 2, y = 0 })
        setFault(f, "lock", "false")
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assertEqual(f.runtime.selectCalls, 1)
        assertEqual(f.loop:GetFishingState().state, "failed")
        assert(not fish.captureLocked and not fish.removed)
        f.bridge:Update(4)
        local ok, reason = f.bridge:CompleteFishing(token)
        assertEqual(ok, false); assertEqual(reason, "injected_lock_failure")
        assertEqual(f.runtime.selectCalls, 1)
        assertEqual(f.loop.player.stamina, 100)
    end)

    test("39 stamina rejects while 40 starts and a successful catch consumes exactly 40", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("sardine", { x = 1, y = 0 })
        f.loop.player.stamina = 39
        local rejected = f.bridge:BeginFishing({ x = 0, y = 0 })
        assertEqual(rejected, nil)
        assertEqual(f.runtime.selectCalls, 0)
        f.loop.player.stamina = 40
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        assertEqual(f.loop.player.stamina, 40)
        f.bridge:Update(4)
        local ok, outcome = f.bridge:CompleteFishing(token)
        assert(ok and outcome == "caught")
        assertEqual(f.loop.player.stamina, 0)
        assert(fish.removed)
    end)

    test("pause freezes progress and time scale advances action time without scaling sea budget", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("tuna", { x = 1, y = 0 })
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.loop.clock:SetTimeScale(5)
        f.bridge:Update(0.049, 1, 1)
        assertNear(f.loop:GetFishingState().elapsed, 0.245, 1e-8)
        assert(not fish.captureLocked)
        local seaBeforePause = f.runtime.oceanTime
        f.bridge:TogglePause()
        f.bridge:Update(10, 1, 1)
        assertNear(f.loop:GetFishingState().elapsed, 0.245, 1e-8)
        assertNear(f.runtime.oceanTime, seaBeforePause, 1e-8)
        f.bridge:TogglePause()
        f.bridge:Update(0.051, 1, 1)
        assert(fish.captureLocked)
        assertNear(f.loop:GetFishingState().elapsed, 0.5, 1e-8)
        f.bridge:Update(0.7, 1, 1)
        local ok, outcome = f.bridge:CompleteFishing(token)
        assert(ok and outcome == "caught")
        assertEqual(f.loop.player.stamina, 60)
        for _, call in ipairs(f.runtime.updateCalls) do
            assertEqual(call.axisX, 0); assertEqual(call.axisY, 0)
        end
        assertFrameSeaBound(f.runtime)
    end)

    test("large dt uses the real frame World once and clamps aggregate Ocean advancement", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("tuna", { x = 1, y = 0 })
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        local beforeSea = f.runtime.oceanTime
        local beforeFrames = f.runtime.world.frameUpdateCount
        f.bridge:Update(6, 0, 0)
        assertEqual(f.runtime.world.frameUpdateCount - beforeFrames, 1)
        assertEqual(#f.runtime.world.systems, 1)
        assertEqual(f.runtime.world.systemCadences[f.runtime.world.systems[1]], "frame")
        assertNear(f.loop.clock.elapsed, 6, 1e-8)
        assertNear(f.runtime.oceanTime - beforeSea, OceanConfig.world.maxFrameSec, 1e-8)
        assertFrameSeaBound(f.runtime)
        assert(fish.removed and f.loop.player.stamina == 60)
        local ok, outcome = f.bridge:CompleteFishing(token)
        assert(ok and outcome == "caught")
    end)

    test("night exhaustion on the completion boundary cancels first and unlocks for free", function()
        local f = Tests.Fixture()
        f.loop.clock:Seek("night", 56)
        assert(f.loop:Depart())
        local fish = f.runtime:spawnFish("sardine", { x = 1, y = 0 })
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assert(fish.captureLocked)
        f.bridge:Update(3.5)
        assert(f.loop.clock.exhausted and f.loop.forcedReturnPending)
        assertEqual(f.loop:GetFishingState().state, "cancelled")
        assert(not fish.captureLocked and not fish.removed)
        assertEqual(f.loop.player.stamina, 100)
        local ok, reason = f.bridge:CompleteFishing(token)
        assertEqual(ok, false); assertEqual(reason, "night_interrupted")
    end)

    test("forced return waits until night-interrupted fishing cleanup releases its lock", function()
        local f = Tests.Fixture()
        f.loop.clock:Seek("night", 56)
        assert(f.loop:Depart())
        local fish = f.runtime:spawnFish("sardine", { x = 1, y = 0 })
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assert(fish.captureLocked)

        local originalUnlock = f.runtime.UnlockFishingTarget
        local rejectUnlock = true
        local failedUnlockCalls = 0
        f.runtime.UnlockFishingTarget = function(self, id, ownerToken)
            if rejectUnlock then
                failedUnlockCalls = failedUnlockCalls + 1
                return false, "injected_night_unlock_failure"
            end
            return originalUnlock(self, id, ownerToken)
        end

        f.bridge:Update(3.5)
        assert(f.loop.clock.exhausted and f.loop.forcedReturnPending)
        assert(failedUnlockCalls >= 2, "cleanup should remain unacknowledged through repeated unlock attempts")
        assert(f.loop.actions._pendingFishing)
        assertEqual(f.loop.actions._pendingFishing.state, "cleanup_pending")
        assert(fish.captureLocked and not fish.removed)
        assertEqual(f.loop.player.stamina, 100)
        local returned, returnReason = f.loop:ConfirmForcedReturn()
        assertEqual(returned, false); assertEqual(returnReason, "busy")
        assert(f.loop.forcedReturnPending)

        rejectUnlock = false
        f.bridge:Update(0)
        assert(not fish.captureLocked and not fish.removed)
        assertEqual(f.loop.actions._pendingFishing, nil)
        assertEqual(f.loop:GetFishingState().state, "cancelled")
        local completed, reason = f.bridge:CompleteFishing(token)
        assertEqual(completed, false); assertEqual(reason, "night_interrupted")
        assert(f.loop:ConfirmForcedReturn())
    end)

    test("new run clears the old lock before a reused fish ID enters the new generation", function()
        local f = Tests.Fixture({ refreshSpawn = { species = "tuna", position = { x = 1, y = 0 } } })
        assert(f.loop:Depart())
        local oldFish = f.runtime:spawnFish("sardine", { x = 1, y = 0 })
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assert(oldFish.captureLocked)
        assert(f.bridge:NewRun())
        local replacement = assert(f.runtime:GetFishingTarget(oldFish.id))
        assert(replacement ~= oldFish)
        assertEqual(replacement.id, oldFish.id)
        assert(not oldFish.captureLocked and not replacement.captureLocked)
        assertEqual(f.runtime.refreshCalls, 1)
        local ok = f.bridge:CompleteFishing(token)
        assertEqual(ok, false)
        assert(not replacement.removed and not replacement.captureLocked)
    end)

    test("scene stop cancellation clears a landed lock without charging", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("sardine", { x = 1, y = 0 })
        assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assert(fish.captureLocked)
        assert(f.loop:CancelFishingAction())
        assert(not fish.captureLocked and not fish.removed)
        assertEqual(f.loop.player.stamina, 100)
    end)

    test("reentrant fishing during the lock callback cannot create a second transaction", function()
        local f = atSea()
        f.runtime:spawnFish("tuna", { x = 1, y = 0 })
        local nestedToken, nestedReason
        f.runtime.onSelect = function()
            nestedToken, nestedReason = f.bridge:BeginFishing({ x = 0, y = 0 })
        end
        assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assertEqual(nestedToken, nil)
        assertEqual(nestedReason, "fishing_already_pending")
        assertEqual(f.runtime.selectCalls, 1)
        assertEqual(f.loop.player.stamina, 100)
    end)

    test("mutation then throw during removal restores the exact fish, inventory and stamina", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("tuna", { x = 1, y = 0 })
        local items, stamina = f.loop.player.inventory:GetItems(), f.loop.player.stamina
        setFault(f, "remove", "throw_after")
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(4)
        local ok, reason = f.bridge:CompleteFishing(token)
        assertEqual(ok, false); assertEqual(reason, "fishing_commit_failed")
        assert(f.runtime:GetFishingTarget(fish.id) == fish)
        assert(fish.alive and not fish.removed and not fish.captureLocked)
        assertEqual(f.loop.player.stamina, stamina)
        assertItems(f.loop.player.inventory:GetItems(), items)
        assertEqual(f.loop:GetFishingState().state, "failed")
    end)

    test("failed unlock stays pending and retries through the next real frame dispatch", function()
        local f = atSea()
        local fish = f.runtime:spawnFish("sardine", { x = 1, y = 0 })
        setFault(f, "unlock", "false")
        local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))
        f.bridge:Update(0.5)
        assert(fish.captureLocked)
        local cancelled, reason = f.bridge:CancelFishing(token)
        assertEqual(cancelled, false); assertEqual(reason, "fishing_cleanup_pending")
        assert(fish.captureLocked and f.loop.actions._pendingFishing)
        f.bridge:Update(0)
        assert(not fish.captureLocked)
        assertEqual(f.loop.actions._pendingFishing, nil)
        assertEqual(f.loop:GetFishingState().state, "cancelled")
        assertEqual(f.loop.player.stamina, 100)
    end)

    test("throwing inventory snapshot during commit fails free and releases the fish", function()
        for _, methodName in ipairs({ "GetItems", "HasSpace" }) do
            local f = atSea()
            local fish = f.runtime:spawnFish("tuna", { x = 1, y = 0 })
            local inventory = f.loop.player.inventory
            local originalMethod = inventory[methodName]
            local originalGetItems = inventory.GetItems
            local beforeItems = originalGetItems(inventory)
            local beforeStamina = f.loop.player.stamina
            local token = assert(f.bridge:BeginFishing({ x = 0, y = 0 }))

            inventory[methodName] = function()
                error("injected " .. methodName .. " failure")
            end
            local updateOk, updateError = pcall(function() f.bridge:Update(4) end)
            inventory[methodName] = originalMethod

            assert(updateOk, tostring(updateError))
            local completed, reason = f.bridge:CompleteFishing(token)
            assertEqual(completed, false)
            assert(reason ~= nil, methodName .. " failure should be retained on the token")
            assertEqual(f.loop:GetFishingState().state, "failed")
            assertEqual(f.loop.actions._pendingFishing, nil)
            assert(not fish.captureLocked and not fish.removed)
            assert(f.runtime.unlockCalls >= 1)
            assertEqual(f.loop.player.stamina, beforeStamina)
            assertItems(originalGetItems(inventory), beforeItems, methodName .. " inventory")
        end
    end)

    test("world-bound CompleteAction cannot charge for fishing without a bridge token", function()
        local f = Tests.Fixture()
        assert(f.loop:Depart())
        local beforeStamina = f.loop.player.stamina
        local completed, reason = f.loop:CompleteAction("fishing")
        assertEqual(completed, false)
        assertEqual(reason, "fishing_requires_bridge_token")
        assertEqual(f.loop.player.stamina, beforeStamina)
        assertEqual(f.loop.actions._pendingFishing, nil)
        assert(not f.loop:HasPendingCatch())
    end)

    return { results = results }
end

return Tests
