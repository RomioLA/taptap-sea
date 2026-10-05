-- Pending-catch transaction tests share the protocol Runtime used by the flow suite.
local Flow = require("tests.Circle1BFishingFlowTests")
local Tests = {}

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function items(actual, expected, label)
    Flow.AssertItems(actual, expected, label)
end

local FULL_HOLD = { "apple", "bait", "sardine", "tuna", "sardine" }

local function fullFixture()
    local fixture = Flow.Fixture({ items = FULL_HOLD })
    assert(fixture.loop:Depart())
    return fixture
end

local function completeCatch(fixture, species)
    local fish = fixture.runtime:spawnFish(species or "tuna", { x = 1, y = 0 })
    local token = assert(fixture.bridge:BeginFishing({ x = 0, y = 0 }))
    assert(fixture.runtime.selectCalls == 0)
    fixture.bridge:Update(4)
    local ok, outcome, itemId = fixture.bridge:CompleteFishing(token)
    assert(ok and outcome == "pending_catch" and itemId == (species or "tuna"))
    return fish, token, itemId
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("full hold can cast and an empty net completes without fee or forced receive", function()
        local fixture = fullFixture()
        local before = fixture.loop.player.inventory:GetItems()
        local token = assert(fixture.bridge:BeginFishing({ x = 0, y = 0 }))
        assert(fixture.runtime.selectCalls == 0)
        fixture.bridge:Update(4)
        local ok, outcome = fixture.bridge:CompleteFishing(token)
        assert(ok and outcome == "empty")
        eq(fixture.loop.player.stamina, 100)
        items(fixture.loop.player.inventory:GetItems(), before)
        assert(not fixture.loop:HasPendingCatch())
        assert(not fixture.loop.inventoryOpen)
    end)

    test("full hold preserves a successful catch, charges once and requires the cargo panel", function()
        local fixture = fullFixture()
        local before = fixture.loop.player.inventory:GetItems()
        local fish, token = completeCatch(fixture, "tuna")
        assert(fish.removed and fixture.runtime:GetFishingTarget(fish.id) == nil)
        eq(fixture.loop.player.stamina, 60)
        items(fixture.loop.player.inventory:GetItems(), before)
        assert(fixture.loop:HasPendingCatch())
        local pending = assert(fixture.loop:GetPendingCatch())
        eq(pending.requiredSlots, 1)
        items(pending.itemIds, { "tuna" }, "pending items")
        assert(fixture.loop.inventoryOpen and fixture.loop.clock.pauseReasons.inventory)
        local closed, closeReason = fixture.loop:SetInventoryOpen(false)
        eq(closed, false); eq(closeReason, "pending_catch_required")
        local started, startReason = fixture.bridge:BeginFishing({ x = 0, y = 0 })
        eq(started, nil); eq(startReason, "pending_catch_required")
        local replay, outcome, itemId = fixture.bridge:CompleteFishing(token)
        assert(replay and outcome == "pending_catch" and itemId == "tuna")
        eq(fixture.loop.player.stamina, 60)
        items(fixture.loop.player.inventory:GetItems(), before)
        local claimed, claimReason = fixture.loop:ClaimPendingCatch()
        eq(claimed, false); eq(claimReason, "inventory_full")
        assert(fixture.loop:HasPendingCatch())
    end)

    test("using or dropping cargo frees one slot and claims the retained catch exactly once", function()
        for _, mode in ipairs({ "use", "drop" }) do
            local fixture = fullFixture()
            -- Existing treasure state is outside ordinary cargo and must survive cargo edits.
            local treasures = fixture.loop.player.treasures
            treasures.circle1BProtectionSentinel = true
            local fish, token = completeCatch(fixture, "sardine")
            local spentStamina = fixture.loop.player.stamina
            assert(fish.removed and fixture.loop:HasPendingCatch())
            local closed, reason = fixture.loop:SetInventoryOpen(false)
            eq(closed, false); eq(reason, "pending_catch_required")

            if mode == "use" then
                assert(fixture.loop:UseItem(1))
            else
                assert(fixture.bridge:SetDropTarget({ x = 2, y = 0 }))
                assert(fixture.loop:DropItem(2))
                eq(#fixture.runtime.droppedItems, 1)
                eq(fixture.runtime.droppedItems[1].itemId, "bait")
            end
            local afterFreeing = fixture.loop.player.inventory:GetItems()
            assert(#afterFreeing == #FULL_HOLD - 1)
            assert(fixture.loop:HasPendingCatch())

            assert(fixture.loop:ClaimPendingCatch())
            assert(not fixture.loop:HasPendingCatch())
            local afterClaim = fixture.loop.player.inventory:GetItems()
            assert(fixture.loop.player.treasures == treasures and treasures.circle1BProtectionSentinel == true)
            eq(#afterClaim, #FULL_HOLD)
            eq(afterClaim[#afterClaim], "sardine")
            if mode == "drop" then eq(fixture.loop.player.stamina, spentStamina) end
            if mode == "use" then eq(fixture.loop.player.stamina, 80) end
            local repeated = fixture.loop:ClaimPendingCatch()
            eq(repeated, false)
            local replay, outcome = fixture.bridge:CompleteFishing(token)
            assert(replay and outcome == "pending_catch")
            eq(#fixture.loop.player.inventory:GetItems(), #FULL_HOLD)
        end
    end)

    test("claim restores the full post-freeing inventory after Add mutates then throws", function()
        local fixture = fullFixture()
        local fish, token = completeCatch(fixture, "tuna")
        assert(fish.removed)
        assert(fixture.loop.player.inventory:Remove(1))
        local beforeClaim = fixture.loop.player.inventory:GetItems()
        local stamina = fixture.loop.player.stamina
        local inventory = fixture.loop.player.inventory
        local originalAdd = inventory.Add
        inventory.Add = function(self, itemId)
            local added, reason = originalAdd(self, itemId)
            if added then error("injected claim Add failure") end
            return added, reason
        end
        local ok, reason = fixture.loop:ClaimPendingCatch()
        inventory.Add = originalAdd
        eq(ok, false); eq(reason, "inventory_add_failed")
        items(inventory:GetItems(), beforeClaim, "restored inventory")
        eq(fixture.loop.player.stamina, stamina)
        assert(fixture.loop:HasPendingCatch())
        assert(fixture.runtime:GetFishingTarget(fish.id) == nil)

        assert(fixture.loop:ClaimPendingCatch())
        assert(not fixture.loop:HasPendingCatch())
        eq(#inventory:GetItems(), #beforeClaim + 1)
        eq(inventory:GetItems()[#inventory:GetItems()], "tuna")
        local replay, outcome = fixture.bridge:CompleteFishing(token)
        assert(replay and outcome == "pending_catch")
        eq(#inventory:GetItems(), #beforeClaim + 1)
        eq(fixture.loop.player.stamina, stamina)
    end)

    test("claim retries inventory rollback before Add and blocks inventory use while rollback is pending", function()
        local fixture = fullFixture()
        local fish, token = completeCatch(fixture, "tuna")
        assert(fish.removed)
        local inventory = fixture.loop.player.inventory
        assert(inventory:Remove(2)) -- free bait's slot, retaining the heal item for the blocked-operation check
        local beforeClaim = inventory:GetItems()
        local stamina = fixture.loop.player.stamina
        local originalGetItems = inventory.GetItems
        local originalAdd = inventory.Add
        local originalRestoreItems = inventory.RestoreItems
        local addCalls, restoreCalls, order = 0, 0, {}

        inventory.Add = function(self, itemId)
            addCalls = addCalls + 1
            order[#order + 1] = "add"
            local added, reason = originalAdd(self, itemId)
            if addCalls == 1 and added then error("injected claim Add mutation failure") end
            return added, reason
        end
        inventory.RestoreItems = function(self, itemsToRestore)
            restoreCalls = restoreCalls + 1
            order[#order + 1] = "restore"
            if restoreCalls == 1 then error("injected claim RestoreItems failure") end
            return originalRestoreItems(self, itemsToRestore)
        end

        local claimed, claimReason = fixture.loop:ClaimPendingCatch()
        eq(claimed, false); eq(claimReason, "fishing_rollback_pending")
        assert(fixture.loop:HasPendingCatch())
        assert(fixture.loop.actions:IsClaimBlocked())
        local afterFailedRollback = originalGetItems(inventory)
        eq(#afterFailedRollback, #beforeClaim + 1)
        eq(afterFailedRollback[#afterFailedRollback], "tuna")
        eq(fixture.loop.player.stamina, stamina)

        assert(not fixture.loop:CanManageInventory())
        local used, useReason = fixture.loop:UseItem(1)
        eq(used, false); assert(useReason ~= nil)
        items(originalGetItems(inventory), afterFailedRollback, "inventory while rollback is pending")
        eq(fixture.loop.player.stamina, stamina)

        assert(fixture.loop:ClaimPendingCatch())
        assert(not fixture.loop:HasPendingCatch())
        eq(addCalls, 2)
        eq(restoreCalls, 2)
        items(order, { "add", "restore", "restore", "add" }, "claim recovery order")
        local afterClaim = originalGetItems(inventory)
        items(afterClaim, { "apple", "sardine", "tuna", "sardine", "tuna" }, "claimed inventory")
        eq(fixture.loop.player.stamina, stamina)
        assert(fixture.runtime:GetFishingTarget(fish.id) == nil)
        local repeated = fixture.loop:ClaimPendingCatch()
        eq(repeated, false)
        local replay, outcome, itemId = fixture.bridge:CompleteFishing(token)
        assert(replay and outcome == "pending_catch" and itemId == "tuna")
        items(originalGetItems(inventory), afterClaim, "inventory after replay")

        inventory.Add = originalAdd
        inventory.RestoreItems = originalRestoreItems
    end)

    test("UseItem and DropItem roll back a Remove that mutates then throws before freeing cargo", function()
        for _, mode in ipairs({ "use", "drop" }) do
            local fixture = fullFixture()
            local fish, token = completeCatch(fixture, "tuna")
            assert(fish.removed and fixture.loop:HasPendingCatch())
            local inventory = fixture.loop.player.inventory
            local originalRemove = inventory.Remove
            local beforeItems = inventory:GetItems()
            local beforeStamina = fixture.loop.player.stamina
            if mode == "drop" then assert(fixture.bridge:SetDropTarget({ x = 2, y = 0 })) end

            inventory.Remove = function(self, index)
                local removed, reason = originalRemove(self, index)
                if removed then error("injected " .. mode .. " Remove failure") end
                return removed, reason
            end
            local freed, freeReason
            if mode == "use" then
                freed, freeReason = fixture.loop:UseItem(1)
            else
                freed, freeReason = fixture.loop:DropItem(2)
            end
            inventory.Remove = originalRemove

            eq(freed, false); assert(freeReason ~= nil)
            items(inventory:GetItems(), beforeItems, mode .. " restored inventory")
            eq(fixture.loop.player.stamina, beforeStamina)
            assert(fixture.loop:HasPendingCatch())
            if mode == "drop" then eq(#fixture.runtime.droppedItems, 0) end

            if mode == "use" then
                assert(fixture.loop:UseItem(1))
                eq(fixture.loop.player.stamina, 80)
            else
                assert(fixture.bridge:SetDropTarget({ x = 2, y = 0 }))
                assert(fixture.loop:DropItem(2))
                eq(#fixture.runtime.droppedItems, 1)
                eq(fixture.runtime.droppedItems[1].itemId, "bait")
            end
            assert(fixture.loop:HasPendingCatch())
            assert(fixture.loop:ClaimPendingCatch())
            assert(not fixture.loop:HasPendingCatch())
            local afterClaim = inventory:GetItems()
            eq(#afterClaim, #FULL_HOLD)
            eq(afterClaim[#afterClaim], "tuna")
            eq(fixture.loop.player.stamina, mode == "use" and 80 or beforeStamina)
            local repeated = fixture.loop:ClaimPendingCatch()
            eq(repeated, false)
            local replay, outcome, itemId = fixture.bridge:CompleteFishing(token)
            assert(replay and outcome == "pending_catch" and itemId == "tuna")
            items(inventory:GetItems(), afterClaim, mode .. " inventory after replay")
        end
    end)

    test("rejected drop receiver restores cargo and allows one later successful release and claim", function()
        local receiverAccepts = false
        local fixture = Flow.Fixture({
            items = FULL_HOLD,
            dropReceiver = function() return receiverAccepts end,
        })
        assert(fixture.loop:Depart())
        local fish, token = completeCatch(fixture, "tuna")
        assert(fish.removed and fixture.loop:HasPendingCatch())
        local inventory = fixture.loop.player.inventory
        local beforeItems = inventory:GetItems()
        local beforeStamina = fixture.loop.player.stamina

        assert(fixture.bridge:SetDropTarget({ x = 2, y = 0 }))
        local dropped, dropReason = fixture.loop:DropItem(2)
        eq(dropped, false); eq(dropReason, "drop_rejected")
        items(inventory:GetItems(), beforeItems, "inventory after rejected receiver")
        eq(fixture.loop.player.stamina, beforeStamina)
        assert(fixture.loop:HasPendingCatch())
        eq(#fixture.runtime.droppedItems, 1)
        local rejectedEntity = fixture.runtime.droppedItems[1]
        assert(rejectedEntity.removed)
        eq(fixture.runtime.world:GetEntity(rejectedEntity.id), nil)

        receiverAccepts = true
        assert(fixture.bridge:SetDropTarget({ x = 2, y = 0 }))
        assert(fixture.loop:DropItem(2))
        items(inventory:GetItems(), { "apple", "sardine", "tuna", "sardine" }, "inventory after accepted drop")
        eq(#fixture.runtime.droppedItems, 2)
        eq(fixture.runtime.droppedItems[2].itemId, "bait")
        assert(not fixture.runtime.droppedItems[2].removed)
        assert(fixture.loop:ClaimPendingCatch())
        assert(not fixture.loop:HasPendingCatch())
        local afterClaim = inventory:GetItems()
        eq(#afterClaim, #FULL_HOLD)
        eq(afterClaim[#afterClaim], "tuna")
        eq(fixture.loop.player.stamina, beforeStamina)
        local repeated = fixture.loop:ClaimPendingCatch()
        eq(repeated, false)
        local replay, outcome, itemId = fixture.bridge:CompleteFishing(token)
        assert(replay and outcome == "pending_catch" and itemId == "tuna")
        items(inventory:GetItems(), afterClaim, "inventory after replay")
    end)

    test("world removal mutation followed by an exception restores fish, inventory and stamina", function()
        local fixture = Flow.Fixture()
        assert(fixture.loop:Depart())
        local fish = fixture.runtime:spawnFish("tuna", { x = 1, y = 0 })
        local inventory = fixture.loop.player.inventory
        local beforeItems, beforeStamina = inventory:GetItems(), fixture.loop.player.stamina
        fixture.runtime:SetFault("remove", "throw_after")
        local token = assert(fixture.bridge:BeginFishing({ x = 0, y = 0 }))
        fixture.bridge:Update(4)
        local ok, reason = fixture.bridge:CompleteFishing(token)
        eq(ok, false); eq(reason, "fishing_commit_failed")
        assert(fixture.runtime:GetFishingTarget(fish.id) == fish)
        assert(fish.alive and not fish.removed and not fish.captureLocked)
        items(inventory:GetItems(), beforeItems)
        eq(fixture.loop.player.stamina, beforeStamina)
        assert(not fixture.loop:HasPendingCatch())
        eq(fixture.loop:GetFishingState().state, "failed")
    end)

    test("night settlement and NewRun cannot discard an already completed pending catch", function()
        local fixture = fullFixture()
        local fish = completeCatch(fixture, "tuna")
        assert(fish.removed and fixture.loop:HasPendingCatch())
        local before = fixture.loop:GetPendingCatch()
        fixture.loop.clock:Resume("inventory")
        fixture.loop.clock:Seek("night", fixture.loop.clock.nightSec)
        fixture.loop:RefreshClockStatus()
        assert(fixture.loop.forcedReturnPending)
        local returned, returnReason = fixture.loop:ConfirmForcedReturn()
        eq(returned, false); eq(returnReason, "pending_catch_required")
        local reset, resetReason = fixture.bridge:NewRun()
        eq(reset, false); eq(resetReason, "pending_catch_required")
        assert(fixture.loop:HasPendingCatch())
        local after = assert(fixture.loop:GetPendingCatch())
        items(after.itemIds, before.itemIds, "pending catch after night/reset")
        eq(after.requiredSlots, before.requiredSlots)
        eq(fixture.loop.player.stamina, 60)
        assert(fixture.runtime:GetFishingTarget(fish.id) == nil)
    end)

    -- S6 教学（05 页 P6）：首次成功捕获 = "投饵→捕鱼→结果反馈" 闭环完成。
    test("a successful catch completes the elder teaching marker (S6)", function()
        local Progress = require("Gameplay.Circle1B2Progress")
        local fixture = Flow.Fixture({})
        assert(fixture.loop:Depart())
        local player = fixture.loop.player
        eq(Progress.IsTeachingDone(player), false)
        eq(fixture.loop:IsTeachingDone(), false)
        -- 非满舱主路径：收网直接入包即标记。
        local fish = fixture.runtime:spawnFish("tuna", { x = 1, y = 0 })
        local token = assert(fixture.bridge:BeginFishing({ x = 0, y = 0 }))
        fixture.bridge:Update(4)
        local ok, outcome = fixture.bridge:CompleteFishing(token)
        assert(ok and outcome == "caught")
        eq(Progress.IsTeachingDone(player), true)
        eq(fixture.loop:IsTeachingDone(), true)
        -- 幂等：重复标记不报错。
        assert(Progress.MarkTeachingDone(player))
        assert(fish.removed)
    end)

    test("full-hold catch marks the teaching only after the claim lands (S6)", function()
        local Progress = require("Gameplay.Circle1B2Progress")
        local fixture = fullFixture()
        local player = fixture.loop.player
        completeCatch(fixture, "tuna")
        eq(Progress.IsTeachingDone(player), false)
        -- 腾出一格后领取（满舱保留路径）。
        assert(fixture.loop:UseItem(1))
        assert(fixture.loop:ClaimPendingCatch())
        eq(Progress.IsTeachingDone(player), true)
    end)

    test("teaching marker tolerates legacy saves without the field (S6)", function()
        local Progress = require("Gameplay.Circle1B2Progress")
        local fixture = Flow.Fixture({})
        local player = fixture.loop.player
        -- 模拟旧档：elder record 无 teachingDone 字段。
        player.elder = { circle1B2 = { applesGiven = 1, decision = "pending" } }
        assert(Progress.Validate(player))
        eq(Progress.IsTeachingDone(player), false)
        assert(Progress.MarkTeachingDone(player))
        eq(Progress.IsTeachingDone(player), true)
        assert(Progress.Validate(player))
    end)

    return { results = results }
end

return Tests
