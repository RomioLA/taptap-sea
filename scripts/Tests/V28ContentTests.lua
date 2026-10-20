-- V2.8 海上内容扩充回归：固定节点、0体力观察/拾取、探海镜标记、40体力/4秒事务、
-- 破渔网双分支、浮藻假岛钥匙链、海眼投放/珍珠原子结算、巨骨生态特例、存档兼容。
-- 依据：V2.8最终封板 / 系统规则·V2.8 固定世界坐标与检查点增量 / 游戏道具总表。
local Content = require "data.content"
local Config = require "Ocean.Config"
local Items = require "data.items"
local Runtime = require "Ocean.SeaRuntime"
local Strategy = require "Ocean.SpawnStrategy"
local FishData = require "Ocean.FishData"
local PlayerState = require "Gameplay.PlayerState"
local Persistence = require "Gameplay.Persistence"
local V28 = require "Gameplay.V28Progress"
local Actions = require "Gameplay.V28ContentActions"
local Progress = require "Gameplay.WorldContentProgress"
local MemoryFragments = require "Gameplay.MemoryFragments"

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value mismatch") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function truthy(value, label)
    assert(value, label or "expected a truthy value")
end

local function falsy(value, label)
    assert(not value, label or "expected a falsy value")
end

local function near(actual, expected, epsilon, label)
    assert(type(actual) == "number" and math.abs(actual - expected) <= (epsilon or 1e-6),
        (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function definition(contentId)
    for _, item in ipairs(Content.fixed) do
        if item.contentId == contentId then return item end
    end
    error("missing content " .. tostring(contentId))
end

local function findItem(player, itemId)
    local count = 0
    for _, id in ipairs(player.inventory:GetItems()) do
        if id == itemId then count = count + 1 end
    end
    return count
end

---Lightweight adapter mirroring the real Loop adapter contract, with an
---explicit in-scope set and configurable surface gap per content id.
local function fixture(options)
    options = options or {}
    local player = options.player or assert(PlayerState.New())
    if options.lens then player.treasures.scopeLens = true end
    local adapter = {
        player = player,
        gaps = options.gaps or {},
        scope = options.scope or {},
        generation = options.generation or 1,
        sessionGeneration = 1,
        runtimeIdentity = {},
    }
    function adapter:GetContext()
        return { player = self.player, sessionGeneration = self.sessionGeneration,
            runtimeIdentity = self.runtimeIdentity, fixedContentGeneration = self.generation }
    end
    function adapter:GetWorldContentAccess(contentId)
        local gap = self.gaps[contentId]
        if gap == nil then gap = 0 end
        return { contentId = contentId, entityId = "fixture:" .. contentId,
            generation = self.generation, surfaceGap = gap }
    end
    function adapter:IsWorldContentInScope(contentId)
        return self.scope[contentId] == true
    end
    local actions, reason = Actions.New(adapter)
    assert(actions, tostring(reason))
    return { player = player, adapter = adapter, actions = actions }
end

---Shared empty-store Bridge fixture.
local function bridgeFixture()
    local RuntimeBridge = require "Integration.Bridge"
    local store = {}
    function store:Save(_, done) if done then done(true) end end
    function store:Load(done) if done then done(true, nil) end end
    local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
    local bridge = RuntimeBridge.New(runtime, { store = store })
    return runtime, bridge, bridge.loop
end

function Tests.Run(recorder)
    local results = {}
    local names = {}
    local function test(name, run)
        assert(not names[name], "duplicate test name: " .. name)
        names[name] = true
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    -- ===== 固定内容与坐标 =====
    test("V2.8 authored coordinates, radii, layers and blocking match the sealed workbook", function()
        local expected = {
            { "reef_vis_01", -70, 55, 3, "surface", true },
            -- 2026-10-20（V2.8 截止前可发现性）：reef_vis_02/03 从 110,-80 / 160,-115
            -- 向外移到 150,-92 / 200,-140，与东南向的海岛链（island_reefcluster_v1 /
            -- island_stele_v1）形成“礁石→羽毛→岛影”的逐段引导，而不是三个点
            -- 堆在同一块水域里（旧坐标三者互相遮住）。半径/层/阻挡未改。
            { "reef_vis_02", 150, -92, 3, "surface", true },
            { "reef_vis_03", 200, -140, 3, "surface", true },
            { "debris_01", -96, -72, 3, "surface", false },
            { "shipwreck_01", -116, -87, 3.5, "underwater", false },
            { "bottle_note_01", -55, 95, 1.2, "surface", false },
            { "bottle_note_02", 145, -45, 1.2, "surface", false },
            { "leviathan_bones_01", -40, 235, 4, "underwater", false },
            { "sea_eye_vortex_01", 215, 115, 6, "surface", false },
            { "trapped_net_01", -195, -75, 2, "surface", true },
            { "kelp_mirage_01", 85, -195, 2.5, "underwater", false },
        }
        for _, row in ipairs(expected) do
            local item = definition(row[1])
            eq(item.position.x, row[2], row[1] .. " x")
            eq(item.position.y, row[3], row[1] .. " y")
            eq(item.radius, row[4], row[1] .. " radius")
            eq(item.layer, row[5], row[1] .. " layer")
            eq(item.blocking, row[6], row[1] .. " blocking")
        end
        -- 13 个海上节点（不含港口）。
        eq(#Content.fixed, 14, "13 sea nodes + the harbor-adjacent authored set")
        -- 海眼核心 3m 禁网 / 5m 观察与投放半径来自配置。
        local vortex = definition("sea_eye_vortex_01").vortex
        eq(vortex.noNetRadius, 3)
        eq(vortex.observeRadius, 5)
        eq(vortex.dropRadius, 5)
        eq(vortex.smallFishAttractRadius, 60)
        eq(vortex.bigFishAttractRadius, 90)
        eq(vortex.attractDurationSec, 20)
    end)

    test("authored positions stay fixed across five NewRun cycles", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local before = {}
        for _, item in ipairs(Content.fixed) do
            local snapshot = assert(runtime:GetWorldContent(item.contentId))
            before[item.contentId] = { x = snapshot.position.x, y = snapshot.position.y }
        end
        for _ = 1, 5 do
            runtime:Reset()
            for _, item in ipairs(Content.fixed) do
                local snapshot = assert(runtime:GetWorldContent(item.contentId))
                near(snapshot.position.x, before[item.contentId].x, 1e-9, item.contentId .. " x")
                near(snapshot.position.y, before[item.contentId].y, 1e-9, item.contentId .. " y")
            end
        end
    end)

    -- ===== 1~3 礁石 0 体力观察 =====
    test("three reefs provide a repeatable 0-stamina observation with no reward", function()
        for _, contentId in ipairs({ "reef_vis_01", "reef_vis_02", "reef_vis_03" }) do
            local f = fixture()
            local stamina = f.player.stamina
            local items = f.player.inventory:GetItems()
            -- 固定顺序决定多目标同时合法时的优先级；这里只要求礁石可观察。
            local prompt = assert(f.actions:GetPrompt())
            eq(prompt.operation, "observe", contentId .. " prompt operation")
            for _ = 1, 3 do
                local ok, result, detail = f.actions:Observe(contentId)
                truthy(ok, contentId .. " observe must succeed")
                eq(result, "observed")
                truthy(detail and type(detail.text) == "string" and detail.text ~= "",
                    contentId .. " observation text")
            end
            eq(f.player.stamina, stamina, contentId .. " observation is free")
            eq(#f.player.inventory:GetItems(), #items, contentId .. " observation grants no item")
            local state = V28.GetProgressState(f.player, contentId)
            eq(state, nil, contentId .. " reefs store no周目 state")
        end
    end)

    test("out-of-range observation is rejected without charging", function()
        local f = fixture({ gaps = { reef_vis_01 = 5.5 } })
        local ok, reason = f.actions:Observe("reef_vis_01")
        falsy(ok)
        eq(reason, "out_of_range")
        eq(f.player.stamina, 100, "rejected observation is free")
    end)

    -- ===== 4~5 漂流瓶 =====
    test("bottle pickup grants the sea note into the independent bar and hides the bottle", function()
        local f = fixture()
        local prompt = assert(f.actions:GetPrompt())
        eq(prompt.operation, "observe") -- reef_vis_01 comes first in authored order
        local ok, result, detail = f.actions:Pickup("bottle_note_01")
        truthy(ok)
        eq(result, "picked")
        eq(detail.treasureId, "sea_note_01")
        truthy(V28.HasTreasure(f.player, "sea_note_01"))
        eq(f.player.inventory:GetItems()[1], "apple", "note must not consume a cargo slot")
        eq(#f.player.inventory:GetItems(), 2, "bottle pickup never uses the cargo grid")
        truthy(V28.IsBottlePicked(f.player, "bottle_note_01"))
        -- 拾取状态由残页持有推导，不新增 picked 布尔位。
        eq(f.player.story.v28.picked, nil)
        eq(f.player.story.v28.bottlePicked, nil)
        -- 不可重复领取。
        local again, reason = f.actions:Pickup("bottle_note_01")
        falsy(again)
        eq(reason, "already_picked")
    end)

    test("picked bottles disappear from the dynamic prompt and the world query", function()
        local f = fixture()
        truthy(V28.GrantTreasure(f.player, "sea_note_01"))
        truthy(V28.GrantTreasure(f.player, "sea_note_02"))
        local prompt = f.actions:GetPrompt()
        truthy(prompt)
        assert(prompt.contentId ~= "bottle_note_01" and prompt.contentId ~= "bottle_note_02",
            "picked bottles must not offer a prompt")
        truthy(V28.IsBottlePicked(f.player, "bottle_note_01"))
        truthy(V28.IsBottlePicked(f.player, "bottle_note_02"))
    end)

    -- ===== 6~7 沉船 =====
    test("shipwreck salvage requires a lens mark, 40 stamina and two free slots", function()
        local f = fixture({ lens = true })
        -- 未标记：不可开始。
        local token, reason = f.actions:BeginAction("shipwreck_01")
        eq(token, nil)
        eq(reason, "content_not_marked")

        f.adapter.scope.shipwreck_01 = true
        truthy(f.actions:Advance(0.99))
        eq(assert(Progress.GetState(f.player, "shipwreck_01")).marked, false)
        truthy(f.actions:Advance(0.01))
        eq(assert(Progress.GetState(f.player, "shipwreck_01")).marked, true)

        -- 空位不足 2：拒绝开始，不扣体力。
        f.player.inventory:Add("sardine")
        f.player.inventory:Add("sardine")
        f.player.inventory:Add("sardine")
        eq(#f.player.inventory:GetItems(), 5, "cargo full")
        local stamina = f.player.stamina
        token, reason = f.actions:BeginAction("shipwreck_01")
        eq(token, nil)
        eq(reason, "inventory_full")
        eq(f.player.stamina, stamina, "rejected begin must not charge")

        -- 腾出 2 格后可以开始。
        f.player.inventory:Remove(5)
        f.player.inventory:Remove(4)
        token, reason = f.actions:BeginAction("shipwreck_01")
        truthy(token, tostring(reason))
        eq(f.player.stamina, stamina, "begin is free")
        truthy(f.actions:Advance(3.99))
        eq(f.player.stamina, stamina, "incomplete action is free")
        truthy(f.actions:Advance(0.01))
        eq(f.player.stamina, stamina - 40, "successful salvage charges 40")
        eq(findItem(f.player, "shipwreck_jewelry"), 1)
        eq(findItem(f.player, "coral_branch"), 1)
        local state = assert(Progress.GetState(f.player, "shipwreck_01"))
        eq(state.completed, true)
        -- 每周目一次。
        local again, againReason = f.actions:BeginAction("shipwreck_01")
        eq(again, nil)
        eq(againReason, "already_completed")
    end)

    test("insufficient stamina refuses to start the shipwreck salvage without charging", function()
        local f = fixture({ lens = true })
        f.adapter.scope.shipwreck_01 = true
        f.actions:Advance(1)
        f.player.stamina = 39
        local token, reason = f.actions:BeginAction("shipwreck_01")
        eq(token, nil)
        eq(reason, "insufficient_stamina")
        eq(f.player.stamina, 39)
        eq(findItem(f.player, "shipwreck_jewelry"), 0)
    end)

    test("cancelled shipwreck salvage charges nothing and awards nothing", function()
        local f = fixture({ lens = true })
        f.adapter.scope.shipwreck_01 = true
        f.actions:Advance(1)
        local token = assert(f.actions:BeginAction("shipwreck_01"))
        truthy(f.actions:Advance(3))
        truthy(f.actions:Cancel(token, "cancelled"))
        local receipt = assert(f.actions:GetReceipt(token))
        eq(receipt.status, "cancelled")
        eq(f.player.stamina, 100)
        eq(findItem(f.player, "shipwreck_jewelry"), 0)
        eq(assert(Progress.GetState(f.player, "shipwreck_01")).completed, false)
        -- 取消后可重新开始。
        truthy(f.actions:BeginAction("shipwreck_01"))
    end)

    test("night interruption mid-action awards nothing and keeps the mark", function()
        local f = fixture({ lens = true })
        f.adapter.scope.shipwreck_01 = true
        f.actions:Advance(1)
        local token = assert(f.actions:BeginAction("shipwreck_01"))
        f.actions:Advance(2)
        truthy(f.actions:Invalidate("night_interrupted"))
        local receipt = assert(f.actions:GetReceipt(token))
        eq(receipt.status, "failed")
        eq(receipt.failureReason, "night_interrupted")
        eq(f.player.stamina, 100)
        eq(findItem(f.player, "shipwreck_jewelry"), 0)
        eq(assert(Progress.GetState(f.player, "shipwreck_01")).marked, true)
        eq(assert(Progress.GetState(f.player, "shipwreck_01")).completed, false)
    end)

    -- ===== 8~9 巨骨生态 =====
    test("leviathan region spawns 4 small + 2 big fish with total still six", function()
        local world = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false }).world
        local size = Config.world.regionSize
        local half = Config.world.halfSize
        local content = definition("leviathan_bones_01")
        local ix = math.floor((content.position.x + half) / size)
        local iy = math.floor((content.position.y + half) / size)
        for day = 1, 3 do
            local placements = Strategy.GenerateRegion(world, Config.world.seed + day - 1, ix, iy,
                { x = 0, y = 0 }, FishData, { x = 0, y = 0 })
            local sardine, tuna = 0, 0
            local ringHits = 0
            for _, placement in ipairs(placements) do
                if placement.species == "sardine" then
                    sardine = sardine + 1
                elseif placement.species == "tuna" then
                    tuna = tuna + 1
                    local dx = placement.position.x - content.position.x
                    local dy = placement.position.y - content.position.y
                    local distance = math.sqrt(dx * dx + dy * dy)
                    if distance >= 15 and distance <= 45 then ringHits = ringHits + 1 end
                end
            end
            eq(sardine, 4, "day " .. day .. " sardine count")
            eq(tuna, 2, "day " .. day .. " tuna count")
            eq(sardine + tuna, 6, "day " .. day .. " total stays six")
            eq(ringHits, 2, "day " .. day .. " both big fish spawn inside the 15-45m ring")
        end
    end)

    test("leviathan override never breaks the 200m tuna spawn boundary", function()
        local world = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false }).world
        local size = Config.world.regionSize
        local half = Config.world.halfSize
        local content = definition("leviathan_bones_01")
        local ix = math.floor((content.position.x + half) / size)
        local iy = math.floor((content.position.y + half) / size)
        local placements = Strategy.GenerateRegion(world, Config.world.seed, ix, iy,
            { x = 0, y = 0 }, FishData, { x = 0, y = 0 })
        for _, placement in ipairs(placements) do
            if placement.species == "tuna" then
                local distance = math.sqrt(placement.position.x ^ 2 + placement.position.y ^ 2)
                assert(distance >= 200, "tuna must stay at least 200m from the harbor")
            end
        end
    end)

    test("leviathan lens recognition happens once per run and only after one full second", function()
        local f = fixture({ lens = true })
        f.adapter.scope.leviathan_bones_01 = true
        truthy(f.actions:Advance(0.99))
        eq(V28.IsRecognized(f.player, "leviathan_bones_01"), false)
        truthy(f.actions:Advance(0.01))
        eq(V28.IsRecognized(f.player, "leviathan_bones_01"), true)
        local notice = f.actions:ConsumeLensNotice()
        truthy(notice and notice.text and notice.text:find("骸骨", 1, true))
        -- 重复照射不再弹第二次提示。
        f.actions:Advance(2)
        eq(f.actions:ConsumeLensNotice(), nil)
        -- 识别不扣体力、不发放物品。
        eq(f.player.stamina, 100)
        eq(#f.player.inventory:GetItems(), 2)
    end)

    -- ===== 10 海眼 =====
    test("vortex observation is free and repeatable", function()
        local f = fixture({ gaps = { sea_eye_vortex_01 = 5 } })
        local ok, result, detail = f.actions:Observe("sea_eye_vortex_01")
        truthy(ok)
        eq(result, "observed")
        truthy(detail.text:find("漩涡", 1, true))
        eq(f.player.stamina, 100)
    end)

    test("vortex core inside three meters refuses a fishing net center", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local vortex = definition("sea_eye_vortex_01")
        runtime.ship.position = { x = vortex.position.x + 2, y = vortex.position.y }
        falsy(runtime:canCastNet({ x = vortex.position.x + 2.9, y = vortex.position.y }),
            "net center inside the 3m core must be refused")
        local allowed, reason = runtime:IsFishingCenterAllowed({ x = vortex.position.x + 2.9,
            y = vortex.position.y })
        falsy(allowed)
        eq(reason, "vortex_core_no_net")
        truthy(runtime:IsFishingCenterAllowed({ x = vortex.position.x + 3, y = vortex.position.y }),
            "the 3m rim is a legal net center")
    end)

    test("vortex drop only reacts to the official WorldDrop position", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local vortex = definition("sea_eye_vortex_01")
        runtime.ship.position = { x = vortex.position.x, y = vortex.position.y - 4 }
        local inside = runtime:IsInsideVortexDropRadius({ x = vortex.position.x, y = vortex.position.y + 4 })
        truthy(inside)
        local outside = runtime:IsInsideVortexDropRadius({ x = vortex.position.x + 5.1, y = vortex.position.y })
        falsy(outside, "5.1m is outside the drop radius")
    end)

    test("vortex small/big attractants extend only existing fish perception", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local vortex = definition("sea_eye_vortex_01")
        runtime.ship.position = { x = vortex.position.x, y = vortex.position.y - 4 }
        local position = { x = vortex.position.x, y = vortex.position.y + 2 }
        local small = assert(runtime:HandleVortexDrop(
            { itemId = "apple", category = "food", worldEffect = "ATTRACT_SMALL_FISH" }, position))
        eq(small.kind, "small")
        eq(small.attractRadius, 60)
        eq(runtime.world.attractBoostRadius.ATTRACT_SMALL_FISH, 60)
        local big = assert(runtime:HandleVortexDrop(
            { itemId = "sardine", category = "fish", worldEffect = "ATTRACT_BIG_FISH" }, position))
        eq(big.kind, "big")
        eq(big.attractRadius, 90)
        eq(runtime.world.attractBoostRadius.ATTRACT_BIG_FISH, 90)
        -- 不凭空刷鱼。
        local counts = runtime.world:getCounts()
        eq(counts.sardine, 0)
        eq(counts.tuna, 0)
        -- 临时诱饵 20 秒后过期，索引回落。
        runtime.world.time = 25
        runtime.world:updateLifecycle(21, runtime.ship)
        eq(runtime.world.attractBoostRadius.ATTRACT_SMALL_FISH, nil)
    end)

    test("vortex never spawns new fish and only affects fish already in range", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local vortex = definition("sea_eye_vortex_01")
        runtime.ship.position = { x = vortex.position.x, y = vortex.position.y - 4 }
        -- 30m 外的小鱼在常规 18m 感知外，但在海眼 60m 扩域内。
        local far = runtime:spawnFish("sardine", { x = vortex.position.x + 30, y = vortex.position.y }, 0)
        local behavior = runtime.behaviors[far.id]
        runtime:HandleVortexDrop({ itemId = "apple", category = "food",
            worldEffect = "ATTRACT_SMALL_FISH" }, { x = vortex.position.x, y = vortex.position.y + 2 })
        for _ = 1, 40 do behavior:Update(0.05) end
        eq(behavior.state, "Attracted", "the far sardine is attracted by the vortex bait")
        eq(runtime.world:getCounts().sardine, 1, "no extra fish were created")
    end)

    test("vortex big-fish pearl claim is atomic, once per run and survives selling", function()
        local PlayerLoop = require "Gameplay.Loop"
        local loop = PlayerLoop.New()
        local pearl = Items.GetDefinition("abyss_pearl")
        truthy(pearl, "abyss_pearl definition")
        eq(pearl.sellPrice, 260)
        eq(pearl.category, "misc")
        -- 投放的大鱼在调用方已从船舱移除，释放出 1 格。
        local before = #loop.player.inventory:GetItems()
        truthy(loop:ClaimVortexPearl({}))
        eq(findItem(loop.player, "abyss_pearl"), 1)
        eq(#loop.player.inventory:GetItems(), before + 1, "pearl fills the released slot")
        eq(loop:IsVortexPearlClaimed(), true)
        -- 第二次不再产珍珠。
        local again = loop:ClaimVortexPearl({})
        falsy(again)
        eq(loop:ConsumeVortexBigFish({}), true)
        eq(findItem(loop.player, "abyss_pearl"), 1, "no second pearl")
        -- 卖掉珍珠后 vortexPearlClaimed 仍为 true。
        local index = nil
        for i, id in ipairs(loop.player.inventory:GetItems()) do
            if id == "abyss_pearl" then index = i end
        end
        truthy(index)
        loop.player.inventory:Remove(index)
        eq(loop:IsVortexPearlClaimed(), true)
        falsy(loop:ClaimVortexPearl({}))
    end)

    -- ===== 11~12 破渔网 =====
    test("trapped net branch A grants two small fish and permanently loses the key", function()
        local f = fixture()
        truthy(f.actions:GetPrompt())
        local token, reason = f.actions:BeginNetCollect("trapped_net_01")
        truthy(token, tostring(reason))
        eq(f.player.stamina, 100, "begin is free")
        truthy(f.actions:Advance(4))
        eq(f.player.stamina, 60)
        eq(findItem(f.player, "sardine"), 2)
        eq(assert(Progress.GetState(f.player, "trapped_net_01")).completed, true)
        falsy(V28.HasTreasure(f.player, "rusty_key"))
        local again, againReason = f.actions:BeginNetCollect("trapped_net_01")
        eq(again, nil)
        eq(againReason, "already_completed")
        -- 分支 B 也不可再走。
        local cut, cutReason = f.actions:ResolveNetCut("trapped_net_01", nil)
        falsy(cut)
        eq(cutReason, "already_completed")
        falsy(V28.HasTreasure(f.player, "rusty_key"))
    end)

    test("trapped net branch B grants the only rusty key and releases two real fish", function()
        local f = fixture()
        local released = { species = nil, count = 0 }
        local ok, result, detail = f.actions:ResolveNetCut("trapped_net_01", function(species, count)
            released.species, released.count = species, count
            return true
        end)
        truthy(ok, tostring(result))
        eq(result, "cut")
        eq(detail.treasureId, "rusty_key")
        truthy(V28.HasTreasure(f.player, "rusty_key"))
        eq(released.species, "sardine")
        eq(released.count, 2)
        eq(f.player.stamina, 100, "branch B is free")
        eq(assert(Progress.GetState(f.player, "trapped_net_01")).completed, true)
        eq(findItem(f.player, "sardine"), 0, "released fish go into the sea, not the cargo")
    end)

    test("trapped net branch B releases two flee-state fish and spawns no extra big fish", function()
        local runtime = Runtime.New({ departure = { x = -195, y = -80 }, initializeRegions = false })
        local net = definition("trapped_net_01")
        runtime.ship.position = { x = net.position.x, y = net.position.y - 4 }
        local before = runtime.world:getCounts()
        truthy(runtime:ReleaseFishAtContent("trapped_net_01", "sardine", 2))
        local after = runtime.world:getCounts()
        eq(after.sardine, before.sardine + 2, "two real small fish")
        eq(after.tuna, before.tuna, "no extra big fish")
        local fleeing = 0
        for _, entity in ipairs(runtime.world.entities) do
            if entity.species == "sardine" and entity.state == "Flee" then fleeing = fleeing + 1 end
        end
        eq(fleeing, 2, "both released fish enter Flee")
    end)

    test("released fish actually flee away from the net and rise, then settle", function()
        local runtime = Runtime.New({ departure = { x = -195, y = -80 }, initializeRegions = false })
        local net = definition("trapped_net_01")
        runtime.ship.position = { x = net.position.x, y = net.position.y - 4 }
        truthy(runtime:ReleaseFishAtContent("trapped_net_01", "sardine", 2))
        local fish, behavior
        for _, entity in ipairs(runtime.world.entities) do
            if entity.species == "sardine" then fish, behavior = entity, runtime.behaviors[entity.id] end
        end
        truthy(fish and behavior)
        local startDistance = math.sqrt((fish.position.x - net.position.x) ^ 2
            + (fish.position.y - net.position.y) ^ 2)
        for _ = 1, 20 do behavior:Update(0.05) end
        eq(behavior.state, "Flee", "released fish keep fleeing")
        truthy(fish.riseRemaining and fish.riseRemaining > 0, "released fish rise to the surface")
        local nowDistance = math.sqrt((fish.position.x - net.position.x) ^ 2
            + (fish.position.y - net.position.y) ^ 2)
        assert(nowDistance > startDistance, "released fish move away from the net")
        -- 逃跑源到期后回到常规行为（不再是无限逃跑）。
        for _ = 1, 100 do behavior:Update(0.05) end
        eq(fish.fleeSource, nil, "the external flee source expires")
    end)

    test("released fish never spawn an extra big fish even with a nearby tuna", function()
        local runtime = Runtime.New({ departure = { x = -195, y = -80 }, initializeRegions = false })
        local net = definition("trapped_net_01")
        runtime.ship.position = { x = net.position.x, y = net.position.y - 4 }
        local tuna = runtime:spawnFish("tuna", { x = net.position.x + 20, y = net.position.y }, 0)
        local before = runtime.world:getCounts().tuna
        truthy(runtime:ReleaseFishAtContent("trapped_net_01", "sardine", 2))
        eq(runtime.world:getCounts().tuna, before, "no additional big fish")
        truthy(tuna and not tuna.removed)
    end)

    -- ===== 13~15 浮藻假岛 =====
    test("kelp mirage requires the rusty key, one free slot and a lens mark", function()
        local f = fixture({ lens = true })
        local token, reason = f.actions:BeginAction("kelp_mirage_01")
        eq(token, nil)
        eq(reason, "content_not_marked")

        f.adapter.scope.kelp_mirage_01 = true
        f.actions:Advance(1)
        eq(assert(Progress.GetState(f.player, "kelp_mirage_01")).marked, true)

        -- 无钥匙：拒绝开始，不扣体力。
        local stamina = f.player.stamina
        token, reason = f.actions:BeginAction("kelp_mirage_01")
        eq(token, nil)
        eq(reason, "missing_key")
        eq(f.player.stamina, stamina)

        -- 有钥匙但满舱：拒绝开始。
        truthy(V28.GrantTreasure(f.player, "rusty_key"))
        f.player.inventory:Add("sardine")
        f.player.inventory:Add("sardine")
        f.player.inventory:Add("sardine")
        eq(#f.player.inventory:GetItems(), 5)
        token, reason = f.actions:BeginAction("kelp_mirage_01")
        eq(token, nil)
        eq(reason, "inventory_full")
        eq(f.player.stamina, stamina)
        truthy(V28.HasTreasure(f.player, "rusty_key"), "refused begin keeps the key")

        f.player.inventory:Remove(5)
        token, reason = f.actions:BeginAction("kelp_mirage_01")
        truthy(token, tostring(reason))
        truthy(f.actions:Advance(4))
        eq(f.player.stamina, stamina - 40)
        eq(findItem(f.player, "salvaged_chest"), 1)
        falsy(V28.HasTreasure(f.player, "rusty_key"), "the key is consumed on success")
        eq(assert(Progress.GetState(f.player, "kelp_mirage_01")).completed, true)
    end)

    test("kelp mirage cancellation and interruption keep the rusty key", function()
        local f = fixture({ lens = true })
        truthy(V28.GrantTreasure(f.player, "rusty_key"))
        f.adapter.scope.kelp_mirage_01 = true
        f.actions:Advance(1)

        local token = assert(f.actions:BeginAction("kelp_mirage_01"))
        f.actions:Advance(2)
        truthy(f.actions:Cancel(token, "cancelled"))
        truthy(V28.HasTreasure(f.player, "rusty_key"), "cancel keeps the key")
        eq(f.player.stamina, 100)
        eq(findItem(f.player, "salvaged_chest"), 0)

        local second = assert(f.actions:BeginAction("kelp_mirage_01"))
        f.actions:Advance(3)
        truthy(f.actions:Invalidate("night_interrupted"))
        truthy(V28.HasTreasure(f.player, "rusty_key"), "night interruption keeps the key")
        eq(f.player.stamina, 100)
        eq(findItem(f.player, "salvaged_chest"), 0)
        eq(assert(f.actions:GetReceipt(second)).status, "failed")
    end)

    test("kelp mirage recognition is runtime-only and the run resets it", function()
        local f = fixture()
        truthy(V28.MarkRecognized(f.player, "kelp_mirage_01"))
        eq(V28.IsRecognized(f.player, "kelp_mirage_01"), true)
        truthy(V28.ResetRun(f.player))
        eq(V28.IsRecognized(f.player, "kelp_mirage_01"), false)
    end)

    -- ===== 存档兼容 / NewRun =====
    test("V2.7 save without V2.8 fields loads with false defaults", function()
        local player = assert(PlayerState.New())
        local snapshot = Persistence.Snapshot(player)
        -- 模拟 V2.7 存档：删除全部 V2.8 字段。
        snapshot.story.v28 = nil
        snapshot.treasures.sea_note_01 = nil
        snapshot.treasures.sea_note_02 = nil
        snapshot.treasures.rusty_key = nil
        local restored, reason = Persistence.Restore(snapshot)
        truthy(restored, tostring(reason))
        eq(restored.story.v28.vortexPearlClaimed, false)
        eq(restored.story.v28.content.shipwreck_01.marked, false)
        eq(restored.story.v28.content.shipwreck_01.completed, false)
        eq(restored.story.v28.content.leviathan_bones_01.recognized, false)
        eq(restored.story.v28.content.trapped_net_01.completed, false)
        eq(restored.story.v28.content.kelp_mirage_01.marked, false)
        eq(restored.treasures.sea_note_01, false)
        eq(restored.treasures.rusty_key, false)
    end)

    test("V2.8 state survives a save/restore round trip", function()
        local player = assert(PlayerState.New())
        truthy(V28.GrantTreasure(player, "sea_note_01"))
        truthy(V28.GrantTreasure(player, "rusty_key"))
        truthy(V28.SetFlag(player, "shipwreck_01", "marked", true))
        truthy(V28.SetFlag(player, "leviathan_bones_01", "recognized", true))
        truthy(V28.SetPearlClaimed(player, true))
        local restored = assert(Persistence.Restore(Persistence.Snapshot(player)))
        truthy(V28.HasTreasure(restored, "sea_note_01"))
        truthy(V28.HasTreasure(restored, "rusty_key"))
        eq(assert(Progress.GetState(restored, "shipwreck_01")).marked, true)
        eq(V28.IsRecognized(restored, "leviathan_bones_01"), true)
        eq(V28.IsPearlClaimed(restored), true)
        truthy(V28.IsBottlePicked(restored, "bottle_note_01"))
    end)

    test("NewRun clears every V2.8 run-scoped field", function()
        local player = assert(PlayerState.New())
        truthy(V28.GrantTreasure(player, "sea_note_02"))
        truthy(V28.GrantTreasure(player, "rusty_key"))
        truthy(V28.SetFlag(player, "kelp_mirage_01", "completed", true))
        truthy(V28.SetFlag(player, "kelp_mirage_01", "marked", true))
        truthy(V28.SetPearlClaimed(player, true))
        truthy(V28.ResetRun(player))
        falsy(V28.HasTreasure(player, "sea_note_02"))
        falsy(V28.HasTreasure(player, "rusty_key"))
        eq(assert(Progress.GetState(player, "kelp_mirage_01")).completed, false)
        eq(assert(Progress.GetState(player, "kelp_mirage_01")).marked, false)
        eq(V28.IsPearlClaimed(player), false)
        -- 固定坐标不属于周目状态。
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        truthy(runtime:GetWorldContent("kelp_mirage_01"))
    end)

    -- ===== W-08 =====
    test("W-08 three memories bind to the sealed titles and bodies", function()
        local expected = {
            memory_island_01 = { title = "有人牵着我的手", contentId = "island_01" },
            memory_island_02 = { title = "第一次自己走远", contentId = "island_02" },
            memory_treasure_01 = { title = "那盏还亮着的灯", contentId = "underwater_treasure_01" },
        }
        local player = assert(PlayerState.New())
        for rewardId, item in pairs(expected) do
            truthy(V28.GrantTreasure(player, rewardId))
            local story = assert(MemoryFragments.GetOwnedStory(player, item.contentId))
            eq(story.title, item.title, rewardId .. " title")
            truthy(story.text:match("%S"), rewardId .. " body")
            assert(not story.text:find("环境", 1, true),
                rewardId .. " must not fall back to the old location-environment memory")
        end
    end)

    test("W-08 never shows before the memory is owned", function()
        local player = assert(PlayerState.New())
        eq(MemoryFragments.GetOwnedStory(player, "island_01"), nil)
        eq(MemoryFragments.GetOwnedStory(player, "underwater_treasure_01"), nil)
    end)

    -- ===== 物品与经济 =====
    test("V2.8 items keep their sealed prices and independent-bar membership", function()
        local prices = { shipwreck_jewelry = 90, coral_branch = 45, abyss_pearl = 260, salvaged_chest = 110 }
        for itemId, price in pairs(prices) do
            local item = assert(Items.GetDefinition(itemId))
            eq(item.sellPrice, price, itemId .. " sell price")
            eq(item.category, "misc", itemId .. " category")
            falsy(item.independentBar, itemId .. " occupies a cargo slot")
        end
        for _, itemId in ipairs({ "sea_note_01", "sea_note_02", "rusty_key" }) do
            local item = assert(Items.GetDefinition(itemId))
            eq(item.independentBar, true, itemId .. " independent bar")
            eq(item.protected, true, itemId .. " protected")
            eq(item.sellPrice, 0, itemId .. " not sellable")
        end
    end)

    test("V2.8 trade goods sell through the existing port transaction", function()
        local PlayerLoop = require "Gameplay.Loop"
        local loop = PlayerLoop.New()
        truthy(loop:Depart())
        truthy(loop:ReturnToPort())
        truthy(loop.player.inventory:Add("shipwreck_jewelry"))
        local index = #loop.player.inventory:GetItems()
        local money = loop.player.money
        local ok, reason = loop:Sell(index, "shipwreck_jewelry")
        truthy(ok, tostring(reason))
        eq(loop.player.money, money + 90)
    end)

    test("independent-bar items never enter the throw or sell flows", function()
        local PlayerLoop = require "Gameplay.Loop"
        local loop = PlayerLoop.New()
        truthy(V28.GrantTreasure(loop.player, "rusty_key"))
        truthy(loop:Depart())
        local candidates = loop:GetThrowCandidates()
        for _, candidate in ipairs(candidates) do
            assert(candidate.itemId ~= "rusty_key", "independent-bar key must not be throwable")
        end
        truthy(loop:ReturnToPort())
        local treasures = loop:GetV28Treasures()
        eq(#treasures, 1)
        eq(treasures[1], "rusty_key")
    end)

    -- ===== Bridge 级：正式投放 vs 背包丢弃 =====
    test("vortex only reacts to the official WorldDrop, never to the inventory discard", function()
        local runtime, bridge, loop = bridgeFixture()
        truthy(loop:Depart())
        local vortex = definition("sea_eye_vortex_01")
        runtime.ship.position = { x = vortex.position.x, y = vortex.position.y - 3 }

        -- 背包【丢弃】绝不触发海眼。
        truthy(loop.player.inventory:Add("apple"))
        local appleIndex = #loop.player.inventory:GetItems()
        loop:DropItem(appleIndex)
        eq(loop:IsVortexPearlClaimed(), false, "inventory discard must not claim the pearl")
        local temporary = 0
        for _, entity in ipairs(runtime.world.entities) do
            if entity.kind == "temporary" then temporary = temporary + 1 end
        end
        eq(temporary, 0, "inventory discard must not create a vortex attractant")

        -- 正式【投放】选点：60m 吸小鱼临时诱饵。
        truthy(loop.player.inventory:Add("apple"))
        appleIndex = #loop.player.inventory:GetItems()
        truthy(loop:BeginThrowItem(appleIndex))
        truthy(bridge:OnSeaPointer({ x = vortex.position.x, y = vortex.position.y + 1 }))
        local boosted = 0
        for _, entity in ipairs(runtime.world.entities) do
            if entity.kind == "temporary" and entity.attractRadius then boosted = boosted + 1 end
        end
        eq(boosted, 1, "official drop creates exactly one boosted attractant")
    end)

    test("vortex big-fish pearl is claimed atomically through the bridge drop path", function()
        local runtime, bridge, loop = bridgeFixture()
        truthy(loop:Depart())
        local vortex = definition("sea_eye_vortex_01")
        runtime.ship.position = { x = vortex.position.x, y = vortex.position.y - 3 }

        truthy(loop.player.inventory:Add("tuna"))
        local tunaIndex = #loop.player.inventory:GetItems()
        truthy(loop:BeginThrowItem(tunaIndex))
        truthy(bridge:OnSeaPointer({ x = vortex.position.x, y = vortex.position.y + 1 }))
        eq(loop:IsVortexPearlClaimed(), true, "first big fish claims the pearl")
        eq(findItem(loop.player, "abyss_pearl"), 1, "pearl replaces the consumed big fish")

        -- 第二次投大鱼：仍消耗、不再产珍珠。
        truthy(loop.player.inventory:Add("tuna"))
        tunaIndex = #loop.player.inventory:GetItems()
        truthy(loop:BeginThrowItem(tunaIndex))
        truthy(bridge:OnSeaPointer({ x = vortex.position.x, y = vortex.position.y + 1 }))
        eq(findItem(loop.player, "abyss_pearl"), 1, "no second pearl")
        eq(findItem(loop.player, "tuna"), 0, "the second big fish is still consumed")
    end)

    -- ===== Loop 级端到端 =====
    test("Loop-level reef observation, bottle pickup and shipwreck salvage work end to end", function()
        local runtime, bridge, loop = bridgeFixture()
        truthy(loop:Depart())

        -- 礁石：0 体力、停船、取消自动返航。
        local reef = definition("reef_vis_01")
        runtime.ship.position = { x = reef.position.x, y = reef.position.y - 4 }
        local stamina = loop.player.stamina
        truthy(loop:ObserveV28Content("reef_vis_01"))
        eq(loop.player.stamina, stamina, "reef observation is free")

        -- 漂流瓶：拾取 → 残页入独立道具栏 → 弹出阅读模态。
        local bottle = definition("bottle_note_01")
        runtime.ship.position = { x = bottle.position.x, y = bottle.position.y - 3 }
        truthy(loop:PickupV28Content("bottle_note_01"))
        local noteDialog = assert(loop:GetStoryDialog())
        eq(noteDialog.kind, "v28_note")
        truthy(loop:NotifyStoryShown(noteDialog.token))
        truthy(loop:CloseStoryDialog())
        eq(#loop:GetV28Treasures(), 1)
        eq(loop:GetV28Treasures()[1], "sea_note_01")

        -- 沉船：探海镜 1 秒标记 → 40 体力/4 秒打捞 → 珠宝 + 珊瑚枝。
        loop.player.treasures.scopeLens = true
        loop.scopeEnabled = true
        bridge:Sync()
        local wreck = definition("shipwreck_01")
        runtime.ship.position = { x = wreck.position.x, y = wreck.position.y - 3 }
        runtime.ship.rotation = math.pi / 2
        truthy(runtime:IsWorldContentInScope("shipwreck_01"))
        for _ = 1, 40 do bridge:Update(0.05) end
        truthy(loop:IsWorldContentMarked("shipwreck_01"))
        truthy(loop:BeginV28Salvage("shipwreck_01"))
        for _ = 1, 100 do bridge:Update(0.05) end
        local resultDialog = assert(loop:GetStoryDialog())
        eq(resultDialog.kind, "v28_result")
        truthy(loop:NotifyStoryShown(resultDialog.token))
        truthy(loop:CloseStoryDialog())
        eq(findItem(loop.player, "shipwreck_jewelry"), 1)
        eq(findItem(loop.player, "coral_branch"), 1)
        eq(loop.player.stamina, stamina - 40)
    end)

    test("Loop-level trapped net branch B keeps the only key and releases two real fish", function()
        local runtime, _, loop = bridgeFixture()
        truthy(loop:Depart())
        local net = definition("trapped_net_01")
        runtime.ship.position = { x = net.position.x, y = net.position.y - 3 }
        truthy(loop:OpenTrappedNetChoice("trapped_net_01"))
        truthy(loop:ResolveTrappedNet("trapped_net_01", "B"))
        local dialog = assert(loop:GetStoryDialog())
        truthy(loop:NotifyStoryShown(dialog.token))
        truthy(loop:CloseStoryDialog())
        truthy(V28.HasTreasure(loop.player, "rusty_key"))
        eq(loop.player.stamina, 100, "branch B is free")
        local released = 0
        for _, entity in ipairs(runtime.world.entities) do
            if entity.species == "sardine" and entity.state == "Flee" then released = released + 1 end
        end
        eq(released, 2, "two real fleeing fish")
        -- 分支互斥：再选 A 被拒（已完成，不能重复领取）。
        local again, reason = loop:ResolveTrappedNet("trapped_net_01", "A")
        falsy(again)
        eq(reason, "already_completed")
    end)

    test("kelp mirage is exposed as an unknown silhouette then recognized within 20m", function()
        local runtime, bridge, loop = bridgeFixture()
        truthy(loop:Depart())
        local kelp = definition("kelp_mirage_01")
        -- 25m：仍只是未知轮廓，不写识别态。
        runtime.ship.position = { x = kelp.position.x, y = kelp.position.y - 25 }
        bridge:Update(0.05)
        falsy(V28.IsRecognized(loop.player, "kelp_mirage_01"), "25m is still an unknown silhouette")
        -- 20m 内：识破为浮藻层，顶部轻提示一次。
        runtime.ship.position = { x = kelp.position.x, y = kelp.position.y - 19 }
        bridge:Update(0.05)
        truthy(V28.IsRecognized(loop.player, "kelp_mirage_01"), "inside 20m the mirage is recognized")
        local toast = assert(loop:GetActionToast(), "a top notice is queued")
        assert(toast.text:find("海藻", 1, true), "the notice explains the kelp layer")
        truthy(loop:AcknowledgeActionToast(toast.id))
        bridge:Update(0.05)
        eq(loop:GetActionToast(), nil, "the recognition notice shows only once")
        -- 没有登岛按钮：浮藻假岛不提供 explore 动作。
        eq(definition("kelp_mirage_01").actionKind, nil)
    end)

    test("Loop NewRun resets V2.8 state and keeps authored coordinates", function()
        local runtime, bridge, _ = bridgeFixture()
        local loop = bridge.loop
        truthy(V28.GrantTreasure(loop.player, "rusty_key"))
        truthy(V28.SetFlag(loop.player, "kelp_mirage_01", "completed", true))
        truthy(V28.SetPearlClaimed(loop.player, true))
        truthy(bridge:NewRun())
        falsy(V28.HasTreasure(bridge.loop.player, "rusty_key"))
        eq(assert(Progress.GetState(bridge.loop.player, "kelp_mirage_01")).completed, false)
        eq(V28.IsPearlClaimed(bridge.loop.player), false)
        truthy(runtime:GetWorldContent("kelp_mirage_01"))
    end)

    -- ===== 门禁 =====
    test("scene prompts hide while a selection or a four-second action is active", function()
        local f = fixture()
        truthy(f.actions:GetPrompt())
        -- 4 秒动作期间：prompt 变为取消，0 体力场景按钮不再出现。
        f.adapter.scope.shipwreck_01 = true
        f.player.treasures.scopeLens = true
        f.actions:Advance(1)
        local token = assert(f.actions:BeginAction("shipwreck_01"))
        local prompt = assert(f.actions:GetPrompt())
        eq(prompt.operation, "cancel")
        eq(prompt.token, token)
        f.actions:Cancel(token, "cancelled")
        prompt = assert(f.actions:GetPrompt())
        assert(prompt.operation ~= "cancel", "after cancellation the normal prompt returns")
    end)

    test("Loop hides the scene button during fishing selection, throw selection and 4s actions", function()
        local runtime, bridge, loop = bridgeFixture()
        truthy(loop:Depart())
        local reef = definition("reef_vis_01")
        runtime.ship.position = { x = reef.position.x, y = reef.position.y - 4 }
        truthy(loop:GetV28Prompt(), "the reef prompt is available while sailing")

        -- 捕鱼选点期间隐藏。
        truthy(loop:BeginFishingSelection())
        eq(loop:GetV28Prompt(), nil, "fishing selection hides the scene button")
        loop:CancelFishingAction()
        truthy(loop:GetV28Prompt(), "the prompt returns after cancelling fishing")

        -- 投放选点期间隐藏。
        truthy(loop.player.inventory:Add("apple"))
        truthy(loop:BeginThrowItem(#loop.player.inventory:GetItems()))
        eq(loop:GetV28Prompt(), nil, "throw selection hides the scene button")
        loop:CancelThrowSelection()
        truthy(loop:GetV28Prompt(), "the prompt returns after cancelling the throw")

        -- 4 秒动作期间：原位按钮只保留「取消打捞」。
        loop.player.treasures.scopeLens = true
        loop.scopeEnabled = true
        bridge:Sync()
        local wreck = definition("shipwreck_01")
        runtime.ship.position = { x = wreck.position.x, y = wreck.position.y - 3 }
        runtime.ship.rotation = math.pi / 2
        for _ = 1, 40 do bridge:Update(0.05) end
        truthy(loop:IsWorldContentMarked("shipwreck_01"))
        truthy(loop:BeginV28Salvage("shipwreck_01"))
        local active = assert(loop:GetV28Prompt())
        eq(active.operation, "cancel", "an active 4s action turns the button into cancel")
        truthy(loop:CancelV28Action())
    end)

    test("Loop-level observation stops the ship", function()
        local runtime, _, loop = bridgeFixture()
        truthy(loop:Depart())
        local reef = definition("reef_vis_01")
        runtime.ship.position = { x = reef.position.x, y = reef.position.y - 4 }
        runtime.movement:SetTarget({ x = 40, y = 40 })
        truthy(loop:ObserveV28Content("reef_vis_01"))
        eq(runtime.movement.target, nil, "the ship stops moving")
        eq(loop.player.stamina, 100, "observation stays free")
    end)

    test("fixture-injected stale generation fails closed and charges nothing", function()
        local f = fixture({ lens = true })
        f.adapter.scope.shipwreck_01 = true
        f.actions:Advance(1)
        local token = assert(f.actions:BeginAction("shipwreck_01"))
        f.actions:Advance(2)
        f.adapter.generation = 2
        -- 身份变更时事务 fail closed：动作终止、0 扣费、0 奖励。
        f.actions:Advance(3)
        eq(f.player.stamina, 100)
        eq(findItem(f.player, "shipwreck_jewelry"), 0)
        local receipt = assert(f.actions:GetReceipt(token))
        eq(receipt.status, "failed")
    end)

    test("kelp mirage keeps its 80m surface illusion visible without the scope", function()
        -- 策划（系统规则 15 / 12 浮藻假岛）：80m 内显岛影轮廓、20m 内识破为藻层。
        -- 该节点登记在 underwater 层（水下货箱需探海镜），但岛影是海面假象，
        -- 必须不依赖探海镜可见性绘制，否则 80m 轮廓永远不会出现。
        -- 这里只验证绘制前置条件（层/可见性/距离），渲染细节由实机 GUI 验收。
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local kelp = assert(runtime.world.fixedContentEntities["kelp_mirage_01"])
        eq(kelp.layer, "underwater", "the kelp node stays on the underwater layer")
        -- visualRadius 由 data.content 携带，World 注册实体时不复制该字段。
        eq(definition("kelp_mirage_01").visualRadius, 14, "the authored 80m island silhouette radius")
        eq(definition("kelp_mirage_01").recognizeDistance, 20, "the authored 20m reveal distance")

        runtime.world.showUnderwater = false
        runtime.world.scopeEnabled = false
        runtime.ship.position = { x = kelp.position.x, y = kelp.position.y - 60 }
        -- 无探海镜、水下隐藏时，underwater 实体默认不可见。
        eq(runtime.world:isVisible(kelp), false,
            "the underwater kelp box stays hidden without the scope")
        -- 因此海面假象必须由 SeaDraw 单独按 outlineDistance 绘制，不能依赖 isVisible。
        truthy(Config.interaction.outlineDistance == 80, "outline range is the authored 80m")
        local dx = kelp.position.x - runtime.ship.position.x
        local dy = kelp.position.y - runtime.ship.position.y
        truthy(dx * dx + dy * dy <= Config.interaction.outlineDistance ^ 2,
            "at 60m the illusion is inside the 80m outline range")
        runtime.ship.position = { x = kelp.position.x, y = kelp.position.y - 80.01 }
        dx = kelp.position.x - runtime.ship.position.x
        dy = kelp.position.y - runtime.ship.position.y
        falsy(dx * dx + dy * dy <= Config.interaction.outlineDistance ^ 2,
            "beyond 80m the illusion must not draw")
    end)

    test("kelp mirage 80m silhouette really reaches the draw commands", function()
        -- 第二轮审查：上一条只验「逻辑条件」，没验「真的画了」。
        -- 这里用运行器提供的真实 NVG 录制器跑一遍 SeaDraw.Scene，断言：
        --   ① 60m 处（无探海镜、水下隐藏）假岛轮廓真的产生填充绘制；
        --   ② 20m 内识破后轮廓半径收窄（同屏填充量下降，不是同一张图）；
        --   ③ 超过 80m 后零绘制。
        -- 若运行器未提供录制器（例如被单独 require），跳过并明确标记。
        -- 两套运行器能力不同：sea_view_regression 注入真实 NVGCapture，
        -- world_content 不注入任何 nvg 绑定。后者在这里装一个**只记录填充色**
        -- 的最小桩，保证本用例在任何运行器下都真的跑绘制路径（不 skcip）。
        local ownRecorder = nil
        if recorder == nil or type(recorder.reset) ~= "function" then
            ownRecorder = { elements = {} }
            function ownRecorder.reset() ownRecorder.elements = {} end
            function ownRecorder.setFillColor(ctx, color)
                ownRecorder.pending = color
            end
            function ownRecorder.fill(ctx)
                local c = ownRecorder.pending
                if type(c) == "table" then
                    ownRecorder.elements[#ownRecorder.elements + 1] = {
                        r = c.r or c[1], g = c.g or c[2], b = c.b or c[3], a = c.a or c[4],
                    }
                end
            end
            function ownRecorder.countFillColor(r, g, b, a)
                local count = 0
                for _, e in ipairs(ownRecorder.elements) do
                    if math.abs(e.r - r) < 1 and math.abs(e.g - g) < 1
                        and math.abs(e.b - b) < 1 and math.abs(e.a - (a or 255)) < 1 then
                        count = count + 1
                    end
                end
                return count
            end
            local stubs = {
                nvgRGBA = function(r, g, b, a)
                    return { r = r, g = g, b = b, a = a or 255 }
                end,
                nvgBeginPath = function() end, nvgMoveTo = function() end,
                nvgLineTo = function() end, nvgQuadTo = function() end,
                nvgBezierTo = function() end, nvgClosePath = function() end,
                nvgRect = function() end, nvgRoundedRect = function() end,
                nvgCircle = function() end, nvgEllipse = function() end,
                nvgFillColor = ownRecorder.setFillColor, nvgFill = ownRecorder.fill,
                nvgStrokeColor = function() end, nvgStrokeWidth = function() end,
                nvgStroke = function() end, nvgSave = function() end,
                nvgRestore = function() end, nvgTranslate = function() end,
                nvgScale = function() end, nvgRotate = function() end,
                nvgScissor = function() end, nvgIntersectScissor = function() end,
                nvgResetScissor = function() end, nvgGlobalAlpha = function() end,
                nvgShapeAntiAlias = function() end, nvgTransform = function() end,
                nvgFillPaint = function() end, nvgLinearGradient = function() return 0 end,
                nvgRadialGradient = function() return 0 end,
                nvgImagePattern = function() return 0 end,
                nvgCreateImage = function() return -1 end,
                nvgImageSize = function() end,
                nvgText = function() end, nvgFontFace = function() end,
                nvgFontSize = function() end, nvgTextAlign = function() end,
                nvgCreateFont = function() return 0 end,
                nvgTextBounds = function() return 0, 0, 0, 0 end,
                -- ImageArt 读取这几个标志常量做位运算（REPEATX|REPEATY|MIPMAPS）。
                NVG_IMAGE_GENERATE_MIPMAPS = 1,
                NVG_IMAGE_REPEATX = 2,
                NVG_IMAGE_REPEATY = 4,
                NVG_IMAGE_FLIPY = 8,
                NVG_IMAGE_PREMULTIPLIED = 16,
                NVG_IMAGE_NEAREST = 32,
            }
            local saved = {}
            for name, fn in pairs(stubs) do
                saved[name] = _G[name]
                _G[name] = fn
            end
            recorder = ownRecorder
            recorder._restore = function()
                for name in pairs(stubs) do _G[name] = saved[name] end
            end
        end
        local function cleanup()
            if ownRecorder and ownRecorder._restore then ownRecorder._restore() end
        end
        local SeaDraw = require("Ocean.SeaDraw")
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        runtime.movement:SetViewport(1280, 720)
        local kelp = assert(runtime.world.fixedContentEntities["kelp_mirage_01"])
        runtime.world.showUnderwater = false
        runtime.world.scopeEnabled = false

        local function drawAt(distance)
            runtime.ship.position = { x = kelp.position.x, y = kelp.position.y - distance }
            runtime.movement:ResetAtPosition(runtime.ship.position)
            recorder.reset()
            SeaDraw.Scene({}, 1280, 720, runtime, nil, nil,
                function() return false end, function() return false end)
            return recorder.countFillColor(150, 170, 150, 90) -- 未识破的岛影填充色
        end

        local okBody, bodyErr = pcall(function()
        local farIllusion = drawAt(60)
        assert(farIllusion > 0,
            "at 60m the unknown-island silhouette must really be painted, got " .. farIllusion .. " fills")
        local beyondRange = drawAt(85)
        eq(beyondRange, 0, "beyond 80m the illusion must paint nothing")

        -- 20m 内识破：改用藻层配色（V28_PALETTE.kelp.fill = 88,138,96,190）。
        runtime.ship.position = { x = kelp.position.x, y = kelp.position.y - 15 }
        runtime.movement:ResetAtPosition(runtime.ship.position)
        recorder.reset()
        SeaDraw.Scene({}, 1280, 720, runtime, nil, nil,
            function(contentId) return contentId == "kelp_mirage_01" end,
            function() return false end)
        local recognizedFills = recorder.countFillColor(88, 138, 96, 190)
        assert(recognizedFills > 0,
            "once recognized the kelp layer must be painted instead of the illusion")
        eq(recorder.countFillColor(150, 170, 150, 90), 0,
            "the unknown-island fill must disappear after recognition")
        end)
        cleanup()
        assert(okBody, bodyErr)
    end)

    return { results = results }
end

return Tests
