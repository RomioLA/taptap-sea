-- Run boundary, save migration, and NG+ reset contract for Circle 1 B.
local Config = require "config.gameplay"
local Loop = require "Gameplay.Loop"
local Persistence = require "Gameplay.Persistence"
local PlayerState = require "Gameplay.PlayerState"

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function newLoop(options)
    local store = { saves = {}, callbacks = {}, loaded = nil }
    function store:Save(snapshot, done)
        self.saves[#self.saves + 1] = copy(snapshot)
        self.callbacks[#self.callbacks + 1] = done
    end
    function store:Load(done) done(true, self.loaded) end
    options = options or {}
    options.store = store
    options.initialRunRequired = true
    return Loop.New(options), store
end

local function startRun(loop, store)
    eq(loop.player.runStatus, "not_started", "initial state")
    eq(loop.player.runNumber, 0, "initial run number")
    assert(loop:NewRun())
    eq(#store.callbacks, 1, "initial save callback")
    store.callbacks[1](true)
    eq(loop.player.runStatus, "active", "started state")
    eq(loop.player.runNumber, 1, "first run number")
end

local function settleDay(loop, store)
    assert(loop:EndToday())
    assert(loop:ConfirmSettlement())
    local callback = store.callbacks[#store.callbacks]
    assert(callback, "settlement save callback missing")
    callback(true)
end

function Tests.Run()
    local results = {}
    local function test(name, fn)
        local ok, reason = pcall(fn)
        local row = { name = name, passed = ok }
        if not ok then row.error = tostring(reason) end
        results[#results + 1] = row
    end

    test("the seventh settlement closes the run without creating day eight", function()
        local newDays = {}
        local loop, store = newLoop({ onNewDay = function(day) newDays[#newDays + 1] = day end })
        startRun(loop, store)
        for day = 2, Config.run.days do
            settleDay(loop, store)
            eq(loop.player.day, day, "day after settlement")
            eq(loop.player.runStatus, "active", "run stays active through the seventh day")
        end
        settleDay(loop, store)
        eq(#newDays, Config.run.days - 1, "new-day hook count")
        eq(newDays[#newDays], Config.run.days, "last day hook")
        eq(store.saves[#store.saves].day, Config.run.days, "final saved day")
        eq(store.saves[#store.saves].runStatus, "awaiting_ending", "final saved state")
        eq(loop:EndToday(), false, "cannot settle beyond final day")
        eq(loop:Ready(), false, "completed run is not gameplay-ready")
    end)

    test("completed state survives load and freezes world advancement", function()
        local loop, store = newLoop()
        startRun(loop, store)
        for _ = 2, Config.run.days do settleDay(loop, store) end
        settleDay(loop, store)
        local finalSnapshot = copy(store.saves[#store.saves])
        local restored = assert(Persistence.Restore(finalSnapshot))
        eq(restored.day, Config.run.days, "restored day")
        eq(restored.runNumber, 1, "restored run number")
        eq(restored.runStatus, "awaiting_ending", "restored run status")

        local loadLoop, loadStore = newLoop()
        loadStore.loaded = finalSnapshot
        assert(loadLoop:LoadSaved())
        eq(loadLoop.player.runStatus, "awaiting_ending", "loaded run status")
        local worldSteps = 0
        loadLoop:Update(5, function() worldSteps = worldSteps + 1 end)
        eq(worldSteps, 0, "world does not advance after completion")
        eq(loadLoop:Depart(), false, "cannot depart after completion")
        assert(loadLoop.clock:IsPaused(), "completed run clock must stay paused")
    end)

    test("an active run cannot be reset early; NG+ resets all run progress", function()
        local loop, store = newLoop()
        startRun(loop, store)
        loop.player.money = 777
        eq(loop:NewRun(), false, "premature new run")
        eq(loop.player.money, 777, "early attempt preserves state")
        eq(loop.player.runNumber, 1, "early attempt preserves run number")

        for _ = 2, Config.run.days do settleDay(loop, store) end
        settleDay(loop, store)
        loop.player.money = 777
        loop.player.maxStamina, loop.player.stamina = 160, 17
        loop.player.boatSpeedLevel = 3
        assert(loop.player.inventory:Upgrade())
        assert(loop.player.inventory:Add("tuna"))
        assert(loop.player:MarkRecognized("old_island"))
        loop.player.treasures.scopeLens = true
        loop.player.story.circle1B2.barrelStage = 2
        loop.player.story.circle1B2.paperShown = true
        loop.player.elder.lastGivenItemId = "apple"

        assert(loop:NewRun())
        eq(loop.player.runNumber, 2, "NG+ run number")
        eq(loop.player.runStatus, "active", "NG+ status")
        eq(loop.player.day, 1, "NG+ day")
        eq(loop.player.money, Config.initial.money, "reset money")
        eq(loop.player.maxStamina, Config.initial.maxStamina, "reset max stamina")
        eq(loop.player.stamina, Config.initial.stamina, "reset stamina")
        eq(loop.player.boatSpeedLevel, 1, "reset boat upgrade")
        eq(loop.player.inventory:GetCapacity(), Config.inventory.capacities[1], "reset inventory size")
        eq(#loop.player.inventory:GetItems(), #Config.initial.items, "reset inventory contents")
        eq(loop.player:IsRecognized("old_island"), false, "reset discoveries")
        eq(loop.player.treasures.scopeLens, false, "reset treasure progress")
        eq(loop.player.story.circle1B2.barrelStage, 0, "reset story progress")
        eq(loop.player.story.circle1B2.paperShown, false, "reset paper flag")
        eq(loop.player.elder.circle1B2.applesGiven, 0, "reset elder progress")
        eq(loop.player.elder.lastGivenItemId, nil, "reset elder interaction")
        local nextRun = store.saves[#store.saves]
        eq(nextRun.runNumber, 2, "NG+ saved run number")
        eq(nextRun.day, 1, "NG+ saved day")
    end)

    test("schema v1 saves migrate as run one and all saves reject day eight", function()
        local snapshot = Persistence.Snapshot(assert(PlayerState.New()))
        snapshot.schemaVersion = 1
        snapshot.runNumber, snapshot.runStatus = nil, nil
        local migrated = assert(Persistence.Restore(snapshot))
        eq(migrated.runNumber, 1, "migrated run number")
        eq(migrated.runStatus, "active", "migrated run status")

        snapshot.day = Config.run.days + 1
        eq(Persistence.Restore(snapshot), nil, "v1 day eight")
        local current = Persistence.Snapshot(assert(PlayerState.New()))
        current.day = Config.run.days + 1
        eq(Persistence.Restore(current), nil, "v2 day eight")
    end)

    test("a failed port preparation retries the same pending run", function()
        local attempts = 0
        local loop, store = newLoop({ resetDynamicWorld = function()
            attempts = attempts + 1
            return attempts > 1
        end })
        eq(loop:NewRun(), false, "first preparation attempt")
        eq(loop.pendingRunStart, true, "pending run marker")
        eq(loop.player.runNumber, 1, "pending run number")
        eq(loop.initialSaveStatus, "idle", "no save before world preparation")
        assert(loop:NewRun())
        eq(#store.saves, 1, "retry saves once")
        eq(store.saves[1].runNumber, 1, "retry keeps run number")
        store.callbacks[1](true)
        eq(loop.pendingRunStart, false, "pending marker clears")
        eq(loop.entryPending, false, "entry resumes")
    end)

    return { results = results }
end

return Tests
