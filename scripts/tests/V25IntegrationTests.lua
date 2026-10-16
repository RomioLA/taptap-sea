-- V2.5 cross-module contract tests. Keep these on real Ocean Runtime, Bridge,
-- Gameplay Loop and Persistence; only the storage boundary is in-memory.
local Runtime = require("Ocean.SeaRuntime")
local GameplayConfig = require("config.gameplay")
local OceanConfig = require("Ocean.Config")
local PlayerState = require("Gameplay.PlayerState")
local Persistence = require("Gameplay.Persistence")
local WorldContentProgress = require("Gameplay.WorldContentProgress")
local Bridge = require("Integration.Bridge")

local Tests = {}
local FREE_SEA = { x = -20, y = -20 }
local SAFE_AUTO_RETURN = { x = -11, y = 0 }
local CONTENT_IDS = { "island_01", "island_02", "underwater_treasure_01" }
local MEMORY_IDS = { "memory_island_01", "memory_island_02", "memory_treasure_01" }

local function copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copyTable(child) end
    return result
end

local function eq(actual, expected, label)
    assert(actual == expected, (label or "values differ") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end

local function near(actual, expected, epsilon, label)
    assert(type(actual) == "number" and math.abs(actual - expected) <= (epsilon or 0.00001),
        (label or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function memoryStore()
    local store = { saves = {}, loadCalls = 0, loadValue = nil, loadOk = true }
    function store:Save(snapshot, done)
        self.saves[#self.saves + 1] = copyTable(snapshot)
        if done then done(true) end
        return true
    end
    function store:Load(done)
        self.loadCalls = self.loadCalls + 1
        if done then done(self.loadOk, copyTable(self.loadValue)) end
        return true
    end
    return store
end

local function fixture(settings)
    settings = settings or {}
    local runtime = Runtime.New({
        departure = copyTable(settings.departure or FREE_SEA),
        initializeRegions = settings.initializeRegions == true,
        daySeed = settings.daySeed or 314159,
        shipLevel = settings.shipLevel or 1,
        autoReturnDiagnostic = function() end,
    })
    local store = settings.store or memoryStore()
    local bridge = Bridge.New(runtime, { store = store })
    assert(bridge and bridge.loop and bridge.runtime == runtime,
        "Bridge.New must retain the real Runtime and Loop")
    return { runtime = runtime, bridge = bridge, loop = bridge.loop, store = store }
end

local function contentDeparture(contentId)
    local probe = Runtime.New({
        departure = copyTable(FREE_SEA),
        initializeRegions = false,
        daySeed = 314159,
    })
    assert(type(probe.GetWorldContent) == "function",
        "Runtime:GetWorldContent is required before positioning the real integration fixture")
    local target = assert(probe:GetWorldContent(contentId), "missing fixed content " .. contentId)
    local center = assert(target.position, "fixed content snapshot has no position")
    local radius = type(target.radius) == "number" and target.radius or 0
    local shipRadius = OceanConfig.ship.radius
    local directions = {
        { x = 0, y = 1 }, { x = 1, y = 0 }, { x = 0, y = -1 }, { x = -1, y = 0 },
    }
    for _, direction in ipairs(directions) do
        local departure = {
            x = center.x + direction.x * (radius + 3),
            y = center.y + direction.y * (radius + 3),
        }
        if probe:IsPositionFree(departure, shipRadius) then
            return departure
        end
    end
    error("no free 3m shore fixture around " .. contentId)
end

local function fixtureAtContent(contentId, settings)
    settings = settings or {}
    settings.departure = contentDeparture(contentId)
    settings.initializeRegions = false
    return fixture(settings)
end

local function fixtureAtTreasureScope()
    local probe = Runtime.New({
        departure = copyTable(FREE_SEA),
        initializeRegions = false,
        daySeed = 314159,
    })
    local treasure = assert(probe:GetWorldContent("underwater_treasure_01"), "missing fixed treasure")
    local gap = 2
    local approachDistance = treasure.radius + OceanConfig.ship.radius + gap
    local departure = { x = treasure.position.x - approachDistance, y = treasure.position.y }
    assert(probe:IsPositionFree(departure, OceanConfig.ship.radius),
        "scope fixture must be reachable without overlapping a blocking collider")
    probe.movement:ResetAtPosition(departure)
    local access = assert(probe:GetWorldContentAccess("underwater_treasure_01"))
    assert(access.surfaceGap <= 5, "treasure scope fixture must remain in salvage range")
    near(probe.ship.rotation, 0, 0.0001, "scope fixture uses the Runtime's default eastward heading")
    assert(probe:SetScopeEnabled(true))
    eq(probe:IsWorldContentInScope("underwater_treasure_01"), true,
        "scope fixture position and default heading must include Treasure")
    return fixture({ departure = departure, initializeRegions = false })
end

local function barrelDeparture()
    local probe = Runtime.New({
        departure = copyTable(FREE_SEA),
        initializeRegions = false,
        daySeed = 314159,
    })
    local barrel = assert(probe:GetFixedBarrel(), "missing fixed barrel")
    local directions = {
        { x = 1, y = 0 }, { x = 0, y = 1 }, { x = -1, y = 0 }, { x = 0, y = -1 },
    }
    local distance = OceanConfig.interaction.operateDistance - 0.1
    for _, direction in ipairs(directions) do
        local departure = {
            x = barrel.position.x + direction.x * distance,
            y = barrel.position.y + direction.y * distance,
        }
        if probe:IsPositionFree(departure, OceanConfig.ship.radius) then
            probe.movement:ResetAtPosition(departure)
            local canInteract = probe:CanInteractWithBarrel(barrel.id, barrel.generation)
            if canInteract then return departure end
        end
    end
    error("no free in-range coordinate around the fixed barrel")
end

local function depart(env)
    local ok, reason = env.loop:Depart()
    assert(ok, tostring(reason or "could not depart"))
    env.bridge:Sync()
    assert(not env.runtime.paused, "departing must release the Runtime pause")
end

local function startAutoReturn(env)
    local started, reason = env.bridge:RequestAutoReturn()
    assert(started, tostring(reason or "auto-return request rejected"))
    eq(env.runtime:GetAutoReturnState().phase, "active", "runtime auto-return must be active")
end

local function autoReturnFixture(settings)
    local options = {}
    for key, value in pairs(settings or {}) do options[key] = value end
    options.departure = copyTable(options.departure or SAFE_AUTO_RETURN)
    options.initializeRegions = false
    local env = fixture(options)
    depart(env)
    startAutoReturn(env)
    return env
end

local function positionShipForAction(env, position)
    env.runtime.movement:ResetAtPosition(copyTable(position))
    eq(env.runtime:GetAutoReturnState().phase, "active",
        "test positioning must preserve the Runtime auto-return owner until takeover")
end

local function startOverlappingAutoReturn(env)
    local actionPosition = copyTable(env.runtime:GetShipPosition())
    env.runtime.movement:ResetAtPosition(copyTable(SAFE_AUTO_RETURN))
    local started, reason = env.runtime:StartAutoReturn()
    assert(started, tostring(reason or "Runtime AutoReturn fixture rejected"))
    env.runtime.movement:ResetAtPosition(actionPosition)
    eq(env.runtime:GetAutoReturnState().phase, "active",
        "test positioning must preserve the Runtime auto-return owner through cleanup")
end

local function assertAutoReturnCancelled(env, label)
    local state = assert(env.runtime:GetAutoReturnState(), "Runtime auto-return state is unavailable")
    eq(state.phase, "cancelled", (label or "takeover") .. " must observe cancellation before taking effect")
    return state
end

local function progress(loop, contentId)
    return assert(WorldContentProgress.GetState(loop.player, contentId))
end

local function actionReceipt(loop, token)
    local service = assert(loop.worldContentActions,
        "Loop must own the single WorldContentActions service")
    assert(type(service.GetReceipt) == "function", "WorldContentActions receipt query is required")
    return assert(service:GetReceipt(token), "missing action receipt")
end

local function ownedCount(values, treasureId)
    if type(values) ~= "table" then return 0 end
    if rawget(values, treasureId) == true then return 1 end
    local count = 0
    for _, value in pairs(values) do
        local id = type(value) == "table" and value.id or value
        local owned = type(value) ~= "table" or value.owned ~= false
        if id == treasureId and owned then count = count + 1 end
    end
    return count
end

local function withPatched(target, key, replacement, run)
    local original = target[key]
    target[key] = replacement
    local ok, result = xpcall(run, debug.traceback)
    target[key] = original
    if not ok then error(result, 0) end
    return result
end

local function withSceneTestModules(departure, run)
    local state = { uiShutdownCalls = 0, hudDestroyCalls = 0, oceanStopCalls = 0 }
    local function node(props)
        return {
            props = props or {},
            GetChildren = function() return {} end,
            FindById = function() return nil end,
        }
    end
    local ui = {
        Scale = { DEFAULT = 1 },
        Init = function() end,
        GetScale = function() return 1 end,
        Panel = function(props) return node(props) end,
        SetRoot = function() end,
        Shutdown = function() state.uiShutdownCalls = state.uiShutdownCalls + 1 end,
    }
    local fusedScene = {
        Start = function(options)
            local runtime = Runtime.New({
                departure = copyTable(options.departure or FREE_SEA),
                initializeRegions = options.initializeRegions == true,
                daySeed = 314159,
                autoReturnDiagnostic = function() end,
            })
            local sea = { SyncViewport = function() return true end }
            state.runtime = runtime
            local uiCallbacks = options.uiFactory and options.uiFactory(runtime, sea) or nil
            sea.Stop = function()
                state.oceanStopCalls = state.oceanStopCalls + 1
                if uiCallbacks and uiCallbacks.stop then uiCallbacks.stop() end
                return true
            end
            return sea
        end,
    }
    local hud = {
        Create = function()
            return {
                root = node(),
                Refresh = function() end,
                Destroy = function() state.hudDestroyCalls = state.hudDestroyCalls + 1 end,
            }
        end,
    }
    local debugModule = { New = function() return {} end }
    local seaDebug = { Create = function() return {} end }
    local overrides = {
        ["urhox-libs/UI"] = ui,
        ["Ocean.FusedScene"] = fusedScene,
        ["Gameplay.HUD"] = hud,
        ["Gameplay.Debug"] = debugModule,
        ["Ocean.SeaDebug"] = seaDebug,
    }
    local previous = {}
    for name, module in pairs(overrides) do
        previous[name] = package.loaded[name]
        package.loaded[name] = module
    end
    local previousScene = package.loaded["Integration.Scene"]
    package.loaded["Integration.Scene"] = nil
    local ok, result = xpcall(function()
        local sceneModule = require("Integration.Scene")
        local sea = sceneModule.Start({
            departure = copyTable(departure),
            initializeRegions = false,
            store = memoryStore(),
            loadSaved = false,
        })
        return run(sea, state)
    end, debug.traceback)
    package.loaded["Integration.Scene"] = previousScene
    for name, module in pairs(previous) do package.loaded[name] = module end
    if not ok then error(result, 0) end
    return result
end

function Tests.Run()
    local results = {}
    local function check(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = {
            name = name,
            passed = ok,
            error = ok and "" or tostring(err),
        }
    end

    check("fixed content IDs return stable defensive snapshots and spatial facts", function()
        local runtime = Runtime.New({ departure = FREE_SEA, initializeRegions = false, daySeed = 314159 })
        local generation = assert(runtime:GetFixedContentGeneration())
        assert(type(generation) == "number")
        for _, contentId in ipairs(CONTENT_IDS) do
            local snapshot = assert(runtime:GetWorldContent(contentId), "missing " .. contentId)
            eq(snapshot.contentId, contentId)
            assert(snapshot.id ~= nil, contentId .. " has no entity identity")
            eq(snapshot.generation, generation, contentId .. " fixed-content generation")
            assert(type(snapshot.position) == "table"
                and type(snapshot.position.x) == "number" and type(snapshot.position.y) == "number")
            local access = assert(runtime:GetWorldContentAccess(contentId), "missing access for " .. contentId)
            eq(access.exists, true)
            assert(type(access.distance) == "number")
            assert(type(access.edgeDistance) == "number")
            assert(type(access.surfaceGap) == "number")
            local ship = runtime:GetShipPosition()
            local dx, dy = snapshot.position.x - ship.x, snapshot.position.y - ship.y
            near(access.distance, math.sqrt(dx * dx + dy * dy), 0.0001, contentId .. " distance")
            near(access.edgeDistance, math.max(0, access.distance - snapshot.radius), 0.0001,
                contentId .. " edge distance")
            near(access.surfaceGap, math.max(0, access.edgeDistance - runtime.ship.radius), 0.0001,
                contentId .. " surface gap")
            eq(access.withinInteractionRange, nil, "Gameplay owns the interaction-range threshold")
            local originalX = snapshot.position.x
            pcall(function() snapshot.position.x = originalX + 1000 end)
            near(runtime:GetWorldContent(contentId).position.x, originalX, 0.0001,
                contentId .. " snapshot must not mutate Runtime state")
        end

        local treasure = assert(runtime:GetWorldContent("underwater_treasure_01"))
        eq(treasure.layer, "underwater")
        eq(treasure.blocking, false)
        assert(treasure.entityType ~= "fish")
        if treasure.ordinaryFish ~= nil then eq(treasure.ordinaryFish, false) end
        eq(runtime:IsWorldContentInScope("underwater_treasure_01"), false)
        local islandScope, islandScopeError = runtime:IsWorldContentInScope("island_01")
        eq(islandScope, nil)
        eq(islandScopeError, "scope_not_applicable")
    end)

    check("ordinary fish refresh leaves a fixed-content action receipt valid", function()
        local env = fixtureAtContent("island_01")
        depart(env)
        local fixedGeneration = env.runtime:GetFixedContentGeneration()
        local islandBefore = assert(env.runtime:GetWorldContent("island_01"))
        local token = assert(env.bridge:BeginWorldContentAction("island_01", "explore"))
        assert(env.bridge:Update(1.5))
        env.runtime:refreshOrdinaryFish(271829, env.runtime:GetShipPosition())
        eq(env.runtime:GetFixedContentGeneration(), fixedGeneration,
            "daily fish refresh must not change fixed-content generation")
        local islandAfter = assert(env.runtime:GetWorldContent("island_01"))
        eq(islandAfter.id, islandBefore.id, "island entity identity")
        eq(islandAfter.generation, fixedGeneration)
        local active = assert(env.bridge:GetWorldContentActionState())
        eq(active.token, token)
        near(active.elapsed, 1.5, 0.0001)
        assert(env.bridge:Update(2.5))
        local receipt = actionReceipt(env.loop, token)
        eq(receipt.status, "completed")
        eq(receipt.commitState, "committed")
        eq(env.loop.player.stamina, 60, "one exploration charge")
        assert(progress(env.loop, "island_01").completed)
    end)

    check("dynamic prompt, cancellation, pause freeze, four-second commit and elder display", function()
        local env = fixtureAtContent("island_01")
        depart(env)
        local service = assert(env.loop.worldContentActions)
        assert(not rawget(env.bridge, "worldContentActions"),
            "Bridge must delegate rather than keep a second action service")
        local prompt = assert(env.bridge:GetWorldContentPrompt())
        eq(prompt.operation, "begin")
        eq(prompt.contentId, "island_01")
        eq(prompt.actionKind, "explore")
        local startingStamina = env.loop.player.stamina
        local token = assert(env.bridge:BeginWorldContentAction(prompt.contentId, prompt.actionKind))
        assert(env.loop:IsMovementBlocked(), "an active content action must block ship movement")
        local cancelling = assert(env.loop:GetWorldContentPrompt())
        eq(cancelling.operation, "cancel")
        eq(cancelling.contentId, "island_01")
        eq(env.bridge:GetWorldContentActionState().token, token)
        eq(env.loop.player.stamina, startingStamina, "begin is free")

        assert(env.bridge:CancelWorldContentAction())
        eq(env.bridge:GetWorldContentActionState(), nil)
        eq(actionReceipt(env.loop, token).status, "cancelled")
        eq(env.loop.player.stamina, startingStamina)
        assert(not progress(env.loop, "island_01").completed)
        eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_island_01"), 0)

        prompt = assert(env.bridge:GetWorldContentPrompt())
        eq(prompt.operation, "begin")
        token = assert(env.bridge:BeginWorldContentAction("island_01", "explore"))
        assert(env.bridge:Update(3.5))
        near(assert(env.bridge:GetWorldContentActionState()).elapsed, 3.5, 0.0001)
        local clockBeforePause = env.loop.clock.elapsed
        local paused, isPaused = env.bridge:TogglePause()
        assert(paused and isPaused and env.runtime.paused)
        assert(env.bridge:Update(1))
        near(assert(env.bridge:GetWorldContentActionState()).elapsed, 3.5, 0.0001,
            "unified pause must freeze world-content elapsed")
        near(env.loop.clock.elapsed, clockBeforePause, 0.0001,
            "unified pause must freeze the Gameplay clock")
        paused, isPaused = env.bridge:TogglePause()
        assert(paused and not isPaused and not env.runtime.paused)
        assert(env.bridge:Update(0.49))
        near(assert(env.bridge:GetWorldContentActionState()).elapsed, 3.99, 0.0001)
        eq(env.loop.player.stamina, startingStamina, "no charge before completion")
        assert(env.bridge:Update(0.01))

        eq(env.bridge:GetWorldContentActionState(), nil)
        local receipt = actionReceipt(env.loop, token)
        eq(receipt.status, "completed")
        eq(receipt.commitState, "committed")
        eq(env.loop.player.stamina, startingStamina - 40, "exactly one completion charge")
        local completed = progress(env.loop, "island_01")
        assert(completed.completed and completed.rewardOwned)
        eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_island_01"), 1)
        eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_island_02"), 0)

        assert(env.bridge:Update(4))
        eq(actionReceipt(env.loop, token).status, "completed")
        eq(env.loop.player.stamina, startingStamina - 40, "duplicate advance cannot charge again")
        eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_island_01"), 1,
            "duplicate advance cannot duplicate a memory")

        assert(env.loop:SetElderOpen(true))
        local cargoCount = #env.loop.player.inventory:GetItems()
        local shown, response = env.bridge:ShowTreasureToElder("memory_island_01")
        assert(shown and response ~= nil, "owned memory should return this display's response")
        shown, response = env.bridge:ShowTreasureToElder("memory_island_01")
        assert(shown and response ~= nil, "repeat display should remain a successful display")
        local unavailable = env.bridge:ShowTreasureToElder("memory_island_02")
        eq(unavailable, false, "unowned memory must be rejected")
        eq(#env.loop.player.inventory:GetItems(), cargoCount, "memory display must not consume cargo")
        eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_island_01"), 1,
            "memory display must not consume or duplicate ownership")
    end)

    check("NewRun invalidates active receipts before replacing player progress", function()
        local env = fixtureAtContent("island_01")
        depart(env)
        local oldPlayer = env.loop.player
        local oldService = assert(env.loop.worldContentActions)
        local token = assert(env.bridge:BeginWorldContentAction("island_01", "explore"))
        local startingStamina = env.loop.player.stamina
        local ok, reason = env.bridge:NewRun()
        assert(ok, tostring(reason or "NewRun rejected"))
        assert(env.loop.player ~= oldPlayer, "NewRun must replace PlayerState")
        local receipt = actionReceipt(env.loop, token)
        assert(receipt.status ~= "active", "NewRun left an old receipt active")
        assert(not env.bridge:GetWorldContentActionState(), "NewRun left an active content action")
        local fresh = progress(env.loop, "island_01")
        assert(not fresh.completed and not fresh.rewardOwned)
        eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_island_01"), 0)
        eq(oldService:GetReceipt(token).status, receipt.status)
        assert(startingStamina >= env.loop.player.stamina,
            "new run must not inherit the old action's paid progress")
    end)

    check("Load request at sea invalidates the old receipt before refusing the load", function()
        local env = fixtureAtContent("island_01")
        depart(env)
        local token = assert(env.bridge:BeginWorldContentAction("island_01", "explore"))
        local startingStamina = env.loop.player.stamina
        local started = env.bridge:LoadSaved()
        eq(started, false, "LoadSaved remains port-only")
        local receipt = actionReceipt(env.loop, token)
        assert(receipt.status ~= "active", "Load request left a stale action active")
        eq(env.bridge:GetWorldContentActionState(), nil)
        eq(env.loop.player.stamina, startingStamina)
        assert(not progress(env.loop, "island_01").completed)
        eq(env.store.loadCalls, 0, "rejected sea load must not touch persistence")
    end)

    check("Runtime reset changes fixed generation and rejects the old action receipt", function()
        local env = fixtureAtContent("island_01")
        depart(env)
        local generation = env.runtime:GetFixedContentGeneration()
        local token = assert(env.bridge:BeginWorldContentAction("island_01", "explore"))
        local startingStamina = env.loop.player.stamina
        env.runtime:Reset()
        assert(env.runtime:GetFixedContentGeneration() ~= generation,
            "Runtime reset must advance fixed-content generation")
        assert(env.bridge:Update(4))
        assert(actionReceipt(env.loop, token).status ~= "active",
            "old-world action survived Runtime reset")
        assert(not progress(env.loop, "island_01").completed)
        eq(env.loop.player.stamina, startingStamina)
        eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_island_01"), 0)
    end)

    check("old save initializes V2.5 defaults without a schema bump", function()
        local source = assert(PlayerState.New())
        assert(WorldContentProgress.Initialize(source))
        local oldSave = Persistence.Snapshot(source)
        local schemaVersion = oldSave.schemaVersion
        oldSave.story.worldContent = nil
        for _, rewardId in ipairs(MEMORY_IDS) do oldSave.treasures[rewardId] = nil end

        local store = memoryStore()
        store.loadValue = oldSave
        local env = fixture({ departure = { x = 0, y = 0 }, store = store })
        local callbackOk, callbackData
        local started, reason = env.bridge:LoadSaved(function(ok, data)
            callbackOk, callbackData = ok, data
        end)
        assert(started, tostring(reason or "LoadSaved did not start"))
        eq(callbackOk, true, "legacy save callback")
        assert(env.loop.player ~= source)
        eq(schemaVersion, GameplayConfig.persistence.schemaVersion, "V2.5 fields must not bump schema")
        assert(WorldContentProgress.Validate(env.loop.player))
        for index, contentId in ipairs(CONTENT_IDS) do
            local state = progress(env.loop, contentId)
            assert(not state.completed, contentId .. " must initialize incomplete")
            assert(not state.rewardOwned, MEMORY_IDS[index] .. " must initialize unowned")
            if contentId == "underwater_treasure_01" then
                assert(not state.marked, "legacy treasure must initialize unmarked")
            end
        end
        for _, rewardId in ipairs(MEMORY_IDS) do
            eq(ownedCount(env.bridge:GetOwnedTreasures(), rewardId), 0)
        end
    end)

    check("malformed V2.5 save fails closed without replacing the current player", function()
        local source = assert(PlayerState.New())
        assert(WorldContentProgress.Initialize(source))
        local malformed = Persistence.Snapshot(source)
        malformed.story.worldContent.island_01.completed = true
        malformed.treasures.memory_island_01 = false

        local store = memoryStore()
        store.loadValue = malformed
        local env = fixture({ departure = { x = 0, y = 0 }, store = store })
        local currentPlayer = env.loop.player
        local callbackOk, callbackData
        local started, reason = env.bridge:LoadSaved(function(ok, data)
            callbackOk, callbackData = ok, data
        end)
        assert(started, tostring(reason or "LoadSaved did not start"))
        eq(callbackOk, false, "malformed save callback")
        assert(callbackData ~= nil, "malformed save rejection should report a reason")
        assert(env.loop.player == currentPlayer, "malformed save replaced current PlayerState")
        assert(WorldContentProgress.Validate(currentPlayer))
        assert(not progress(env.loop, "island_01").completed)
        assert(not progress(env.loop, "island_01").rewardOwned)
    end)

    check("manual sea pointer cancels auto-return before the same point takes movement control", function()
        local env = fixture({ departure = { x = -11, y = 0 }, initializeRegions = false })
        depart(env)
        local started, reason = env.bridge:RequestAutoReturn()
        assert(started, tostring(reason or "auto-return request rejected"))
        eq(env.bridge:GetAutoReturnState().phase, "active")

        local manualPoint = { x = -30, y = -15 }
        local setTarget = env.runtime.movement.SetTarget
        local takeoverObserved = false
        env.runtime.movement.SetTarget = function(movement, point)
            local state = assert(env.bridge:GetAutoReturnState())
            assert(state.phase ~= "active", "manual target installed before auto-return cancellation")
            takeoverObserved = true
            return setTarget(movement, point)
        end
        local consumed = env.bridge:OnSeaPointer(manualPoint)
        eq(consumed, false, "manual click must continue through ordinary navigation")
        eq(env.bridge:GetAutoReturnState().phase, "cancelled")
        assert(env.runtime.movement:SetTarget(manualPoint))
        assert(takeoverObserved)
        near(env.runtime.movement.target.x, manualPoint.x, 0.0001)
        near(env.runtime.movement.target.y, manualPoint.y, 0.0001)
    end)

    check("return button cancels the active Runtime auto-return", function()
        local env = autoReturnFixture()
        eq(env.loop:GetReturnActionMode(), "cancel_auto_return")

        -- Mirrors the HUD button route: cancel_auto_return -> user_cancel.
        local cancelled, reason = env.loop:CancelAutoReturn("user_cancel")
        assert(cancelled, tostring(reason or "return button cancellation rejected"))
        local state = assertAutoReturnCancelled(env, "return button")
        eq(state.cancelReason, "user_cancel")
        assert(env.loop:GetReturnActionMode() ~= "cancel_auto_return",
            "the return button must leave its cancel mode after cancellation")
    end)

    check("keyboard movement cancels Runtime auto-return before Game movement updates", function()
        local env = autoReturnFixture()
        local gameUpdate = env.bridge.game.Update
        local takeoverObserved = false
        withPatched(env.bridge.game, "Update", function(game, dt, axisX, axisY)
            assertAutoReturnCancelled(env, "keyboard movement")
            takeoverObserved = true
            return gameUpdate(game, dt, axisX, axisY)
        end, function()
            local updated, reason = env.bridge:Update(0.05, 1, 0)
            assert(updated, tostring(reason or "keyboard update rejected"))
        end)
        assert(takeoverObserved, "keyboard movement did not reach Game after cancellation")
    end)

    check("inventory pause starts only after Runtime auto-return is cancelled", function()
        local env = autoReturnFixture()
        local pause = env.loop.clock.Pause
        local takeoverObserved = false
        withPatched(env.loop.clock, "Pause", function(clock, reason)
            if reason == "inventory" then
                assertAutoReturnCancelled(env, "inventory open")
                takeoverObserved = true
            end
            return pause(clock, reason)
        end, function()
            local opened, reason = env.loop:SetInventoryOpen(true)
            assert(opened, tostring(reason or "inventory open rejected"))
        end)
        assert(takeoverObserved, "inventory did not take the pause before cancellation")
        eq(env.loop.inventoryOpen, true)
        eq(env.loop.clock.pauseReasons.inventory, true)
    end)

    check("manual Pause takes effect only after Runtime auto-return is cancelled", function()
        local env = autoReturnFixture()
        local pause = env.loop.clock.Pause
        local takeoverObserved = false
        withPatched(env.loop.clock, "Pause", function(clock, reason)
            if reason == "manual" then
                assertAutoReturnCancelled(env, "manual pause")
                takeoverObserved = true
            end
            return pause(clock, reason)
        end, function()
            local toggled, paused = env.bridge:TogglePause()
            assert(toggled and paused, "manual Pause was not applied")
        end)
        assert(takeoverObserved, "manual Pause did not observe cancellation")
        assert(env.runtime.paused and env.loop.clock:IsPaused())
    end)

    check("Fishing selection starts only after Runtime auto-return is cancelled", function()
        local env = autoReturnFixture()
        local beginSelection = env.loop.actions.BeginSelection
        local takeoverObserved = false
        withPatched(env.loop.actions, "BeginSelection", function(actions, ...)
            assertAutoReturnCancelled(env, "Fishing selection")
            takeoverObserved = true
            return beginSelection(actions, ...)
        end, function()
            local started, reason = env.loop:BeginFishingSelection()
            assert(started, tostring(reason or "Fishing selection rejected"))
        end)
        assert(takeoverObserved, "Fishing selection began before cancellation")
        eq(env.loop:GetFishingState().state, "selecting")
    end)

    check("Barrel inspection starts only after Runtime auto-return is cancelled", function()
        local env = autoReturnFixture()
        positionShipForAction(env, barrelDeparture())
        local beginBarrel = env.loop.barrel.Begin
        local takeoverObserved = false
        withPatched(env.loop.barrel, "Begin", function(barrel, ...)
            assertAutoReturnCancelled(env, "Barrel inspection")
            takeoverObserved = true
            return beginBarrel(barrel, ...)
        end, function()
            local token, reason = env.loop:BeginBarrelInspection()
            assert(token, tostring(reason or "Barrel inspection rejected"))
        end)
        assert(takeoverObserved, "Barrel inspection began before cancellation")
        assert(env.loop.barrel:IsBusy())
    end)

    check("Explore creates its C receipt only after Runtime auto-return is cancelled", function()
        local env = autoReturnFixture()
        positionShipForAction(env, contentDeparture("island_01"))
        local prompt = assert(env.bridge:GetWorldContentPrompt())
        eq(prompt.actionKind, "explore")
        local actions = assert(env.loop.worldContentActions)
        local beginExplore = actions.BeginExplore
        local takeoverObserved = false
        withPatched(actions, "BeginExplore", function(service, contentId)
            assertAutoReturnCancelled(env, "Explore")
            eq(env.loop:GetWorldContentActionState(), nil,
                "Explore must not create a C receipt before AutoReturn cancellation")
            takeoverObserved = true
            return beginExplore(service, contentId)
        end, function()
            local token, reason = env.bridge:BeginWorldContentAction("island_01", "explore")
            assert(token, tostring(reason or "Explore rejected"))
        end)
        assert(takeoverObserved)
        eq(env.loop:GetWorldContentActionState().actionKind, "explore")
    end)

    check("Salvage creates its C receipt only after Runtime auto-return is cancelled", function()
        local env = autoReturnFixture()
        positionShipForAction(env, contentDeparture("underwater_treasure_01"))
        assert(WorldContentProgress.Mark(env.loop.player, "underwater_treasure_01"))
        local prompt = assert(env.bridge:GetWorldContentPrompt())
        eq(prompt.actionKind, "salvage")
        local actions = assert(env.loop.worldContentActions)
        local beginSalvage = actions.BeginSalvage
        local takeoverObserved = false
        withPatched(actions, "BeginSalvage", function(service, contentId)
            assertAutoReturnCancelled(env, "Salvage")
            eq(env.loop:GetWorldContentActionState(), nil,
                "Salvage must not create a C receipt before AutoReturn cancellation")
            takeoverObserved = true
            return beginSalvage(service, contentId)
        end, function()
            local token, reason = env.bridge:BeginWorldContentAction(
                "underwater_treasure_01", "salvage")
            assert(token, tostring(reason or "Salvage rejected"))
        end)
        assert(takeoverObserved)
        eq(env.loop:GetWorldContentActionState().actionKind, "salvage")
    end)

    check("night forced return cancels AutoReturn and the active C receipt before port preparation", function()
        local env = fixtureAtContent("island_01")
        depart(env)
        local token = assert(env.bridge:BeginWorldContentAction("island_01", "explore"))
        -- Start at a safe routeable coordinate, then restore the action position before takeover.
        startOverlappingAutoReturn(env)

        local cancelContent = env.loop.CancelWorldContentAction
        local preparePort = env.loop.PreparePort
        local contentCancelled = false
        withPatched(env.loop, "CancelWorldContentAction", function(loop, ...)
            assertAutoReturnCancelled(env, "night forced return")
            local cancelled, cancelReason = cancelContent(loop, ...)
            assert(cancelled, tostring(cancelReason or "night C receipt cancellation rejected"))
            assert(actionReceipt(loop, token).status ~= "active",
                "forced return left the active C receipt open")
            contentCancelled = true
            return cancelled, cancelReason
        end, function()
            withPatched(env.loop, "PreparePort", function(loop, portReason)
                assertAutoReturnCancelled(env, "night port preparation")
                assert(actionReceipt(loop, token).status ~= "active",
                    "port preparation began before the C receipt was closed")
                return preparePort(loop, portReason)
            end, function()
                env.loop.clock:Seek("night", env.loop.clock.nightSec)
                local updated, updateReason = env.bridge:Update(0)
                assert(updated, tostring(updateReason or "forced-return update rejected"))
            end)
        end)
        assert(contentCancelled)
        assert(env.loop.forcedReturnPending and env.loop.inPort)
        assertAutoReturnCancelled(env, "night forced return result")
    end)

    check("throw selection is assigned only after Runtime auto-return is cancelled", function()
        local env = autoReturnFixture()
        local cancelAutoReturn = env.loop.CancelAutoReturn
        local cancellationObserved = false
        withPatched(env.loop, "CancelAutoReturn", function(loop, reason)
            eq(loop.throwSelection, nil, "throw selection must not be assigned before cancellation")
            local cancelled, cancelReason = cancelAutoReturn(loop, reason)
            if cancelled then
                assertAutoReturnCancelled(env, "throw selection")
                cancellationObserved = true
            end
            return cancelled, cancelReason
        end, function()
            local selected, reason = env.loop:BeginThrowItem(1)
            assert(selected, tostring(reason or "throw selection rejected"))
        end)
        assert(cancellationObserved)
        eq(env.loop:GetThrowSelection().itemId, "apple")
    end)

    check("ReturnToPort clears movement only after Runtime auto-return is cancelled", function()
        local env = autoReturnFixture()
        env.runtime.movement:ResetAtPosition(env.runtime:GetPortPosition())
        local clearTarget = env.runtime.ClearMovementTarget
        local takeoverObserved = false
        withPatched(env.runtime, "ClearMovementTarget", function(runtime, ...)
            assertAutoReturnCancelled(env, "ReturnToPort")
            takeoverObserved = true
            return clearTarget(runtime, ...)
        end, function()
            local returned, reason = env.loop:ReturnToPort()
            assert(returned, tostring(reason or "ReturnToPort rejected"))
        end)
        assert(takeoverObserved, "ReturnToPort did not reach its takeover boundary")
        assert(env.loop.inPort)
    end)

    check("Loop.Close cancels AutoReturn before invalidating the active C receipt", function()
        local env = fixtureAtContent("island_01")
        depart(env)
        local token = assert(env.bridge:BeginWorldContentAction("island_01", "explore"))
        -- Public Loop admission blocks this overlap; real Runtime positioning makes it deterministic.
        startOverlappingAutoReturn(env)
        local invalidate = env.loop.InvalidateWorldContent
        local closeObserved = false
        withPatched(env.loop, "InvalidateWorldContent", function(loop, why)
            assertAutoReturnCancelled(env, "Loop.Close")
            eq(actionReceipt(loop, token).status, "active",
                "Close must cancel Runtime AutoReturn before invalidating its C receipt")
            local invalidated, invalidateReason = invalidate(loop, why)
            assert(invalidated, tostring(invalidateReason or "WorldContent invalidation rejected"))
            assert(actionReceipt(loop, token).status ~= "active",
                "successful Close must leave no active C receipt")
            closeObserved = true
            return invalidated, invalidateReason
        end, function()
            local closed, closeReason = env.loop:Close()
            assert(closed, tostring(closeReason or "Loop.Close rejected"))
        end)
        assert(closeObserved)
        assert(env.loop.closed)
        assertAutoReturnCancelled(env, "Loop.Close result")
    end)

    check("Scene.Stop respects Loop.Close rejection and retries cleanup with the live C receipt", function()
        withSceneTestModules(contentDeparture("island_01"), function(sea, state)
            local env = { runtime = sea.bridge.runtime, bridge = sea.bridge, loop = sea.loop }
            depart(env)
            local token = assert(sea.bridge:BeginWorldContentAction("island_01", "explore"))
            startOverlappingAutoReturn(env)

            local invalidate = env.loop.InvalidateWorldContent
            local rejectOnce = true
            withPatched(env.loop, "InvalidateWorldContent", function(loop, why)
                assertAutoReturnCancelled(env, "Scene.Stop before Loop.Close invalidation")
                if rejectOnce then
                    rejectOnce = false
                    eq(actionReceipt(loop, token).status, "active")
                    return false, "injected_close_rejection"
                end
                eq(actionReceipt(loop, token).status, "active")
                local invalidated, invalidateReason = invalidate(loop, why)
                assert(invalidated, tostring(invalidateReason or "WorldContent invalidation rejected"))
                assert(actionReceipt(loop, token).status ~= "active")
                return invalidated, invalidateReason
            end, function()
                local stopped, stopReason = sea:Stop()
                eq(stopped, false, "Scene.Stop must propagate Loop.Close rejection")
                eq(stopReason, "injected_close_rejection")
                eq(actionReceipt(env.loop, token).status, "active",
                    "rejected Close must keep its C receipt available for retry")
                eq(state.oceanStopCalls, 0, "renderer Stop must wait for successful Loop.Close")
                eq(state.hudDestroyCalls, 0, "HUD must remain live after Close rejection")
                eq(state.uiShutdownCalls, 0, "UI must remain live after Close rejection")
                assertAutoReturnCancelled(env, "Scene.Stop rejected Close")

                local retried, retryReason = sea:Stop()
                assert(retried ~= false, tostring(retryReason or "Scene.Stop retry rejected"))
                assert(actionReceipt(env.loop, token).status ~= "active",
                    "successful Scene.Stop must close its active C receipt")
                eq(state.oceanStopCalls, 1)
                eq(state.hudDestroyCalls, 1)
                eq(state.uiShutdownCalls, 1)
                assert(env.loop.closed)
                assertAutoReturnCancelled(env, "Scene.Stop successful retry")
            end)
        end)
    end)

    check("Treasure uses reachable real scope observation and commits one salvage reward", function()
        local env = fixtureAtTreasureScope()
        depart(env)
        local treasure = assert(env.runtime:GetWorldContent("underwater_treasure_01"))
        eq(treasure.blocking, false)
        local blockerCount = 0
        for _, entity in pairs(env.runtime.world.entities) do
            if entity and entity.blocking == true then
                blockerCount = blockerCount + 1
                local dx = treasure.position.x - entity.position.x
                local dy = treasure.position.y - entity.position.y
                local minimumDistance = treasure.radius + entity.radius
                assert(dx * dx + dy * dy > minimumDistance * minimumDistance,
                    "fixed Treasure overlaps blocking collider " .. tostring(entity.id))
            end
        end
        assert(blockerCount > 0, "fixture must verify against the actual blocking colliders")

        local access = assert(env.runtime:GetWorldContentAccess("underwater_treasure_01"))
        assert(access.surfaceGap <= 5, "treasure approach must be reachable for salvage")
        eq(env.runtime:IsWorldContentInScope("underwater_treasure_01"), false,
            "Runtime scope starts disabled")
        local prompt = env.bridge:GetWorldContentPrompt()
        eq(prompt, nil, "unmarked Treasure must not offer salvage")

        env.loop.player.treasures.scopeLens = true
        local scopeEnabled, scopeReason = env.loop:ToggleScope()
        assert(scopeEnabled, tostring(scopeReason or "scope could not be enabled"))
        eq(env.runtime:IsWorldContentInScope("underwater_treasure_01"), true,
            "real ship heading and scope query must include Treasure")

        assert(env.bridge:Update(0.5))
        eq(progress(env.loop, "underwater_treasure_01").marked, false,
            "half a second of real scope observation must not mark Treasure")
        assert(env.bridge:Update(0.5))
        eq(progress(env.loop, "underwater_treasure_01").marked, true,
            "one continuous second in real scope must mark Treasure")

        prompt = assert(env.bridge:GetWorldContentPrompt())
        eq(prompt.operation, "begin")
        eq(prompt.contentId, "underwater_treasure_01")
        eq(prompt.actionKind, "salvage")
        local cargo = env.loop.player.inventory:GetItems()
        local stamina = env.loop.player.stamina
        local actions = assert(env.loop.worldContentActions)
        local beginSalvage = actions.BeginSalvage
        local takeoverObserved = false
        startAutoReturn(env)
        withPatched(actions, "BeginSalvage", function(service, contentId)
            assertAutoReturnCancelled(env, "Treasure salvage")
            eq(env.loop:GetWorldContentActionState(), nil,
                "AutoReturn must be cancelled before the Treasure receipt is created")
            takeoverObserved = true
            return beginSalvage(service, contentId)
        end, function()
            local token, reason = env.bridge:BeginWorldContentAction(
                prompt.contentId, prompt.actionKind)
            assert(token, tostring(reason or "Treasure salvage rejected"))
            assert(env.bridge:Update(4))
            local receipt = actionReceipt(env.loop, token)
            eq(receipt.status, "completed")
            eq(receipt.commitState, "committed")
            eq(env.loop.player.stamina, stamina - 40)
            eq(env.loop.player.treasures.memory_treasure_01, true)
            eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_treasure_01"), 1)
            local afterCargo = env.loop.player.inventory:GetItems()
            eq(#afterCargo, #cargo, "salvage must not add cargo items")
            for index, itemId in ipairs(cargo) do eq(afterCargo[index], itemId) end

            assert(env.bridge:Update(4))
            eq(actionReceipt(env.loop, token).status, "completed")
            eq(env.loop.player.stamina, stamina - 40, "repeat Update must not charge twice")
            eq(ownedCount(env.bridge:GetOwnedTreasures(), "memory_treasure_01"), 1,
                "repeat Update must not duplicate the reward")
        end)
        assert(takeoverObserved)
        assertAutoReturnCancelled(env, "Treasure salvage result")
    end)

    check("arrival calls formal ReturnToPort once and consumes the Runtime handshake", function()
        local env = fixture({ departure = { x = -11, y = 0 }, initializeRegions = false })
        depart(env)
        local stamina = env.loop.player.stamina
        local returnCalls = 0
        local original = env.loop.ReturnToPort
        env.loop.ReturnToPort = function(loop, ...)
            returnCalls = returnCalls + 1
            return original(loop, ...)
        end
        local started, reason = env.bridge:RequestAutoReturn()
        assert(started, tostring(reason or "auto-return request rejected"))
        eq(returnCalls, 0, "remote auto-return must not immediately teleport/return")

        for _ = 1, 80 do
            assert(env.bridge:Update(0.05))
            if env.loop.inPort then break end
        end
        assert(env.loop.inPort, "arrival did not complete the formal port transaction")
        eq(returnCalls, 1)
        eq(env.bridge:GetAutoReturnState().phase, "arrival_consumed")
        for _ = 1, 4 do assert(env.bridge:Update(0.05)) end
        eq(returnCalls, 1, "consumed arrival must not repeat ReturnToPort")
        eq(env.loop.player.stamina, stamina, "auto-return must not charge stamina")
    end)

    check("rejected arrival is marked failed and is not retried every frame", function()
        local env = fixture({ departure = { x = -11, y = 0 }, initializeRegions = false })
        depart(env)
        local returnCalls = 0
        withPatched(env.loop, "ReturnToPort", function()
            returnCalls = returnCalls + 1
            return false, "integration_return_rejected"
        end, function()
            local started, reason = env.bridge:RequestAutoReturn()
            assert(started, tostring(reason or "auto-return request rejected"))
            for _ = 1, 80 do
                assert(env.bridge:Update(0.05))
                if env.bridge:GetAutoReturnState().phase == "failed" then break end
            end
            local state = env.bridge:GetAutoReturnState()
            eq(state.phase, "failed")
            eq(state.failureReason, "integration_return_rejected")
            assert(not env.loop.inPort, "rejected arrival must not mark Loop in-port")
            eq(returnCalls, 1)
            for _ = 1, 4 do assert(env.bridge:Update(0.05)) end
            eq(returnCalls, 1, "rejected arrival must not retry automatically")
        end)
    end)

    return { results = results, guiVerified = false }
end

return Tests
