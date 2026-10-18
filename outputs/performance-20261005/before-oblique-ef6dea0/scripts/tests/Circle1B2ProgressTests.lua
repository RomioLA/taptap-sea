-- Circle 1B2 elder, daily-save, and paper-dialog integration tests.
local Flow = require("tests.Circle1BFishingFlowTests")
local Persistence = require("Gameplay.Persistence")
local Progress = require("Gameplay.Circle1B2Progress")

local Tests = {}

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function items(actual, expected, label)
    Flow.AssertItems(actual, expected, label)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function withPatched(target, key, createReplacement, run)
    local original = target[key]
    target[key] = createReplacement(original)
    local ok, err = xpcall(run, debug.traceback)
    target[key] = original
    if not ok then error(err, 0) end
end

local function memoryStore()
    local store = { writes = 0, data = nil, failNext = false }
    function store:Save(snapshot, done)
        self.writes = self.writes + 1
        if self.failNext then
            self.failNext = false
            if done then done(false, "injected_offline") end
            return
        end
        self.data = copy(snapshot)
        if done then done(true) end
    end
    function store:Load(done)
        if self.data == nil then
            if done then done(false, "memory_store_empty") end
            return
        end
        if done then done(true, copy(self.data)) end
    end
    return store
end

local function advanceDay(loop, store, failSave)
    assert(loop:EndToday())
    if failSave then store.failNext = true end
    assert(loop:ConfirmSettlement())
end

local function findItem(inventory, wanted)
    for index, itemId in ipairs(inventory:GetItems()) do
        if itemId == wanted then return index end
    end
    return nil
end

local function giftApple(loop)
    local index = assert(findItem(loop.player.inventory, "apple") or (function()
        assert(loop.player.inventory:Add("apple"))
        return findItem(loop.player.inventory, "apple")
    end)())
    assert(loop:SetElderOpen(true))
    local stamina = loop.player.stamina
    local accepted, message = loop:GiveToElder(index)
    assert(accepted and type(message) == "string")
    eq(loop.player.stamina, stamina, "giving food must not restore stamina")
    assert(loop:SetElderOpen(false))
end

local function giftApples(loop, count)
    local appleCount = 0
    for _, itemId in ipairs(loop.player.inventory:GetItems()) do
        if itemId == "apple" then appleCount = appleCount + 1 end
    end
    while appleCount < count do
        assert(loop.player.inventory:Add("apple"))
        appleCount = appleCount + 1
    end
    assert(loop:SetElderOpen(true))
    local stamina = loop.player.stamina
    for _ = 1, count do
        local accepted, message = loop:GiveToElder(assert(findItem(loop.player.inventory, "apple")))
        assert(accepted and type(message) == "string")
    end
    eq(loop.player.stamina, stamina, "giving food must not restore stamina")
    assert(loop:SetElderOpen(false))
end

local function decideElder(giftDays)
    local fixture = Flow.Fixture()
    for day = 1, 3 do
        if giftDays[day] then giftApple(fixture.loop) end
        if day < 3 then advanceDay(fixture.loop, fixture.store) end
    end
    advanceDay(fixture.loop, fixture.store) -- Day 3 settles into Day 4.
    return fixture
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("elder counts food apples, displays other offerings without consuming them, and saves after three days", function()
        local fixture = Flow.Fixture({ items = { "apple", "bait", "sardine", "tuna", "sardine" } })
        local loop = fixture.loop
        loop.player.stamina = 50
        loop.player.treasures.scopeLens = true
        local before = loop.player.inventory:GetItems()
        assert(loop:IsElderPresent())
        local status = loop:GetElderStatus()
        eq(status.applesGiven, 0)
        eq(status.decision, "pending")
        assert(status.present)
        assert(loop:SetElderOpen(true))

        assert(loop:GiveToElder(2)) -- bait is shown, not consumed
        items(loop.player.inventory:GetItems(), before, "bait display")
        assert(loop:GiveToElder(3)) -- fish is shown, not consumed
        items(loop.player.inventory:GetItems(), before, "fish display")
        assert(loop:GiveTreasureToElder("scopeLens"))
        assert(loop.player.treasures.scopeLens)
        items(loop.player.inventory:GetItems(), before, "lens display")

        assert(loop:GiveToElder(1)) -- apple is food: count it, do not use its heal effect
        eq(loop.player.stamina, 50)
        eq(loop:GetElderStatus().applesGiven, 1)
        assert(loop:SetElderOpen(false))
        advanceDay(loop, fixture.store)

        giftApple(loop)
        eq(loop:GetElderStatus().applesGiven, 2)
        advanceDay(loop, fixture.store)
        giftApple(loop)
        eq(loop:GetElderStatus().applesGiven, 3)
        eq(loop:GetElderStatus().decision, "pending")
        advanceDay(loop, fixture.store)

        eq(loop.player.day, 4)
        status = loop:GetElderStatus()
        eq(status.applesGiven, 3)
        eq(status.decision, "saved")
        assert(status.present and loop:IsElderPresent())
        eq(loop:GetElderStatus().decision, "saved", "the day-four decision is stable")
    end)

    test("elder who received fewer than three apples is marked dead once on day four", function()
        local fixture = decideElder({ [1] = true, [3] = true })
        local loop = fixture.loop
        eq(loop.player.day, 4)
        local status = loop:GetElderStatus()
        eq(status.applesGiven, 2)
        eq(status.decision, "dead")
        eq(status.present, false)
        eq(loop:IsElderPresent(), false)
        eq(loop:GetElderStatus().decision, "dead", "the day-four decision must not be recomputed")
        local opened = loop:SetElderOpen(true)
        eq(opened, false)
    end)

    test("failed apple progress rolls back the removed apple, stamina, and prior count", function()
        local failures = {
            { name = "rejected", fail = function(player)
                player.elder.circle1B2.applesGiven = player.elder.circle1B2.applesGiven + 1
                return false, "injected_record_rejection"
            end },
            { name = "thrown", fail = function(player)
                player.elder.circle1B2.applesGiven = player.elder.circle1B2.applesGiven + 1
                error("injected_record_error")
            end },
        }

        for _, case in ipairs(failures) do
            local fixture = Flow.Fixture({ items = { "apple", "bait" } })
            local loop = fixture.loop
            loop.player.stamina = 37
            local beforeItems = loop.player.inventory:GetItems()
            assert(loop:SetElderOpen(true))

            withPatched(Progress, "RecordApple", function()
                return case.fail
            end, function()
                local accepted, reason = loop:GiveToElder(1)
                eq(accepted, false, case.name .. " record result")
                eq(reason, "elder_progress_failed", case.name .. " rollback reason")
                items(loop.player.inventory:GetItems(), beforeItems, case.name .. " inventory rollback")
                eq(loop.player.stamina, 37, case.name .. " stamina rollback")
                eq(loop.player.elder.circle1B2.applesGiven, 0, case.name .. " count rollback")
                eq(loop.player.elder.lastGivenItemId, nil, case.name .. " no gift receipt")
                eq(loop.inventoryRollback, nil, case.name .. " rollback completed")
                eq(loop.dropInFlight, false, case.name .. " single-flight released")
            end)
            assert(loop:SetElderOpen(false))
        end
    end)

    test("three apples offered on day one are counted cumulatively until day-four decision", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        giftApples(loop, 3)
        eq(loop:GetElderStatus().applesGiven, 3)
        eq(loop:GetElderStatus().decision, "pending")
        advanceDay(loop, fixture.store)
        advanceDay(loop, fixture.store)
        advanceDay(loop, fixture.store)
        eq(loop.player.day, 4)
        eq(loop:GetElderStatus().decision, "saved")
    end)

    test("three apples offered on day three still save the elder on day four", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        advanceDay(loop, fixture.store)
        advanceDay(loop, fixture.store)
        giftApples(loop, 3)
        eq(loop:GetElderStatus().applesGiven, 3)
        eq(loop:GetElderStatus().decision, "pending")
        advanceDay(loop, fixture.store)
        eq(loop.player.day, 4)
        eq(loop:GetElderStatus().decision, "saved")
    end)

    test("zero apples leave the elder dead after the one-time day-four decision", function()
        local fixture = decideElder({})
        local status = fixture.loop:GetElderStatus()
        eq(status.applesGiven, 0)
        eq(status.decision, "dead")
        eq(status.present, false)
    end)

    test("memory save retries once without double-advancing and restores progress through day seven", function()
        local store = memoryStore()
        local fixture = Flow.Fixture({ store = store })
        local loop = fixture.loop
        loop.player.elder.circle1B2.applesGiven = 3
        loop.player.elder.circle1B2.decision = "pending"
        loop.player.treasures.scopeLens = true
        loop.player.story.circle1B2 = { barrelStage = 2, paperShown = false }

        for day = 1, 6 do
            eq(loop.player.day, day)
            advanceDay(loop, store, day == 3)
            if day == 3 then
                eq(loop.player.day, 4)
                eq(loop.saveStatus, "error")
                eq(loop.settlementSnapshot.day, 4)
                assert(loop:ConfirmSettlement())
                eq(loop.player.day, 4, "save retry must not advance another day")
                eq(loop.saveStatus, "saved")
            end
            eq(loop.player.day, day + 1)
        end

        eq(loop.player.day, 7)
        eq(store.data.day, 7)
        eq(store.writes, 7, "six transitions with one failed save and one retry")
        local restored = Flow.Fixture({ store = store })
        local loadResult, loadError
        assert(restored.loop:LoadSaved(function(ok, err)
            loadResult, loadError = ok, err
        end))
        assert(loadResult, tostring(loadError))
        eq(restored.loop.player.day, 7)
        eq(restored.loop.player.elder.circle1B2.applesGiven, 3)
        eq(restored.loop.player.elder.circle1B2.decision, "saved")
        assert(restored.loop.player.treasures.scopeLens)
        eq(restored.loop.player.story.circle1B2.barrelStage, 2)
        eq(restored.loop.player.story.circle1B2.paperShown, false)
    end)

    test("progress validation rejects malformed and inconsistent saved states", function()
        local source = Flow.Fixture()
        local validSnapshot = Persistence.Snapshot(source.loop.player)
        local invalidCases = {
            { name = "negative elder count", reason = "invalid_elder_apples_given",
                mutate = function(data) data.elder.circle1B2.applesGiven = -1 end },
            { name = "fractional elder count", reason = "invalid_elder_apples_given",
                mutate = function(data) data.elder.circle1B2.applesGiven = 1.5 end },
            { name = "missing elder count", reason = "invalid_elder_apples_given",
                mutate = function(data) data.elder.circle1B2.applesGiven = nil end },
            { name = "unknown elder decision", reason = "invalid_elder_decision",
                mutate = function(data) data.elder.circle1B2.decision = "unknown" end },
            { name = "missing elder decision", reason = "invalid_elder_decision",
                mutate = function(data) data.elder.circle1B2.decision = nil end },
            { name = "saved before day four", reason = "invalid_elder_decision_day",
                mutate = function(data)
                    data.elder.circle1B2.applesGiven = 3
                    data.elder.circle1B2.decision = "saved"
                end },
            { name = "dead before day four", reason = "invalid_elder_decision_day",
                mutate = function(data) data.elder.circle1B2.decision = "dead" end },
            { name = "saved below the three apple threshold", reason = "invalid_elder_saved_count",
                mutate = function(data)
                    data.day = 4
                    data.elder.circle1B2.applesGiven = 2
                    data.elder.circle1B2.decision = "saved"
                end },
            { name = "dead at the three apple threshold", reason = "invalid_elder_dead_count",
                mutate = function(data)
                    data.day = 4
                    data.elder.circle1B2.applesGiven = 3
                    data.elder.circle1B2.decision = "dead"
                end },
            { name = "missing barrel stage", reason = "invalid_barrel_stage",
                mutate = function(data) data.story.circle1B2.barrelStage = nil end },
            { name = "barrel stage above three", reason = "invalid_barrel_stage",
                mutate = function(data) data.story.circle1B2.barrelStage = 4 end },
            { name = "missing paper flag", reason = "invalid_paper_shown",
                mutate = function(data) data.story.circle1B2.paperShown = nil end },
            { name = "nonboolean paper flag", reason = "invalid_paper_shown",
                mutate = function(data) data.story.circle1B2.paperShown = 0 end },
            { name = "paper shown before day seven", reason = "paper_shown_before_day_seven",
                mutate = function(data) data.story.circle1B2.paperShown = true end },
            { name = "final barrel stage without lens", reason = "final_barrel_stage_requires_lens",
                mutate = function(data) data.story.circle1B2.barrelStage = 3 end },
        }

        for _, invalid in ipairs(invalidCases) do
            local snapshot = copy(validSnapshot)
            invalid.mutate(snapshot)
            local valid, validationReason = Progress.Validate(snapshot)
            eq(valid, false, invalid.name .. " validation")
            eq(validationReason, invalid.reason, invalid.name .. " validation reason")
            local restored, restoreReason = Persistence.Restore(snapshot)
            eq(restored, nil, invalid.name .. " restore")
            eq(restoreReason, invalid.reason, invalid.name .. " restore reason")
        end

        local positive = copy(validSnapshot)
        positive.day = 4
        positive.elder.circle1B2.applesGiven = 8 -- no upper count limit
        positive.elder.circle1B2.decision = "saved"
        positive.story.circle1B2.barrelStage = 1
        positive.treasures.scopeLens = true -- lens ownership is valid before stage three
        assert(Progress.Validate(positive))
        assert(Persistence.Restore(positive))

        positive.day = 7
        positive.elder.circle1B2.applesGiven = 3
        positive.story.circle1B2.barrelStage = 3
        positive.story.circle1B2.paperShown = true
        assert(Progress.Validate(positive))
        assert(Persistence.Restore(positive))
    end)

    test("legacy snapshots preserve unknown progress while filling missing circle records", function()
        local fixture = Flow.Fixture()
        local legacy = Persistence.Snapshot(fixture.loop.player)
        legacy.elder = { legacyNote = "keep elder note" }
        legacy.story = { legacyChapter = 12 }
        legacy.treasures.legacyToken = true
        legacy.recognizedLocations.oldHarbor = true

        local restored, restoreError = Persistence.Restore(legacy)
        assert(restored, tostring(restoreError))
        eq(restored.elder.legacyNote, "keep elder note")
        eq(restored.elder.circle1B2.applesGiven, 0)
        eq(restored.elder.circle1B2.decision, "pending")
        eq(restored.story.legacyChapter, 12)
        eq(restored.story.circle1B2.barrelStage, 0)
        eq(restored.story.circle1B2.paperShown, false)
        assert(restored.treasures.legacyToken)
        assert(restored.recognizedLocations.oldHarbor)
    end)

    test("snapshot failure keeps the applied day-four decision and retries without advancing twice", function()
        local store = memoryStore()
        local fixture = Flow.Fixture({ store = store })
        local loop = fixture.loop
        advanceDay(loop, store)
        advanceDay(loop, store)
        eq(loop.player.day, 3)

        local originalSnapshot = Persistence.Snapshot
        Persistence.Snapshot = function() error("injected_snapshot_failure") end
        local callOk, result, reason = pcall(function()
            assert(loop:EndToday())
            local ok, err = loop:ConfirmSettlement()
            return ok, err
        end)
        Persistence.Snapshot = originalSnapshot
        assert(callOk, tostring(result))
        eq(result, false)
        eq(reason, "settlement_snapshot_failed")
        eq(loop.player.day, 4)
        eq(loop.player.elder.circle1B2.decision, "dead")
        eq(loop.settlementApplied, true)
        eq(loop.settlementSnapshot, nil)
        eq(loop.saveStatus, "error")

        assert(loop:ConfirmSettlement())
        eq(loop.player.day, 4, "snapshot retry must not advance a second day")
        eq(loop.player.elder.circle1B2.decision, "dead", "day-four decision is not repeated")
        eq(loop.saveStatus, "saved")
        eq(store.data.day, 4)
        eq(store.writes, 3)
    end)

    test("day-seven paper opens only explicitly, acknowledgement round-trips without auto-saving", function()
        local store = memoryStore()
        local fixture = Flow.Fixture({ store = store })
        local loop = fixture.loop
        for day = 1, 5 do advanceDay(loop, store) end
        eq(loop.player.day, 6)
        local earlyOpen, earlyOpenReason = loop:OpenDay7PaperBeforeEnding()
        eq(earlyOpen, false)
        eq(earlyOpenReason, "paper_day_required")
        local earlyMark, earlyMarkReason = Progress.MarkPaperShown(loop.player)
        eq(earlyMark, false)
        eq(earlyMarkReason, "paper_not_available_today")
        eq(loop.player.story.circle1B2.paperShown, false)
        advanceDay(loop, store)
        eq(loop.player.day, 7)
        eq(loop:GetStoryDialog(), nil, "day start must not auto-open the paper")
        local writesBeforePaper = store.writes

        assert(loop:OpenDay7PaperBeforeEnding())
        local dialog = assert(loop:GetStoryDialog())
        eq(dialog.kind, "paper")
        eq(dialog.text, "海岸边那只木桶，下面一定有什么东西，我想多打捞几次就能打捞上来吧。")
        local token = dialog.token
        assert(type(token) == "table")
        assert(loop:NotifyStoryShown(token))
        assert(loop.player.story.circle1B2.paperShown)
        eq(store.writes, writesBeforePaper, "paper acknowledgement is not an implicit save")
        assert(loop:CloseStoryDialog())
        eq(loop:GetStoryDialog(), nil)

        -- Acknowledgement changes live progress, while day-seven progress persists only
        -- through the explicit snapshot/settlement save path.
        eq(store.data.story.circle1B2.paperShown, false)
        local acknowledgedSnapshot = Persistence.Snapshot(loop.player)
        local restoredPlayer, restoreError = Persistence.Restore(acknowledgedSnapshot)
        assert(restoredPlayer, tostring(restoreError))
        assert(restoredPlayer.story.circle1B2.paperShown)
        local restoreStore = memoryStore()
        restoreStore.data = copy(acknowledgedSnapshot)
        local restored = Flow.Fixture({ store = restoreStore })
        local loadResult, loadError
        assert(restored.loop:LoadSaved(function(ok, err)
            loadResult, loadError = ok, err
        end))
        assert(loadResult, tostring(loadError))
        eq(restored.loop.player.day, 7)
        assert(restored.loop.player.story.circle1B2.paperShown)
        eq(restored.loop:GetStoryDialog(), nil)
        local reopened, reopenReason = restored.loop:OpenDay7PaperBeforeEnding()
        eq(reopened, false); eq(reopenReason, "paper_already_shown")
        eq(restored.loop:GetStoryDialog(), nil)
        local secondLoad
        assert(restored.loop:LoadSaved(function(ok) secondLoad = ok end))
        assert(secondLoad)
        eq(restored.loop:GetStoryDialog(), nil)
    end)

    return { results = results }
end

return Tests
