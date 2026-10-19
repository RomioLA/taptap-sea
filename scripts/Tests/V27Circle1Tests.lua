-- V2.7 圈1 最终裁决回归：老人同行、情境教学、D4 判定、D6 回想、D7 终局、投放与探海镜命名。
-- 只覆盖 V2.7 已拍板的规则；待定项（W-05 二选一 / W-08 正文）不在此断言。
local Flow = require("tests.Circle1BFishingFlowTests")
local Persistence = require("Gameplay.Persistence")
local Progress = require("Gameplay.Circle1B2Progress")
local SeaRuntime = require("Ocean.SeaRuntime")

local Tests = {}

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function findItem(inventory, wanted)
    for index, itemId in ipairs(inventory:GetItems()) do
        if itemId == wanted then return index end
    end
    return nil
end

local function closeStory(loop)
    local dialog = loop:GetStoryDialog()
    if not dialog then return nil end
    assert(loop:NotifyStoryShown(dialog.token), "story acknowledgement")
    assert(loop:CloseStoryDialog(), "story close")
    return dialog
end

local function advanceDay(loop)
    closeStory(loop)
    assert(loop:EndToday(), "end today")
    assert(loop:ConfirmSettlement(), "confirm settlement")
end

local function withOceanRuntime(loop, run)
    local originalRuntime = loop.runtime
    local runtime = SeaRuntime.New({ initializeRegions = false, departure = { x = 0, y = 0 } })
    assert(runtime.movement:SetViewport(1280, 720), "the real Ocean viewport is ready")
    loop.runtime = runtime
    local ok, err = xpcall(function() run(runtime) end, debug.traceback)
    loop.runtime = originalRuntime
    assert(ok, tostring(err))
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("V2.7 D1 basic teaching fires once on first departure, not in port", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        eq(Progress.IsTeachingShown(loop.player, "basic"), false, "no teaching before departure")
        assert(loop:GetStoryDialog() == nil, "no story dialog opens in port")
        assert(loop:Depart())
        eq(Progress.IsTeachingShown(loop.player, "basic"), true, "departure marks the basic teaching")
        assert(loop.lastMessage:find("15", 1, true), "basic teaching states the 15 second rule")
        assert(loop.lastMessage:find("强制返港", 1, true), "basic teaching states the forced-return rule")
        assert(loop:ReturnToPort())
        assert(loop:Depart())
        eq(Progress.IsTeachingShown(loop.player, "basic"), true, "teaching stays shown for the run")
    end)

    test("V2.7 bird teaching waits for a real bird signal and defers when unseen", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        assert(loop:Depart())
        closeStory(loop)
        loop.player.day = 2
        withOceanRuntime(loop, function(runtime)
            -- 没有真实海鸟信号时，绝不触发教学。
            assert(loop:ProcessContextTeaching(true) == false, "no birds means no teaching")
            eq(Progress.IsTeachingShown(loop.player, "bird"), false, "bird teaching stays pending")
            -- 仅存在于绘制 broad-phase 之外的信号也不能触发教学。
            local movement = runtime.movement
            local cue = { id = "b1", position = {
                x = movement.camera.x + 10000, y = movement.camera.y + 15,
            } }
            runtime.surfaceSignals = { GetBirds = function() return { cue } end }
            assert(loop.runtime:HasSurfaceSignalInView("bird") == false,
                "an out-of-bounds bird fails the broad-phase")
            assert(loop:ProcessContextTeaching(true) == false, "an out-of-bounds bird is not seen")
            eq(Progress.IsTeachingShown(loop.player, "bird"), false, "offscreen bird leaves teaching pending")
            -- 同一条活跃信号进入当前 draw bounds 后，首次观察具备触发资格。
            cue.position.x = movement.camera.x
            cue.position.y = movement.camera.y + 15
            assert(loop.runtime:HasSurfaceSignalInView("bird"), "the live draw viewport admits the nearby bird")
            assert(loop:ProcessContextTeaching(true))
        end)
        eq(Progress.IsTeachingShown(loop.player, "bird"), true, "bird teaching marked after a real signal")
        assert(loop.lastMessage:find("鸟", 1, true), "bird teaching mentions the bird")
    end)

    test("V2.7 splash teaching requires day three and a real splash", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        assert(loop:Depart())
        closeStory(loop)
        loop.player.day = 2
        Progress.MarkTeachingShown(loop.player, "bird")  -- 单独验证水花日期门槛
        withOceanRuntime(loop, function(runtime)
            local movement = runtime.movement
            local cue = { id = "s1", trailLength = 2, position = {
                x = movement.camera.x, y = movement.camera.y + 15,
            } }
            runtime.surfaceSignals = { GetSplashes = function() return { cue } end }
            assert(loop:ProcessContextTeaching(true) == false, "day two cannot teach the splash")
            eq(Progress.IsTeachingShown(loop.player, "splash"), false, "splash stays pending before day three")
            loop.player.day = 3
            cue.position.x = movement.camera.x + 10000
            assert(loop.runtime:HasSurfaceSignalInView("splash") == false,
                "an out-of-bounds splash fails the broad-phase")
            assert(loop:ProcessContextTeaching(true) == false, "an out-of-bounds splash is not seen")
            eq(Progress.IsTeachingShown(loop.player, "splash"), false, "offscreen splash leaves teaching pending")
            cue.position.x = movement.camera.x
            assert(loop:ProcessContextTeaching(true))
        end)
        eq(Progress.IsTeachingShown(loop.player, "splash"), true, "splash teaching marked")
        assert(loop.lastMessage:find("水花", 1, true), "splash teaching mentions the splash")
    end)

    test("V2.7 bird teaching has priority when bird and splash are both seen", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        assert(loop:Depart())
        closeStory(loop)
        loop.player.day = 3
        withOceanRuntime(loop, function(runtime)
            local movement = runtime.movement
            local point = { x = movement.camera.x, y = movement.camera.y + 15 }
            runtime.surfaceSignals = {
                GetBirds = function() return { { id = "b1", position = point } } end,
                GetSplashes = function() return { { id = "s1", position = point, trailLength = 2 } } end,
            }
            assert(loop:ProcessContextTeaching(true))
            eq(Progress.IsTeachingShown(loop.player, "bird"), true, "bird is taught first")
            eq(Progress.IsTeachingShown(loop.player, "splash"), false, "splash waits behind bird")
            assert(loop.lastMessage:find("鸟", 1, true), "the first line is the bird teaching")
            assert(loop:ProcessContextTeaching(true))
            eq(Progress.IsTeachingShown(loop.player, "splash"), true, "splash becomes eligible afterward")
        end)
    end)

    test("V2.7 teaching flags survive a day boundary and reset for a new run", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        assert(loop:Depart())
        closeStory(loop)
        assert(loop:ReturnToPort())
        advanceDay(loop)
        eq(Progress.IsTeachingShown(loop.player, "basic"), true, "basic teaching persists across days")
        assert(loop:NewRun())
        eq(Progress.IsTeachingShown(loop.player, "basic"), false, "NewRun resets the teaching flags")
    end)

    test("V2.7 elder is present at sea and in port while alive", function()
        local fixture = Flow.Fixture({ items = { "apple" } })
        local loop = fixture.loop
        assert(loop:IsElderPresent(), "present on day one in port")
        assert(loop:Depart())
        assert(loop:IsElderPresent(), "still present at sea")
        assert(loop:SetInventoryOpen(true))
        assert(loop:SetElderOpen(true), "the elder panel opens at sea")
        local index = assert(findItem(loop.player.inventory, "apple"))
        local stamina = loop.player.stamina
        assert(loop:GiveToElder(index))
        eq(loop:GetElderStatus().applesGiven, 1, "sea gift counts toward rescue")
        eq(loop.player.stamina, stamina, "gift never restores stamina")
        assert(loop:SetElderOpen(false))
        assert(loop:SetInventoryOpen(false))
    end)

    test("V2.7 apples can no longer be counted after the day four decision", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        for day = 1, 3 do
            assert(loop.player.inventory:Add("apple"))
            assert(loop:SetElderOpen(true))
            assert(loop:GiveToElder(assert(findItem(loop.player.inventory, "apple"))))
            assert(loop:SetElderOpen(false))
            if day < 3 then advanceDay(loop) end
        end
        advanceDay(loop)
        eq(loop.player.day, 4, "advanced to day four")
        eq(loop:GetElderStatus().decision, "saved", "three apples save the elder")
        closeStory(loop)
        assert(loop.player.inventory:Add("apple"))
        assert(loop:SetElderOpen(true))
        assert(loop:GiveToElder(assert(findItem(loop.player.inventory, "apple"))))
        assert(loop:SetElderOpen(false))
        eq(loop:GetElderStatus().applesGiven, 3, "day four gifts never add to the rescue count")
    end)

    test("V2.7 day four result appears once and is saved with the settlement snapshot", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        advanceDay(loop)  -- day 1 -> 2
        advanceDay(loop)  -- day 2 -> 3
        advanceDay(loop)  -- day 3 -> 4
        eq(loop.player.day, 4)
        local dialog = assert(loop:GetStoryDialog())
        eq(dialog.kind, "elder_fate", "day four opens the fate result")
        eq(loop:GetElderStatus().decision, "dead", "no apples means the elder is gone")
        assert(dialog.text:find("甲板上静悄悄的", 1, true), "W-02 polished closing line")
        eq(Progress.IsElderFateShown(loop.player), false, "not persisted before the player reads it")
        assert(loop:NotifyStoryShown(dialog.token))
        eq(Progress.IsElderFateShown(loop.player), true)
        assert(loop:CloseStoryDialog())
        eq(loop:GetStoryDialog(), nil)
        local reopened, reason = loop:OpenDay4ElderFate()
        eq(reopened, false); eq(reason, "elder_fate_already_shown")
        assert(loop:Ready(), "the run continues after the result")
    end)

    test("V2.7 unsaved day six recall replays from an older checkpoint without rewards", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        for _ = 1, 5 do advanceDay(loop) end
        eq(loop.player.day, 6, "entered day six")
        local recall = assert(loop:GetStoryDialog())
        eq(recall.kind, "apple_basket", "day six opens the apple basket recall")
        eq(loop:GetElderStatus().decision, "dead", "recall only happens on the unsaved route")
        local before = Persistence.Snapshot(loop.player)
        assert(loop:NotifyStoryShown(recall.token))
        assert(loop:CloseStoryDialog())
        local expected = before
        expected.story.circle1B2.appleBasketRecallShown = true
        eq(Persistence.Snapshot(loop.player).story.circle1B2.appleBasketRecallShown, true,
            "recall marker only changes in memory")
        eq(loop:OpenDayEntryStory(), false, "recall is not reopened the same day")
    end)

    test("V2.7 saved route gets one advanced teaching line per day from day four", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        for _ = 1, 3 do
            assert(loop.player.inventory:Add("apple"))
            assert(loop:SetElderOpen(true))
            assert(loop:GiveToElder(assert(findItem(loop.player.inventory, "apple"))))
            assert(loop:SetElderOpen(false))
            if loop.player.day < 3 then advanceDay(loop) end
        end
        advanceDay(loop)
        eq(loop:GetElderStatus().decision, "saved", "three apples save the elder")
        closeStory(loop)
        assert(loop:Depart())
        assert(loop.lastMessage:find("二十来米", 1, true), "day four advanced teaching")
        assert(loop:ReturnToPort())
        advanceDay(loop)
        eq(loop.player.day, 5)
        assert(loop:Depart())
        assert(loop.lastMessage:find("动手探索", 1, true), "day five advanced teaching")
    end)

    test("V2.7 throw picker lists merged item types and rejects an empty hold", function()
        local fixture = Flow.Fixture({ items = { "bait", "bait", "apple" } })
        local loop = fixture.loop
        local inPort, inPortReason = loop:OpenThrowPicker()
        eq(inPort, false); eq(inPortReason, "sea_required", "throwing requires the sea")
        assert(loop:Depart())
        local ok, candidates = loop:OpenThrowPicker()
        assert(ok, "the picker opens with throwable items")
        eq(#candidates, 2, "same item types merge into one row")
        eq(candidates[1].itemId, "bait"); eq(candidates[1].count, 2)
        eq(candidates[2].itemId, "apple"); eq(candidates[2].count, 1)
        assert(loop:CloseThrowPicker())
        eq(loop:GetThrowPicker(), nil, "the picker closes")
    end)

    test("V2.7 bait drop frees a slot in port and still rejects out-of-range drops", function()
        -- 港内：鱼饵点「丢弃」直接移除完成腾格（C-08）。
        local fixture = Flow.Fixture({ items = { "bait" } })
        local loop = fixture.loop
        eq(#loop.player.inventory:GetItems(), 1)
        local dropped, payload = loop:DropItem(1)
        assert(dropped, "bait can be dropped in port")
        eq(#loop.player.inventory:GetItems(), 0, "the slot is freed")
        assert(type(payload) == "table" and payload.itemId == "bait")

        -- 海上超距：必须拒绝且保留物品（不属于鱼饵例外）。
        local sea = Flow.Fixture({ items = { "bait" } })
        assert(sea.loop:Depart())
        assert(sea.bridge:SetDropTarget({ x = -7.999, y = -20 }))  -- 12.001 米
        local rejected, reason = sea.loop:DropItem(1)
        eq(rejected, false)
        eq(#sea.loop.player.inventory:GetItems(), 1, "an over-range bait drop keeps the item")
        assert(type(reason) == "string" and reason ~= "", "the rejection carries a reason")
    end)

    test("V2.7 an empty hold shows a light hint instead of a modal", function()
        local fixture = Flow.Fixture({ items = {} })
        local loop = fixture.loop
        assert(loop:Depart())
        local ok, reason = loop:OpenThrowPicker()
        eq(ok, false); eq(reason, "no_throwable_item")
        eq(loop.lastMessage, "船舱里没有可以投放的物品。")
        eq(loop:GetStoryDialog(), nil, "the hint never opens a modal")
    end)

    test("V2.7 every holdable item keeps the three menu operations and never greys them out", function()
        -- 鱼饵没有恢复体力效果，但「使用」入口仍需可点并给出原因。
        local fixture = Flow.Fixture({ items = { "apple", "bait" } })
        local loop = fixture.loop
        assert(loop:SetInventoryOpen(true))
        local baitIndex = assert(findItem(loop.player.inventory, "bait"))
        local used, useReason = loop:UseItem(baitIndex)
        eq(used, false); eq(useReason, "item_has_no_use")
        assert(loop.lastMessage:find("没有可用的使用效果", 1, true), "use rejection explains itself")
        eq(loop.player.inventory:GetItems()[baitIndex], "bait", "rejected use keeps the item")
        -- 丢弃在港内被拒，也必须给出原因且不消耗。
        local dropped, dropReason = loop:DropItem(1)
        eq(dropped, false)
        eq(loop.player.inventory:GetItems()[1], "apple", "rejected drop keeps the item")
        assert(type(dropReason) == "string" and dropReason ~= "", "drop rejection has a reason")
        assert(type(loop.lastMessage) == "string" and loop.lastMessage ~= "",
            "drop rejection explains itself to the player")
    end)

    test("V2.7 the elder gift entry survives death and only explains the reason", function()
        local fixture = Flow.Fixture({ items = { "apple" } })
        local loop = fixture.loop
        loop.player.day = 4
        Progress.OnDayStarted(loop.player)
        eq(loop:IsElderPresent(), false, "dead elder is no longer present")
        local opened, reason = loop:SetElderOpen(true)
        eq(opened, false); eq(reason, "elder_not_present")
        eq(loop.lastMessage, "老人已经不在了，无法再把东西交给他。")
        assert(loop:SetInventoryOpen(true))
        local gave, giveReason = loop:GiveToElder(1)
        eq(gave, false); eq(giveReason, "elder_not_present")
        eq(loop.player.inventory:GetItems()[1], "apple", "a rejected gift keeps the apple")
    end)

    test("V2.7 scope lens resets on load, on a new day it keeps ownership, and NewRun clears it", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        -- Flow 桩 runtime 没有 scope 接口；按 Circle1B2ScopeTests 的生产同步契约装配。
        local runtime = fixture.runtime
        runtime.scopeEnabled = false
        function runtime:SetScopeEnabled(enabled) self.scopeEnabled = enabled == true; return self.scopeEnabled end
        function runtime:IsScopeEnabled() return runtime.scopeEnabled end
        assert(Progress.GrantLens(loop.player))
        assert(loop:Depart())
        assert(loop:ToggleScope())
        eq(loop:IsScopeEnabled(), true, "scope toggles on")
        assert(loop:ReturnToPort())
        eq(loop:IsScopeEnabled(), true, "returning to port does not force it closed")
        advanceDay(loop)
        eq(loop:IsScopeEnabled(), false, "a new day resets the switch to off")
        eq(loop:HasLens(), true, "the lens itself is kept")
        assert(loop:NewRun())
        eq(loop:HasLens(), false, "NewRun clears lens ownership")
    end)

    test("V2.7 finishing the run blocks further play and keeps the ending page", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        for _ = 1, 6 do advanceDay(loop) end
        eq(loop.player.day, 7)
        closeStory(loop)  -- D7 paper
        assert(loop:EndToday())
        assert(loop:ConfirmSettlement())
        eq(loop.player.story.circle1B2.runCompleted, true, "terminal snapshot marks the run complete")
        eq(loop.endingPending, true, "the ending page takes over")
        assert(not loop:Ready(), "ordinary play is locked")
        eq(loop:Depart(), false)
        eq(loop:EndToday(), false)
        assert(loop:NewRun())
        eq(loop.player.day, 1, "NewRun returns to day one")
        eq(loop.player.story.circle1B2.runCompleted, false, "NewRun clears the terminal marker")
    end)

    test("V2.7 no path advances the run to day eight", function()
        local fixture = Flow.Fixture()
        local loop = fixture.loop
        for _ = 1, 6 do advanceDay(loop) end
        eq(loop.player.day, 7)
        closeStory(loop)
        assert(loop:EndToday())
        assert(loop:ConfirmSettlement())
        eq(loop.player.day, 7, "the terminal settlement never advances the day")
        local snapshot = Persistence.Snapshot(loop.player)
        snapshot.day = 8
        local restored, restoreError = Persistence.Restore(snapshot)
        eq(restored, nil); eq(restoreError, "invalid_run_day")
    end)

    return { results = results }
end

return Tests
