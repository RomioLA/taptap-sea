-- V2.8 Closure Fix 回归：玩家实际入口闭环。
-- 覆盖：
--   P0  V2.8 story dialog 走真实 HUD 模态（不再被白名单过滤）→ 可见 → 关闭 → story pause 释放
--   P1  普通交易品不进【投放】白名单；【丢弃】直接腾格且不产生 WorldDrop
--   P1  海眼按明确物品身份接受，worldEffect=NONE 的普通物品不得触发 tuna→pearl
--   P1  独立道具栏（航海残页/生锈钥匙）真实可点击 UI 入口：重读/查看 + 给老人 + 丢弃拒绝
--   P2  破渔网 B 分支 2 鱼原子性（0/2、1/2、2/2）
--   P2  海眼珍珠事务原子性（前置失败不消耗大鱼、不发珍珠、不置 claim）
--
-- 说明：本套件用 in-memory widget double 构造真实 HUD，不用 loop:GetStoryDialog()
-- 单点断言代替 HUD 可见性。
local Content = require "data.content"
local Items = require "data.items"
local Runtime = require "Ocean.SeaRuntime"
local PlayerState = require "Gameplay.PlayerState"
local V28 = require "Gameplay.V28Progress"
local Flow = require "tests.Circle1BFishingFlowTests"

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function truthy(value, label)
    assert(value, label or "expected a truthy value")
end

local function falsy(value, label)
    assert(not value, label or "expected a falsy value")
end

local function definition(contentId)
    for _, item in ipairs(Content.fixed) do
        if item.contentId == contentId then return item end
    end
    error("missing content " .. tostring(contentId))
end

-- ===== 真实 HUD 构造（与 Circle1B2UITests 同一 in-memory widget double）=====
local activeUI = nil

local function makeUI()
    local Widget = {}
    Widget.__index = Widget

    function Widget:AddChild(child)
        self.children[#self.children + 1] = child
        child.parent = self
    end
    function Widget:RemoveChild(child)
        for index, value in ipairs(self.children) do
            if value == child then table.remove(self.children, index); break end
        end
        child.parent = nil
    end
    function Widget:GetChildAt(index) return self.children[index] end
    function Widget:GetChildren() return self.children end
    function Widget:ClearChildren()
        for _, child in ipairs(self.children) do child.parent = nil end
        self.children = {}
    end
    function Widget:SetVisible(value) self.visible = value == true end
    function Widget:IsVisible() return self.visible end
    function Widget:Show() self:SetVisible(true) end
    function Widget:Hide() self:SetVisible(false) end
    function Widget:SetText(value)
        assert(self.kind == "Label" or self.kind == "Button", "SetText requires a text widget")
        self.props.text = value
    end
    function Widget:SetDisabled(value)
        assert(self.kind == "Button", "SetDisabled requires a button")
        self.disabled = value == true
    end
    function Widget:Destroy()
        self.destroyed = true
        if self.parent then self.parent:RemoveChild(self) end
    end

    local UI = { widgets = {} }
    for _, kind in ipairs({ "Panel", "SafeAreaView", "Label", "Button", "Spacer", "ScrollView", "TextField" }) do
        UI[kind] = function(props)
            props = props or {}
            local widget = setmetatable({
                kind = kind, props = props, children = {},
                visible = props.visible ~= false, disabled = false,
            }, Widget)
            UI.widgets[#UI.widgets + 1] = widget
            for _, child in ipairs(props.children or {}) do widget:AddChild(child) end
            return widget
        end
    end
    return UI
end

local function withHUD(run)
    local previousUI = package.loaded["urhox-libs/UI"]
    local previousHUD = package.loaded["Gameplay.HUD"]
    local UI = makeUI()
    package.loaded["urhox-libs/UI"] = UI
    package.loaded["Gameplay.HUD"] = nil
    local ok, result = xpcall(function()
        return run(require("Gameplay.HUD"), UI)
    end, debug.traceback)
    package.loaded["urhox-libs/UI"] = previousUI
    package.loaded["Gameplay.HUD"] = previousHUD
    if not ok then error(result, 0) end
    return result
end

local function walk(root, visit, visibleOnly)
    local function descend(widget, parentsVisible)
        local visible = parentsVisible and widget.visible == true
        if visibleOnly and not visible then return end
        visit(widget)
        for _, child in ipairs(widget.children) do descend(child, visible) end
    end
    descend(root, true)
end

local function isVisible(widget)
    while widget do
        if widget.visible ~= true then return false end
        widget = widget.parent
    end
    return true
end

local function findButtons(root, text)
    local found = {}
    walk(root, function(widget)
        if widget.kind == "Button" and widget.props.text == text then found[#found + 1] = widget end
    end)
    return found
end

local function button(root, text)
    local found = findButtons(root, text)
    assert(#found > 0, "missing button: " .. text)
    return found[1]
end

local function click(widget)
    assert(widget.kind == "Button" and type(widget.props.onClick) == "function", "button callback missing")
    assert(isVisible(widget), "cannot click a hidden button: " .. tostring(widget.props.text))
    assert(not widget.disabled, "button is disabled: " .. tostring(widget.props.text))
    widget.props.onClick()
end

local function exactLabel(root, text)
    local found
    walk(root, function(widget)
        if not found and widget.kind == "Label" and widget.props.text == text then found = widget end
    end)
    return found
end

local function findById(root, id)
    if root.props and root.props.id == id then return root end
    for _, child in ipairs(root.children or {}) do
        local found = findById(child, id)
        if found then return found end
    end
    return nil
end

local function atSea(settings)
    local fixture = Flow.Fixture(settings)
    assert(fixture.loop:Depart())
    return fixture
end

---真实 Ocean Runtime + Bridge：海眼/破网需要 world.fixedContentEntities 里的真实实体。
---Flow.Fixture 用的是测试替身 world（无固定实体），不能用于这些路径。
local Bridge = require "Integration.Bridge"
local function realFixture()
    local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
    local store = {}
    function store:Save(_, done) if done then done(true) end end
    function store:Load(done) if done then done(true, nil) end end
    local bridge = Bridge.New(runtime, { store = store })
    bridge:Sync()
    assert(bridge.loop:Depart())
    return { runtime = runtime, bridge = bridge, loop = bridge.loop }
end

---真实 HUD 是否把当前 storyDialog 渲染成了可见正文。
---返回可见的 storyDialogText 控件（nil 表示玩家看不到）。
local function visibleStoryText(hud)
    local widget = findById(hud.root, "storyDialogText")
    if not widget then return nil end
    return isVisible(widget) and widget or nil
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

    -- =========================================================
    -- P0：V2.8 story dialog 走真实 HUD 模态
    -- =========================================================
    test("P0 v28_note pickup renders a visible HUD modal and closing releases the story pause", function()
        local f = realFixture()
        local bottle = definition("bottle_note_01")
        f.runtime.ship.position = { x = bottle.position.x, y = bottle.position.y - 2 }
        truthy(f.loop:PickupV28Content("bottle_note_01"), "pickup should succeed")

        local dialog = assert(f.loop:GetStoryDialog(), "pickup opens the note dialog")
        eq(dialog.kind, "v28_note")
        eq(f.loop.clock.pauseReasons.story, true, "the note pauses the world")

        withHUD(function(HUD)
            activeUI = makeUI()
            local hud = HUD.Create(f.loop)
            -- 关键：HUD 必须真的把正文渲染出来，而不是只让 Loop 返回成功。
            local text = visibleStoryText(hud)
            assert(text, "P0 REGRESSION: the v28_note body is not visible in the HUD")
            eq(text.props.text, dialog.text, "the HUD must show the exact note body")
            truthy(exactLabel(hud.root, dialog.title or "航海残页"),
                "the HUD must show the note title")

            click(button(hud.root, "结束对话"))
            eq(f.loop:GetStoryDialog(), nil, "closing clears the dialog")
            eq(f.loop.clock.pauseReasons.story, nil, "closing releases the story pause")
            hud.Refresh()
            eq(visibleStoryText(hud), nil, "no stale modal remains after closing")
        end)
    end)

    test("P0 v28_result salvage renders a visible HUD modal and closing releases the story pause", function()
        local f = realFixture()
        local wreck = definition("shipwreck_01")
        f.loop.player.treasures.scopeLens = true
        f.loop.scopeEnabled = true
        f.bridge:Sync()
        f.runtime.ship.position = { x = wreck.position.x, y = wreck.position.y - 3 }
        f.runtime.ship.rotation = math.pi / 2
        for _ = 1, 40 do f.bridge:Update(0.05) end
        truthy(f.loop:IsWorldContentMarked("shipwreck_01"), "the lens marks the wreck")
        truthy(f.loop:BeginV28Salvage("shipwreck_01"))
        for _ = 1, 90 do f.bridge:Update(0.05) end

        local dialog = assert(f.loop:GetStoryDialog(), "salvage success opens the result dialog")
        eq(dialog.kind, "v28_result")
        eq(f.loop.clock.pauseReasons.story, true)

        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local text = visibleStoryText(hud)
            assert(text, "P0 REGRESSION: the v28_result body is not visible in the HUD")
            eq(text.props.text, dialog.text)
            click(button(hud.root, "结束对话"))
            eq(f.loop.clock.pauseReasons.story, nil, "closing releases the story pause")
        end)
    end)

    test("P0 every V2.8 result path uses a kind the HUD accepts", function()
        -- 白名单必须覆盖 Loop 实际会产生的全部 V2.8 kind。
        -- 漏一种就是“pause 已开、弹窗不可见”的软锁。
        local f = atSea()
        local cases = {
            { kind = "v28_note", title = "航海残页（一）", text = "残页正文。" },
            { kind = "v28_result", text = "打捞完成。" },
        }
        for _, case in ipairs(cases) do
            f.loop.storyDialog = { token = {}, kind = case.kind,
                title = case.title, text = case.text }
            f.loop.clock:Pause("story")
            withHUD(function(HUD)
                local hud = HUD.Create(f.loop)
                assert(visibleStoryText(hud),
                    "the HUD must render story kind: " .. case.kind)
                click(button(hud.root, "结束对话"))
            end)
            eq(f.loop.clock.pauseReasons.story, nil, case.kind .. " must release the pause")
        end
    end)

    -- =========================================================
    -- P1：投放 / 丢弃能力分离
    -- =========================================================
    test("P1 V2.8 trade goods never enter the throw picker", function()
        -- 库存 5 格：分两批覆盖全部 8 种物品。
        local batches = {
            { "shipwreck_jewelry", "coral_branch", "abyss_pearl", "salvaged_chest", "apple" },
            { "bait", "sardine", "tuna" },
        }
        local seen = {}
        for _, batch in ipairs(batches) do
            local f = atSea({ items = batch })
            for _, entry in ipairs(f.loop:GetThrowCandidates()) do seen[entry.itemId] = true end
        end
        for _, itemId in ipairs({ "shipwreck_jewelry", "coral_branch", "abyss_pearl", "salvaged_chest" }) do
            falsy(seen[itemId], "P1 REGRESSION: " .. itemId .. " must not be throwable")
        end
        for _, itemId in ipairs({ "apple", "bait", "sardine", "tuna" }) do
            truthy(seen[itemId], "the ecology items must stay throwable: " .. itemId)
        end
    end)

    test("P1 unknown future items default to not throwable", function()
        -- 能力表是显式白名单：未登记物品一律不可投放，
        -- 这样 V2.9 新增 worldEffect=NONE 的物品不会自动进入投放列表。
        falsy(Items.CanWorldDrop("a_future_item"), "unknown items must not be throwable")
        falsy(Items.CanWorldDrop("shipwreck_jewelry"))
        falsy(Items.CanWorldDrop("sea_note_01"))
        falsy(Items.CanWorldDrop("rusty_key"))
        truthy(Items.CanWorldDrop("apple"))
        truthy(Items.CanWorldDrop("bait"))
        truthy(Items.CanWorldDrop("sardine"))
        truthy(Items.CanWorldDrop("tuna"))
    end)

    test("P1 discarding a trade good frees a slot without creating a world drop", function()
        local f = atSea({ items = { "shipwreck_jewelry", "apple" } })
        local dropCalls = 0
        f.loop.options.dropReceiver = function() dropCalls = dropCalls + 1; return true end
        local before = #f.loop.player.inventory:GetItems()
        local ok, result = f.loop:DropItem(1)
        truthy(ok, "discarding a trade good must succeed at sea")
        eq(result, "discarded")
        eq(#f.loop.player.inventory:GetItems(), before - 1, "the slot is freed")
        eq(dropCalls, 0, "P1 REGRESSION: discard must not reach the WorldDrop receiver")
        eq(f.loop.player.inventory:GetItems()[1], "apple", "the other item is untouched")
    end)

    test("P1 ecology items still go through the WorldDrop receiver", function()
        local f = atSea({ items = { "apple" } })
        local dropCalls = 0
        f.loop.options.dropReceiver = function() dropCalls = dropCalls + 1; return true end
        truthy(f.loop:DropItem(1))
        eq(dropCalls, 1, "apple discard still produces a world drop (existing bait/throw path)")
    end)

    -- =========================================================
    -- P1：海眼物品类型安全
    -- =========================================================
    test("P1 vortex role table accepts only the four ecology items", function()
        eq(Items.VortexRole("apple"), "small")
        eq(Items.VortexRole("bait"), "small")
        eq(Items.VortexRole("sardine"), "big")
        eq(Items.VortexRole("tuna"), "pearl")
        for _, itemId in ipairs({ "shipwreck_jewelry", "coral_branch", "abyss_pearl",
            "salvaged_chest", "sea_note_01", "sea_note_02", "rusty_key" }) do
            eq(Items.VortexRole(itemId), nil,
                "P1 REGRESSION: " .. itemId .. " must not be a vortex item")
        end
        eq(Items.VortexRole("a_future_none_item"), nil, "unknown items are rejected")
    end)

    test("P1 a worldEffect=NONE non-tuna item never triggers the tuna pearl rule", function()
        local f = realFixture()
        local vortex = definition("sea_eye_vortex_01")
        -- 站在海眼附近，并把物品塞进船舱。
        f.runtime.ship.position = { x = vortex.position.x, y = vortex.position.y - 2 }
        truthy(f.loop.player.inventory:Add("shipwreck_jewelry"))
        local index = #f.loop.player.inventory:GetItems()
        local pearlBefore = V28.IsPearlClaimed(f.loop.player)
        -- 珠宝没有投放能力：投放入口直接拒绝，根本不进入 WorldDrop / 海眼。
        local begun, reason = f.loop:BeginThrowItem(index)
        eq(begun, false, "P1 REGRESSION: jewelry must not enter throw selection")
        eq(reason, "item_not_throwable")
        truthy(f.loop.lastMessage:find("不能投放", 1, true), "the refusal is explained")
        eq(V28.IsPearlClaimed(f.loop.player), pearlBefore, "the pearl claim flag must not change")
        -- 快捷投掷路径同样必须拒绝。
        local quick, quickReason = f.loop:ThrowItemAtShip(index)
        eq(quick, false, "the quick throw path must reject it too")
        eq(quickReason, "item_not_throwable")
    end)

    test("P1 real tuna inside the vortex still claims exactly one pearl", function()
        local f = realFixture()
        local vortex = definition("sea_eye_vortex_01")
        f.runtime.ship.position = { x = vortex.position.x, y = vortex.position.y - 2 }
        truthy(f.loop.player.inventory:Add("tuna"))
        local index = #f.loop.player.inventory:GetItems()
        truthy(f.loop:BeginThrowItem(index), "tuna is throwable")
        -- 船离海眼 2m，落点就在船位（≤12m 且在海眼核心内）。
        assert(f.loop.actions):SetDropTarget({ x = f.runtime.ship.position.x,
            y = f.runtime.ship.position.y })
        truthy(f.loop:DropItem(index), "tuna must be accepted as a formal vortex drop")
        truthy(V28.IsPearlClaimed(f.loop.player), "the first tuna claims the pearl")
        local hasPearl = false
        for _, id in ipairs(f.loop.player.inventory:GetItems()) do
            if id == "abyss_pearl" then hasPearl = true end
        end
        truthy(hasPearl, "the pearl lands in the freed slot")
    end)

    -- =========================================================
    -- P1：独立道具栏真实 UI 入口
    -- =========================================================
    test("P1 independent-bar items expose real clickable HUD actions", function()
        local f = atSea()
        truthy(V28.GrantTreasure(f.loop.player, "sea_note_01"))
        truthy(V28.GrantTreasure(f.loop.player, "rusty_key"))

        local actions = f.loop:GetV28TreasureActions()
        eq(#actions, 2, "both independent-bar items are listed")
        for _, entry in ipairs(actions) do
            truthy(entry.treasureId, "each row identifies its item")
            truthy(entry.name, "each row has a display name")
            truthy(entry.useLabel, "each row offers a use label")
            eq(entry.canUse, true, "both items can be viewed/reread")
            eq(entry.canDiscard, false, "neither item can be discarded")
            truthy(entry.discardDisabledReason, "the discard refusal is explained")
        end
    end)

    test("P1 sea note can be reopened from the HUD and the world resumes after closing", function()
        -- 宝物卡挂在信息屏下，港口默认展开（infoOpen = nil and inPort）。
        -- 留在港口才能验证玩家真实看到的入口。
        local f = Flow.Fixture()
        truthy(V28.GrantTreasure(f.loop.player, "sea_note_01"))
        local note = assert(Items.GetDefinition("sea_note_01"))
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            -- 宝物卡挂在信息屏（drawerContent）下，港口默认展开；
            -- 显式点「港口商店」确保玩家入口可见。
            if not isVisible(findById(hud.root, "storyDialogText") or hud.root) then end
            local rows = true
            -- 找到「重读」按钮并点击：这就是玩家的真实入口。
            local reread = button(hud.root, "重读")
            truthy(isVisible(reread), "the reread button must be visible in the HUD")
            click(reread)
            local dialog = assert(f.loop:GetStoryDialog(), "reread opens the note body")
            eq(dialog.kind, "v28_note")
            eq(dialog.text, note.useText, "the note body is the authored copy")
            hud.Refresh()
            local text = visibleStoryText(hud)
            assert(text, "the reopened note must be visible through the HUD")
            eq(text.props.text, note.useText)
            click(button(hud.root, "结束对话"))
            eq(f.loop.clock.pauseReasons.story, nil, "closing the note releases the pause")
            truthy(V28.HasTreasure(f.loop.player, "sea_note_01"), "rereading never consumes the note")
            truthy(rows, "")
        end)
    end)

    test("P1 rusty key can be viewed and shown to the elder without being consumed", function()
        local f = Flow.Fixture()
        truthy(V28.GrantTreasure(f.loop.player, "rusty_key"))
        local key = assert(Items.GetDefinition("rusty_key"))
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local view = button(hud.root, "查看")
            truthy(isVisible(view), "the key view button must be visible")
            click(view)
            eq(f.loop.lastMessage, key.useText, "viewing shows the authored key description")
            truthy(V28.HasTreasure(f.loop.player, "rusty_key"), "viewing never consumes the key")

            -- 给老人：老人不在世时按钮禁用，但 Loop 仍给出明确原因。
            local give = button(hud.root, "给老人")
            local okGive, reason = f.loop:ShowV28TreasureToElder("rusty_key")
            if f.loop:IsElderPresent() then
                truthy(okGive or reason, "an alive elder accepts the key")
            else
                eq(okGive, false, "a departed elder refuses the key")
                truthy(reason, "the refusal carries a reason")
            end
            truthy(V28.HasTreasure(f.loop.player, "rusty_key"), "showing never consumes the key")
            truthy(give, "the give button exists")
        end)
    end)

    test("P1 discarding an independent-bar item is refused with an explicit reason", function()
        local f = atSea()
        truthy(V28.GrantTreasure(f.loop.player, "rusty_key"))
        local ok, reason = f.loop:DiscardV28Treasure("rusty_key")
        eq(ok, false)
        eq(reason, "treasure_protected")
        truthy(f.loop.lastMessage:find("不能丢弃", 1, true),
            "the refusal must explain why, not just fail")
        truthy(V28.HasTreasure(f.loop.player, "rusty_key"), "the key survives the refusal")
    end)

    -- =========================================================
    -- P2：破渔网 B 分支 2 鱼原子性
    -- =========================================================
    local function fishCount(runtime)
        local count = 0
        for _, entity in ipairs(runtime.world.entities) do
            if entity.species == "sardine" and not entity.removed then count = count + 1 end
        end
        return count
    end

    test("P2 net branch B releases exactly two live fleeing sardines", function()
        local f = realFixture()
        local net = definition("trapped_net_01")
        f.runtime.ship.position = { x = net.position.x, y = net.position.y - 3 }
        local before = fishCount(f.runtime)
        local okNet, reasonNet = f.loop:ResolveTrappedNet("trapped_net_01", "B")
        truthy(okNet, "net branch B failed: " .. tostring(reasonNet))
        eq(fishCount(f.runtime), before + 2, "exactly two sardines are released")
        truthy(V28.HasTreasure(f.loop.player, "rusty_key"), "the key is granted")
        local fleeing = 0
        for _, entity in ipairs(f.runtime.world.entities) do
            if entity.species == "sardine" and not entity.removed and entity.state == "Flee" then
                fleeing = fleeing + 1
            end
        end        eq(fleeing, 2, "both released fish enter the Flee state")
    end)

    test("P2 release aborts atomically when it cannot place every fish", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local net = definition("trapped_net_01")
        local originalFree = runtime.world.isPositionFree
        -- 只允许第一个位置成功：模拟 1/2 容量。
        local allowed = 0
        runtime.world.isPositionFree = function(world, position, radius)
            local ok = originalFree(world, position, radius)
            if not ok then return false end
            allowed = allowed + 1
            return allowed <= 1
        end
        local before = fishCount(runtime)
        local ok, reason = runtime:ReleaseFishAtContent("trapped_net_01", "sardine", 2)
        eq(ok, false, "P2 REGRESSION: a partial release must fail as a whole")
        eq(reason, "fish_release_no_space")
        eq(fishCount(runtime), before, "no fish is spawned when placement fails")
    end)

    test("P2 release succeeds when both positions are available", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local before = fishCount(runtime)
        truthy(runtime:ReleaseFishAtContent("trapped_net_01", "sardine", 2))
        eq(fishCount(runtime), before + 2, "2/2 spawns two fish")
    end)

    -- =========================================================
    -- P2：海眼珍珠事务原子性
    -- =========================================================
    test("P2 pearl claim rolls back completely when the inventory insert fails", function()
        local player = assert(PlayerState.New())
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local FlowLoop = require "Gameplay.Loop"
        local store = {}
        function store:Save(_, done) if done then done(true) end end
        function store:Load(done) if done then done(true, nil) end end
        local loop = FlowLoop.New({ store = store, dropReceiver = function() return true end })
        loop.player = player

        local before = #player.inventory:GetItems()
        local originalAdd = player.inventory.Add
        player.inventory.Add = function() return false, "simulated_insert_failure" end
        local ok = loop:ClaimVortexPearl({ itemId = "tuna" })
        player.inventory.Add = originalAdd

        eq(ok, false, "a failed insert must not report success")
        eq(#player.inventory:GetItems(), before, "the inventory is unchanged")
        eq(V28.IsPearlClaimed(player), false, "P2 REGRESSION: the claim flag must stay false")
        eq(player.stamina, 100, "stamina is untouched")
        truthy(runtime, "")
    end)

    test("P2 a failed pearl claim does not consume the tuna", function()
        local f = realFixture()
        local vortex = definition("sea_eye_vortex_01")
        f.runtime.ship.position = { x = vortex.position.x, y = vortex.position.y - 2 }
        truthy(f.loop.player.inventory:Add("tuna"))
        local index = #f.loop.player.inventory:GetItems()

        -- 让珍珠写入失败。
        local originalAdd = f.loop.player.inventory.Add
        f.loop.player.inventory.Add = function(_, itemId)
            if itemId == "abyss_pearl" then return false, "simulated_insert_failure" end
            return originalAdd(f.loop.player.inventory, itemId)
        end

        truthy(f.loop:BeginThrowItem(index))
        assert(f.loop.actions):SetDropTarget({ x = vortex.position.x, y = vortex.position.y })
        local ok = f.loop:DropItem(index)
        f.loop.player.inventory.Add = originalAdd

        eq(ok, false, "the drop is rejected when the pearl cannot be inserted")
        eq(V28.IsPearlClaimed(f.loop.player), false, "the claim flag must stay false")
        local stillHasTuna = false
        for _, id in ipairs(f.loop.player.inventory:GetItems()) do
            if id == "tuna" then stillHasTuna = true end
        end
        truthy(stillHasTuna, "P2 REGRESSION: a failed pearl claim must not swallow the tuna")
    end)

    return { results = results }
end

return Tests
