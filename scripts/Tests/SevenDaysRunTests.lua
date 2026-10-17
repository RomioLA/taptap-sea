-- Boundary and persistence regressions for the seven-day run contract.
-- These tests use the real Gameplay modules and a controllable asynchronous store.
local Config = require("config.gameplay")
local Loop = require("Gameplay.Loop")
local Player = require("Gameplay.PlayerState")
local Persistence = require("Gameplay.Persistence")
local Progress = require("Gameplay.Circle1B2Progress")

local Tests = {}
local PAPER_TEXT = "海岸边那只木桶，下面一定有什么东西，我想多打捞几次就能打捞上来吧。"

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

local function same(actual, expected, label)
    label = label or "table"
    eq(type(actual), type(expected), label .. " type")
    if type(expected) ~= "table" then
        eq(actual, expected, label)
        return
    end
    for key, value in pairs(expected) do same(actual[key], value, label .. "." .. tostring(key)) end
    for key in pairs(actual) do
        assert(expected[key] ~= nil, label .. " has unexpected key " .. tostring(key))
    end
end

local function makeStore()
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
        local callback = assert(self.saveCallbacks[index], "save callback missing: " .. tostring(index))
        return callback(ok, reason)
    end
    function store:FinishLoad(index, ok, data)
        local callback = assert(self.loadCallbacks[index], "load callback missing: " .. tostring(index))
        return callback(ok, copy(data))
    end
    return store
end

local function newLoop(options)
    options = options or {}
    local store = makeStore()
    options.store = store
    return Loop.New(options), store
end

local function finishNormalDay(loop, store, day)
    eq(loop.player.day, day, "day before normal settlement")
    assert(loop:Depart())
    assert(loop:ReturnToPort())
    assert(loop:EndToday())
    assert(loop:ConfirmSettlement())
    eq(loop.player.day, day + 1, "normal day advances once")
    eq(loop.settlementFinal, false, "ordinary day is not final")
    store:FinishSave(#store.saves, true)
    eq(loop.settlementPending, false, "ordinary settlement closes after save")
end

local function advanceToDay(loop, store, targetDay)
    while loop.player.day < targetDay do
        finishNormalDay(loop, store, loop.player.day)
    end
end

local function preparePaper(loop)
    local dialog = loop:GetStoryDialog()
    assert(dialog and dialog.kind == "paper", "day seven paper must be the active story dialog")
    eq(dialog.text, PAPER_TEXT, "existing paper copy")
    eq(Progress.IsPaperShown(loop.player), false, "paper is not persisted before it is shown")
    assert(loop:NotifyStoryShown(dialog.token), "visible paper should be acknowledged")
    eq(Progress.IsPaperShown(loop.player), true, "paper acknowledgement marks the current run")
    assert(loop:CloseStoryDialog(), "shown paper can close")
    eq(loop:GetStoryDialog(), nil, "paper dialog closes once acknowledged")
    return dialog.text
end

local function markDaySeven(loop)
    loop.player.day = Config.totalDays
    assert(Progress.OnDayStarted(loop.player))
end

local function configureFinalResources(loop)
    loop.player.stamina, loop.player.maxStamina = 63, 160
    loop.player.money = 777
    loop.player.boatSpeedLevel = 3
    assert(loop.player.inventory:Upgrade())
    assert(loop.player.inventory:Upgrade())
    assert(loop.player.inventory:Add("sardine"))
    assert(loop.player:MarkRecognized("reef-east"))
    assert(Progress.GrantLens(loop.player))
    loop.player.treasures.wreckFound = true
    assert(Progress.SetBarrelStage(loop.player, 2))
    loop.player.story.chapter = 4
    loop.player.elder.circle1B2.applesGiven = 3
    loop.player.elder.circle1B2.decision = "saved"
    loop.shopStock.apple = 1
    loop.shopStock.bait = 0
end

local function daySevenSnapshot()
    local player = assert(Player.New())
    player.day, player.stamina, player.maxStamina, player.money = 7, 83, 200, 1250
    player.boatSpeedLevel = 3
    assert(player.inventory:Upgrade())
    assert(player.inventory:Upgrade())
    assert(player.inventory:Add("tuna"))
    assert(player:MarkRecognized("saved-reef"))
    assert(Progress.GrantLens(player))
    player.treasures.wreckFound = true
    player.story.chapter = 6
    assert(Progress.SetBarrelStage(player, 3))
    player.elder.circle1B2.applesGiven = 3
    player.elder.circle1B2.decision = "saved"
    assert(Progress.MarkPaperShown(player))
    return Persistence.Snapshot(player)
end

local cases = {}

cases[#cases + 1] = {
    name = "normal seven-day cycle reaches a terminal day-seven save without recovery",
    run = function()
        local preparedDays = {}
        local loop, store = newLoop({ onNewDay = function(day)
            preparedDays[#preparedDays + 1] = day
        end })
        advanceToDay(loop, store, Config.totalDays)
        eq(loop.player.day, 7, "six normal transitions reach day seven")
        eq(#preparedDays, 6, "each saved ordinary transition prepares one next day")
        configureFinalResources(loop)
        local before = Persistence.Snapshot(loop.player)

        assert(loop:EndToday(), "day-seven end must enter final settlement")
        eq(loop.settlementPending, true, "paper presentation holds final settlement")
        local dialog = loop:GetStoryDialog()
        assert(dialog and dialog.kind == "paper")
        eq(dialog.text, PAPER_TEXT)
        eq(Progress.IsPaperShown(loop.player), false)
        eq(#store.saves, 6, "opening the paper must not save or advance")
        eq(loop:CloseStoryDialog(), false, "unread paper cannot be closed around final settlement")
        assert(loop:GetStoryDialog(), "rejected close leaves paper visible")
        eq(loop:ConfirmSettlement(), false, "settlement cannot bypass the visible paper")
        eq(#store.saves, 6)

        assert(loop:NotifyStoryShown(dialog.token))
        assert(loop:CloseStoryDialog())
        local finalState = Persistence.Snapshot(loop.player)
        assert(finalState.story.circle1B2.paperShown)
        assert(loop:ConfirmSettlement(), "read paper permits final save")
        eq(loop.player.day, 7, "final settlement keeps day seven")
        eq(loop.player.stamina, before.stamina, "final settlement does not restore stamina")
        eq(loop.player.money, before.money, "final settlement keeps money")
        eq(loop.player.maxStamina, before.maxStamina)
        eq(loop.player.boatSpeedLevel, before.boatSpeedLevel)
        same(Persistence.Snapshot(loop.player), finalState, "live final state")
        eq(#store.saves, 7, "one final snapshot is written")
        same(store.saves[7], finalState, "day-seven final snapshot")
        eq(store.saves[7].day, 7)
        eq(store.saves[7].story.circle1B2.paperShown, true)
        eq(store.saves[7].runEndPending, nil, "runtime ending boundary is not persisted")
        eq(store.saves[7].finished, nil, "no invented completion schema")
        eq(store.saves[7].endingId, nil, "no invented ending identifier")

        store:FinishSave(7, true)
        eq(loop:IsRunEndPending(), true, "successful final save reaches runtime end boundary")
        eq(loop:Ready(), false, "run-end boundary blocks gameplay")
        eq(loop.clock.pauseReasons.run_end, true, "run-end boundary owns a pause reason")
        eq(#preparedDays, 6, "final day never calls the next-day preparation hook")
        eq(loop:GetShopStock("apple"), 1, "final day does not refresh shop stock")
        eq(loop:GetShopStock("bait"), 0)
        store:FinishSave(7, false, "duplicate final callback")
        eq(loop:IsRunEndPending(), true, "duplicate final callback cannot undo completion")
        eq(loop.saveStatus, "saved", "duplicate final callback cannot overwrite save status")
        eq(loop.player.day, 7, "duplicate final callback cannot advance the day")
        eq(#preparedDays, 6)

        local clockBefore = loop.clock:GetState()
        loop:Update(300)
        local clockAfter = loop.clock:GetState()
        eq(clockAfter.phase, clockBefore.phase, "run-end Update phase")
        eq(clockAfter.elapsed, clockBefore.elapsed, "run-end Update elapsed")
        eq(clockAfter.duration, clockBefore.duration, "run-end Update duration")
        eq(clockAfter.progress, clockBefore.progress, "run-end Update progress")
        eq(clockAfter.remaining, clockBefore.remaining, "run-end Update remaining")
        return {
            day = loop.player.day, stamina = loop.player.stamina, maxStamina = loop.player.maxStamina,
            money = loop.player.money, saves = #store.saves, nextDayHooks = #preparedDays,
            paperShown = store.saves[7].story.circle1B2.paperShown,
            runEndPaused = loop.clock.pauseReasons.run_end == true,
        }
    end,
}

cases[#cases + 1] = {
    name = "forced day-seven return opens the same paper and cannot skip its read acknowledgement",
    run = function()
        local nextDays = {}
        local loop, store = newLoop({ onNewDay = function(day)
            nextDays[#nextDays + 1] = day
        end })
        markDaySeven(loop)
        loop.player.stamina = 41
        assert(loop:Depart())
        loop:Update(Config.clock.daySec + Config.clock.nightSec)
        eq(loop.forcedReturnPending, true, "night end requests forced return")
        assert(loop:ConfirmForcedReturn(), "forced return enters final settlement and paper flow")
        eq(loop.settlementPending, true)
        eq(loop.settlementForced, true)
        eq(loop.settlementApplied, false, "day-seven settlement waits for the story read")
        eq(#store.saves, 0, "forced return cannot save past the unread paper")
        local dialog = loop:GetStoryDialog()
        assert(dialog and dialog.kind == "paper")
        eq(dialog.text, PAPER_TEXT)
        eq(Progress.IsPaperShown(loop.player), false)
        eq(loop:CloseStoryDialog(), false)
        eq(loop:ConfirmSettlement(), false, "confirm cannot bypass an open paper dialog")
        eq(#store.saves, 0)

        assert(loop:NotifyStoryShown(dialog.token))
        assert(loop:CloseStoryDialog())
        assert(loop:ConfirmSettlement())
        eq(#store.saves, 1)
        eq(loop.player.day, 7)
        eq(loop.player.stamina, 41, "forced final settlement has no next-day half-stamina recovery")
        store:FinishSave(1, true)
        eq(loop:IsRunEndPending(), true)
        eq(#nextDays, 0, "forced final settlement has no next day hook")
        eq(loop:EndToday(), false, "the shown paper and final save are not replayable")
        eq(loop:GetStoryDialog(), nil, "paper is presented once in the run")
        local saveCount = #store.saves
        local clockBefore = loop.clock:GetState()
        loop:Update(300)
        local clockAfter = loop.clock:GetState()
        eq(loop.forcedReturnPending, false, "run-end update cannot re-enter forced return")
        eq(loop:GetStoryDialog(), nil, "run-end update cannot reopen the paper")
        eq(#store.saves, saveCount, "run-end update cannot start another save")
        eq(clockAfter.phase, clockBefore.phase)
        eq(clockAfter.elapsed, clockBefore.elapsed)
        eq(clockAfter.progress, clockBefore.progress)
        return { day = loop.player.day, stamina = loop.player.stamina, saves = #store.saves,
            nextDayHooks = #nextDays, paperShown = Progress.IsPaperShown(loop.player) }
    end,
}

cases[#cases + 1] = {
    name = "final save retry reuses the day-seven snapshot and never advances or refreshes",
    run = function()
        local nextDays = {}
        local loop, store = newLoop({ onNewDay = function(day)
            nextDays[#nextDays + 1] = day
        end })
        markDaySeven(loop)
        configureFinalResources(loop)
        assert(loop:EndToday())
        local paper = loop:GetStoryDialog()
        assert(paper and loop:NotifyStoryShown(paper.token))
        assert(loop:CloseStoryDialog())
        local before = Persistence.Snapshot(loop.player)
        assert(loop:ConfirmSettlement())
        eq(loop.player.day, 7)
        store:FinishSave(1, false, "offline")
        eq(loop.saveStatus, "error")
        eq(loop.settlementPending, true)
        eq(loop.settlementFinal, true)
        eq(loop.player.day, 7)
        same(Persistence.Snapshot(loop.player), before, "resources after failed final save")
        eq(#nextDays, 0)

        assert(loop:ConfirmSettlement(), "failed final save can retry")
        eq(#store.saves, 2)
        same(store.saves[1], store.saves[2], "final retry snapshot")
        store:FinishSave(2, true)
        eq(loop.saveStatus, "saved")
        eq(loop.player.day, 7)
        same(Persistence.Snapshot(loop.player), before, "resources after successful final retry")
        eq(loop:GetShopStock("apple"), 1, "retry does not refresh stock")
        eq(loop:GetShopStock("bait"), 0)
        eq(#nextDays, 0, "final retry never prepares day eight")
        assert(loop:IsRunEndPending())
        return { day = loop.player.day, saveAttempts = #store.saves,
            saveStatus = loop.saveStatus, nextDayHooks = #nextDays }
    end,
}

cases[#cases + 1] = {
    name = "day-six save skip enters playable day seven without final-run state",
    run = function()
        local nextDays = {}
        local loop, store = newLoop({ onNewDay = function(day)
            nextDays[#nextDays + 1] = day
        end })
        advanceToDay(loop, store, 6)
        eq(#nextDays, 5)
        loop.shopStock.apple = 0
        assert(loop:Depart())
        assert(loop:ReturnToPort())
        assert(loop:EndToday())
        assert(loop:ConfirmSettlement())
        eq(loop.player.day, 7)
        eq(loop.settlementFinal, false, "day-six settlement remains an ordinary transition")
        eq(Progress.IsPaperShown(loop.player), false, "day-six transition does not show final paper")
        eq(loop:GetStoryDialog(), nil)
        store:FinishSave(6, false, "offline")
        eq(loop.saveStatus, "error")
        local daySevenStamina = loop.player.stamina
        local appleStock = loop:GetShopStock("apple")
        assert(loop:ContinueWithoutSaving(), "explicitly skipping an ordinary save enters day seven")
        eq(loop.player.day, 7)
        eq(loop.player.stamina, daySevenStamina, "skip does not restore stamina a second time")
        eq(loop:GetShopStock("apple"), appleStock, "skip does not refresh stock a second time")
        eq(loop.settlementFinal, false)
        eq(loop:IsRunEndPending(), false, "day seven is not the run-end boundary")
        eq(loop.clock.pauseReasons.run_end, nil)
        eq(#nextDays, 6, "one day-seven preparation hook")
        store:FinishSave(6, true, "late success")
        eq(loop.saveStatus, "skipped", "late ordinary callback cannot undo explicit skip")
        eq(loop.player.day, 7)
        eq(#nextDays, 6)
        assert(loop:Ready())
        assert(loop:Depart(), "skipped day-six save leaves day seven playable")
        assert(loop:ReturnToPort())
        assert(loop:EndToday(), "only ending day seven opens the forced paper")
        local paper = loop:GetStoryDialog()
        assert(paper and paper.kind == "paper")
        eq(paper.text, PAPER_TEXT)
        return { day = loop.player.day, finalSettlement = loop.settlementFinal,
            runEndPending = loop:IsRunEndPending(), nextDayHooks = #nextDays,
            paperShownBeforeRead = Progress.IsPaperShown(loop.player) }
    end,
}

cases[#cases + 1] = {
    name = "day-eight save data is rejected intact while a loaded day-seven save remains playable",
    run = function()
        local savedDaySeven = daySevenSnapshot()
        local invalidDayEight = copy(savedDaySeven)
        invalidDayEight.day = Config.totalDays + 1

        local badPlayer = assert(Player.New())
        badPlayer.day = Config.totalDays + 1
        local snapshotOk, snapshotError = pcall(Persistence.Snapshot, badPlayer)
        eq(snapshotOk, false, "Snapshot rejects day eight")
        assert(tostring(snapshotError):find("invalid_run_day", 1, true))
        local restored, restoreError = Persistence.Restore(invalidDayEight)
        eq(restored, nil, "Restore rejects day eight without truncating it")
        eq(restoreError, "invalid_run_day")

        local loop, store = newLoop()
        loop.player.money, loop.player.stamina = 333, 27
        assert(loop.player:MarkRecognized("keep-on-bad-load"))
        local original = loop.player
        local before = Persistence.Snapshot(original)
        local completions = {}
        assert(loop:LoadSaved(function(ok, reason)
            completions[#completions + 1] = { ok = ok, reason = reason }
        end))
        store:FinishLoad(1, true, invalidDayEight)
        eq(#completions, 1)
        eq(completions[1].ok, false)
        eq(loop.player, original, "invalid load retains the original player object")
        same(Persistence.Snapshot(loop.player), before, "invalid load keeps original state")
        eq(loop.loading, false)
        local invalidLoadPreservedPlayer = loop.player == original

        assert(loop:LoadSaved())
        store:FinishLoad(2, true, savedDaySeven)
        eq(loop.player.day, 7)
        eq(Progress.IsPaperShown(loop.player), true, "paper-read state survives day-seven restore")
        eq(loop:IsRunEndPending(), false, "terminal status is runtime-only")
        eq(loop.runEndPending, false)
        eq(loop:Ready(), true, "paperShown alone does not block a loaded day-seven run")
        assert(loop:Depart(), "restored day seven remains playable")
        assert(loop:ReturnToPort())
        assert(loop:EndToday(), "paperShown prevents a second paper presentation")
        eq(loop:GetStoryDialog(), nil, "a previously shown paper is not presented twice")
        eq(loop.settlementPending, true)

        assert(savedDaySeven.runEndPending == nil and savedDaySeven.finished == nil
            and savedDaySeven.endingId == nil,
            "current persistence schema must not invent an ending or terminal marker")
        return {
            invalidDay = invalidDayEight.day,
            invalidLoadPreservedPlayer = invalidLoadPreservedPlayer,
            loadedDay = loop.player.day,
            paperShown = Progress.IsPaperShown(loop.player),
            loadedDaySevenPlayable = true,
            terminalPersistence = "unresolved: paperShown is readable but cannot distinguish a finished final settlement",
        }
    end,
}

cases[#cases + 1] = {
    name = "new run resets all run state, retries its initial save, and ignores stale final callbacks",
    run = function()
        local nextDays = {}
        local loop, store = newLoop({ onNewDay = function(day)
            nextDays[#nextDays + 1] = day
        end })
        markDaySeven(loop)
        configureFinalResources(loop)
        loop.player.elder.lastGivenItemId = "apple"
        loop.player.story.campaignMarker = "old-run"
        assert(loop:EndToday())
        local paper = loop:GetStoryDialog()
        assert(paper and loop:NotifyStoryShown(paper.token))
        assert(loop:CloseStoryDialog())
        local finalState = Persistence.Snapshot(loop.player)
        local finalStock = { apple = loop:GetShopStock("apple"), bait = loop:GetShopStock("bait") }
        assert(loop:ConfirmSettlement())
        assert(loop:ContinueWithoutSaving(), "final save can be explicitly skipped")
        assert(loop:IsRunEndPending())
        eq(loop.saveStatus, "skipped")
        eq(loop.player.day, 7, "skipping final save keeps day seven")
        same(Persistence.Snapshot(loop.player), finalState, "final skip preserves the day-seven state")
        eq(loop:GetShopStock("apple"), finalStock.apple, "final skip does not refresh stock")
        eq(loop:GetShopStock("bait"), finalStock.bait)
        eq(#nextDays, 0, "final skip does not prepare another day")

        assert(loop:NewRun(), "the existing new-run entry works after the run-end boundary")
        eq(loop:IsRunEndPending(), false)
        eq(loop.entryPending, true)
        eq(loop.initialSaveStatus, "saving")
        eq(loop.clock.pauseReasons.entry, true)
        eq(loop.player.day, 1)
        eq(loop.player.money, Config.initial.money)
        eq(loop.player.stamina, Config.initial.stamina)
        eq(loop.player.maxStamina, Config.initial.maxStamina)
        eq(loop.player.boatSpeedLevel, 1)
        eq(loop.player.inventory:GetLevel(), 1)
        eq(loop.player.inventory:GetCapacity(), Config.inventory.capacities[1])
        same(loop.player.inventory:GetItems(), Config.initial.items, "new-run inventory")
        eq(next(loop.player.recognizedLocations), nil, "new run resets location recognition")
        eq(loop.player.treasures.scopeLens, false, "new run resets the lens")
        eq(loop.player.treasures.wreckFound, nil, "new run resets ordinary treasure progress")
        eq(loop.player.story.circle1B2.barrelStage, 0, "new run resets barrel stage")
        eq(loop.player.story.circle1B2.paperShown, false, "new run resets the paper event")
        eq(loop.player.story.chapter, nil)
        eq(loop.player.story.campaignMarker, nil)
        eq(loop.player.elder.circle1B2.applesGiven, 0)
        eq(loop.player.elder.circle1B2.decision, "pending")
        eq(loop.player.elder.lastGivenItemId, nil)

        store:FinishSave(1, true, "late final save success")
        eq(loop.player.day, 1, "old final callback cannot replace the new-run state")
        eq(loop.initialSaveStatus, "saving", "old final callback cannot finish the initial save")
        eq(loop.entryPending, true)
        eq(loop:IsRunEndPending(), false)

        store:FinishSave(2, false, "offline")
        eq(loop.initialSaveStatus, "error")
        eq(loop.entryPending, true, "failed NG+ initial save keeps entry locked")
        eq(loop.clock.pauseReasons.entry, true)
        eq(loop:Ready(), false)
        assert(loop:RetryInitialSave(), "failed NG+ initial save can retry")
        eq(#store.saves, 3)
        same(store.saves[2], store.saves[3], "NG+ initial save retry snapshot")
        store:FinishSave(3, true)
        eq(loop.initialSaveStatus, "saved")
        eq(loop.entryPending, false)
        eq(loop.clock.pauseReasons.entry, nil)
        assert(loop:Ready())

        assert(loop:LoadSaved(), "the successfully written NG+ start can be reloaded")
        store:FinishLoad(1, true, store.saves[3])
        eq(loop.player.day, 1)
        eq(loop.player.money, Config.initial.money)
        eq(loop.player.maxStamina, Config.initial.maxStamina)
        eq(loop.player.stamina, Config.initial.stamina)
        eq(loop.player.inventory:GetLevel(), 1)
        same(loop.player.inventory:GetItems(), Config.initial.items, "reloaded NG+ inventory")
        eq(loop.player.treasures.scopeLens, false)
        eq(loop.player.story.circle1B2.paperShown, false)
        eq(loop.player.elder.circle1B2.applesGiven, 0)
        eq(loop:IsRunEndPending(), false)
        assert(loop:Ready())
        local reloaded = Persistence.Snapshot(loop.player)

        store:FinishSave(1, false, "late duplicate final callback")
        same(Persistence.Snapshot(loop.player), reloaded, "late final callback after load generation")
        eq(loop.saveStatus, "saved", "late final callback cannot overwrite loaded status")
        eq(loop.player.day, 1)
        eq(loop:IsRunEndPending(), false)
        return {
            newRunDay = loop.player.day, initialSaveAttempts = 2,
            initialSaveStatus = loop.initialSaveStatus, reloadedDay = loop.player.day,
            staleFinalCallbackIgnored = true, reset = true, finalSkipPreservedDaySeven = true,
        }
    end,
}

cases[#cases + 1] = {
    name = "explicitly skipping a failed final save preserves the actual older save",
    run = function()
        local nextDays = {}
        local store = makeStore()
        store.persisted = nil
        local finishSave = store.FinishSave
        function store:FinishSave(index, ok, reason)
            if ok then self.persisted = copy(self.saves[index]) end
            return finishSave(self, index, ok, reason)
        end
        local loop = Loop.New({ store = store, onNewDay = function(day)
            nextDays[#nextDays + 1] = day
        end })

        advanceToDay(loop, store, 6)
        configureFinalResources(loop)
        loop.clock:Seek("night", 40)
        assert(loop:Depart())
        assert(loop:ReturnToPort())
        assert(loop:EndToday())
        assert(loop:ConfirmSettlement())
        eq(loop.player.day, 7)
        store:FinishSave(6, true)
        eq(store.persisted.day, 7, "day-seven entry is the actual old save")
        eq(store.persisted.story.circle1B2.paperShown, false)
        local oldSavedSnapshot = copy(store.persisted)
        eq(loop.player.stamina, oldSavedSnapshot.stamina)

        loop.shopStock.apple, loop.shopStock.bait = 1, 0
        local stockBefore = { apple = loop:GetShopStock("apple"), bait = loop:GetShopStock("bait") }
        assert(loop:EndToday())
        local paper = loop:GetStoryDialog()
        assert(paper and loop:NotifyStoryShown(paper.token))
        assert(loop:CloseStoryDialog())
        local daySevenResources = Persistence.Snapshot(loop.player)
        assert(loop:ConfirmSettlement())
        eq(#store.saves, 7)
        eq(store.saves[7].story.circle1B2.paperShown, true)
        store:FinishSave(7, false, "offline")
        eq(loop.saveStatus, "error")
        same(store.persisted, oldSavedSnapshot, "failed final write retains old saved data")
        same(Persistence.Snapshot(loop.player), daySevenResources, "failed final write keeps live resources")

        assert(loop:ContinueWithoutSaving(), "explicit final skip closes the failed save")
        eq(loop:IsRunEndPending(), true)
        eq(loop.saveStatus, "skipped", "final skip is never reported as saved")
        eq(loop.player.day, 7)
        same(Persistence.Snapshot(loop.player), daySevenResources, "final skip preserves day-seven resources")
        same(store.persisted, oldSavedSnapshot, "explicit skip leaves the actual old save intact")
        eq(loop:GetShopStock("apple"), stockBefore.apple)
        eq(loop:GetShopStock("bait"), stockBefore.bait)
        eq(#nextDays, 6, "final skip does not run next-day preparation")
        eq(loop:Ready(), false)

        eq(loop:ContinueWithoutSaving(), false, "repeated skip is rejected")
        store:FinishSave(7, false, "late duplicate failure")
        eq(loop.saveStatus, "skipped", "late failure cannot turn a skip into a save")
        eq(loop.player.day, 7)
        same(Persistence.Snapshot(loop.player), daySevenResources, "late callback cannot mutate live state")
        same(store.persisted, oldSavedSnapshot, "late failed callback cannot replace old saved data")
        eq(loop:GetShopStock("apple"), stockBefore.apple)
        eq(loop:GetShopStock("bait"), stockBefore.bait)
        eq(#nextDays, 6)
        return {
            day = loop.player.day,
            saveStatus = loop.saveStatus,
            runEndPending = loop:IsRunEndPending(),
            oldSavedDay = store.persisted.day,
            oldSavePreserved = true,
            livePaperShown = Progress.IsPaperShown(loop.player),
            nextDayHooks = #nextDays,
        }
    end,
}

function Tests.Run()
    local report = { results = {}, passed = 0, failed = 0 }
    for _, case in ipairs(cases) do
        local ok, evidence = xpcall(case.run, debug.traceback)
        local row = { name = case.name, passed = ok, error = ok and "" or tostring(evidence) }
        if ok then
            row.evidence = evidence
            report.passed = report.passed + 1
        else
            report.failed = report.failed + 1
        end
        report.results[#report.results + 1] = row
    end
    report.limits = {
        terminalRunPersistence = "A day-seven save with paperShown=true reloads as playable; current schema has no distinct persisted terminal marker.",
        endingContent = "No ending system or ending field is created or inferred by these tests.",
    }
    return report
end

return Tests
