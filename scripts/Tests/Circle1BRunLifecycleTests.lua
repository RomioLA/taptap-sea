-- Persisted day-seven run boundary and schema-v1 compatibility tests.
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

local function newLoop()
    local store = { saves = {}, saveCallbacks = {}, loadCallbacks = {} }
    function store:Save(snapshot, done)
        local index = #self.saves + 1
        self.saves[index] = copy(snapshot)
        self.saveCallbacks[index] = done
        return true
    end
    function store:Load(done)
        local index = #self.loadCallbacks + 1
        self.loadCallbacks[index] = done
        return true
    end
    function store:FinishSave(index, ok, reason)
        return assert(self.saveCallbacks[index], "save callback missing")(ok, reason)
    end
    function store:FinishLoad(index, ok, data)
        return assert(self.loadCallbacks[index], "load callback missing")(ok, copy(data))
    end
    return Loop.New({ store = store }), store
end

local function finishFinalSettlement(decision)
    local loop, store = newLoop()
    local elder = loop.player.elder.circle1B2
    loop.player.day = Config.clock.maxDay
    elder.applesGiven = decision == "saved" and 3 or 0
    elder.decision = decision
    loop.player.story.circle1B2.paperShown = true
    eq(loop.player.story.circle1B2.runCompleted, false)
    assert(loop:EndToday())
    assert(loop:ConfirmSettlement())
    eq(loop.player.day, 7)
    eq(loop.player.story.circle1B2.runCompleted, true)
    eq(store.saves[1].story.circle1B2.runCompleted, true)
    store:FinishSave(1, true)
    eq(loop.endingPending, true)
    eq(loop.endingKind, decision == "saved" and "changed" or "normal")
    return copy(store.saves[1])
end

local function loadSnapshot(snapshot)
    local loop, store = newLoop()
    assert(loop:LoadSaved())
    store:FinishLoad(1, true, snapshot)
    return loop, store
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("terminal saves restore the normal and changed endings and block gameplay entries", function()
        for _, variant in ipairs({
            { decision = "dead", ending = "normal" },
            { decision = "saved", ending = "changed" },
        }) do
            local snapshot = finishFinalSettlement(variant.decision)
            local loop, store = loadSnapshot(snapshot)
            eq(loop.player.day, 7)
            eq(loop.player.story.circle1B2.runCompleted, true)
            eq(loop.endingPending, true)
            eq(loop.endingKind, variant.ending)
            eq(loop.settlementPending, false)
            eq(loop:GetStoryDialog(), nil)
            eq(loop.clock.pauseReasons.port, true)
            eq(loop.clock:IsPaused(), true)

            local before = Persistence.Snapshot(loop.player)
            eq(loop:Ready(), false)
            eq(loop:Depart(), false)
            eq(loop:CanStartAction("fishing"), false)
            eq(loop:EndToday(), false)
            eq(loop:SettleDay(), false)
            eq(loop:ConfirmSettlement(), false)
            eq(loop:ConfirmForcedReturn(), false)
            eq(loop:BeginNewDay(), false)
            eq(loop:RecognizeLocation("terminal-only-location"), false)
            eq(loop:LoadSaved(), false)
            local clockBefore = loop.clock:GetState()
            loop:Update(5, function() end)
            local clockAfter = loop.clock:GetState()
            eq(clockAfter.phase, clockBefore.phase)
            eq(clockAfter.elapsed, clockBefore.elapsed)
            eq(clockAfter.progress, clockBefore.progress)
            eq(#store.saves, 0)
            eq(#store.loadCallbacks, 1, "terminal LoadSaved rejects before a new request")
            eq(Persistence.Snapshot(loop.player).story.circle1B2.runCompleted, true)
            eq(Persistence.Snapshot(loop.player).day, before.day)
            eq(Persistence.Snapshot(loop.player).money, before.money)
        end
    end)

    test("schema-v1 missing markers default to false and old completed saves remain conservatively playable", function()
        eq(Config.persistence.schemaVersion, 1)
        for day = 1, 6 do
            local player = assert(PlayerState.New())
            player.day = day
            if day >= 4 then
                player.elder.circle1B2.applesGiven = 0
                player.elder.circle1B2.decision = "dead"
            end
            local snapshot = Persistence.Snapshot(player)
            snapshot.story.circle1B2.runCompleted = nil
            local restored = assert(Persistence.Restore(copy(snapshot)))
            eq(restored.day, day)
            eq(restored.story.circle1B2.runCompleted, false)
            local loop = loadSnapshot(snapshot)
            eq(loop.player.day, day)
            eq(loop.endingPending, false)
            eq(loop.player.story.circle1B2.runCompleted, false)
            if loop:GetStoryDialog() then
                local dialog = loop:GetStoryDialog()
                eq(day, 4)
                eq(dialog.kind, "elder_fate")
                assert(loop:NotifyStoryShown(dialog.token))
                assert(loop:CloseStoryDialog())
            end
            assert(loop:Ready())
        end

        local oldCompleted = finishFinalSettlement("dead")
        oldCompleted.story.circle1B2.runCompleted = nil
        local restored = assert(Persistence.Restore(copy(oldCompleted)))
        eq(restored.story.circle1B2.runCompleted, false)
        local loop = loadSnapshot(oldCompleted)
        eq(loop.endingPending, false)
        eq(loop.player.day, 7)
        assert(loop:Ready(), "legacy completion cannot be inferred from day, paper, or fate")
    end)

    test("invalid terminal marker combinations and day eight are rejected", function()
        local valid = finishFinalSettlement("saved")
        assert(Persistence.Restore(copy(valid)))

        local invalid = {
            { name = "nonboolean marker", mutate = function(data)
                data.story.circle1B2.runCompleted = 1
            end },
            { name = "completion before day seven", mutate = function(data)
                data.day = 6
                data.story.circle1B2.paperShown = false
            end },
            { name = "paper not confirmed", mutate = function(data)
                data.story.circle1B2.paperShown = false
            end },
            { name = "elder fate pending", mutate = function(data)
                data.elder.circle1B2.decision = "pending"
            end },
            { name = "invalid elder fate", mutate = function(data)
                data.elder.circle1B2.decision = "unknown"
            end },
            { name = "day eight", mutate = function(data)
                data.day = 8
            end },
        }
        for _, variant in ipairs(invalid) do
            local data = copy(valid)
            variant.mutate(data)
            eq(Persistence.Restore(data), nil, variant.name)
        end
    end)

    test("new run after a restored ending clears completion and saves a playable day one", function()
        local snapshot = finishFinalSettlement("saved")
        local loop, store = loadSnapshot(snapshot)
        eq(loop.endingPending, true)
        assert(loop:NewRun())
        eq(loop.player.day, 1)
        eq(loop.player.story.circle1B2.runCompleted, false)
        eq(loop.player.story.circle1B2.paperShown, false)
        eq(loop.endingPending, false)
        eq(loop.entryPending, true)
        eq(store.saves[1].day, 1)
        eq(store.saves[1].story.circle1B2.runCompleted, false)
        store:FinishSave(1, true)
        eq(loop.entryPending, false)
        assert(loop:Ready())
    end)

    local failed = 0
    for _, row in ipairs(results) do
        if not row.passed then failed = failed + 1 end
    end
    return { results = results, passed = failed == 0, failed = failed, checkCount = #results }
end

return Tests
