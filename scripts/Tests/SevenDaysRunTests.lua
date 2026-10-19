-- Boundary and persistence regressions for the seven-day run contract.
-- These tests use the real Gameplay modules and a controllable asynchronous store.
local Config = require("config.gameplay")
local Loop = require("Gameplay.Loop")
local Player = require("Gameplay.PlayerState")
local Persistence = require("Gameplay.Persistence")
local Progress = require("Gameplay.Circle1B2Progress")
local AchievementSystem = require("Gameplay.AchievementSystem")

local Tests = {}
local PAPER_TEXT = "海边那只木桶还有秘密，快去再探探。"

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

local function loadSnapshot(snapshot)
    local loop, store = newLoop()
    assert(loop:LoadSaved())
    store:FinishLoad(1, true, snapshot)
    return loop, store
end

local function finishNormalDay(loop, store, day)
    eq(loop.player.day, day, "day before normal settlement")
    local pendingStory = loop:GetStoryDialog()
    if pendingStory then
        assert(loop:NotifyStoryShown(pendingStory.token))
        assert(loop:CloseStoryDialog())
    end
    assert(loop:Depart())
    assert(loop:ReturnToPort())
    assert(loop:EndToday())
    assert(loop:ConfirmSettlement())
    eq(loop.player.day, day + 1, "normal day advances once")
    eq(loop.endingPending, false, "ordinary day is not final")
    store:FinishSave(#store.saves, true)
    eq(loop.settlementPending, false, "ordinary settlement closes after save")
end

-- V2.7：日初剧情（D4 老人结果 / D6 未救回想 / D7 纸条）会在换日后自动打开，
-- 其中 D4/D6 属于可关闭的结果模态；这里统一处理除 D7 纸条以外的日初剧情。
local function closeEntryStory(loop)
    local dialog = loop:GetStoryDialog()
    while dialog and dialog.kind ~= "paper" do
        assert(loop:NotifyStoryShown(dialog.token))
        assert(loop:CloseStoryDialog())
        loop:OpenDayEntryStory()
        dialog = loop:GetStoryDialog()
    end
    return dialog
end

local function advanceToDay(loop, store, targetDay)
    while loop.player.day < targetDay do
        finishNormalDay(loop, store, loop.player.day)
        if loop.player.day < targetDay then closeEntryStory(loop) end
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
    loop.player.day = Config.clock.maxDay
    assert(Progress.OnDayStarted(loop.player))
    assert(loop:OpenDay7PaperBeforeEnding())
    preparePaper(loop)
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

local function attachEndingSpies(loop, options)
    options = options or {}
    local calls = { unusualBranch = 0, settleRun = 0, profileSave = 0 }
    local remainingProfileSaveFailures = options.profileSaveFailures or 0
    loop.achievements = {
        NoteUnusualBranch = function()
            calls.unusualBranch = calls.unusualBranch + 1
        end,
        SettleRun = function()
            calls.settleRun = calls.settleRun + 1
        end,
    }
    loop.profileStore = {
        Save = function(_, done)
            calls.profileSave = calls.profileSave + 1
            if remainingProfileSaveFailures > 0 then
                remainingProfileSaveFailures = remainingProfileSaveFailures - 1
                error("injected_profile_save_failure")
            end
            if done then done(true) end
        end,
    }
    return calls
end

local function beginFinalSettlement(loop, decision)
    markDaySeven(loop)
    local elder = loop.player.elder.circle1B2
    elder.applesGiven = decision == "saved" and 3 or 0
    elder.decision = decision
    assert(loop:EndToday())
end

local cases = {}

cases[#cases + 1] = {
    name = "terminal achievement settlement runs once for normal and changed endings",
    run = function()
        for _, decision in ipairs({ "dead", "saved" }) do
            local loop, store = newLoop()
            local calls = attachEndingSpies(loop)
            beginFinalSettlement(loop, decision)
            assert(loop:ConfirmSettlement())
            eq(loop.endingKind, decision == "saved" and "changed" or "normal")
            eq(calls.unusualBranch, decision == "saved" and 1 or 0)
            eq(calls.settleRun, 1)
            eq(calls.profileSave, 1)
            eq(loop.endingAchievementsSettled, true)
            eq(loop.endingProfileSaveDispatched, true)
            store:FinishSave(1, true)
            eq(loop:ConfirmSettlement(), false, "completed settlement cannot be replayed")
            store:FinishSave(1, false, "duplicate callback")
            eq(calls.unusualBranch, decision == "saved" and 1 or 0)
            eq(calls.settleRun, 1)
            eq(calls.profileSave, 1)
        end
        return { endings = 2, terminalSettlements = 2 }
    end,
}

cases[#cases + 1] = {
    name = "final snapshot exception retries through the same achievement settlement path",
    run = function()
        local loop, store = newLoop()
        local calls = attachEndingSpies(loop)
        beginFinalSettlement(loop, "saved")
        local originalSnapshot = Persistence.Snapshot
        local failuresRemaining = 1
        Persistence.Snapshot = function(player)
            if failuresRemaining > 0 then
                failuresRemaining = failuresRemaining - 1
                error("injected_final_snapshot_failure")
            end
            return originalSnapshot(player)
        end
        local callOk, accepted, reason = pcall(loop.ConfirmSettlement, loop)
        Persistence.Snapshot = originalSnapshot
        assert(callOk, accepted)
        eq(accepted, false)
        eq(reason, "ending_snapshot_failed")
        eq(loop.endingPending, true)
        eq(loop.settlementApplied, true)
        eq(loop.settlementSnapshot, nil)
        eq(calls.unusualBranch, 0)
        eq(calls.settleRun, 0)
        eq(calls.profileSave, 0)
        eq(#store.saves, 0)

        assert(loop:ConfirmSettlement(), "snapshot retry should prepare final awards and save")
        eq(calls.unusualBranch, 1)
        eq(calls.settleRun, 1)
        eq(calls.profileSave, 1)
        eq(#store.saves, 1)
        store:FinishSave(1, true)
        eq(loop.settlementPending, false)
        return { snapshotAttempts = 2, achievementSettlements = calls.settleRun, profileSaves = calls.profileSave }
    end,
}

cases[#cases + 1] = {
    name = "main final save retries and duplicate callbacks do not repeat ending awards",
    run = function()
        local loop, store = newLoop()
        local calls = attachEndingSpies(loop)
        beginFinalSettlement(loop, "dead")
        assert(loop:ConfirmSettlement())
        eq(calls.settleRun, 1)
        eq(calls.profileSave, 1)
        store:FinishSave(1, false, "offline")
        eq(loop.saveStatus, "error")
        assert(loop:ConfirmSettlement(), "failed main save retries")
        eq(#store.saves, 2)
        same(store.saves[1], store.saves[2], "retry reuses the terminal snapshot")
        eq(calls.unusualBranch, 0)
        eq(calls.settleRun, 1)
        eq(calls.profileSave, 1)
        store:FinishSave(1, true, "late duplicate success")
        eq(loop.saveStatus, "saving", "late old callback is ignored")
        store:FinishSave(2, true)
        store:FinishSave(2, false, "duplicate callback")
        eq(loop.saveStatus, "saved")
        eq(calls.settleRun, 1)
        eq(calls.profileSave, 1)
        return { mainSaveAttempts = 2, endingSettlements = calls.settleRun }
    end,
}

cases[#cases + 1] = {
    name = "profile save call exception retries without replaying achievements",
    run = function()
        local loop, store = newLoop()
        local calls = attachEndingSpies(loop, { profileSaveFailures = 1 })
        beginFinalSettlement(loop, "saved")
        local accepted, reason = loop:ConfirmSettlement()
        eq(accepted, false)
        eq(reason, "ending_profile_save_call_failed")
        eq(loop.saveStatus, "error")
        eq(calls.settleRun, 1)
        eq(calls.profileSave, 1)
        eq(#store.saves, 0)

        assert(loop:ConfirmSettlement(), "profile save call can retry")
        eq(calls.unusualBranch, 1)
        eq(calls.settleRun, 1)
        eq(calls.profileSave, 2)
        eq(#store.saves, 1)
        store:FinishSave(1, true)
        eq(calls.settleRun, 1)
        return { profileSaveCalls = calls.profileSave, achievementSettlements = calls.settleRun }
    end,
}

cases[#cases + 1] = {
    name = "explicit final skip survives persistent achievement settlement exception",
    run = function()
        local loop, store = newLoop()
        local markCalls, profileSaveCalls = 0, 0
        local profile = {
            HasAchievement = function() return false end,
            MarkAchievement = function(_, id)
                if id == "A6" then markCalls = markCalls + 1 end
                error("injected_persistent_achievement_mark_failure:" .. tostring(id))
            end,
            Save = function(_, done)
                profileSaveCalls = profileSaveCalls + 1
                error("injected_persistent_profile_save_failure")
            end,
        }
        loop.profileStore = profile
        loop.knowledge = { GetDomainLevel = function() return 0 end }
        loop.achievements = AchievementSystem.New({
            data = require("data.achievements"),
            knowledge = loop.knowledge,
            profile = profile,
            player = loop.player,
        })
        beginFinalSettlement(loop, "dead")
        local accepted, reason = loop:ConfirmSettlement()
        eq(accepted, false)
        eq(reason, "ending_achievement_settlement_failed")
        eq(markCalls, 1)
        eq(profileSaveCalls, 0)
        eq(#store.saves, 0)
        eq(loop.saveStatus, "error")
        eq(loop.player.story.circle1B2.runCompleted, true)
        eq(loop.settlementPending, true)

        assert(loop:ContinueWithoutSaving(), "achievement exception must not block explicit skip")
        eq(markCalls, 1, "skip does not retry the throwing achievement")
        eq(profileSaveCalls, 0)
        eq(loop.settlementPending, false)
        eq(loop.settlementApplied, false)
        eq(loop.endingPending, true)
        eq(loop.player.day, 7)
        eq(loop.player.story.circle1B2.runCompleted, true)
        eq(loop.saveStatus, "skipped")
        assert(loop.lastMessage:find("重启后可能恢复此前检查点", 1, true))
        eq(#store.saves, 0, "skip does not start or claim a main save")
        eq(loop:ContinueWithoutSaving(), false, "skip can only be accepted once")
        return { markCalls = markCalls, saveStatus = loop.saveStatus, memoryEndingPreserved = true }
    end,
}

cases[#cases + 1] = {
    name = "explicit final skip survives persistent profile save exception",
    run = function()
        local loop, store = newLoop()
        local calls = { unusualBranch = 0, settleRun = 0, profileSave = 0 }
        loop.achievements = {
            NoteUnusualBranch = function()
                calls.unusualBranch = calls.unusualBranch + 1
            end,
            SettleRun = function()
                calls.settleRun = calls.settleRun + 1
            end,
        }
        loop.profileStore = {
            Save = function(_, done)
                calls.profileSave = calls.profileSave + 1
                error("injected_persistent_profile_save_failure")
            end,
        }
        beginFinalSettlement(loop, "saved")
        local accepted, reason = loop:ConfirmSettlement()
        eq(accepted, false)
        eq(reason, "ending_profile_save_call_failed")
        eq(calls.unusualBranch, 1)
        eq(calls.settleRun, 1)
        eq(calls.profileSave, 1)
        eq(loop.endingAchievementsSettled, true)
        eq(loop.endingProfileSaveDispatched, false)
        eq(#store.saves, 0)
        eq(loop.saveStatus, "error")

        assert(loop:ContinueWithoutSaving(), "profile save exception must not block explicit skip")
        eq(calls.unusualBranch, 1, "skip does not repeat ending branch achievement")
        eq(calls.settleRun, 1, "skip does not repeat run settlement")
        eq(calls.profileSave, 1, "skip does not retry the throwing profile save")
        eq(loop.settlementPending, false)
        eq(loop.settlementApplied, false)
        eq(loop.endingPending, true)
        eq(loop.player.day, 7)
        eq(loop.player.story.circle1B2.runCompleted, true)
        eq(loop.saveStatus, "skipped")
        assert(loop.lastMessage:find("重启后可能恢复此前检查点", 1, true))
        eq(#store.saves, 0, "skip does not start or claim a main save")
        return { profileSaveCalls = calls.profileSave, saveStatus = loop.saveStatus, memoryEndingPreserved = true }
    end,
}cases[#cases + 1] = {
    name = "partial ending award failure retries without duplicating A4 and settles A6 cognition",
    run = function()
        local loop, store = newLoop()
        local granted, markCalls = {}, {}
        local failA6 = true
        local profileSaveCalls = 0
        local profile = {
            HasAchievement = function(_, id) return granted[id] == true end,
            MarkAchievement = function(_, id)
                markCalls[id] = (markCalls[id] or 0) + 1
                if id == "A6" and failA6 then
                    failA6 = false
                    error("injected_profile_achievement_mark_failure")
                end
                granted[id] = true
            end,
            Save = function(_, done)
                profileSaveCalls = profileSaveCalls + 1
                if done then done(true) end
            end,
        }
        loop.profileStore = profile
        loop.knowledge = { GetDomainLevel = function() return 99 end }
        loop.achievements = AchievementSystem.New({
            data = require("data.achievements"),
            knowledge = loop.knowledge,
            profile = profile,
            player = loop.player,
        })
        beginFinalSettlement(loop, "saved")
        local accepted, reason = loop:ConfirmSettlement()
        eq(accepted, false)
        eq(reason, "ending_achievement_settlement_failed")
        eq(granted.A4, true, "earlier changed-ending award remains granted")
        eq(granted.A6, nil, "failed profile mark is not cached as granted")
        eq(loop.achievements:IsUnlocked("A6"), false)
        eq(#store.saves, 0)

        assert(loop:ConfirmSettlement(), "partial achievement settlement is retried")
        eq(granted.A4, true, "changed ending A4 is restored")
        eq(granted.A6, true, "no-force-return final check runs")
        eq(granted.C1, true)
        eq(granted.C2, true)
        eq(granted.C3, true)
        eq(markCalls.A4, 1, "earlier A4 grant is not repeated")
        eq(markCalls.A6, 2)
        eq(markCalls.C1, 1)
        eq(markCalls.C2, 1)
        eq(markCalls.C3, 1)
        eq(profileSaveCalls, 1)
        store:FinishSave(1, false, "offline")
        assert(loop:ConfirmSettlement(), "main save retries after award settlement")
        eq(markCalls.A6, 2)
        eq(markCalls.C1, 1)
        eq(markCalls.C2, 1)
        eq(markCalls.C3, 1)
        eq(profileSaveCalls, 1)
        store:FinishSave(2, true)
        return { A4 = granted.A4, A6 = granted.A6, cognition = 3, markCallsA6 = markCalls.A6 }
    end,
}

cases[#cases + 1] = {
    name = "new run resets ending settlement guards and completed loads do not re-award",
    run = function()
        local loop, store = newLoop()
        local calls = attachEndingSpies(loop)
        beginFinalSettlement(loop, "dead")
        assert(loop:ConfirmSettlement())
        store:FinishSave(1, true)
        eq(loop.endingAchievementsSettled, true)
        assert(loop:NewRun())
        eq(loop.endingPending, false)
        eq(loop.endingAchievementsSettled, false)
        eq(loop.endingProfileSaveDispatched, false)
        store:FinishSave(2, true)
        beginFinalSettlement(loop, "saved")
        assert(loop:ConfirmSettlement())
        eq(calls.unusualBranch, 1)
        eq(calls.settleRun, 2)
        eq(calls.profileSave, 3, "NewRun keeps its existing independent profile save")
        store:FinishSave(3, true)

        local completed = daySevenSnapshot()
        completed.story.circle1B2.runCompleted = true
        local loaded, loadedStore = newLoop()
        local loadedCalls = attachEndingSpies(loaded)
        assert(loaded:LoadSaved())
        loadedStore:FinishLoad(1, true, completed)
        eq(loaded.endingPending, true)
        eq(loaded.endingAchievementsSettled, true)
        eq(loaded.endingProfileSaveDispatched, true)
        eq(loaded:ConfirmSettlement(), false, "completed read cannot start another settlement")
        eq(loadedCalls.unusualBranch, 0)
        eq(loadedCalls.settleRun, 0)
        eq(loadedCalls.profileSave, 0)
        eq(#loadedStore.saves, 0)
        return { newRunSettlements = calls.settleRun, loadedTerminalAwards = loadedCalls.settleRun }
    end,
}

cases[#cases + 1] = {
    name = "normal seven-day cycle reaches a terminal day-seven save without recovery",
    run = function()
        local preparedDays = {}
        local loop, store = newLoop({ onNewDay = function(day)
            preparedDays[#preparedDays + 1] = day
        end })
        advanceToDay(loop, store, Config.clock.maxDay)
        eq(loop.player.day, 7, "six normal transitions reach day seven")
        eq(#preparedDays, 6, "each saved ordinary transition prepares one next day")
        configureFinalResources(loop)
        local dialog = loop:GetStoryDialog()
        assert(dialog and dialog.kind == "paper", "day-seven port entry automatically opens the paper")
        eq(dialog.text, PAPER_TEXT)
        eq(Progress.IsPaperShown(loop.player), false)
        eq(loop.settlementPending, false, "day-seven entry save finishes before day preparation")
        eq(#store.saves, 6, "paper display adds no extra save")
        local staminaBeforeRead = loop.player.stamina
        eq(loop:CloseStoryDialog(), false, "unread paper cannot be dismissed")
        eq(loop:ConfirmSettlement(), false, "final settlement cannot bypass the visible paper")
        assert(loop:NotifyStoryShown(dialog.token))
        assert(loop:CloseStoryDialog())
        eq(loop.player.stamina, staminaBeforeRead, "paper acknowledgement does not change stamina")
        eq(#store.saves, 6, "paper acknowledgement adds no autosave")
        local before = Persistence.Snapshot(loop.player)
        eq(before.story.circle1B2.runCompleted, false, "paper acknowledgement is not final settlement")
        assert(loop:EndToday(), "read paper permits final settlement")
        eq(loop.settlementPending, true)
        local finalState = Persistence.Snapshot(loop.player)
        assert(finalState.story.circle1B2.paperShown)
        assert(loop:ConfirmSettlement(), "final save uses the acknowledged paper state")
        local completedState = Persistence.Snapshot(loop.player)
        eq(completedState.story.circle1B2.runCompleted, true, "final settlement marks the run complete")
        eq(loop.player.day, 7, "final settlement keeps day seven")
        eq(loop.player.stamina, before.stamina, "final settlement does not restore stamina")
        eq(loop.player.money, before.money, "final settlement keeps money")
        eq(loop.player.maxStamina, before.maxStamina)
        eq(loop.player.boatSpeedLevel, before.boatSpeedLevel)
        same(Persistence.Snapshot(loop.player), completedState, "live final state")
        eq(#store.saves, 7, "one final snapshot is written")
        same(store.saves[7], completedState, "day-seven final snapshot")
        eq(store.saves[7].day, 7)
        eq(store.saves[7].story.circle1B2.paperShown, true)
        eq(store.saves[7].story.circle1B2.runCompleted, true)
        eq(store.saves[7].runEndPending, nil, "runtime ending boundary is not persisted")
        eq(store.saves[7].finished, nil, "no invented completion schema")
        eq(store.saves[7].endingId, nil, "no invented ending identifier")

        store:FinishSave(7, true)
        eq(loop.endingPending, true, "successful final save reaches the existing ending state")
        eq(loop.settlementPending, false, "final save closes the settlement")
        eq(loop.endingKind, "changed", "saved elder keeps the existing changed-ending branch")
        eq(#preparedDays, 6, "final day never calls the next-day preparation hook")
        eq(loop:GetShopStock("apple"), 1, "final day does not refresh shop stock")
        eq(loop:GetShopStock("bait"), 0)
        store:FinishSave(7, false, "duplicate final callback")
        eq(loop.endingPending, true, "duplicate final callback cannot undo the ending state")
        eq(loop.saveStatus, "saved", "duplicate final callback cannot overwrite save status")
        eq(loop.player.day, 7, "duplicate final callback cannot advance the day")
        eq(#preparedDays, 6)

        return {
            day = loop.player.day, stamina = loop.player.stamina, maxStamina = loop.player.maxStamina,
            money = loop.player.money, saves = #store.saves, nextDayHooks = #preparedDays,
            paperShown = store.saves[7].story.circle1B2.paperShown,
            endingPending = loop.endingPending,
        }
    end,
}

cases[#cases + 1] = {
    name = "completed day-seven snapshots restore both endings and block every gameplay settlement entry",
    run = function()
        local variants = {
            { decision = "dead", apples = 2, ending = "normal" },
            { decision = "saved", apples = 3, ending = "changed" },
        }
        for _, variant in ipairs(variants) do
            local snapshot = daySevenSnapshot()
            snapshot.elder.circle1B2.applesGiven = variant.apples
            snapshot.elder.circle1B2.decision = variant.decision
            snapshot.story.circle1B2.runCompleted = true

            local restored = assert(Persistence.Restore(copy(snapshot)))
            eq(restored.day, 7)
            eq(restored.story.circle1B2.runCompleted, true)

            local loop, store = loadSnapshot(snapshot)
            eq(loop.player.day, 7)
            eq(loop.endingPending, true)
            eq(loop.endingKind, variant.ending)
            eq(loop.settlementPending, false)
            eq(loop:GetStoryDialog(), nil, "completed restore does not replay the paper")
            eq(loop.clock.pauseReasons.port, true, "completed restore keeps the port pause")
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
            eq(loop:RecognizeLocation("late-terminal-discovery"), false,
                "automatic location recognition cannot mutate a completed save")
            eq(loop:LoadSaved(), false, "terminal state cannot be replaced by an older in-session checkpoint")
            local clockBefore = loop.clock:GetState()
            loop:Update(5, function() end)
            local clockAfter = loop.clock:GetState()
            eq(clockAfter.phase, clockBefore.phase)
            eq(clockAfter.elapsed, clockBefore.elapsed)
            eq(clockAfter.progress, clockBefore.progress)
            same(Persistence.Snapshot(loop.player), before, "blocked entry points do not change terminal state")
            eq(#store.saves, 0, "blocked entry points do not save again")
        end
        return { branches = 2, terminalLoads = 2, gameplayEntriesBlocked = true }
    end,
}

cases[#cases + 1] = {
    name = "day-seven completion admission rejects invalid final state before port preparation",
    run = function()
        local loop = newLoop()
        loop.player.day = 7
        assert(Progress.OnDayStarted(loop.player))
        loop.player.story.circle1B2.paperShown = false
        loop.settlementPending = true
        loop.inPort = false
        local accepted, reason = loop:BeginNewDay()
        eq(accepted, false)
        eq(reason, "day7_paper_required")
        eq(loop.portPreparedForSettlement, false, "invalid paper state must reject before port preparation")
        eq(loop.endingPending, false)
        eq(loop.settlementApplied, false)
        eq(loop.player.story.circle1B2.runCompleted, false)
        eq(loop.settlementSnapshot and next(loop.settlementSnapshot), nil)
        return { rejected = reason, portPreparationStarted = false }
    end,
}

cases[#cases + 1] = {
    name = "schema-one saves without runCompleted stay playable, including day-seven paper checkpoints",
    run = function()
        for day = 1, 6 do
            local player = assert(Player.New())
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
            -- V2.7：日初剧情属于当天 —— D4 老人结果只在 D4，D6 未救回想只在 D6。
            local dialog = loop:GetStoryDialog()
            if dialog then
                if day == 4 then eq(dialog.kind, "elder_fate")
                elseif day == 6 then eq(dialog.kind, "apple_basket")
                else assert(false, "no entry story is expected on this day") end
                assert(loop:NotifyStoryShown(dialog.token))
                assert(loop:CloseStoryDialog())
            else
                assert(day ~= 4 and day ~= 6, "day four and day six must open their entry story")
            end
            assert(loop:Ready(), "legacy days one through six remain playable")
        end

        local paperCheckpoint = daySevenSnapshot()
        paperCheckpoint.story.circle1B2.paperShown = false
        paperCheckpoint.story.circle1B2.runCompleted = nil
        local loop, store = loadSnapshot(paperCheckpoint)
        eq(loop.player.day, 7)
        eq(loop.endingPending, false, "an acknowledged but unfinished day-seven checkpoint is not terminal")
        eq(loop.player.story.circle1B2.runCompleted, false)
        local paper = assert(loop:GetStoryDialog())
        eq(paper.kind, "paper", "old unread checkpoint may present the paper again")
        local itemsBefore = loop.player.inventory:GetItems()
        local moneyBefore = loop.player.money
        local applesBefore = loop.player.elder.circle1B2.applesGiven
        local decisionBefore = loop.player.elder.circle1B2.decision
        assert(loop:NotifyStoryShown(paper.token))
        assert(loop:CloseStoryDialog())
        eq(loop.player.money, moneyBefore)
        eq(loop.player.elder.circle1B2.applesGiven, applesBefore)
        eq(loop.player.elder.circle1B2.decision, decisionBefore)
        same(loop.player.inventory:GetItems(), itemsBefore, "paper replay gives no inventory reward")
        eq(#store.saves, 0, "paper replay does not add an immediate save")
        eq(loop.player.story.circle1B2.runCompleted, false)
        assert(loop:Ready())

        local oldCompletedSnapshot = daySevenSnapshot()
        oldCompletedSnapshot.story.circle1B2.runCompleted = nil
        local oldCompletedLoop = loadSnapshot(oldCompletedSnapshot)
        eq(oldCompletedLoop.endingPending, false,
            "legacy completed snapshots cannot be distinguished and conservatively remain playable")
        eq(oldCompletedLoop.player.story.circle1B2.runCompleted, false)
        assert(oldCompletedLoop:Ready())
        return { loadedLegacyDays = 1, through = 7, missingFieldDefaultsFalse = true,
            oldDaySevenPaperMayReplay = true, oldTerminalStateIndistinguishable = true }
    end,
}

cases[#cases + 1] = {
    name = "invalid runCompleted types and terminal state combinations are rejected",
    run = function()
        local completed = daySevenSnapshot()
        completed.story.circle1B2.runCompleted = true
        assert(Persistence.Restore(copy(completed)), "valid day-seven completion restores")

        local invalid = {
            { name = "nonboolean", mutate = function(data)
                data.story.circle1B2.runCompleted = "true"
            end },
            { name = "before day seven", mutate = function(data)
                data.day = 6
                data.story.circle1B2.paperShown = false
            end },
            { name = "paper not confirmed", mutate = function(data)
                data.story.circle1B2.paperShown = false
            end },
            { name = "elder decision pending", mutate = function(data)
                data.elder.circle1B2.decision = "pending"
            end },
            { name = "invalid elder fate", mutate = function(data)
                data.elder.circle1B2.decision = "unknown"
            end },
            { name = "day eight", mutate = function(data)
                data.day = 8
            end },
        }
        for _, case in ipairs(invalid) do
            local data = copy(completed)
            case.mutate(data)
            local player = Persistence.Restore(data)
            eq(player, nil, case.name .. " must be rejected")
        end
        return { validTerminal = true, invalidCombinationsRejected = #invalid }
    end,
}

cases[#cases + 1] = {
    name = "unread day-seven entry paper blocks ending until its visible acknowledgement",
    run = function()
        local loop, store = newLoop()
        markDaySeven(loop)
        -- Recreate an old day-seven checkpoint that has not yet acknowledged the entry event.
        loop.player.story.circle1B2.paperShown = false
        local handled, result = loop:EndToday()
        eq(handled, true)
        eq(result, "paper_opened")
        local dialog = assert(loop:GetStoryDialog())
        eq(dialog.kind, "paper")
        eq(dialog.text, PAPER_TEXT)
        eq(loop.settlementPending, false)
        eq(Progress.IsPaperShown(loop.player), false)
        eq(loop:ConfirmSettlement(), false, "direct settlement cannot bypass unread paper")
        eq(loop:CloseStoryDialog(), false, "unread paper remains open")
        assert(loop:NotifyStoryShown(dialog.token))
        assert(loop:CloseStoryDialog())
        assert(loop:EndToday())
        eq(loop.settlementPending, true)
        assert(loop:ConfirmSettlement())
        eq(#store.saves, 1)
        return { day = loop.player.day, paperShown = Progress.IsPaperShown(loop.player),
            saveAttempts = #store.saves }
    end,
}

cases[#cases + 1] = {
    name = "forced day-seven return after the entry paper was read reaches the same ending without replay",
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
        eq(loop.settlementApplied, true, "the acknowledged paper permits final settlement")
        eq(Progress.IsPaperShown(loop.player), true)
        eq(loop:GetStoryDialog(), nil, "forced return does not replay the entry paper")
        eq(#store.saves, 1, "forced final settlement saves the acknowledged state")
        assert(store.saves[1].story.circle1B2.paperShown)
        eq(store.saves[1].story.circle1B2.runCompleted, true)
        eq(loop.player.day, 7)
        eq(loop.player.stamina, 41, "forced final settlement has no next-day half-stamina recovery")
        store:FinishSave(1, true)
        eq(loop.endingPending, true)
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
        eq(loop:GetStoryDialog(), nil, "entry paper was already acknowledged")
        assert(loop:ConfirmSettlement())
        eq(loop.player.day, 7)
        store:FinishSave(1, false, "offline")
        eq(loop.saveStatus, "error")
        eq(loop.settlementPending, true)
        eq(loop.endingPending, true)
        eq(loop.player.day, 7)
        local completedState = Persistence.Snapshot(loop.player)
        eq(completedState.story.circle1B2.runCompleted, true)
        same(Persistence.Snapshot(loop.player), completedState, "state after failed final save")
        eq(#nextDays, 0)

        assert(loop:ConfirmSettlement(), "failed final save can retry")
        eq(#store.saves, 2)
        same(store.saves[1], store.saves[2], "final retry snapshot")
        store:FinishSave(2, true)
        eq(loop.saveStatus, "saved")
        eq(loop.player.day, 7)
        same(Persistence.Snapshot(loop.player), completedState, "state after successful final retry")
        eq(loop:GetShopStock("apple"), 1, "retry does not refresh stock")
        eq(loop:GetShopStock("bait"), 0)
        eq(#nextDays, 0, "final retry never prepares day eight")
        assert(loop.endingPending)
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
        closeEntryStory(loop)  -- V2.7：D6 日初回想会打开一次
        eq(#nextDays, 5)
        loop.shopStock.apple = 0
        assert(loop:Depart())
        assert(loop:ReturnToPort())
        assert(loop:EndToday())
        assert(loop:ConfirmSettlement())
        eq(loop.player.day, 7)
        eq(loop.endingPending, false, "day-six settlement remains an ordinary transition")
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
        eq(loop.endingPending, false, "day seven is playable before its final settlement")
        eq(#nextDays, 6, "one day-seven preparation hook")
        store:FinishSave(6, true, "late success")
        eq(loop.saveStatus, "skipped", "late ordinary callback cannot undo explicit skip")
        eq(loop.player.day, 7)
        eq(#nextDays, 6)
        local paper = loop:GetStoryDialog()
        assert(paper and paper.kind == "paper", "day-seven entry opens paper after save skip")
        eq(paper.text, PAPER_TEXT)
        eq(Progress.IsPaperShown(loop.player), false)
        local paperShownBeforeRead = Progress.IsPaperShown(loop.player)
        eq(loop:CloseStoryDialog(), false, "unread paper cannot be dismissed")
        preparePaper(loop)
        assert(loop:Ready())
        assert(loop:Depart(), "read paper leaves skipped day seven playable")
        assert(loop:ReturnToPort())
        assert(loop:EndToday(), "final day can end after the entry paper was read")
        eq(loop:GetStoryDialog(), nil)
        return { day = loop.player.day, endingPending = loop.endingPending,
            nextDayHooks = #nextDays,
            paperShownBeforeRead = paperShownBeforeRead }
    end,
}

cases[#cases + 1] = {
    name = "day-eight save data is rejected intact while a loaded day-seven save remains playable",
    run = function()
        local savedDaySeven = daySevenSnapshot()
        local invalidDayEight = copy(savedDaySeven)
        invalidDayEight.day = Config.clock.maxDay + 1

        local badPlayer = assert(Player.New())
        badPlayer.day = Config.clock.maxDay + 1
        local invalidSnapshot = Persistence.Snapshot(badPlayer)
        eq(invalidSnapshot.day, Config.clock.maxDay + 1,
            "Snapshot preserves the invalid day value instead of silently truncating it")
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
        eq(loop.endingPending, false, "loaded final-day state keeps the existing nonterminal branch")
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
            terminalPersistence = "runCompleted distinguishes an unfinished day-seven save; only legacy snapshots missing the marker remain ambiguous",
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
        eq(loop:GetStoryDialog(), nil, "entry paper was already acknowledged")
        local finalState = Persistence.Snapshot(loop.player)
        local finalStock = { apple = loop:GetShopStock("apple"), bait = loop:GetShopStock("bait") }
        assert(loop:ConfirmSettlement())
        assert(loop:ContinueWithoutSaving(), "final save can be explicitly skipped")
        assert(loop.endingPending)
        eq(loop.saveStatus, "skipped")
        eq(loop.player.day, 7, "skipping final save keeps day seven")
        assert(loop.lastMessage:find("重启后可能恢复此前检查点", 1, true),
            "final skip explains the checkpoint fallback")
        local skippedState = Persistence.Snapshot(loop.player)
        eq(skippedState.story.circle1B2.runCompleted, true, "live ending remains complete after save skip")
        local expectedSkippedState = copy(finalState)
        expectedSkippedState.story.circle1B2.runCompleted = true
        same(skippedState, expectedSkippedState, "final skip preserves all other live state")
        eq(loop:GetShopStock("apple"), finalStock.apple, "final skip does not refresh stock")
        eq(loop:GetShopStock("bait"), finalStock.bait)
        eq(#nextDays, 0, "final skip does not prepare another day")

        assert(loop:NewRun(), "the existing new-run entry works after the run-end boundary")
        eq(loop.endingPending, false)
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
        eq(loop.player.story.circle1B2.elderFateShown, false, "new run resets the day-four result")
        eq(loop.player.story.circle1B2.paperShown, false, "new run resets the paper event")
        eq(loop.player.story.circle1B2.runCompleted, false, "new run clears the persisted terminal marker")
        eq(loop.player.story.chapter, nil)
        eq(loop.player.story.campaignMarker, nil)
        eq(loop.player.elder.circle1B2.applesGiven, 0)
        eq(loop.player.elder.circle1B2.decision, "pending")
        eq(loop.player.elder.lastGivenItemId, nil)

        store:FinishSave(1, true, "late final save success")
        eq(loop.player.day, 1, "old final callback cannot replace the new-run state")
        eq(loop.initialSaveStatus, "saving", "old final callback cannot finish the initial save")
        eq(loop.entryPending, true)
        eq(loop.endingPending, false)

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
        eq(loop.endingPending, false)
        assert(loop:Ready())
        local reloaded = Persistence.Snapshot(loop.player)

        store:FinishSave(1, false, "late duplicate final callback")
        same(Persistence.Snapshot(loop.player), reloaded, "late final callback after load generation")
        eq(loop.saveStatus, "saved", "late final callback cannot overwrite loaded status")
        eq(loop.player.day, 1)
        eq(loop.endingPending, false)
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
        closeEntryStory(loop)  -- V2.7：D6 日初回想会打开一次
        configureFinalResources(loop)
        loop.clock:Seek("night", 29.999)
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
        local entryPaper = assert(loop:GetStoryDialog())
        eq(entryPaper.kind, "paper", "day-seven entry paper appears before final settlement")
        eq(store.persisted.story.circle1B2.paperShown, false, "entry checkpoint predates display acknowledgement")
        preparePaper(loop)
        assert(loop:EndToday())
        eq(loop:GetStoryDialog(), nil)
        local daySevenResources = Persistence.Snapshot(loop.player)
        assert(loop:ConfirmSettlement())
        eq(#store.saves, 7)
        eq(store.saves[7].story.circle1B2.paperShown, true)
        store:FinishSave(7, false, "offline")
        eq(loop.saveStatus, "error")
        same(store.persisted, oldSavedSnapshot, "failed final write retains old saved data")
        local completedResources = copy(daySevenResources)
        completedResources.story.circle1B2.runCompleted = true
        same(Persistence.Snapshot(loop.player), completedResources,
            "failed final write keeps live resources and in-memory completion")

        assert(loop:ContinueWithoutSaving(), "explicit final skip closes the failed save")
        eq(loop.endingPending, true)
        eq(loop.saveStatus, "skipped", "final skip is never reported as saved")
        eq(loop.player.day, 7)
        same(Persistence.Snapshot(loop.player), completedResources,
            "final skip keeps the live ending but does not save it implicitly")
        same(store.persisted, oldSavedSnapshot, "explicit skip leaves the actual old save intact")
        eq(loop:GetShopStock("apple"), stockBefore.apple)
        eq(loop:GetShopStock("bait"), stockBefore.bait)
        eq(#nextDays, 6, "final skip does not run next-day preparation")
        eq(loop:Ready(), false)

        eq(loop:ContinueWithoutSaving(), false, "repeated skip is rejected")
        store:FinishSave(7, false, "late duplicate failure")
        eq(loop.saveStatus, "skipped", "late failure cannot turn a skip into a save")
        eq(loop.player.day, 7)
        same(Persistence.Snapshot(loop.player), completedResources, "late callback cannot mutate live state")
        same(store.persisted, oldSavedSnapshot, "late failed callback cannot replace old saved data")
        eq(loop:GetShopStock("apple"), stockBefore.apple)
        eq(loop:GetShopStock("bait"), stockBefore.bait)
        eq(#nextDays, 6)
        return {
            day = loop.player.day,
            saveStatus = loop.saveStatus,
            endingPending = loop.endingPending,
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
        terminalRunPersistence = "Legacy schema-v1 day-seven snapshots without runCompleted conservatively restore as playable because their completion state cannot be distinguished.",
        endingContent = "No ending system or ending field is created or inferred by these tests.",
    }
    return report
end

return Tests
