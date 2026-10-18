-- Fixed world-content transaction regressions. Adapter and scope signals are test doubles.
local Player = require "Gameplay.PlayerState"
local Persistence = require "Gameplay.Persistence"
local Circle1B2Progress = require "Gameplay.Circle1B2Progress"
local Progress = require "Gameplay.WorldContentProgress"
local Actions = require "Gameplay.WorldContentActions"
local Loop = require "Gameplay.Loop"

local Tests = {}
local MEMORY_IDS = { "memory_island_01", "memory_island_02", "memory_treasure_01" }

local function eq(actual, expected, label)
    assert(actual == expected, (label or "values differ") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function state(f, contentId)
    return assert(Progress.GetState(f.player, contentId))
end

local function fixture(player)
    player = player or assert(Player.New())
    if player.maxStamina < 200 then
        player.maxStamina, player.stamina = 200, 200
    end
    local f = {
        player = player,
        context = {
            player = player,
            sessionGeneration = 1,
            runtimeIdentity = {},
            fixedContentGeneration = 1,
            fishingGeneration = 1,
        },
        scopeInside = false,
        surfaceGap = 0,
        accessEntityId = nil,
        accessContentId = nil,
        accessGeneration = nil,
    }

    function f:GetContext()
        return self.context
    end

    function f:GetWorldContentAccess(contentId)
        return {
            contentId = self.accessContentId or contentId,
            entityId = self.accessEntityId or ("entity:" .. contentId),
            generation = self.accessGeneration or self.context.fixedContentGeneration,
            surfaceGap = self.surfaceGap,
        }
    end

    function f:IsWorldContentInScope(contentId)
        return contentId == "underwater_treasure_01" and self.scopeInside
    end

    f.actions = assert(Actions.New(f))
    return f
end

local function begin(f, kind, contentId)
    if kind == "salvage" then return f.actions:BeginSalvage(contentId) end
    return f.actions:BeginExplore(contentId)
end

local function complete(f, kind, contentId)
    local token, reason = begin(f, kind, contentId)
    assert(token, tostring(reason))
    local ok, outcome = f.actions:Advance(4)
    eq(ok, true)
    eq(outcome, "completed")
    return token
end

local function owned(actual, expected)
    eq(#actual, #expected, "owned memory count")
    for index, contentId in ipairs(expected) do eq(actual[index], contentId, "owned memory order") end
end

local function assertNoMemoryInInventory(player)
    local memorySet = {}
    for _, contentId in ipairs(MEMORY_IDS) do memorySet[contentId] = true end
    for _, itemId in ipairs(player.inventory:GetItems()) do
        assert(not memorySet[itemId], "memory fragment entered inventory: " .. tostring(itemId))
    end
end

local function markTreasure(f)
    f.player.treasures.scopeLens = true
    f.scopeInside = true
    local ok, reason = f.actions:Advance(1)
    assert(ok, tostring(reason))
    eq(state(f, "underwater_treasure_01").marked, true)
end

local function withPatched(target, key, replacement, run)
    local original = target[key]
    target[key] = replacement
    local ok, err = xpcall(run, debug.traceback)
    target[key] = original
    if not ok then error(err, 0) end
end

local function assertRollback(f, token, contentId, stamina, marked)
    local receipt = assert(f.actions:GetReceipt(token))
    eq(receipt.status, "failed")
    eq(receipt.commitState, "rolled_back")
    eq(receipt.rollback, "restored")
    eq(f.player.stamina, stamina, "rollback stamina")
    local after = state(f, contentId)
    eq(after.completed, false)
    eq(after.rewardOwned, false)
    if marked ~= nil then eq(after.marked, marked) end
    assert(Progress.Validate(f.player))
    assertNoMemoryInInventory(f.player)
    return receipt
end

function Tests.Run()
    local results = {}
    local names = {}
    local function test(name, run)
        assert(not names[name], "duplicate test name: " .. name)
        names[name] = true
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("first island exploration commits one matching memory for one 40-stamina cost", function()
        local f = fixture()
        local before = f.player.stamina
        local token = assert(f.actions:BeginExplore("island_01"))
        eq(f.player.stamina, before, "begin is free")
        local ok, stage = f.actions:Advance(3.99)
        eq(ok, true); eq(stage, "active"); eq(f.player.stamina, before)
        ok, stage = f.actions:Advance(0.01)
        eq(ok, true); eq(stage, "completed")
        eq(f.player.stamina, before - 40)
        eq(state(f, "island_01").completed, true)
        eq(state(f, "island_01").rewardOwned, true)
        owned(f.actions:GetOwnedTreasures(), { "memory_island_01" })
        eq(f.actions:GetReceipt(token).commitState, "committed")
        assertNoMemoryInInventory(f.player)
    end)

    test("second island exploration grants its own memory and no first-island reward", function()
        local f = fixture()
        local before = f.player.stamina
        local token = complete(f, "explore", "island_02")
        eq(f.player.stamina, before - 40)
        eq(state(f, "island_02").completed, true)
        eq(state(f, "island_02").rewardOwned, true)
        eq(state(f, "island_01").completed, false)
        owned(f.actions:GetOwnedTreasures(), { "memory_island_02" })
        eq(f.actions:GetReceipt(token).status, "completed")
        assertNoMemoryInInventory(f.player)
    end)

    test("completed island exploration cannot be replayed or charged again", function()
        local f = fixture()
        complete(f, "explore", "island_01")
        local stamina = f.player.stamina
        local token, reason = f.actions:BeginExplore("island_01")
        eq(token, nil); eq(reason, "already_completed")
        eq(f.player.stamina, stamina)
        owned(f.actions:GetOwnedTreasures(), { "memory_island_01" })
    end)

    test("T08/T09 committed exploration and salvage toast exact memory and actual remaining stamina once", function()
        local cases = {
            { contentId = "island_01", kind = "explore", label = "岛屿记忆一" },
            { contentId = "island_02", kind = "explore", label = "岛屿记忆二" },
            { contentId = "underwater_treasure_01", kind = "salvage", label = "海底记忆" },
        }
        for _, case in ipairs(cases) do
            local loop = Loop.New()
            local f = fixture(loop.player)
            loop.worldContentActions = f.actions
            if case.kind == "salvage" then markTreasure(f) end
            assert(loop:Depart())
            local before = loop.player.stamina
            local token = assert(loop:BeginWorldContentAction(case.contentId, case.kind))
            eq(loop:GetActionToast(), nil, "begin must not show a successful charge")
            eq(loop.player.stamina, before, "begin must be free")
            loop:Update(3.99)
            eq(loop:GetActionToast(), nil, "incomplete action must not show a reward")
            loop:Update(0.01)
            local toast = assert(loop:GetActionToast())
            assert(toast.text:find("获得记忆：" .. case.label, 1, true), "toast must name the committed memory")
            assert(toast.text:find(string.format("消耗40体力，剩余%d体力", loop.player.stamina), 1, true),
                "toast must use the actual post-commit stamina")
            eq(toast.durationSec, 3)
            eq(loop.player.stamina, before - 40)
            eq(f.actions:GetReceipt(token).commitState, "committed")
            local sameToast = assert(loop:GetActionToast())
            eq(sameToast.id, toast.id, "one action must enqueue one result")
            assert(state(f, case.contentId).completed and state(f, case.contentId).rewardOwned)
        end
    end)

    test("cancelled world-content action creates no paid or memory toast", function()
        local loop = Loop.New()
        local f = fixture(loop.player)
        loop.worldContentActions = f.actions
        assert(loop:Depart())
        local token = assert(loop:BeginWorldContentAction("island_01", "explore"))
        assert(loop:CancelWorldContentAction(token))
        loop:Update(1)
        eq(loop:GetActionToast(), nil)
        eq(loop.player.stamina, 200)
        eq(state(f, "island_01").completed, false)
        eq(state(f, "island_01").rewardOwned, false)
    end)

    test("two services on one player cannot both commit the same island reward", function()
        local f = fixture()
        local second = assert(Actions.New(f))
        local firstToken = assert(f.actions:BeginExplore("island_01"))
        local secondToken = assert(second:BeginExplore("island_01"))
        local firstOk, firstReason = f.actions:Advance(4)
        eq(firstOk, true); eq(firstReason, "completed")
        eq(f.player.stamina, 160)
        local secondOk, secondReason = second:Advance(4)
        eq(secondOk, false); eq(secondReason, "already_completed")
        eq(f.player.stamina, 160)
        eq(f.actions:GetReceipt(firstToken).status, "completed")
        eq(second:GetReceipt(secondToken).status, "failed")
        owned(f.actions:GetOwnedTreasures(), { "memory_island_01" })
    end)

    test("world-content access accepts the five-meter boundary and rejects beyond it", function()
        local f = fixture()
        f.surfaceGap = 5
        local token = assert(f.actions:BeginExplore("island_01"))
        assert(f.actions:Cancel(token, "boundary-check"))
        f.surfaceGap = 5.001
        local rejected, reason = f.actions:BeginExplore("island_01")
        eq(rejected, nil); eq(reason, "out_of_range")
        eq(f.player.stamina, 200)
    end)

    test("low-stamina exploration stays visible but cannot start or charge", function()
        local f = fixture()
        f.player.stamina = 39
        local prompt = assert(f.actions:GetWorldContentPrompt())
        eq(prompt.text, "探索岛屿 · 40体力")
        eq(prompt.staminaCost, 40)
        eq(prompt.canAffordStamina, false)
        local token, reason = f.actions:BeginExplore("island_01")
        eq(token, nil); eq(reason, "insufficient_stamina")
        eq(f.player.stamina, 39)
        eq(f.actions:GetActionState(), nil)
        eq(state(f, "island_01").completed, false)
        eq(state(f, "island_01").rewardOwned, false)
    end)

    test("low-stamina marked treasure stays visible without a salvage receipt", function()
        local f = fixture()
        complete(f, "explore", "island_01")
        complete(f, "explore", "island_02")
        markTreasure(f)
        f.player.stamina = 39
        local prompt = assert(f.actions:GetWorldContentPrompt())
        eq(prompt.text, "打捞宝藏 · 40体力")
        eq(prompt.actionKind, "salvage")
        eq(prompt.staminaCost, 40)
        eq(prompt.canAffordStamina, false)
        local token, reason = f.actions:BeginSalvage("underwater_treasure_01")
        eq(token, nil); eq(reason, "insufficient_stamina")
        eq(f.player.stamina, 39)
        eq(f.actions:GetActionState(), nil)
        eq(state(f, "underwater_treasure_01").completed, false)
        eq(state(f, "underwater_treasure_01").rewardOwned, false)
    end)

    test("T06 low-stamina island click explains the cost without starting or cancelling another action", function()
        local loop = Loop.New()
        local f = fixture(loop.player)
        loop.worldContentActions = f.actions
        loop.player.stamina = 39
        local cancelCalls = 0
        loop.runtime = {
            GetAutoReturnState = function() return { phase = "active" } end,
            CancelAutoReturn = function()
                cancelCalls = cancelCalls + 1
                return true
            end,
        }
        assert(loop:Depart())
        local prompt = assert(loop:GetWorldContentPrompt())
        eq(prompt.text, "探索岛屿 · 40体力")
        eq(prompt.canAffordStamina, false)
        local started, reason = loop:BeginWorldContentAction("island_01", "explore")
        eq(started, false); eq(reason, "insufficient_stamina_explore")
        eq(loop.lastMessage, "体力不足，探索需要40体力。")
        eq(loop.player.stamina, 39)
        eq(cancelCalls, 0, "a rejected low-stamina click cannot cancel auto-return")
        eq(f.actions:GetActionState(), nil)
        eq(state(f, "island_01").completed, false)
        eq(state(f, "island_01").rewardOwned, false)
    end)

    test("exactly 40 stamina is sufficient and a successful action reaches zero", function()
        local f = fixture()
        f.player.stamina = 40
        complete(f, "explore", "island_01")
        eq(f.player.stamina, 0)
        eq(state(f, "island_01").rewardOwned, true)
    end)

    test("invalid content ids and wrong action kinds are rejected without cost", function()
        local f = fixture()
        local token, reason = f.actions:BeginExplore("island_03")
        eq(token, nil); eq(reason, "invalid_content_id")
        token, reason = f.actions:BeginSalvage("island_01")
        eq(token, nil); eq(reason, "invalid_action_kind")
        eq(f.player.stamina, 200)
    end)

    test("cancelling a partly elapsed exploration costs zero stamina", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        assert(f.actions:Advance(2))
        local cancelled, reason = f.actions:Cancel(token, "player-cancelled")
        eq(cancelled, true); eq(reason, "cancelled")
        eq(f.player.stamina, 200)
        eq(state(f, "island_01").completed, false)
        local receipt = f.actions:GetReceipt(token)
        eq(receipt.status, "cancelled"); eq(receipt.cancelReason, "player-cancelled")
        eq(receipt.commitState, "pending")
    end)

    test("Advance rejects nil, negative, NaN, and infinite elapsed values", function()
        local f = fixture()
        local ok, reason = f.actions:Advance(nil)
        eq(ok, false); eq(reason, "invalid_elapsed")
        for _, elapsed in ipairs({ -0.01, 0 / 0, math.huge, -math.huge }) do
            ok, reason = f.actions:Advance(elapsed)
            eq(ok, false); eq(reason, "invalid_elapsed")
        end
        eq(f.actions:GetObservationState().elapsed, 0)
        eq(state(f, "island_01").completed, false)
    end)

    test("treasure scope discovery needs the lens and one continuous second", function()
        local f = fixture()
        f.scopeInside = true
        assert(f.actions:Advance(0.5))
        eq(f.actions:GetObservationState().elapsed, 0)
        eq(state(f, "underwater_treasure_01").marked, false)

        f.player.treasures.scopeLens = true
        assert(f.actions:Advance(0.5))
        eq(f.actions:GetObservationState().elapsed, 0.5)
        f.scopeInside = false
        assert(f.actions:Advance(0))
        eq(f.actions:GetObservationState().elapsed, 0)
        f.scopeInside = true
        assert(f.actions:Advance(0.5))
        eq(state(f, "underwater_treasure_01").marked, false)
        assert(f.actions:Advance(0.5))
        eq(state(f, "underwater_treasure_01").marked, true)
        eq(f.actions:GetObservationState().duration, 1)
    end)

    test("marked treasure stays marked after leaving scope and closing the lens", function()
        local f = fixture()
        markTreasure(f)
        f.scopeInside = false
        f.player.treasures.scopeLens = false
        assert(f.actions:Advance(5))
        eq(state(f, "underwater_treasure_01").marked, true)
        eq(f.actions:GetObservationState().elapsed, 0)
    end)

    test("Advance(0) does not accumulate active-action or scope-observation time", function()
        local f = fixture()
        f.player.treasures.scopeLens = true
        f.scopeInside = true
        local token = assert(f.actions:BeginExplore("island_01"))
        local ok, reason = f.actions:Advance(0)
        eq(ok, true); eq(reason, "active")
        eq(f.actions:GetReceipt(token).elapsed, 0)
        eq(f.actions:GetObservationState().elapsed, 0)
        assert(f.actions:Advance(0.25))
        eq(f.actions:GetReceipt(token).elapsed, 0.25)
        eq(f.actions:GetObservationState().elapsed, 0.25)
        ok, reason = f.actions:Advance(0)
        eq(ok, true); eq(reason, "active")
        eq(f.actions:GetReceipt(token).elapsed, 0.25)
        eq(f.actions:GetObservationState().elapsed, 0.25)
    end)

    test("unmarked treasure cannot start salvage even while visible in scope", function()
        local f = fixture()
        f.player.treasures.scopeLens = true
        f.scopeInside = true
        local token, reason = f.actions:BeginSalvage("underwater_treasure_01")
        eq(token, nil); eq(reason, "content_not_marked")
        eq(f.player.stamina, 200)
        eq(state(f, "underwater_treasure_01").marked, false)
    end)

    test("marked salvage accepts a five-meter gap and remains free until commit", function()
        local f = fixture()
        markTreasure(f)
        f.scopeInside = false
        f.surfaceGap = 5
        local token = assert(f.actions:BeginSalvage("underwater_treasure_01"))
        eq(f.player.stamina, 200)
        assert(f.actions:Advance(2))
        eq(f.player.stamina, 200)
        assert(f.actions:Cancel(token))
        eq(state(f, "underwater_treasure_01").marked, true)
    end)

    test("marked treasure rejects salvage just beyond the five-meter boundary", function()
        local f = fixture()
        markTreasure(f)
        f.scopeInside, f.surfaceGap = false, 5.001
        local token, reason = f.actions:BeginSalvage("underwater_treasure_01")
        eq(token, nil); eq(reason, "out_of_range")
        eq(state(f, "underwater_treasure_01").marked, true)
        eq(f.player.stamina, 200)
    end)

    test("cancelling marked salvage preserves its mark and costs zero", function()
        local f = fixture()
        markTreasure(f)
        f.scopeInside = false
        local token = assert(f.actions:BeginSalvage("underwater_treasure_01"))
        assert(f.actions:Advance(1))
        assert(f.actions:Cancel(token, "leave-site"))
        eq(f.player.stamina, 200)
        local after = state(f, "underwater_treasure_01")
        eq(after.marked, true); eq(after.completed, false); eq(after.rewardOwned, false)
        eq(f.actions:GetReceipt(token).status, "cancelled")
    end)

    test("salvage commits one matching treasure memory for one 40-stamina cost", function()
        local f = fixture()
        markTreasure(f)
        f.scopeInside = false
        local stamina = f.player.stamina
        local token = complete(f, "salvage", "underwater_treasure_01")
        eq(f.player.stamina, stamina - 40)
        local after = state(f, "underwater_treasure_01")
        eq(after.marked, true); eq(after.completed, true); eq(after.rewardOwned, true)
        owned(f.actions:GetOwnedTreasures(), { "memory_treasure_01" })
        eq(f.actions:GetReceipt(token).commitState, "committed")
        assertNoMemoryInInventory(f.player)
    end)

    test("completed treasure salvage cannot grant or charge its reward again", function()
        local f = fixture()
        markTreasure(f)
        f.scopeInside = false
        complete(f, "salvage", "underwater_treasure_01")
        local stamina = f.player.stamina
        local token, reason = f.actions:BeginSalvage("underwater_treasure_01")
        eq(token, nil); eq(reason, "already_completed")
        eq(f.player.stamina, stamina)
        local advanced, advanceReason = f.actions:Advance(4)
        eq(advanced, true); eq(advanceReason, "idle")
        eq(f.player.stamina, stamina)
        owned(f.actions:GetOwnedTreasures(), { "memory_treasure_01" })
        assertNoMemoryInInventory(f.player)
    end)

    test("all three memories stay outside inventory and scopeLens is not a memory", function()
        local f = fixture()
        complete(f, "explore", "island_01")
        complete(f, "explore", "island_02")
        markTreasure(f)
        f.scopeInside = false
        complete(f, "salvage", "underwater_treasure_01")
        owned(f.actions:GetOwnedTreasures(), MEMORY_IDS)
        assertNoMemoryInInventory(f.player)
        eq(f.player.treasures.scopeLens, true)
        eq(f.player.stamina, 80)
    end)

    test("owned memory query returns only owned fixed memory ids", function()
        local f = fixture()
        f.player.treasures.scopeLens = true
        owned(f.actions:GetOwnedTreasures(), {})
        complete(f, "explore", "island_02")
        owned(f.actions:GetOwnedTreasures(), { "memory_island_02" })
    end)

    test("world-content memories survive a day change through snapshot and restore", function()
        local f = fixture()
        f.player.day = 2
        f.player.money = 7654
        f.player.recognizedLocations = { reef = true }
        assert(Circle1B2Progress.GrantLens(f.player))
        assert(Circle1B2Progress.SetBarrelStage(f.player, 2))
        complete(f, "explore", "island_01")
        complete(f, "explore", "island_02")
        markTreasure(f)
        f.scopeInside = false
        complete(f, "salvage", "underwater_treasure_01")
        local inventoryBefore = f.player.inventory:GetItems()
        local saved = Persistence.Snapshot(f.player)
        local valid, validationError = Progress.Validate(saved)
        assert(valid, validationError)
        saved.day = saved.day + 1
        local restored, restoreError = Persistence.Restore(saved)
        assert(restored, restoreError)
        assert(Progress.Initialize(restored))
        assert(Progress.Validate(restored))
        eq(restored.day, 3)
        eq(restored.money, 7654)
        eq(restored.stamina, 80)
        eq(restored.maxStamina, 200)
        eq(restored.recognizedLocations.reef, true)
        eq(restored.treasures.scopeLens, true)
        eq(assert(Circle1B2Progress.GetBarrelStage(restored)), 2)
        eq(#restored.inventory:GetItems(), #inventoryBefore)
        for index, itemId in ipairs(inventoryBefore) do eq(restored.inventory:GetItems()[index], itemId) end
        eq(assert(Progress.GetState(restored, "island_01")).rewardOwned, true)
        eq(assert(Progress.GetState(restored, "island_02")).rewardOwned, true)
        local treasure = assert(Progress.GetState(restored, "underwater_treasure_01"))
        eq(treasure.marked, true); eq(treasure.completed, true); eq(treasure.rewardOwned, true)
        local restoredActions = fixture(restored).actions
        owned(restoredActions:GetOwnedTreasures(), MEMORY_IDS)
        assertNoMemoryInInventory(restored)
    end)

    test("Player.Reset clears world memories and the next service initializes empty records", function()
        local f = fixture()
        complete(f, "explore", "island_01")
        complete(f, "explore", "island_02")
        markTreasure(f)
        f.scopeInside = false
        complete(f, "salvage", "underwater_treasure_01")
        local oldStory, oldTreasures = f.player.story, f.player.treasures
        assert(f.player:Reset())
        assert(f.player.story ~= oldStory and f.player.treasures ~= oldTreasures)
        assert(Progress.Initialize(f.player))
        for _, contentId in ipairs({ "island_01", "island_02", "underwater_treasure_01" }) do
            local reset = state(f, contentId)
            eq(reset.completed, false); eq(reset.rewardOwned, false)
            if contentId == "underwater_treasure_01" then eq(reset.marked, false) end
        end
        owned(f.actions:GetOwnedTreasures(), {})
    end)

    test("malformed completed/reward mismatch is rejected without auto-repair", function()
        local f = fixture()
        f.player.story.worldContent.island_01.completed = true
        local valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "content_reward_completion_mismatch")
        eq(f.player.story.worldContent.island_01.completed, true)
        eq(f.player.treasures.memory_island_01, false)
        local service, initReason = Actions.New(f)
        eq(service, nil); eq(initReason, "content_reward_completion_mismatch")
    end)

    test("malformed owned memory without completion is rejected", function()
        local f = fixture()
        f.player.treasures.memory_island_02 = true
        local valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "content_reward_completion_mismatch")
    end)

    test("pre-owned memories with incomplete records reject explore and salvage without charging", function()
        local island = fixture()
        island.player.treasures.memory_island_01 = true
        local islandToken, islandReason = island.actions:BeginExplore("island_01")
        eq(islandToken, nil); eq(islandReason, "content_reward_completion_mismatch")
        eq(island.player.stamina, 200)

        local treasure = fixture()
        treasure.player.story.worldContent.underwater_treasure_01.marked = true
        treasure.player.treasures.memory_treasure_01 = true
        local treasureToken, treasureReason = treasure.actions:BeginSalvage("underwater_treasure_01")
        eq(treasureToken, nil); eq(treasureReason, "content_reward_completion_mismatch")
        eq(treasure.player.stamina, 200)
    end)

    test("completion and reward added after Begin cannot be charged or overwritten", function()
        local cases = {
            { kind = "explore", contentId = "island_01", rewardId = "memory_island_01" },
            { kind = "salvage", contentId = "underwater_treasure_01", rewardId = "memory_treasure_01" },
        }
        for _, case in ipairs(cases) do
            local f = fixture()
            if case.kind == "salvage" then
                f.player.story.worldContent[case.contentId].marked = true
            end
            local token = assert(begin(f, case.kind, case.contentId))
            f.player.story.worldContent[case.contentId].completed = true
            f.player.treasures[case.rewardId] = true
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "already_completed")
            eq(f.player.stamina, 200)
            local current = assert(Progress.GetState(f.player, case.contentId))
            eq(current.completed, true); eq(current.rewardOwned, true)
            eq(f.actions:GetReceipt(token).status, "failed")
        end
    end)

    test("malformed completed treasure without its discovery mark is rejected", function()
        local f = fixture()
        local record = f.player.story.worldContent.underwater_treasure_01
        record.completed = true
        f.player.treasures.memory_treasure_01 = true
        local valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "completed_content_not_marked")
    end)

    test("unknown world-content record ids and fields are rejected", function()
        local f = fixture()
        f.player.story.worldContent.unknown = { completed = false }
        local valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "invalid_content_id")
        f.player.story.worldContent.unknown = nil
        f.player.story.worldContent.island_01.extra = true
        valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "invalid_content_progress_field")
    end)

    test("invalid world-content record types and boolean fields are rejected", function()
        local f = fixture()
        local records = f.player.story.worldContent
        f.player.story.worldContent = false
        local valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "invalid_world_content_progress")
        f.player.story.worldContent = "malformed"
        valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "invalid_world_content_progress")
        f.player.story.worldContent = records

        f.player.story.worldContent.island_01 = false
        valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "invalid_content_progress")
        f.player.story.worldContent.island_01 = { completed = "false" }
        valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "invalid_content_completed")
        f.player.story.worldContent.island_01 = { completed = false }
        f.player.story.worldContent.underwater_treasure_01.marked = 1
        valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "invalid_content_marked")
    end)

    test("Initialize rejects worldContent=false without throwing or repairing it", function()
        local f = fixture()
        f.player.story.worldContent = false
        local safe, initialized, reason = pcall(Progress.Initialize, f.player)
        eq(safe, true)
        eq(initialized, false); eq(reason, "invalid_world_content_progress")
        eq(f.player.story.worldContent, false)
    end)

    test("receipt and action-state snapshots cannot mutate the live receipt", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        local receipt = f.actions:GetReceipt(token)
        receipt.contentId = "island_02"
        receipt.begin.stamina = -1
        local active = f.actions:GetActionState()
        active.actionKind = "salvage"
        eq(active.contentId, "island_01")
        local reread = f.actions:GetActionState()
        eq(reread.contentId, "island_01")
        eq(reread.actionKind, "explore")
        eq(reread.begin.stamina, 200)
        local receiptAgain = f.actions:GetReceipt(token)
        eq(receiptAgain.contentId, "island_01")
        eq(receiptAgain.begin.stamina, 200)
    end)

    test("world-content prompt switches from begin to token-bound cancel and back", function()
        local f = fixture()
        local prompt = assert(f.actions:GetWorldContentPrompt())
        eq(prompt.operation, "begin"); eq(prompt.contentId, "island_01"); eq(prompt.enabled, true)
        local token = assert(f.actions:BeginExplore("island_01"))
        prompt = assert(f.actions:GetWorldContentPrompt())
        eq(prompt.operation, "cancel"); eq(prompt.token, token); eq(prompt.actionKind, "explore")
        assert(f.actions:Cancel(prompt.token))
        prompt = assert(f.actions:GetWorldContentPrompt())
        eq(prompt.operation, "begin")
    end)

    local function assertStaleAction(f, token)
        local stamina = f.player.stamina
        local ok, reason = f.actions:Advance(4)
        eq(ok, false); eq(reason, "stale_generation")
        local receipt = f.actions:GetReceipt(token)
        eq(receipt.status, "failed"); eq(receipt.failureReason, "stale_generation")
        eq(f.player.stamina, stamina)
        eq(state(f, "island_01").completed, false)
    end

    test("load replacement makes an active receipt stale and cannot commit late", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        local saved = Persistence.Snapshot(f.player)
        assert(Progress.Validate(saved))
        local restored = assert(Persistence.Restore(saved))
        assert(Progress.Initialize(restored))
        f.context.sessionGeneration = f.context.sessionGeneration + 1
        f.context.player = restored
        f.player = restored
        assertStaleAction(f, token)
    end)

    test("new-run generation and player replacement invalidate the old receipt", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        local nextPlayer = assert(Player.New())
        f.context.sessionGeneration = f.context.sessionGeneration + 1
        f.context.player = nextPlayer
        f.player = nextPlayer
        assertStaleAction(f, token)
        eq(state(f, "island_01").completed, false)
    end)

    test("Player.Reset invalidates an active action through replaced progress containers", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        assert(f.player:Reset())
        assertStaleAction(f, token)
        local nextService = assert(Actions.New(f))
        eq(assert(Progress.GetState(f.player, "island_01")).completed, false)
        owned(nextService:GetOwnedTreasures(), {})
    end)

    test("runtime identity replacement invalidates even with the same session generation", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        f.context.runtimeIdentity = {}
        assertStaleAction(f, token)
    end)

    test("fixed world-content generation replacement invalidates an active action", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        f.context.fixedContentGeneration = f.context.fixedContentGeneration + 1
        assertStaleAction(f, token)
    end)

    test("GetActionState detects runtime replacement before any Advance call", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        f.context.runtimeIdentity = {}
        eq(f.actions:GetActionState(), nil)
        local receipt = f.actions:GetReceipt(token)
        eq(receipt.status, "failed")
        eq(receipt.failureReason, "stale_generation")
        eq(f.player.stamina, 200)
    end)

    test("GetReceipt detects runtime replacement before any Advance call", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        f.context.runtimeIdentity = {}
        local receipt = f.actions:GetReceipt(token)
        eq(receipt.status, "failed")
        eq(receipt.failureReason, "stale_generation")
        eq(f.player.stamina, 200)
    end)

    test("ordinary fishing generation changes do not stale fixed world-content work", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        f.context.fishingGeneration = f.context.fishingGeneration + 1
        local ok, reason = f.actions:Advance(4)
        eq(ok, true); eq(reason, "completed")
        eq(f.actions:GetReceipt(token).status, "completed")
        eq(state(f, "island_01").rewardOwned, true)
    end)

    test("fixed entity replacement during an action fails before charging", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        f.accessEntityId = "replacement-island"
        local ok, reason = f.actions:Advance(4)
        eq(ok, false); eq(reason, "stale_generation")
        eq(f.actions:GetReceipt(token).status, "failed")
        eq(f.player.stamina, 200)
        eq(state(f, "island_01").completed, false)
    end)

    test("explicit invalidation finalizes active work without charging", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        assert(f.actions:Invalidate("load_saved"))
        local receipt = f.actions:GetReceipt(token)
        eq(receipt.status, "failed"); eq(receipt.failureReason, "load_saved")
        eq(f.player.stamina, 200)
        eq(f.actions:GetActionState(), nil)
    end)

    test("ConsumeStamina returning false rolls back and leaves the action retryable", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        withPatched(f.player, "ConsumeStamina", function(_, _)
            return false, "injected_charge_rejection"
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "injected_charge_rejection")
            local receipt = assertRollback(f, token, "island_01", 200)
            eq(receipt.failureReason, "injected_charge_rejection")
        end)
        local retry = assert(f.actions:BeginExplore("island_01"))
        eq(f.actions:GetReceipt(retry).status, "active")
    end)

    test("ConsumeStamina throwing before deduction rolls back safely", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        withPatched(f.player, "ConsumeStamina", function() error("injected charge exception") end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "commit_exception")
            local receipt = assertRollback(f, token, "island_01", 200)
            eq(receipt.failureReason, "commit_exception")
        end)
    end)

    test("reentrant Advance, Cancel, and Begin calls during ConsumeStamina return busy", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        local nestedAdvance, nestedAdvanceReason
        local nestedCancel, nestedCancelReason
        local nestedBegin, nestedBeginReason
        withPatched(f.player, "ConsumeStamina", function(self, cost)
            nestedAdvance, nestedAdvanceReason = f.actions:Advance(0)
            nestedCancel, nestedCancelReason = f.actions:Cancel(token)
            nestedBegin, nestedBeginReason = f.actions:BeginExplore("island_02")
            return Player.ConsumeStamina(self, cost)
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, true); eq(reason, "completed")
        end)
        eq(nestedAdvance, false); eq(nestedAdvanceReason, "busy")
        eq(nestedCancel, false); eq(nestedCancelReason, "busy")
        eq(nestedBegin, nil); eq(nestedBeginReason, "busy")
        eq(f.player.stamina, 160)
        eq(state(f, "island_01").completed, true)
        eq(f.actions:GetActionState(), nil)
    end)

    test("ConsumeStamina charging and then returning false restores the pre-commit balance", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        f.player.stamina = 123
        withPatched(f.player, "ConsumeStamina", function(self, cost)
            self.stamina = self.stamina - cost
            return false, "injected_rejection_after_charge"
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "injected_rejection_after_charge")
            local receipt = assertRollback(f, token, "island_01", 123)
            eq(receipt.begin.stamina, 200, "begin-time balance is distinct from rollback balance")
        end)
    end)

    test("ConsumeStamina charging and then throwing restores the pre-commit balance", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        f.player.stamina = 123
        withPatched(f.player, "ConsumeStamina", function(self, cost)
            self.stamina = self.stamina - cost
            error("injected exception after charge")
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "commit_exception")
            local receipt = assertRollback(f, token, "island_01", 123)
            eq(receipt.begin.stamina, 200)
        end)
    end)

    test("world generation change during ConsumeStamina rolls back with no net charge", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        withPatched(f.player, "ConsumeStamina", function(self, cost)
            local charged, reason = Player.ConsumeStamina(self, cost)
            assert(charged, reason)
            f.context.fixedContentGeneration = f.context.fixedContentGeneration + 1
            return true
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "stale_generation")
            assertRollback(f, token, "island_01", 200)
        end)
    end)

    test("Player.Reset inside ConsumeStamina keeps reset stamina instead of stale rollback", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        local initialStamina = assert(Player.New()).stamina
        withPatched(f.player, "ConsumeStamina", function(self)
            assert(self:Reset())
            return true
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "stale_generation")
        end)
        eq(f.player.stamina, initialStamina)
        eq(f.actions:GetReceipt(token).status, "failed")
        eq(f.actions:GetReceipt(token).failureReason, "stale_generation")
        eq(assert(Progress.Validate(f.player)), true)
    end)

    test("Progress.Commit returning false restores stamina and progress", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        withPatched(Progress, "Commit", function() return false, "injected_progress_rejection" end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "injected_progress_rejection")
            local receipt = assertRollback(f, token, "island_01", 200)
            eq(receipt.failureReason, "injected_progress_rejection")
        end)
    end)

    test("Progress.Commit throwing after charge restores stamina and progress", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_02"))
        withPatched(Progress, "Commit", function() error("injected progress exception") end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "commit_exception")
            assertRollback(f, token, "island_02", 200)
        end)
    end)

    test("Progress.Commit writing only completion before throw restores both fields", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        withPatched(Progress, "Commit", function(player, contentId)
            player.story.worldContent[contentId].completed = true
            error("injected completion-only write exception")
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "commit_exception")
            assertRollback(f, token, "island_01", 200)
        end)
    end)

    test("Progress.Commit writing only reward before throw restores both fields", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        withPatched(Progress, "Commit", function(player)
            player.treasures.memory_island_01 = true
            error("injected reward-only write exception")
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "commit_exception")
            assertRollback(f, token, "island_01", 200)
        end)
    end)

    test("partial Progress.Commit write followed by throw restores every touched field", function()
        local f = fixture()
        markTreasure(f)
        f.scopeInside = false
        local token = assert(f.actions:BeginSalvage("underwater_treasure_01"))
        withPatched(Progress, "Commit", function(player, contentId)
            player.story.worldContent[contentId].completed = true
            player.treasures.memory_treasure_01 = true
            error("injected post-write exception")
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "commit_exception")
            local receipt = assertRollback(f, token, "underwater_treasure_01", 200, true)
            eq(receipt.failureReason, "commit_exception")
        end)
    end)

    test("Progress.Commit false after a partial write cannot leak completion or a reward", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_01"))
        withPatched(Progress, "Commit", function(player, contentId)
            player.story.worldContent[contentId].completed = true
            return false, "injected_partial_commit_rejection"
        end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "injected_partial_commit_rejection")
            assertRollback(f, token, "island_01", 200)
        end)
    end)

    test("a false-success Progress.Commit result fails consistency checks and rolls back", function()
        local f = fixture()
        local token = assert(f.actions:BeginExplore("island_02"))
        withPatched(Progress, "Commit", function() return true, "committed" end, function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false); eq(reason, "commit_consistency_failed")
            assertRollback(f, token, "island_02", 200)
        end)
    end)

    test("Circle1B2 scope lens and barrel progress survive world-content initialization", function()
        local f = fixture()
        assert(Circle1B2Progress.GrantLens(f.player))
        assert(Circle1B2Progress.SetBarrelStage(f.player, 2))
        local legacyRecord = f.player.story.circle1B2
        local nextService = assert(Actions.New(f))
        eq(assert(Circle1B2Progress.HasLens(f.player)), true)
        eq(assert(Circle1B2Progress.GetBarrelStage(f.player)), 2)
        eq(f.player.story.circle1B2, legacyRecord)
        assert(Progress.Validate(f.player))
        owned(nextService:GetOwnedTreasures(), {})
    end)

    test("malformed Circle1B2 lens/barrel state still blocks world-content initialization", function()
        local f = fixture()
        f.player.story.circle1B2.barrelStage = 3
        f.player.treasures.scopeLens = false
        local valid, reason = Progress.Validate(f.player)
        eq(valid, false); eq(reason, "final_barrel_stage_requires_lens")
        local safe, initialized, initReason = pcall(Progress.Initialize, f.player)
        eq(safe, true)
        eq(initialized, false); eq(initReason, "final_barrel_stage_requires_lens")
        local service, serviceReason = Actions.New(f)
        eq(service, nil); eq(serviceReason, "final_barrel_stage_requires_lens")
    end)

    test("world-content access rejects a mismatched returned id and stale generation", function()
        local f = fixture()
        f.accessContentId = "island_02"
        local token, reason = f.actions:BeginExplore("island_01")
        eq(token, nil); eq(reason, "content_identity_mismatch")
        f.accessContentId = nil
        f.accessGeneration = 99
        token, reason = f.actions:BeginExplore("island_01")
        eq(token, nil); eq(reason, "stale_generation")
        eq(f.player.stamina, 200)
    end)

    local passed = 0
    for _, result in ipairs(results) do
        if result.passed then passed = passed + 1 end
    end
    return { results = results, passed = passed, total = #results }
end

return Tests
