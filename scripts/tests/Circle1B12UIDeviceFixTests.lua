-- A2（UI 重设计 v2.0 · 2026-10-20 真机第二轮截图闭环）：四处真机缺陷的回归契约。
--
-- ① 「航海残页按钮无效无法点击」
--    HUD 每帧被 Bootstrap.Update 调用；独立道具栏行原先每帧 destroyChildren 重建，
--    真机上按下与抬起跨帧时按钮实例已被换掉，onClick 永不触发。
--    → 同一内容签名跨帧必须保留同一批按钮实例（恒等式断言）。
-- ② 「左侧屏挤占」
--    记忆与探海镜卡原先只按"持有即显"，与背包/商店卡在 cardHost 纵向列堆叠，
--    高度越过坞让位线压住底部按钮坞。
--    → 该卡纳入 §7.13 互斥链末位（老人 > 背包 > 宝物）；老人/背包在屏时整体让位，
--      在港则自动折成 slim 条（保入口可见、不占纵向预算），玩家可手动展开。
-- ③ 「记事本内容缺失」
--    图鉴页只有占位文案、且无空态，真机上等同"内容缺失"。
--    → 两页都必须产生可见条目；图鉴页还要列出玩家本周目真实持有的残页/记载。
-- ④ 「结局重新开始按钮无效」
--    showNewRunConfirm 漏排 showEnding → 确认页与结局页同帧双显、对半分卡高，
--    确认按钮被挤出 460 卡外。
--    → 确认页打开时必须独占，并把结局页压为不可见。
--
-- 与 Circle1B12UIModalFocusTests 同源：用 in-memory widget double 构造真实 HUD，
-- 沿父链判可见性，不用 loop 状态单点代替 HUD 表现。
local Flow = require("tests.Circle1BFishingFlowTests")

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

local TREASURE_ACTIONS = {
    {
        treasureId = "sea_note_01",
        name = "航海残页（一）",
        useLabel = "重读",
        canUse = true,
        canGive = true,
        canDiscard = false,
        discardDisabledReason = "航海残页不可丢弃。",
    },
}

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
    function Widget:InsertChild(child, index)
        table.insert(self.children, index or 1, child)
        child.parent = self
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
    for _, kind in ipairs({ "Panel", "SafeAreaView", "Label", "Button", "Spacer", "ScrollView", "TextField", "Sprite" }) do
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

local function isVisible(widget)
    while widget do
        if widget.visible ~= true then return false end
        widget = widget.parent
    end
    return true
end

local function findById(root, id)
    if root.props and root.props.id == id then return root end
    for _, child in ipairs(root.children or {}) do
        local found = findById(child, id)
        if found then return found end
    end
    return nil
end

local function findButton(root, text)
    local found
    local function descend(widget)
        if widget.kind == "Button" and widget.props.text == text then found = widget end
        for _, child in ipairs(widget.children or {}) do descend(child) end
    end
    descend(root)
    return found
end

local function findLabel(root, text)
    local found
    local function descend(widget)
        if not found and widget.kind == "Label" and type(widget.props.text) == "string"
            and widget.props.text:find(text, 1, true) then found = widget end
        for _, child in ipairs(widget.children or {}) do descend(child) end
    end
    descend(root)
    return found
end

local function clickButton(widget, label)
    truthy(widget, (label or "button") .. " must exist")
    truthy(type(widget.props.onClick) == "function", (label or "button") .. " must expose onClick")
    widget.props.onClick()
end

---在指定子树里找按钮，避免与背包/老人卡同名按钮（"收起"）混淆。
local function findButtonIn(widget, text)
    local found
    local function descend(node)
        if node.kind == "Button" and node.props.text == text then found = node end
        for _, child in ipairs(node.children or {}) do descend(child) end
    end
    descend(widget)
    return found
end

local function childrenOf(widget)
    return widget.children or {}
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

    -- ① ────────────────────────────────────────────────────────────────────
    test("treasure rows keep their button instances across refreshes so taps can land", function()
        local f = Flow.Fixture()
        f.loop.GetV28TreasureActions = function() return TREASURE_ACTIONS end
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local rows = findById(hud.root, "gameplayCardHost") and true
            truthy(rows, "the HUD builds its card host")

            local use1 = findButton(hud.root, "重读")
            truthy(use1, "the note row offers 重读")
            local give1 = findButton(hud.root, "给老人")
            truthy(give1, "the note row offers 给老人")

            -- 真机根因：Bootstrap.Update 每帧 hud.Refresh()。若每帧重建，这里
            -- 拿到的就不是同一个按钮实例，手指按下→抬起的 OnPointerUp 无处投递。
            for _ = 1, 5 do hud.Refresh() end
            eq(findButton(hud.root, "重读"), use1,
                "the 重读 button must be the same instance after repeated refreshes")
            eq(findButton(hud.root, "给老人"), give1,
                "the 给老人 button must be the same instance after repeated refreshes")

            -- 内容确实变化时仍要重建（条目消失 → 按钮随之消失）。
            f.loop.GetV28TreasureActions = function() return {} end
            hud.Refresh()
            falsy(findButton(hud.root, "重读"), "removed treasures drop their action row")
        end)
    end)

    test("the treasure card can be collapsed and expanded from the card itself", function()
        local f = Flow.Fixture()
        f.loop.GetV28TreasureActions = function() return TREASURE_ACTIONS end
        f.loop.inPort = false -- 在港会自动折成 slim 条，此用例要在展开态上手
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local rowsCard = findById(hud.root, "v28TreasureRows").parent
            truthy(rowsCard, "the treasure card wraps its rows")
            local collapse = findButtonIn(rowsCard, "收起")
            truthy(collapse, "the treasure card offers its own collapse control")

            local rows = findById(hud.root, "v28TreasureRows")
            truthy(rows, "the treasure card owns its rows container")
            truthy(#childrenOf(rows) > 0, "the rows are populated before collapsing")

            clickButton(collapse, "收起")
            -- 用 rows.visible 而非父链可见性：本卡在港口会被更高优先卡让位，
            -- 这里断言的是"折叠会不会收掉行内容"本身。
            falsy(rows.visible, "collapsing hides the row content (no stays-on-screen dead card)")

            clickButton(findButtonIn(rowsCard, "展开"), "展开")
            truthy(rows.visible, "expanding restores the row content")
        end)
    end)

    -- ② ────────────────────────────────────────────────────────────────────
    test("the treasure card yields to the inventory, elder and port cards so the dock is never covered", function()
        local f = Flow.Fixture()
        f.loop.GetV28TreasureActions = function() return TREASURE_ACTIONS end
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local treasureLabel = findLabel(hud.root, "记忆与探海镜")
            truthy(treasureLabel, "the treasure card exists in the HUD tree")
            local treasureCard = treasureLabel.parent

            -- 港口默认：本卡仍可见（V2.8 引入它就是给独立道具栏一个可见入口），
            -- 但自动折成 slim 条——行内容不展开，不再与商店卡纵向堆叠压到坞上。
            truthy(isVisible(treasureCard), "the treasure card keeps a visible entry in port")
            falsy(findById(hud.root, "v28TreasureRows").visible,
                "the treasure rows stay collapsed in port so the column does not stack")
            truthy(findButtonIn(treasureCard, "展开"), "the collapsed card offers an expand control")

            -- 背包打开：背包卡在屏（正是截图"左侧屏挤占"的组合）→ 本卡整体让位
            f.loop.inventoryOpen = true
            hud.Refresh()
            falsy(isVisible(treasureCard),
                "the inventory card outranks the treasure card (screenshot: left column squeeze)")

            -- 老人对话打开同理
            f.loop.inventoryOpen = false
            f.loop.elderOpen = true
            hud.Refresh()
            falsy(isVisible(treasureCard), "the elder card outranks the treasure card")
        end)
    end)

    -- ③ ────────────────────────────────────────────────────────────────────
    test("the notebook pages always render visible rows instead of an empty body", function()
        local f = Flow.Fixture()
        f.loop.GetV28TreasureActions = function() return TREASURE_ACTIONS end
        f.loop.clock:Pause("manual")
        f.loop.player.day = 2 -- 第 1 天开场教学模态优先级高于图鉴页，会让剧情页挤掉它
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            clickButton(findButton(hud.root, "记事本"), "记事本")
            hud.Refresh()

            local compList = findById(hud.root, "compendiumList")
            truthy(compList, "the notebook owns a compendium list container")
            truthy(#childrenOf(compList) > 0,
                "the achievements page must not render an empty body")

            clickButton(findButton(hud.root, "图鉴"), "图鉴")
            hud.Refresh()
            truthy(#childrenOf(compList) > 0,
                "the marine page must not render an empty body")
            truthy(findLabel(hud.root, "航海残页（一）（随身）"),
                "the marine page lists the notes the player actually carries")
        end)
    end)

    -- ④ ────────────────────────────────────────────────────────────────────
    test("the ending new-run confirmation takes the modal over so the buttons stay reachable", function()
        local f = Flow.Fixture()
        f.loop.endingPending = true
        f.loop.endingKind = "normal"
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local endingScroll = findById(hud.root, "endingTextScroll")
            truthy(endingScroll, "the ending modal renders its scroll body")
            truthy(isVisible(endingScroll), "the ending body is visible before confirming")

            clickButton(findButton(hud.root, "重新开始"), "重新开始")

            -- 旧缺陷：确认页与结局页各占一半卡高，确认按钮被挤出可视区。
            truthy(findLabel(hud.root, "重新开始会开启新的7天"),
                "the confirmation prompt takes the modal over")
            local yes = findButton(hud.root, "确定重新开始")
            truthy(yes, "the confirm button exists")
            truthy(isVisible(yes), "the confirm button stays reachable inside the modal card")
            truthy(isVisible(findButton(hud.root, "取消")), "the cancel button stays reachable")

            local endingText = endingScroll.children and endingScroll.children[1]
            truthy(endingText, "the ending text widget exists")
            falsy(isVisible(endingText),
                "the ending page must not share the card height with the confirmation")

            clickButton(findButton(hud.root, "取消"), "取消")
            truthy(isVisible(endingScroll), "cancelling returns to the ending page")
        end)
    end)

    return { results = results, metrics = {} }
end

return Tests
