-- 玩家路径与引擎过渡算法的无窗口验证，不证明实际像素/触摸效果。
local Loop = require("Gameplay.Loop")
local Config = require("config.gameplay")
local ArtVariants = require("Ocean.ArtVariants")
local Transition = require("urhox-libs/UI/Core/Transition")
local Tests = {}

local function uiHost()
    local Widget = {}
    Widget.__index = Widget
    function Widget:AddChild(child) self.children[#self.children + 1] = child; child.parent = self end
    function Widget:InsertChild(child, index)
        if child.parent then child.parent:RemoveChild(child) end
        index = math.max(1, math.min(index, #self.children + 1))
        table.insert(self.children, index, child)
        child.parent = self
        return self
    end
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
    for _, kind in ipairs({ "Panel", "SafeAreaView", "Label", "Button", "Spacer", "ScrollView", "TextField", "Sprite" }) do
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
local function isVisible(widget)
    while widget do
        if widget.visible ~= true then return false end
        widget = widget.parent
    end
    return true
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
local function exactButton(root, text)
    return find(root, function(w) return w.kind == "Button" and w.props.text == text end)
end
local function hasVisibleLabel(root, text)
    local found = false
    walk(root, function(w)
        if w.kind == "Label" and type(w.props.text) == "string"
            and w.props.text:find(text, 1, true) and isVisible(w) then found = true end
    end)
    return found
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
    check("port-shop card and entry are hidden at sea while remaining available in port", function()
        fixture({}, function(loop, hud)
            local buy = button(hud.root, "苹果 · ¥")
            assert(isVisible(buy), "the port shop card must be available in port")
            button(hud.root, "收起信息").props.onClick()
            hud.Refresh()
            local entry = exactButton(hud.root, "港口商店")
            assert(entry and isVisible(entry), "the collapsed shop entry must be visible in port")
            entry.props.onClick(entry)
            hud.Refresh()
            assert(isVisible(buy), "the port shop card must be available in port")

            assert(loop:Depart())
            hud.Refresh()
            assert(not isVisible(entry), "the port-shop entry must disappear immediately after departure")
            assert(not isVisible(buy), "the port shop card must not remain at sea")
        end)
    end)
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
            assert(not hasVisibleLabel(hud.root, "已给予老人苹果"),
                "apple progress stays in gameplay state and is not rendered on the elder card")
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
            -- V2.7：老人离世后的统一拒绝语。
            label(hud.root, "老人已经不在了，无法再把东西交给他。")
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
            assert(loop:SetInventoryOpen(true)); hud.Refresh(); label(hud.root, "模式：船舱整理")
            require("Gameplay.Circle1B2Progress").GrantLens(loop.player); hud.Refresh()
            label(hud.root, "探海镜 ×1 · 永久保留，不占船舱格")
            assert(#loop.player.inventory:GetItems() == 1)
            assert(loop:BeginThrowItem(1)); hud.Refresh(); label(hud.root, "模式：投放选点 · 鱼饵")
            assert(loop:CancelThrowSelection()); assert(loop:SetInventoryOpen(false))
        end)
    end)
    check("night HUD explains grace, precise penalty and exhaustion", function()
        fixture({}, function(loop, hud)
            assert(loop:Depart()); loop.clock:Seek("night", 14); hud.Refresh()
            assert(label(hud.root, "还剩 1 秒安全返港").visible)
            loop.clock:Seek("night", 15); hud.Refresh()
            assert(label(hud.root, "还剩 0 秒安全返港").visible)
            loop.clock:Seek("night", 15.5); hud.Refresh()
            assert(label(hud.root, "次日体力 99.0/100").visible)
            loop.clock:Seek("night", Config.clock.nightSec); hud.Refresh()
            assert(not label(hud.root, "晚归处罚中").visible)
        end)
    end)
    check("T01/T02 formal stamina stays visible in port and at sea with StoryArt off or on", function()
        local original = ArtVariants.IsEnabled
        local ok, err = xpcall(function()
            ArtVariants.IsEnabled = function() return false end
            fixture({}, function(loop, hud)
                local stamina = label(hud.root, "体力 100/100")
                assert(isVisible(stamina), "formal stamina must be visible in port")
                assert(loop:Depart())
                hud.Refresh()
                assert(isVisible(stamina), "formal stamina must remain visible at sea")
                ArtVariants.IsEnabled = function() return true end
                hud.Refresh()
                assert(isVisible(stamina), "StoryArt must not control formal stamina visibility")
            end)
        end, debug.traceback)
        ArtVariants.IsEnabled = original
        if not ok then error(err, 0) end
    end)
    check("T03 fishing and barrel buttons show 40 stamina before an action starts", function()
        fixture({}, function(loop, hud)
            assert(loop:Depart())
            loop.runtime = {
                GetFixedBarrel = function() return { position = { x = 0, y = 0 } } end,
                GetShipPosition = function() return { x = 0, y = 0 } end,
            }
            hud.Refresh()
            local stamina = loop.player.stamina
            local fishing = button(hud.root, "捕鱼 · 40体力")
            local barrel = button(hud.root, "检查木桶 · 40体力")
            assert(isVisible(fishing) and isVisible(barrel))
            assert(loop.player.stamina == stamina, "showing action costs must not charge stamina")
        end)
    end)
    check("T11/T12/T13 failed auto-return warning is shown once and outranks saved status", function()
        fixture({}, function(loop, hud)
            assert(loop:Depart())
            local autoState = { phase = "active" }
            loop.runtime = { GetAutoReturnState = function() return autoState end }
            loop.saveStatus = "saved"
            hud.Refresh()
            autoState.phase, autoState.failureReason = "failed", "stuck"
            hud.Refresh()
            local warning = "自动返航受阻，请手动驶离障碍后重试。"
            assert(hasVisibleLabel(hud.root, warning))
            assert(loop.saveStatus == "saved", "failure notice must not mutate saveStatus")
            for _ = 1, 3 do hud.Refresh() end
            local count = 0
            walk(hud.root, function(widget)
                if widget.kind == "Label" and isVisible(widget)
                    and type(widget.props.text) == "string" and widget.props.text:find(warning, 1, true) then
                    count = count + 1
                end
            end)
            assert(count == 1, "refreshes must not create duplicate failure notices")
            autoState.phase = "active"
            hud.Refresh()
            assert(not hasVisibleLabel(hud.root, warning), "a successful restart clears the old warning")
            assert(loop.saveStatus == "saved")
        end)
    end)
    check("T14 successful, cancelled, and idle auto-return states do not report failure", function()
        fixture({}, function(loop, hud)
            assert(loop:Depart())
            local autoState = { phase = "active" }
            loop.runtime = { GetAutoReturnState = function() return autoState end }
            for _, phase in ipairs({ "active", "cancelled", "arrival_ready", "idle" }) do
                autoState.phase, autoState.failureReason = phase, nil
                hud.Refresh()
                assert(not hasVisibleLabel(hud.root, "自动返航受阻"),
                    "phase " .. phase .. " must not show a failure warning")
            end
        end)
    end)
    check("T09 action feedback uses the existing central result bubble once", function()
        fixture({}, function(loop, hud)
            local toastText = "获得记忆：岛屿记忆一\n消耗40体力，剩余60体力"
            assert(loop:QueueActionToast(toastText, 3))
            hud.Refresh()
            assert(hasVisibleLabel(hud.root, "获得记忆：岛屿记忆一"))
            assert(hasVisibleLabel(hud.root, "消耗40体力，剩余60体力"))
            local bubble = find(hud.root, function(widget)
                return widget.props and widget.props.id == "catchResultBubble"
            end)
            assert(isVisible(bubble), "feedback should reuse the central result bubble")
            assert(loop:GetActionToast() == nil, "HUD consumes one result toast")
            hud.Refresh()
            assert(hasVisibleLabel(hud.root, "获得记忆：岛屿记忆一"))
        end)
    end)
    check("T07 opening shows seven-day rule as a system note, separate from elder dialogue", function()
        fixture({}, function(_loop, hud)
            assert(hasVisibleLabel(hud.root,
                "系统提示：本轮旅程共7天。每天可以出海、捕鱼、探索或返港准备；第7天结束后会进入结局，之后可以开始新周目。"))
            assert(not hasVisibleLabel(hud.root, "被救起的老人把一只旧背包递给你"),
                "elder speech stays in the elder dialogue, not duplicated in the opening note")
        end)
    end)
    return { results = results, guiVerified = false }
end

return Tests
