-- Circle 1B2 barrel tests use the real Flow Loop/Bridge and a controlled timer.
local Flow = require("tests.Circle1BFishingFlowTests")
local Progress = require("Gameplay.Circle1B2Progress")
local OceanConfig = require("Ocean.Config")

local Tests = {}
local FULL_HOLD = { "apple", "bait", "sardine", "tuna", "sardine" }

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function items(actual, expected, label)
    Flow.AssertItems(actual, expected, label)
end

local function withPatched(target, key, createReplacement, run)
    local original = target[key]
    target[key] = createReplacement(original)
    local ok, err = xpcall(run, debug.traceback)
    target[key] = original
    if not ok then error(err, 0) end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function memoryStore()
    local store = { writes = 0, data = nil }
    function store:Save(snapshot, done)
        self.writes = self.writes + 1
        self.data = copy(snapshot)
        if done then done(true) end
    end
    function store:Load(done)
        if done then done(self.data ~= nil, copy(self.data)) end
    end
    return store
end

local function fixture(settings)
    local f = Flow.Fixture(settings)
    local runtime = f.runtime
    runtime.fixedBarrelId = "driftwood-barrel-world-1"
    runtime.fixedBarrelGeneration = 1
    runtime.fixedBarrelPosition = { x = 1, y = 0 }
    runtime.scopeEnabled = false

    function runtime:GetFixedBarrel()
        return {
            id = self.fixedBarrelId,
            contentId = "driftwood_barrel",
            generation = self.fixedBarrelGeneration,
            position = { x = self.fixedBarrelPosition.x, y = self.fixedBarrelPosition.y },
        }
    end
    function runtime:CanInteractWithBarrel(id, generation)
        if id ~= self.fixedBarrelId or generation ~= self.fixedBarrelGeneration then
            return false, "stale_barrel_world"
        end
        return true
    end
    function runtime:SetScopeEnabled(enabled)
        self.scopeEnabled = enabled == true
        return true
    end
    function runtime:IsScopeEnabled()
        return self.scopeEnabled
    end

    function f:ReplaceBarrelWorld()
        runtime.fixedBarrelGeneration = runtime.fixedBarrelGeneration + 1
        runtime.fixedBarrelId = "driftwood-barrel-world-" .. runtime.fixedBarrelGeneration
    end
    return f
end

local function executor(f, onStart)
    local state = { requests = {}, callbacks = {}, cancelCalls = 0 }
    f.loop.options.barrelActionExecutor = function(request, done)
        state.requests[#state.requests + 1] = request
        state.callbacks[#state.callbacks + 1] = done
        if onStart then onStart(request, done) end
        return function() state.cancelCalls = state.cancelCalls + 1 end
    end
    return state
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("built-in timer advances with the ocean, blocks steering, and pauses for UI", function()
        local f = fixture()
        assert(f.loop:Depart())
        local stamina = f.loop.player.stamina
        local shipX = f.runtime.ship.position.x
        local oceanTime = f.runtime.oceanTime
        local token = assert(f.loop:BeginBarrelInspection())
        eq(f.loop.player.stamina, stamina)
        eq(f.loop:GetBarrelState().stage, 0)
        eq(f.loop:GetBarrelState().active, true)
        assert(f.loop:GetBarrelState().interfaceAvailable)
        eq(f.loop:GetBarrelState().timingAvailable, true)
        eq(f.loop:GetBarrelState().remaining, 4)
        assert(f.bridge:Update(1, 1, 0))
        eq(f.loop.clock.elapsed, 1)
        eq(f.runtime.oceanTime, oceanTime + OceanConfig.world.maxFrameSec,
            "ocean keeps the existing per-frame budget while gameplay uses full dt")
        eq(f.runtime.ship.position.x, shipX, "steering is locked during the action")
        eq(f.loop:GetBarrelState().remaining, 3)

        assert(f.loop:SetInventoryOpen(true))
        assert(f.loop.clock.pauseReasons.inventory)
        assert(f.bridge:Update(2, 1, 0))
        eq(f.loop.clock.elapsed, 1, "backpack pauses day/night time")
        eq(f.runtime.oceanTime, oceanTime + OceanConfig.world.maxFrameSec, "backpack pauses ocean simulation")
        eq(f.loop:GetBarrelState().remaining, 3, "backpack pauses barrel progress")
        assert(f.loop:SetInventoryOpen(false))

        assert(f.loop:SetElderOpen(true))
        assert(f.loop.clock.pauseReasons.elder)
        assert(f.bridge:Update(2, 1, 0))
        eq(f.loop.clock.elapsed, 1, "dialogue pauses day/night time")
        eq(f.loop:GetBarrelState().remaining, 3, "dialogue pauses barrel progress")
        assert(f.loop:SetElderOpen(false))

        f.loop.player.day = 7
        assert(f.loop:OpenDay7PaperBeforeEnding())
        assert(f.loop.clock.pauseReasons.story)
        assert(f.bridge:Update(2, 1, 0))
        eq(f.loop.clock.elapsed, 1, "dialogue pauses day/night time")
        eq(f.loop:GetBarrelState().remaining, 3, "dialogue pauses barrel progress")
        assert(f.loop:CloseStoryDialog())

        assert(f.bridge:Update(4, 1, 0))
        eq(f.loop.clock.elapsed, 5)
        eq(f.loop.player.stamina, 60)
        eq(f.loop:GetBarrelState().stage, 1)
        eq(f.loop:GetBarrelState().active, false)
        assert(f.runtime.ship.position.x > shipX, "steering resumes after the 4-second action")
        assert(not f.loop:HasPendingCatch())
        assert(type(token) == "table")
    end)

    test("barrel completion at night end commits once, while unfinished work cancels free", function()
        local exact = fixture()
        assert(exact.loop:Depart())
        exact.loop.clock:Seek("night", exact.loop.clock.nightSec - 4)
        assert(exact.loop:BeginBarrelInspection())
        assert(exact.bridge:Update(5))
        eq(exact.loop.forcedReturnPending, true)
        eq(exact.loop.player.stamina, 60)
        eq(exact.loop:GetBarrelState().stage, 1)
        eq(exact.loop:GetBarrelState().active, false)

        local unfinished = fixture()
        assert(unfinished.loop:Depart())
        unfinished.loop.clock:Seek("night", unfinished.loop.clock.nightSec - 2)
        assert(unfinished.loop:BeginBarrelInspection())
        assert(unfinished.bridge:Update(5))
        eq(unfinished.loop.forcedReturnPending, true)
        eq(unfinished.loop.player.stamina, 100)
        eq(unfinished.loop:GetBarrelState().stage, 0)
        eq(unfinished.loop:GetBarrelState().active, false)
    end)

    test("full hold escrows both first rewards and advances only after an atomic two-slot claim", function()
        local f = fixture({ items = FULL_HOLD })
        assert(f.loop:Depart())
        local timers = executor(f)
        local before = f.loop.player.inventory:GetItems()
        local token = assert(f.loop:BeginBarrelInspection())
        eq(f.loop.player.stamina, 100)
        eq(f.loop:GetBarrelState().active, true)
        eq(timers.requests[1].stage, 0)
        eq(timers.requests[1].durationSec, 4)
        eq(f.loop.clock.pauseReasons.barrel_event, nil)

        local tooShort, shortReason = timers.callbacks[1]({ completed = true, durationSec = 3.99 })
        eq(tooShort, false); eq(shortReason, "barrel_action_not_completed")
        eq(f.loop.player.stamina, 100)
        eq(f.loop:GetBarrelState().stage, 0)

        local completed, outcome = timers.callbacks[1]({ completed = true, durationSec = 4 })
        assert(completed and outcome == "pending_reward")
        eq(f.loop.player.stamina, 60)
        eq(f.loop:GetBarrelState().stage, 0)
        assert(not f.loop:GetBarrelState().active and f.loop:GetBarrelState().pending)
        items(f.loop.player.inventory:GetItems(), before, "inventory before pending reward claim")
        local pending = assert(f.loop:GetPendingCatch())
        items(pending.itemIds, { "apple", "bait" }, "barrel escrow")
        eq(pending.requiredSlots, 2)
        local replay, replayOutcome = timers.callbacks[1]({ completed = true, durationSec = 4 })
        assert(replay and replayOutcome == "pending_reward")
        eq(f.loop.player.stamina, 60)
        eq(f.loop:GetBarrelState().stage, 0)
        eq(f.loop:ClaimPendingCatch(), false)
        items(f.loop.player.inventory:GetItems(), before, "full hold claim")
        eq(f.loop:GetBarrelState().stage, 0)

        eq(f.bridge:NewRun(), false)
        eq(f.loop:EndToday(), false)
        eq(f.loop:ConfirmSettlement(), false)
        assert(f.loop:HasPendingCatch())
        eq(f.loop:GetBarrelState().stage, 0)

        assert(f.loop:UseItem(1)) -- one free slot is insufficient for the two-item receipt
        eq(f.loop.player.stamina, 80)
        local oneSlotItems = f.loop.player.inventory:GetItems()
        eq(f.loop:ClaimPendingCatch(), false)
        items(f.loop.player.inventory:GetItems(), oneSlotItems, "one-slot claim remains atomic")
        eq(f.loop:GetBarrelState().stage, 0)

        assert(f.bridge:SetDropTarget({ x = 2, y = 0 }))
        assert(f.loop:DropItem(1)) -- free the second slot
        assert(f.loop:ClaimPendingCatch())
        assert(not f.loop:HasPendingCatch())
        items(f.loop.player.inventory:GetItems(), { "sardine", "tuna", "sardine", "apple", "bait" }, "two-item claim")
        eq(f.loop.player.stamina, 80)
        eq(f.loop:GetBarrelState().stage, 1)
        local repeated = f.loop:ClaimPendingCatch()
        eq(repeated, false)
        eq(f.loop.player.stamina, 80)
        eq(f.loop:GetBarrelState().stage, 1)
        assert(type(token) == "table")
    end)

    test("controlled barrel receipts charge each stage once and grant lens without cargo", function()
        local f = fixture()
        assert(f.loop:Depart())
        local timers = executor(f)
        local initial = f.loop.player.inventory:GetItems()

        local first = assert(f.loop:BeginBarrelInspection())
        eq(timers.requests[1].stage, 0)
        assert(timers.callbacks[1]({ completed = true, durationSec = 4 }))
        eq(f.loop.player.stamina, 60)
        eq(f.loop:GetBarrelState().stage, 1)
        items(f.loop.player.inventory:GetItems(), { "apple", "bait", "apple", "bait" }, "first reward")
        local duplicate, firstOutcome = timers.callbacks[1]({ completed = true, durationSec = 4 })
        assert(duplicate and firstOutcome == "rewarded")
        eq(f.loop.player.stamina, 60)
        eq(f.loop:GetBarrelState().stage, 1)
        assert(type(first) == "table")

        local second = assert(f.loop:BeginBarrelInspection())
        eq(timers.requests[2].stage, 1)
        assert(timers.callbacks[2]({ completed = true, durationSec = 4 }))
        eq(f.loop.player.stamina, 20)
        eq(f.loop:GetBarrelState().stage, 2)
        eq(f.loop.lastMessage, "什么都没有捕捞到")
        items(f.loop.player.inventory:GetItems(), { "apple", "bait", "apple", "bait" }, "empty second stage")
        local secondReplay = timers.callbacks[2]({ completed = true, durationSec = 4 })
        assert(secondReplay)
        eq(f.loop.player.stamina, 20)
        eq(f.loop:GetBarrelState().stage, 2)
        assert(type(second) == "table")

        -- Barrel actions cost 40 stamina each; use one of the earned apples
        -- before the final stage instead of letting stamina go negative.
        assert(f.loop:UseItem(1))
        eq(f.loop.player.stamina, 40)
        local beforeLens = f.loop.player.inventory:GetItems()
        local third = assert(f.loop:BeginBarrelInspection())
        eq(timers.requests[3].stage, 2)
        assert(timers.callbacks[3]({ completed = true, durationSec = 4 }))
        eq(f.loop.player.stamina, 0)
        eq(f.loop:GetBarrelState().stage, 3)
        assert(f.loop:HasLens())
        items(f.loop.player.inventory:GetItems(), beforeLens, "lens must not occupy cargo")
        local thirdReplay = timers.callbacks[3]({ completed = true, durationSec = 4 })
        assert(thirdReplay)
        eq(f.loop.player.stamina, 0)
        eq(f.loop:GetBarrelState().stage, 3)
        assert(type(third) == "table")

        assert(f.loop:ToggleScope())
        assert(f.loop:IsScopeEnabled() and f.runtime:IsScopeEnabled())
        assert(f.loop:ToggleScope())
        assert(not f.loop:IsScopeEnabled() and not f.runtime:IsScopeEnabled())
        local finished, reason = f.loop:BeginBarrelInspection()
        eq(finished, false); eq(reason, "barrel_finished")
        eq(#initial, 2)
    end)

    test("the three barrel stages survive real day settlements and memory save restore", function()
        local store = memoryStore()
        local f = fixture({ store = store })
        assert(f.loop:Depart())
        local timers = executor(f)
        local fixedBarrel = f.runtime:GetFixedBarrel()

        local function loadSaved(expectedDay, expectedStage)
            local loaded, loadError
            assert(f.loop:LoadSaved(function(ok, err)
                loaded, loadError = ok, err
            end))
            assert(loaded, tostring(loadError))
            eq(f.loop.player.day, expectedDay)
            eq(f.loop:GetBarrelState().stage, expectedStage)
            eq(f.runtime:GetFixedBarrel().id, fixedBarrel.id)
            eq(f.runtime:GetFixedBarrel().generation, fixedBarrel.generation)
        end

        local function endDay(expectedStage, expectedDay)
            assert(f.loop:ReturnToPort())
            assert(f.loop:EndToday())
            assert(f.loop:ConfirmSettlement())
            eq(f.loop.player.day, expectedDay)
            eq(f.loop:GetBarrelState().stage, expectedStage)
            eq(store.data.story.circle1B2.barrelStage, expectedStage)
            eq(f.runtime:GetFixedBarrel().id, fixedBarrel.id)
            eq(f.runtime:GetFixedBarrel().generation, fixedBarrel.generation)
        end

        assert(f.loop:BeginBarrelInspection())
        assert(timers.callbacks[1]({ completed = true, durationSec = 4 }))
        eq(f.loop:GetBarrelState().stage, 1)
        items(f.loop.player.inventory:GetItems(), { "apple", "bait", "apple", "bait" }, "stage-zero reward")
        endDay(1, 2)
        loadSaved(2, 1)
        items(f.loop.player.inventory:GetItems(), { "apple", "bait", "apple", "bait" }, "restored stage-one cargo")

        assert(f.loop:Depart())
        assert(f.loop:BeginBarrelInspection())
        assert(timers.callbacks[2]({ completed = true, durationSec = 4 }))
        eq(f.loop:GetBarrelState().stage, 2)
        items(f.loop.player.inventory:GetItems(), { "apple", "bait", "apple", "bait" }, "stage one grants no cargo")
        endDay(2, 3)
        loadSaved(3, 2)

        assert(f.loop:Depart())
        assert(f.loop:BeginBarrelInspection())
        assert(timers.callbacks[3]({ completed = true, durationSec = 4 }))
        eq(f.loop:GetBarrelState().stage, 3)
        assert(f.loop:HasLens())
        items(f.loop.player.inventory:GetItems(), { "apple", "bait", "apple", "bait" }, "lens is not cargo")
        endDay(3, 4)
        loadSaved(4, 3)
        assert(f.loop:HasLens())
        items(f.loop.player.inventory:GetItems(), { "apple", "bait", "apple", "bait" }, "restored stages do not duplicate rewards")
        eq(store.writes, 3)

        assert(f.loop:Depart())
        local stamina = f.loop.player.stamina
        local before = f.loop.player.inventory:GetItems()
        local finished, reason = f.loop:BeginBarrelInspection()
        eq(finished, false)
        eq(reason, "barrel_finished")
        eq(f.loop.player.stamina, stamina)
        items(f.loop.player.inventory:GetItems(), before, "completed stage cannot award again")
    end)

    test("a rejected first-stage progression rolls back stamina and both appended rewards", function()
        local f = fixture()
        assert(f.loop:Depart())
        local timers = executor(f)
        local beforeItems = f.loop.player.inventory:GetItems()

        withPatched(Progress, "SetBarrelStage", function(original)
            local rejectOnce = true
            return function(player, stage)
                if stage == 1 and rejectOnce then
                    rejectOnce = false
                    return false, "injected_stage_rejection"
                end
                return original(player, stage)
            end
        end, function()
            assert(f.loop:BeginBarrelInspection())
            local accepted, reason = timers.callbacks[1]({ completed = true, durationSec = 4 })
            eq(accepted, false)
            eq(reason, "barrel_commit_failed")
            items(f.loop.player.inventory:GetItems(), beforeItems, "stage failure restores appended rewards")
            eq(f.loop.player.stamina, 100, "stage failure restores charged stamina")
            eq(f.loop:GetBarrelState().stage, 0)
            eq(f.loop:GetBarrelState().active, false)
            eq(f.loop:HasPendingCatch(), false)
            eq(f.loop:HasLens(), false)
            eq(f.loop.clock.pauseReasons.barrel_event, nil)
            eq(f.loop.clock:IsPaused(), false)
        end)
    end)

    test("lens grant rejection rolls back the final-stage charge and leaves stage two intact", function()
        local f = fixture()
        assert(Progress.SetBarrelStage(f.loop.player, 2))
        f.loop.player.stamina = 40
        assert(f.loop:Depart())
        local timers = executor(f)
        local beforeItems = f.loop.player.inventory:GetItems()

        withPatched(Progress, "GrantLens", function()
            return function() return false, "injected_lens_rejection" end
        end, function()
            assert(f.loop:BeginBarrelInspection())
            local accepted, reason = timers.callbacks[1]({ completed = true, durationSec = 4 })
            eq(accepted, false)
            eq(reason, "barrel_commit_failed")
            items(f.loop.player.inventory:GetItems(), beforeItems, "lens failure preserves cargo")
            eq(f.loop.player.stamina, 40, "lens failure restores stamina")
            eq(f.loop:GetBarrelState().stage, 2)
            eq(f.loop:HasLens(), false)
            eq(f.loop:GetBarrelState().active, false)
            eq(f.loop.clock.pauseReasons.barrel_event, nil)
            eq(f.loop.clock:IsPaused(), false)
        end)
    end)

    test("claim stage failure restores cargo and keeps the receipt retryable without charging again", function()
        local f = fixture({ items = FULL_HOLD })
        assert(f.loop:Depart())
        local timers = executor(f)
        assert(f.loop:BeginBarrelInspection())
        assert(timers.callbacks[1]({ completed = true, durationSec = 4 }))
        assert(f.loop:HasPendingCatch())

        assert(f.loop:UseItem(1))
        assert(f.bridge:SetDropTarget({ x = 2, y = 0 }))
        assert(f.loop:DropItem(1))
        local beforeClaim = f.loop.player.inventory:GetItems()
        local stamina = f.loop.player.stamina
        eq(#beforeClaim, 3)

        withPatched(Progress, "SetBarrelStage", function(original)
            local rejectOnce = true
            return function(player, stage)
                if stage == 1 and rejectOnce then
                    rejectOnce = false
                    return false, "injected_claim_stage_rejection"
                end
                return original(player, stage)
            end
        end, function()
            local first, firstReason = f.loop:ClaimPendingCatch()
            eq(first, false)
            eq(firstReason, "inventory_add_failed")
            items(f.loop.player.inventory:GetItems(), beforeClaim, "failed claim restores cargo atomically")
            eq(f.loop:GetBarrelState().stage, 0)
            assert(f.loop:HasPendingCatch(), "failed claim must retain its escrow")
            eq(f.loop.player.stamina, stamina, "claim does not charge barrel stamina again")

            assert(f.loop:ClaimPendingCatch())
            items(f.loop.player.inventory:GetItems(), { "sardine", "tuna", "sardine", "apple", "bait" },
                "retry receives both items exactly once")
            eq(f.loop:GetBarrelState().stage, 1)
            eq(f.loop:HasPendingCatch(), false)
            eq(f.loop.player.stamina, stamina)
        end)
    end)

    test("a partial claim rollback is retried on Tick without auto-claiming its pending receipt", function()
        local f = fixture({ items = FULL_HOLD })
        assert(f.loop:Depart())
        local timers = executor(f)
        assert(f.loop:BeginBarrelInspection())
        assert(timers.callbacks[1]({ completed = true, durationSec = 4 }))
        assert(f.loop:HasPendingCatch())
        assert(f.loop:UseItem(1))
        assert(f.bridge:SetDropTarget({ x = 2, y = 0 }))
        assert(f.loop:DropItem(1))

        local inventory = f.loop.player.inventory
        local beforeClaim = inventory:GetItems()
        local stamina = f.loop.player.stamina
        withPatched(inventory, "Add", function(original)
            local addedApple = false
            local rejectedBait = false
            return function(self, itemId)
                if itemId == "bait" and addedApple and not rejectedBait then
                    rejectedBait = true
                    return false, "injected_add_failure"
                end
                local ok, reason = original(self, itemId)
                if ok and itemId == "apple" then addedApple = true end
                return ok, reason
            end
        end, function()
            withPatched(inventory, "RestoreItems", function(original)
                local rejectOnce = true
                return function(self, snapshot)
                    if rejectOnce then
                        rejectOnce = false
                        return false, "injected_restore_failure"
                    end
                    return original(self, snapshot)
                end
            end, function()
                local failed, failReason = f.loop:ClaimPendingCatch()
                eq(failed, false)
                eq(failReason, "barrel_rollback_pending")
                eq(#inventory:GetItems(), #beforeClaim + 1, "the injected partial add remains until retry")
                assert(f.loop:HasPendingCatch())
                eq(f.loop:GetBarrelState().stage, 0)

                assert(f.bridge:Update(0)) -- Tick retries only the saved rollback snapshot.
                items(inventory:GetItems(), beforeClaim, "Tick restores the pre-claim cargo")
                assert(f.loop:HasPendingCatch(), "Tick must not automatically claim the receipt")
                eq(f.loop:GetBarrelState().stage, 0)
                eq(f.loop.player.stamina, stamina)

                assert(f.loop:ClaimPendingCatch())
                items(inventory:GetItems(), { "sardine", "tuna", "sardine", "apple", "bait" },
                    "explicit retry claims the receipt after rollback")
                eq(f.loop:GetBarrelState().stage, 1)
                eq(f.loop:HasPendingCatch(), false)
                eq(f.loop.player.stamina, stamina)
            end)
        end)
    end)

    test("executor failure before evidence is free, but a synchronous completed receipt returns its token", function()
        local noEvidenceCases = {
            { name = "throw", executor = function() error("injected_executor_error") end },
            { name = "false", executor = function() return false end },
        }
        for _, case in ipairs(noEvidenceCases) do
            local f = fixture()
            assert(f.loop:Depart())
            f.loop.options.barrelActionExecutor = case.executor
            local token, reason = f.loop:BeginBarrelInspection()
            eq(token, false, case.name .. " without evidence")
            eq(reason, "barrel_executor_failed", case.name .. " failure reason")
            eq(f.loop.player.stamina, 100)
            eq(f.loop:GetBarrelState().stage, 0)
            eq(f.loop:GetBarrelState().active, false)
            eq(f.loop.clock.pauseReasons.barrel_event, nil)
            eq(f.loop.clock:IsPaused(), false)
        end

        local completedCases = {
            { name = "throw", executor = function(_, done)
                done({ completed = true, durationSec = 4 })
                error("injected_post_completion_error")
            end },
            { name = "false", executor = function(_, done)
                done({ completed = true, durationSec = 4 })
                return false
            end },
        }
        for _, case in ipairs(completedCases) do
            local f = fixture()
            assert(f.loop:Depart())
            local completion
            f.loop.options.barrelActionExecutor = function(request, done)
                completion = done
                return case.executor(request, done)
            end
            local token, reason = f.loop:BeginBarrelInspection()
            assert(type(token) == "table", case.name .. " must return the completed receipt token")
            eq(reason, nil)
            eq(f.loop.player.stamina, 60)
            eq(f.loop:GetBarrelState().stage, 1)
            eq(f.loop:GetBarrelState().active, false)
            eq(f.loop.clock.pauseReasons.barrel_event, nil)
            local replay, replayReason = completion({ completed = true, durationSec = 4 })
            assert(replay)
            eq(replayReason, "rewarded")
            eq(f.loop.player.stamina, 60)
            eq(f.loop:GetBarrelState().stage, 1)
        end
    end)

    test("observer errors do not discard an escrowed result and reset cancels an active receipt", function()
        local f = fixture({ items = FULL_HOLD })
        assert(f.loop:Depart())
        local timers = executor(f)
        local originalSync = f.bridge.Sync
        f.bridge.Sync = function() error("injected_observer_error") end
        assert(f.loop:BeginBarrelInspection())
        local accepted, outcome = timers.callbacks[1]({ completed = true, durationSec = 4 })
        f.bridge.Sync = originalSync
        assert(accepted and outcome == "pending_reward")
        assert(f.loop:HasPendingCatch())
        eq(f.loop.player.stamina, 60)
        eq(f.loop:GetBarrelState().stage, 0)
        eq(f.loop.inventoryOpen, true)
        assert(f.loop.clock.pauseReasons.inventory)
        eq(f.loop.clock.pauseReasons.barrel_event, nil)

        local reset = fixture()
        assert(reset.loop:Depart())
        local resetTimers = executor(reset)
        local initial = reset.loop.player.inventory:GetItems()
        local beforeStamina = reset.loop.player.stamina
        assert(reset.loop:BeginBarrelInspection())
        assert(reset.bridge:NewRun())
        eq(resetTimers.cancelCalls, 1)
        eq(reset.loop.player.day, 1)
        eq(reset.loop.player.stamina, 100)
        eq(reset.loop:GetBarrelState().stage, 0)
        eq(reset.loop:GetBarrelState().active, false)
        eq(reset.loop.clock.pauseReasons.barrel_event, nil)
        items(reset.loop.player.inventory:GetItems(), initial, "new run restores starter inventory")
        local late, lateReason = resetTimers.callbacks[1]({ completed = true, durationSec = 4 })
        eq(late, false)
        assert(lateReason ~= nil)
        eq(reset.loop.player.stamina, beforeStamina)
        eq(reset.loop:GetBarrelState().stage, 0)
    end)

    test("cancellation and a replaced barrel world invalidate late completions for free", function()
        local f = fixture()
        assert(f.loop:Depart())
        local timers = executor(f)
        local stamina = f.loop.player.stamina
        local first = assert(f.loop:BeginBarrelInspection())
        assert(f.loop:CancelBarrelInspection())
        eq(timers.cancelCalls, 1)
        eq(f.loop.player.stamina, stamina)
        eq(f.loop:GetBarrelState().stage, 0)
        local late, lateReason = timers.callbacks[1]({ completed = true, durationSec = 4 })
        eq(late, false); assert(lateReason ~= nil)
        eq(f.loop.player.stamina, stamina)
        assert(type(first) == "table")

        local second = assert(f.loop:BeginBarrelInspection())
        local priorBarrel = f.runtime:GetFixedBarrel()
        f.runtime:refreshOrdinaryFish(12345, f.runtime:GetShipPosition())
        local afterRefresh = f.runtime:GetFixedBarrel()
        eq(afterRefresh.id, priorBarrel.id, "fish refresh must preserve the fixed barrel id")
        eq(afterRefresh.generation, priorBarrel.generation, "fish refresh must preserve barrel generation")
        assert(timers.callbacks[2]({ completed = true, durationSec = 4 }))
        eq(f.loop:GetBarrelState().stage, 1)
        eq(f.loop.player.stamina, 60)
        assert(type(second) == "table")

        local third = assert(f.loop:BeginBarrelInspection())
        f:ReplaceBarrelWorld()
        assert(f.bridge:Update(0))
        eq(f.loop:GetBarrelState().active, false)
        eq(f.loop:GetBarrelState().stage, 1)
        eq(f.loop.player.stamina, 60)
        eq(timers.cancelCalls, 2)
        local stale, staleReason = timers.callbacks[3]({ completed = true, durationSec = 4 })
        eq(stale, false); assert(staleReason ~= nil)
        eq(f.loop.player.stamina, 60)
        eq(f.loop:GetBarrelState().stage, 1)
        assert(type(third) == "table")
    end)

    return { results = results }
end

return Tests
