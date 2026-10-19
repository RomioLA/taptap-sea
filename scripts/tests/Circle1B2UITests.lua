-- Circle 1B2 HUD wiring tests with an in-memory widget tree; no GUI is created.
local Flow = require("tests.Circle1BFishingFlowTests")
local Progress = require("Gameplay.Circle1B2Progress")

local Tests = {}
local PAPER_TEXT = "海边那只木桶还有秘密，快去再探探。"
local FISHING_HINT = "点击附近海面下网"
local activeUI = nil

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function items(actual, expected, label)
    Flow.AssertItems(actual, expected, label)
end

local function makeUI()
    local Widget = {}
    Widget.__index = Widget

    function Widget:AddChild(child)
        self.children[#self.children + 1] = child
        child.parent = self
    end

    function Widget:RemoveChild(child)
        for index, value in ipairs(self.children) do
            if value == child then
                table.remove(self.children, index)
                break
            end
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
                kind = kind,
                props = props,
                children = {},
                visible = props.visible ~= false,
                disabled = false,
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
    assert(package.loaded["urhox-libs/UI"] == previousUI, "UI module cache must be restored")
    assert(package.loaded["Gameplay.HUD"] == previousHUD, "HUD module cache must be restored")
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

local function findButtons(root, text, visibleOnly)
    local found = {}
    walk(root, function(widget)
        if widget.kind == "Button" and widget.props.text == text then
            found[#found + 1] = widget
        end
    end, visibleOnly)
    return found
end

local function button(root, text, visibleOnly)
    local found = assert(findButtons(root, text, visibleOnly)[1], "missing button: " .. text)
    assert(isVisible(found), "button is not visible: " .. text)
    return found
end

local function click(widget)
    assert(widget.kind == "Button" and type(widget.props.onClick) == "function", "button callback missing")
    assert(isVisible(widget), "cannot click a hidden button")
    assert(not widget.disabled, "button is disabled: " .. tostring(widget.props.text))
    widget.props.onClick()
end

local function exactLabel(root, text, visibleOnly)
    local found
    walk(root, function(widget)
        if not found and widget.kind == "Label" and widget.props.text == text then found = widget end
    end, visibleOnly)
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

local function dialogueBubbleCount(root)
    local scroll = assert(findById(root, "elderDialogueScroll"), "elder dialogue scroll missing")
    local rows = assert(scroll.children[1], "elder dialogue rows missing")
    return #rows.children
end

local function atSea(settings)
    local fixture = Flow.Fixture(settings)
    assert(fixture.loop:Depart())
    return fixture
end

local function bindBarrelInterface(runtime)
    runtime.barrelId = "circle1B2-barrel-world"
    runtime.barrelGeneration = 1
    function runtime:GetFixedBarrel()
        return {
            id = self.barrelId,
            contentId = "driftwood_barrel",
            generation = self.barrelGeneration,
            position = { x = 1, y = 0 },
        }
    end
    function runtime:CanInteractWithBarrel(id, generation)
        return id == self.barrelId and generation == self.barrelGeneration
    end
end

local function bindScopeInterface(runtime)
    runtime.scopeEnabled = false
    runtime.scopeSetCalls = 0
    runtime.scopeGetCalls = 0
    function runtime:SetScopeEnabled(enabled)
        self.scopeSetCalls = self.scopeSetCalls + 1
        self.scopeEnabled = enabled == true
        return true
    end
    function runtime:IsScopeEnabled()
        self.scopeGetCalls = self.scopeGetCalls + 1
        return self.scopeEnabled
    end
end

local function settleToDaySeven(loop)
    for _ = 1, 6 do
        local pendingStory = loop:GetStoryDialog()
        if pendingStory then
            assert(loop:NotifyStoryShown(pendingStory.token))
            assert(loop:CloseStoryDialog())
        end
        assert(loop:EndToday())
        assert(loop:ConfirmSettlement())
    end
    eq(loop.player.day, 7)
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("first fishing selection shows a non-modal hint and still accepts the sea pointer", function()
        local f = atSea()
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            click(button(hud.root, "捕鱼 · 40体力", true))
            eq(f.loop:GetFishingState().state, "selecting", "the button enters selection first")
            assert(exactLabel(hud.root, FISHING_HINT, true), "the first selection must show the exact hint")
            eq(f.loop:GetStoryDialog(), nil, "the hint must not open a modal story dialog")
            eq(f.loop.clock:IsPaused(), false, "the hint must not pause the voyage")

            assert(f.bridge:OnSeaPointer({ x = 0, y = 0 }), "the first legal sea tap must be accepted")
            hud.Refresh()
            eq(f.loop:GetFishingState().state, "casting", "the hint adds no confirmation step")
        end)
    end)

    test("scope toggle stays disabled without a lens and toggles through A without pausing", function()
        local f = atSea()
        bindScopeInterface(f.runtime)
        local _, _, scopeSynced = f.bridge:Sync()
        assert(scopeSynced, "the fake A scope interface should clear the initial missing-interface status")
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            -- UI精简 v1.0 §六：无探海镜时探海镜按钮直接隐藏，不显示"探海镜未获得"
            local noLensButtons = findButtons(hud.root, "探海镜未获得", true)
            assert(#noLensButtons == 0, "lens button must be hidden when no lens is owned")
            eq(f.loop:IsScopeEnabled(), false)

            assert(Progress.GrantLens(f.loop.player))
            hud.Refresh()
            local openButton = button(hud.root, "开启探海镜", true)
            assert(not openButton.disabled)
            eq(f.loop.clock:IsPaused(), false)
            click(openButton)
            eq(f.runtime.scopeEnabled, true)
            eq(f.runtime.scopeSetCalls, 1)
            eq(f.loop:IsScopeEnabled(), true)
            eq(f.loop.clock:IsPaused(), false)

            local closeButton = button(hud.root, "关闭探海镜", true)
            click(closeButton)
            eq(f.runtime.scopeEnabled, false)
            eq(f.runtime.scopeSetCalls, 2)
            eq(f.loop:IsScopeEnabled(), false)
            eq(f.loop.clock:IsPaused(), false)
            assert(f.runtime.scopeGetCalls >= 4)
        end)
    end)

    test("V2.7 non-edible bait keeps fixed menu actions and shows the Loop rejection", function()
        local f = Flow.Fixture({ items = { "bait", "sardine" } })
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            click(button(hud.root, "船舱", true))
            local operations = findButtons(hud.root, "操作", true)
            eq(#operations, 2)
            click(operations[1]) -- select the bait

            local useButtons = findButtons(hud.root, "使用", true)
            local giveButtons = findButtons(hud.root, "给老人", true)
            local dropButtons = findButtons(hud.root, "丢弃", true)
            eq(#useButtons, 1, "use stays available for a non-edible item")
            eq(#giveButtons, 1, "the give action keeps its fixed label")
            eq(#dropButtons, 1, "drop stays available for a non-edible item")
            assert(not useButtons[1].disabled, "item type does not disable use")
            assert(not giveButtons[1].disabled, "item type does not disable give")
            assert(not dropButtons[1].disabled, "item type does not disable drop")

            click(useButtons[1])
            assert(f.loop.lastMessage:find("没有可用的使用效果", 1, true),
                "Loop returns a natural-language reason for an unavailable use")
            assert(exactLabel(hud.root, f.loop.lastMessage, true),
                "the HUD log displays Loop's natural-language rejection")
            eq(f.loop.player.inventory:GetItems()[1], "bait", "a rejected use keeps the item")

            click(button(hud.root, "收起船舱", true))
            click(button(hud.root, "拜访老人", true))
            -- v2.3 二级化：先点「展示 ▸」分类键展开物品列表，再找物品行的「展示」
            click(button(hud.root, "展示 ▸", true))
            local displays = findButtons(hud.root, "展示", true)
            eq(#displays, 2)
            local before = f.loop.player.inventory:GetItems()
            click(displays[1])
            items(f.loop.player.inventory:GetItems(), before, "displayed bait remains in cargo")

            -- v2.3：二级操作后不自动返回一级，可连续展示
            displays = findButtons(hud.root, "展示", true)
            eq(#displays, 2)
            click(displays[2])
            items(f.loop.player.inventory:GetItems(), before, "displayed fish remains in cargo")
        end)
    end)

    test("V2.7 busy transactions and active fishing still freeze item actions", function()
        local f = Flow.Fixture({ items = { "bait" } })
        f.loop.inventoryOpen = true
        f.loop.busy = true
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local useButton = assert(findButtons(hud.root, "使用", false)[1])
            local giveButton = assert(findButtons(hud.root, "给老人", false)[1])
            local dropButton = assert(findButtons(hud.root, "丢弃", false)[1])
            assert(useButton.disabled and giveButton.disabled and dropButton.disabled,
                "busy transactions freeze all three item actions")

            f.loop.busy = false
            f.loop.GetFishingState = function() return { state = "casting" } end
            hud.Refresh()
            assert(useButton.disabled and giveButton.disabled and dropButton.disabled,
                "active fishing continues to freeze all three item actions")
        end)
    end)

    test("elder exchanges render both lines only on success and failed gifts add no false bubble", function()
        local f = Flow.Fixture({ items = { "apple", "bait" } })
        local observedExchange
        local originalGive = f.loop.GiveToElder
        f.loop.GiveToElder = function(loop, index)
            local accepted, message, exchange = originalGive(loop, index)
            observedExchange = exchange
            return accepted, message, exchange
        end

        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            click(button(hud.root, "拜访老人", true))
            hud.Refresh()
            local openingBubbles = dialogueBubbleCount(hud.root)

            click(button(hud.root, "给予 ▸", true))
            click(button(hud.root, "给予", true))
            hud.Refresh()
            assert(observedExchange and observedExchange.action == "give", "a successful gift must return a give exchange")
            assert(type(observedExchange.playerLine) == "string" and observedExchange.playerLine ~= "")
            assert(type(observedExchange.elderLine) == "string" and observedExchange.elderLine ~= "")
            eq(dialogueBubbleCount(hud.root), openingBubbles + 2, "a successful gift appends one dialogue pair")
            assert(exactLabel(hud.root, observedExchange.playerLine, true), "player action line must be visible")
            assert(exactLabel(hud.root, observedExchange.elderLine, true), "elder response line must be visible")
            eq(f.loop:GetElderStatus().applesGiven, 1)
            eq(#f.loop.player.inventory:GetItems(), 1, "food is consumed by a successful give")

            click(button(hud.root, "← 返回", true))
            click(button(hud.root, "展示 ▸", true))
            local beforeShow = f.loop.player.inventory:GetItems()
            click(button(hud.root, "展示", true))
            hud.Refresh()
            assert(observedExchange and observedExchange.action == "show", "a successful display must return a show exchange")
            eq(observedExchange.itemId, "bait")
            items(f.loop.player.inventory:GetItems(), beforeShow, "displaying bait must not consume it")
            eq(dialogueBubbleCount(hud.root), openingBubbles + 4, "a successful display appends another pair")

            assert(f.loop.player.inventory:Add("apple"))
            f.loop.options.elderReceiver = function() return false, "injected_elder_rejection" end
            hud.Refresh()
            click(button(hud.root, "← 返回", true))
            click(button(hud.root, "给予 ▸", true))
            observedExchange = nil
            click(button(hud.root, "给予", true))
            hud.Refresh()
            eq(observedExchange, nil, "a rejected give must not return a successful exchange")
            eq(dialogueBubbleCount(hud.root), openingBubbles + 4, "a rejected give must not add success bubbles")
            eq(f.loop:GetElderStatus().applesGiven, 1, "a rejected apple must not increment progress")
            eq(#f.loop.player.inventory:GetItems(), 2, "a rejected apple must be restored")

            f.loop.options.elderReceiver = nil
            click(button(hud.root, "← 返回", true))
            click(button(hud.root, "展示 ▸", true))
            local beforeFailedShow = f.loop.player.inventory:GetItems()
            f.loop.GiveToElder = function() return false, "injected_show_rejection" end
            click(button(hud.root, "展示", true))
            hud.Refresh()
            eq(dialogueBubbleCount(hud.root), openingBubbles + 4,
                "a failed show must not add a false-success exchange")
            items(f.loop.player.inventory:GetItems(), beforeFailedShow,
                "a rejected show must leave the display item in cargo")

            f.loop.GiveToElder = function() return nil, "no_explicit_business_success" end
            click(button(hud.root, "展示", true))
            hud.Refresh()
            eq(dialogueBubbleCount(hud.root), openingBubbles + 4,
                "a nil result is not an explicit success receipt")

            f.loop.GiveToElder = function() error("injected_show_exception") end
            click(button(hud.root, "展示", true))
            hud.Refresh()
            eq(dialogueBubbleCount(hud.root), openingBubbles + 4,
                "a caught exception is not an explicit success receipt")
        end)
    end)

    test("barrel uses its built-in timer and exposes cancel without an instant-finish control", function()
        local f = atSea()
        bindBarrelInterface(f.runtime)
        local stamina = f.loop.player.stamina
        local paused = f.loop.clock:IsPaused()
        local token = assert(f.loop:BeginBarrelInspection())
        eq(f.loop.player.stamina, stamina)
        eq(f.loop:GetBarrelState().stage, 0)
        eq(f.loop:GetBarrelState().active, true)
        eq(f.loop:GetBarrelState().timingAvailable, true)
        eq(f.loop:GetBarrelState().remaining, 4)
        eq(f.loop.clock:IsPaused(), paused)

        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local cancelButton = assert(findButtons(hud.root, "取消检查", false)[1])
            assert(isVisible(cancelButton), "active barrel action should offer cancellation")
            assert(exactLabel(hud.root, "木桶检查进行中，剩余 4.0 秒；打开船舱或对话会暂停计时，可以取消。", true))
            eq(#findButtons(hud.root, "完成检查", false), 0)
            eq(#findButtons(hud.root, "立即完成", false), 0)
        end)
        assert(f.loop:CancelBarrelInspection())
        eq(f.loop.player.stamina, stamina)
        assert(type(token) == "table")
    end)

    test("W-05 changed ending shows the approved title and current copy", function()
        local f = Flow.Fixture()
        f.loop.endingPending = true
        f.loop.endingKind = "changed"

        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local visibleLabels = {}
            walk(hud.root, function(widget)
                if widget.kind == "Label" and type(widget.props.text) == "string" then
                    visibleLabels[#visibleLabels + 1] = widget.props.text
                end
            end, true)
            local visibleText = table.concat(visibleLabels, "\n")

            assert(visibleText:find("改变结局｜有人同行", 1, true),
                "the approved W-05 title must be visible")
            assert(visibleText:find(
                "海没有因为谁的愿望改变规律。你学着观察，也学着在该行动的时候行动。前三天留给老人的那几只苹果，便是其中一个选择。",
                1, true), "the approved changed-ending paragraph must be visible")
            assert(not visibleText:find("安稳", 1, true),
                "the superseded calm-ending draft must not be visible")
        end)
    end)

    test("paper is marked only after the HUD visibly renders exact text and close resumes the clock", function()
        local f = Flow.Fixture()
        settleToDaySeven(f.loop)
        local entryPaper = assert(f.loop:GetStoryDialog(), "day-seven port entry opens the paper")
        eq(entryPaper.kind, "paper")
        eq(entryPaper.text, PAPER_TEXT)
        eq(f.loop.player.story.circle1B2.paperShown, false, "opening is not an acknowledgement")
        eq(f.loop.clock.pauseReasons.story, true)
        eq(f.loop.clock:IsPaused(), true)

        local originalNotify = f.loop.NotifyStoryShown
        local notifyCalls = 0
        f.loop.NotifyStoryShown = function(loop, token)
            notifyCalls = notifyCalls + 1
            local storyText
            for _, widget in ipairs(activeUI.widgets) do
                if widget.props.id == "storyDialogText" then storyText = widget; break end
            end
            assert(storyText, "HUD must create the paper text widget before acknowledgement")
            eq(storyText.props.text, PAPER_TEXT, "paper text before acknowledgement")
            assert(isVisible(storyText), "paper text must be visible before acknowledgement")
            return originalNotify(loop, token)
        end

        withHUD(function(HUD, UI)
            activeUI = UI
            local hud = HUD.Create(f.loop)
            eq(notifyCalls, 1)
            assert(f.loop.player.story.circle1B2.paperShown)
            local rendered = exactLabel(hud.root, PAPER_TEXT, true)
            assert(rendered, "the visible HUD must show the exact paper body")

            hud.Refresh()
            hud.Refresh()
            eq(notifyCalls, 1, "repeated refreshes acknowledge this dialog only once")

            click(button(hud.root, "结束对话", true))
            eq(f.loop:GetStoryDialog(), nil)
            eq(f.loop.clock.pauseReasons.story, nil)
            eq(f.loop.clock:IsPaused(), true, "port pause remains after reading")
            assert(f.loop.player.story.circle1B2.paperShown)
            assert(f.loop:Depart())
            eq(f.loop.clock:IsPaused(), false, "reading the paper permits normal departure")
            hud.Refresh()
            eq(notifyCalls, 1)
        end)
    end)

    return { results = results }
end

return Tests
