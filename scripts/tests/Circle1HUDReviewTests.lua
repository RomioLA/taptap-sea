-- 玩家路径与引擎过渡算法的无窗口验证，不证明实际像素/触摸效果。
local Loop = require("Gameplay.Loop")
local Config = require("config.gameplay")
local Transition = require("urhox-libs/UI/Core/Transition")
local Tests = {}

local function uiHost()
    local Widget = {}
    Widget.__index = Widget
    function Widget:AddChild(child) self.children[#self.children + 1] = child; child.parent = self end
    function Widget:RemoveChild(child)
        for i, value in ipairs(self.children) do if value == child then table.remove(self.children, i); break end end
    end
    function Widget:GetChildren() return self.children end
    function Widget:ClearChildren() self.children = {} end
    function Widget:Destroy() if self.parent then self.parent:RemoveChild(self) end end
    function Widget:SetVisible(value) self.visible = value end
    function Widget:IsVisible() return self.visible end
    function Widget:Show() self:SetVisible(true) end
    function Widget:Hide() self:SetVisible(false) end
    function Widget:SetText(value) self.props.text = value end
    function Widget:SetDisabled(value) self.disabled = value end
    function Widget:SetOpacity(value)
        self.opacityWrites = (self.opacityWrites or 0) + 1
        self.props.opacity = value
    end
    -- 与Widget:SetBackgroundColor的真实SetStyle接线相同，使用实际引擎插值算法。
    function Widget:SetBackgroundColor(color)
        self.colorWrites = (self.colorWrites or 0) + 1
        local cfg = self.props.transition and Transition.ParseConfig(self.props.transition)
        if cfg and Transition.ConfigIncludesProperty(cfg, "backgroundColor", Transition.Properties) then
            local duration, easing = Transition.GetPropertyConfig(cfg, "backgroundColor")
            Transition.Start(self.transitions, "backgroundColor", self.props.backgroundColor, color, duration, easing)
        end
        self.props.backgroundColor = color
    end
    local UI = {}
    for _, kind in ipairs({ "Panel", "SafeAreaView", "Label", "Button", "Spacer", "ScrollView", "TextField" }) do
        UI[kind] = function(props)
            props = props or {}
            local widget = setmetatable({ kind = kind, props = props, children = {},
                transitions = {}, visible = props.visible ~= false, disabled = false }, Widget)
            for _, child in ipairs(props.children or {}) do widget:AddChild(child) end
            return widget
        end
    end
    return UI
end

local function walk(root, fn)
    fn(root)
    for _, child in ipairs(root.children) do walk(child, fn) end
end
local function find(root, predicate)
    local result
    walk(root, function(widget) if not result and predicate(widget) then result = widget end end)
    return assert(result, "HUD widget not found")
end
local function label(root, text)
    return find(root, function(w) return w.kind == "Label" and (w.props.text or ""):find(text, 1, true) end)
end
local function button(root, text)
    return find(root, function(w) return w.kind == "Button" and (w.props.text or ""):find(text, 1, true) end)
end
local function fixture(items, action)
    local oldUI, oldHUD = package.loaded["urhox-libs/UI"], package.loaded["Gameplay.HUD"]
    package.loaded["urhox-libs/UI"], package.loaded["Gameplay.HUD"] = uiHost(), nil
    local loop = Loop.New({})
    assert(loop.player.inventory:RestoreItems(items))
    local hud = require("Gameplay.HUD").Create(loop)
    local ok, err = xpcall(function() action(loop, hud) end, debug.traceback)
    hud.Destroy()
    package.loaded["urhox-libs/UI"], package.loaded["Gameplay.HUD"] = oldUI, oldHUD
    if not ok then error(err, 0) end
end

function Tests.Run()
    local results = {}
    local function check(name, action)
        local ok, err = xpcall(action, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end
    check("stable visible and hidden modal opacity does not dirty layout on each refresh", function()
        fixture({}, function(loop, hud)
            local modal = find(hud.root, function(w) return w.props.transition == "opacity 0.25s easeOut" end) --[[@as any]]
            assert(modal.props.opacity == 1, "opening dialogue must still fade in")
            local writes = assert(modal.opacityWrites) --[[@as number]]
            for _ = 1, 5 do hud.Refresh() end
            assert(modal.opacityWrites == writes, "same visible target repeated SetStyle")
            assert(loop:Depart()); hud.Refresh()
            assert(modal.props.opacity == 0 and modal.opacityWrites == writes + 1,
                "hiding must still change the opacity target exactly once")
            for _ = 1, 5 do hud.Refresh() end
            assert(modal.opacityWrites == writes + 1, "hidden modal repeated SetStyle")
        end)
    end)
    check("fish rows and port sales show rarity without inventing weight", function()
        fixture({ "sardine", "tuna", "bait" }, function(loop, hud)
            assert(loop:SetInventoryOpen(true)); hud.Refresh()
            assert(label(hud.root, "沙丁鱼 · 普通鱼获").props.fontColor == Config.ui.palette.textMuted)
            assert(label(hud.root, "金枪鱼 · 稀有鱼获").props.fontColor == Config.ui.palette.textGold)
            label(hud.root, "稀有鱼获 · 槽位")
            walk(hud.root, function(w) assert(not (w.props.text or ""):find("kg", 1, true)) end)
        end)
    end)
    check("empty cabin and supply-only cabin explain disabled sell-all", function()
        for _, cargo in ipairs({ {}, { "bait" } }) do
            fixture(cargo, function(loop, hud)
                assert(loop:SetInventoryOpen(true)); hud.Refresh()
                assert(button(hud.root, "全部卖出").disabled)
                assert(label(hud.root, "先去捕点鱼：").visible)
                local money = loop.player.money
                local ok = loop:SellAll()
                assert(not ok and loop.player.money == money)
            end)
        end
    end)
    check("catch at sea explains port requirement and sale becomes available on return", function()
        fixture({ "tuna" }, function(loop, hud)
            assert(loop:Depart()); assert(loop:SetInventoryOpen(true)); hud.Refresh()
            assert(button(hud.root, "全部卖出").disabled)
            assert(label(hud.root, "鱼获已装舱").visible)
            assert(loop:SetInventoryOpen(false)); assert(loop:ReturnToPort()); hud.Refresh()
            assert(not button(hud.root, "全部卖出").disabled)
            assert(loop:SellAll()); assert(loop.player.money == 220)
        end)
    end)
    check("drawer and cards use native RGBA interpolation and stable phase writes", function()
        fixture({}, function(loop, hud)
            local drawer = find(hud.root, function(w) return w.props.zIndex == 91 end)
            assert(drawer.props.transition:find("opacity", 1, true))
            assert(drawer.props.transition:find("backgroundColor", 1, true))
            loop.clock:Seek("night", 0); hud.Refresh()
            local writes = drawer.colorWrites
            local active = drawer.transitions[1]
            assert(active, "backgroundColor must start a real transition")
            Transition.Update(drawer.transitions, 0.4)
            local mid = active[8]
            for i = 1, 4 do
                local a, b = Config.ui.palette.seaDeep[i], Config.ui.palette.seaNight[i]
                assert(math.abs(mid[i] - (a + b) / 2) < 0.01)
            end
            hud.Refresh(); assert(drawer.colorWrites == writes, "same phase must not restart transition")
            Transition.Update(drawer.transitions, 0.4)
            assert(#drawer.transitions == 0)
            loop.clock:Seek("day", 0); hud.Refresh()
            assert(drawer.colorWrites == writes + 1)
        end)
    end)
    check("pending catch selects a sea drop point through the real drawer backdrop only", function()
        local Flow = require("Tests.Circle1BFishingFlowTests")
        local Input = require("Integration.Circle1BInput")
        for _, kind in ipairs({ "mouse", "touch" }) do
            local env = Flow.Fixture({ items = { "bait", "bait", "bait", "bait", "bait" } })
            env.runtime:spawnFish("sardine", { x = 1, y = 0 }); assert(env.loop:Depart())
            assert(env.bridge:BeginFishing({ x = 0, y = 0 })); env.bridge:Update(4)
            assert(env.loop:HasPendingCatch() and env.loop.clock:IsPaused())
            env.runtime.movement = { ScreenToWorld = function() return { x = 2, y = 0 } end }
            local ocean = { physicalWidth = 200, physicalHeight = 100, dpr = 2,
                pointerMinY = 0, SyncViewport = function() return true end }
            local hit = { props = { id = "gameplayDrawerBackdrop" } }
            local ui = { GetScale = function() return 2 end, FindWidgetAt = function() return hit end }
            local event = { x = 50, y = 40, pointerType = kind, IsPrimaryButton = function() return true end }
            assert(Input.HandlePendingPointer(env.bridge, ocean, event, ui))
            assert(env.runtime.paused and not env.runtime.ship.isMoving)
            assert(env.loop:DropItem(1)); assert(env.loop:ClaimPendingCatch())
            assert(#env.loop.player.inventory:GetItems() == 5)
            assert(env.loop:SetInventoryOpen(false)); assert(env.loop:SetInventoryOpen(true))
            assert(env.loop:BeginThrowItem(1))
            hit = { props = { id = "gameplayInventoryDrawer" } }
            assert(not Input.HandlePendingPointer(env.bridge, ocean, event, ui))
            assert(env.loop:GetThrowSelection(), "a UI click must preserve the selected bait")
            hit = { props = { id = "elderDialog" } }
            assert(not Input.HandlePendingPointer(env.bridge, ocean, event, ui))
        end
    end)
    check("cabin gift opens actual elder dialogue and consumes food without healing player", function()
        fixture({ "apple", "bait" }, function(loop, hud)
            assert(loop:SetInventoryOpen(true)); hud.Refresh()
            button(hud.root, "操作").props.onClick()
            local stamina = loop.player.stamina
            button(hud.root, "给予").props.onClick()
            assert(loop.elderOpen and loop.clock.pauseReasons.elder)
            assert(#loop.player.inventory:GetItems() == 1 and loop.player.inventory:GetItems()[1] == "bait")
            assert(loop.player.stamina == stamina and loop:GetElderStatus().applesGiven == 1)
        end)
    end)
    check("elder absence remains clickable and explains reason without losing cargo", function()
        fixture({ "apple" }, function(loop, hud)
            loop.player.day = 4
            require("Gameplay.Circle1B2Progress").OnDayStarted(loop.player)
            assert(not loop:IsElderPresent())
            assert(loop:SetInventoryOpen(true)); hud.Refresh()
            button(hud.root, "操作").props.onClick()
            local give = button(hud.root, "给予")
            assert(not give.disabled); give.props.onClick()
            assert(not loop.elderOpen and #loop.player.inventory:GetItems() == 1)
            label(hud.root, "老人不在船上")
        end)
    end)
    check("full cabin gift frees a slot and claims catch once while all dialogue pauses remain", function()
        local Flow = require("Tests.Circle1BFishingFlowTests")
        local env = Flow.Fixture({ items = { "apple", "bait", "bait", "bait", "bait" } })
        env.runtime:spawnFish("sardine", { x = 1, y = 0 }); assert(env.loop:Depart())
        assert(env.bridge:BeginFishing({ x = 0, y = 0 })); env.bridge:Update(4)
        local oldUI, oldHUD = package.loaded["urhox-libs/UI"], package.loaded["Gameplay.HUD"]
        package.loaded["urhox-libs/UI"], package.loaded["Gameplay.HUD"] = uiHost(), nil
        local hud = require("Gameplay.HUD").Create(env.loop)
        button(hud.root, "操作").props.onClick(); button(hud.root, "给予").props.onClick()
        assert(env.loop.elderOpen and env.loop.inventoryOpen and #env.loop.player.inventory:GetItems() == 4)
        assert(env.loop:GetElderStatus().applesGiven == 1)
        assert(env.loop:SetElderOpen(false)); hud.Refresh()
        button(hud.root, "领取渔获").props.onClick()
        assert(not env.loop:HasPendingCatch() and #env.loop.player.inventory:GetItems() == 5)
        assert(not env.loop:ClaimPendingCatch() and env.loop.clock:IsPaused())
        hud.Destroy(); package.loaded["urhox-libs/UI"], package.loaded["Gameplay.HUD"] = oldUI, oldHUD
    end)
    check("shop shortages explain their cause and are re-enabled after restock", function()
        fixture({}, function(loop, hud)
            loop.player.money = 0; hud.Refresh()
            assert(button(hud.root, "苹果 · ¥").disabled); label(hud.root, "金币不足")
            loop.player.money = 1000; assert(loop:Buy("apple")); assert(loop:Buy("apple")); hud.Refresh()
            assert(button(hud.root, "苹果 · 售罄").disabled); label(hud.root, "今日售罄")
            local money = loop.player.money
            button(hud.root, "苹果 · 售罄").props.onClick()
            assert(loop.player.money == money and loop:GetShopStock("apple") == 0)
            loop:ResetShopStock(); hud.Refresh()
            assert(not button(hud.root, "苹果 · ¥").disabled)
            while loop.player.inventory:HasSpace() do assert(loop.player.inventory:Add("bait")) end
            hud.Refresh(); assert(button(hud.root, "苹果 · ¥").disabled); label(hud.root, "船舱已满，先腾出一格")
        end)
    end)
    check("treasure ownership remains separate from cargo and mode follows real state", function()
        fixture({ "bait" }, function(loop, hud)
            assert(loop:Depart()); hud.Refresh(); label(hud.root, "模式：航行")
            assert(loop:SetInventoryOpen(true)); hud.Refresh(); label(hud.root, "模式：背包整理")
            require("Gameplay.Circle1B2Progress").GrantLens(loop.player); hud.Refresh()
            label(hud.root, "望远镜透镜 ×1 · 永久保留，不占船舱格")
            assert(#loop.player.inventory:GetItems() == 1)
            assert(loop:BeginThrowItem(1)); hud.Refresh(); label(hud.root, "模式：投放选点 · 鱼饵")
            assert(loop:CancelThrowSelection()); assert(loop:SetInventoryOpen(false))
        end)
    end)
    check("night HUD explains grace, precise penalty and exhaustion", function()
        fixture({}, function(loop, hud)
            assert(loop:Depart()); loop.clock:Seek("night", 29); hud.Refresh()
            assert(label(hud.root, "还剩 1 秒安全返港").visible)
            loop.clock:Seek("night", 30.5); hud.Refresh()
            assert(label(hud.root, "次日体力 99.5/100").visible)
            loop.clock:Seek("night", 60); hud.Refresh()
            assert(not label(hud.root, "晚归处罚中").visible)
        end)
    end)
    return { results = results, guiVerified = false }
end

return Tests
