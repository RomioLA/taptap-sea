-- Circle 1B2 HUD wiring tests with an in-memory widget tree; no GUI is created.
local Flow = require("tests.Circle1BFishingFlowTests")
local Progress = require("Gameplay.Circle1B2Progress")

local Tests = {}
local PAPER_TEXT = "海岸边那只木桶，下面一定有什么东西，我想多打捞几次就能打捞上来吧。"
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

    test("scope toggle stays disabled without a lens and toggles through A without pausing", function()
        local f = atSea()
        bindScopeInterface(f.runtime)
        local _, _, scopeSynced = f.bridge:Sync()
        assert(scopeSynced, "the fake A scope interface should clear the initial missing-interface status")
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            local noLensButton = button(hud.root, "透镜未获得", true)
            assert(noLensButton.disabled)
            eq(f.loop:IsScopeEnabled(), false)

            assert(Progress.GrantLens(f.loop.player))
            hud.Refresh()
            local openButton = button(hud.root, "开启望远镜", true)
            assert(not openButton.disabled)
            eq(f.loop.clock:IsPaused(), false)
            click(openButton)
            eq(f.runtime.scopeEnabled, true)
            eq(f.runtime.scopeSetCalls, 1)
            eq(f.loop:IsScopeEnabled(), true)
            eq(f.loop.clock:IsPaused(), false)

            local closeButton = button(hud.root, "关闭望远镜", true)
            click(closeButton)
            eq(f.runtime.scopeEnabled, false)
            eq(f.runtime.scopeSetCalls, 2)
            eq(f.loop:IsScopeEnabled(), false)
            eq(f.loop.clock:IsPaused(), false)
            assert(f.runtime.scopeGetCalls >= 4)
        end)
    end)

    test("bait use is disabled with a Chinese reason and bait and fish display without consumption", function()
        local f = Flow.Fixture({ items = { "bait", "sardine" } })
        withHUD(function(HUD)
            local hud = HUD.Create(f.loop)
            click(button(hud.root, "背包", true))
            local operations = findButtons(hud.root, "操作", true)
            eq(#operations, 2)
            click(operations[1]) -- select the bait

            local useButton = button(hud.root, "使用", true)
            assert(useButton.disabled)
            assert(exactLabel(hud.root, "该物品没有可用效果，无法使用。", true))

            click(button(hud.root, "背包", true))
            click(button(hud.root, "拜访老人", true))
            local displays = findButtons(hud.root, "展示", true)
            eq(#displays, 2)
            local before = f.loop.player.inventory:GetItems()
            click(displays[1])
            items(f.loop.player.inventory:GetItems(), before, "displayed bait remains in cargo")

            displays = findButtons(hud.root, "展示", true)
            eq(#displays, 2)
            click(displays[2])
            items(f.loop.player.inventory:GetItems(), before, "displayed fish remains in cargo")
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
            assert(exactLabel(hud.root, "木桶检查进行中，剩余 4.0 秒；打开背包或对话会暂停计时，可以取消。", true))
            eq(#findButtons(hud.root, "完成检查", false), 0)
            eq(#findButtons(hud.root, "立即完成", false), 0)
        end)
        assert(f.loop:CancelBarrelInspection())
        eq(f.loop.player.stamina, stamina)
        assert(type(token) == "table")
    end)

    test("paper is marked only after the HUD visibly renders exact text and close resumes the clock", function()
        local f = Flow.Fixture()
        settleToDaySeven(f.loop)
        assert(f.loop:Depart())
        eq(f.loop.player.story.circle1B2.paperShown, false)
        eq(f.loop.clock:IsPaused(), false)

        assert(f.loop:OpenDay7PaperBeforeEnding())
        eq(f.loop.player.story.circle1B2.paperShown, false, "opening the entry is not an acknowledgement")
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
            eq(f.loop.clock:IsPaused(), false)
            assert(f.loop.player.story.circle1B2.paperShown)
            hud.Refresh()
            eq(notifyCalls, 1)
        end)
    end)

    return { results = results }
end

return Tests
