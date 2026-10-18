-- Engine-adapter acceptance using a small UI/event harness and the real runtime.
local Tests = {}

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end
    local Runtime = require("Ocean.SeaRuntime")
    local SceneState = require("Ocean.SceneState")
    local Config = require("Ocean.Config")
    check("original HUD directional contract drives the real ship", function()
        local runtime = Runtime.New({ initializeRegions = false })
        runtime.movement:SetViewport(1920, 1080)
        local state = SceneState.New(runtime)
        state:MoveBy(1)
        assert(math.abs(runtime.movement.target.x - 80 * Config.boat.buttonStep) < 0.00001)
        for _ = 1, 20 do runtime:Update(0.05) end
        assert(runtime.ship.position.x > 0)
        state:MoveBy(-1)
        assert(math.abs(runtime.movement.target.x) < 0.00001)
    end)
    check("original HUD pause and reset synchronize and preserve ship level", function()
        local runtime = Runtime.New({ initializeRegions = false, shipLevel = 3 })
        local calls = 0
        local state = SceneState.New(runtime, function() calls = calls + 1 end)
        state:TogglePause()
        assert(runtime.paused and state.paused)
        state:MoveBy(1)
        assert(runtime.movement.target == nil)
        state:Reset()
        assert(calls == 1 and not state.paused and state.time == 0 and runtime.ship.level == 3)
        runtime:TogglePause()
        assert(state:Sync() and state.paused)
    end)

    local saved = {}
    local function replace(name, value)
        saved[name] = { value = _G[name] }
        _G[name] = value
    end
    local oldUI, oldDraw = package.loaded["urhox-libs/UI"], package.loaded["Ocean.SeaDraw"]
    local UI = { Scale = { DEFAULT = 1 }, roots = 0, initialized = 0, shutdowns = 0 }
    local function widget(props)
        local self = { props = props, children = props.children or {}, visible = props.visible ~= false }
        function self:AddChild(child) self.children[#self.children + 1] = child end
        function self:SetVisible(value) self.visible = value end
        function self:IsVisible() return self.visible end
        function self:SetText(text) self.props.text = text end
        function self:GetText() return self.props.text end
        function self:SetStyle(style) for k, v in pairs(style) do self.props[k] = v end end
        function self:SetFontColor(color) self.props.fontColor = color end
        function self:FindById(id)
            if self.props.id == id then return self end
            for _, child in ipairs(self.children) do
                local found = child:FindById(id)
                if found then return found end
            end
            return nil
        end
        return self
    end
    for _, kind in ipairs({ "Panel", "Button", "Label", "Row", "SafeAreaView" }) do UI[kind] = widget end
    UI.Init = function() UI.initialized = UI.initialized + 1 end
    UI.Shutdown = function() UI.shutdowns = UI.shutdowns + 1 end
    UI.SetRoot = function(root) UI.root = root; UI.roots = UI.roots + 1 end
    UI.GetRoot = function() return UI.root end
    UI.GetScale = function() return 1 end
    UI.FindWidgetAt = function() return UI.hit end
    package.loaded["urhox-libs/UI"] = UI
    local rendered = { calls = {} }
    package.loaded["Ocean.SeaDraw"] = { Scene = function(_, w, h, runtime, clock)
        rendered.width, rendered.height, rendered.runtime, rendered.clock = w, h, runtime, clock
        rendered.calls[#rendered.calls + 1] = { width = w, height = h, runtime = runtime, clock = clock }
    end }
    local callbacks, unsubscribes, removals, deletes = {}, 0, 0, 0
    replace("graphics", { GetWidth = function() return 1920 end, GetHeight = function() return 1080 end,
        GetDPR = function() return 2 end })
    replace("input", { GetKeyDown = function() return false end })
    replace("Node", function()
        return { CreateScriptObject = function()
            return {
                SubscribeToEvent = function(_, a, b, c) callbacks[#callbacks + 1] = { event = c and b or a, fn = c or b } end,
                UnsubscribeFromAllEvents = function() unsubscribes = unsubscribes + 1 end,
            }
        end, Remove = function() removals = removals + 1 end }
    end)
    for _, name in ipairs({ "nvgSetRenderOrder", "nvgBeginFrame", "nvgEndFrame" }) do replace(name, function() end) end
    replace("nvgCreate", function() return {} end)
    replace("nvgDelete", function() deletes = deletes + 1 end)
    for index, name in ipairs({ "KEY_A", "KEY_D", "KEY_W", "KEY_S", "KEY_LEFT", "KEY_RIGHT", "KEY_UP", "KEY_DOWN",
        "KEY_SPACE", "KEY_R", "KEY_F3", "KEY_U", "KEY_H", "KEY_P", "KEY_J", "KEY_1", "KEY_2", "KEY_C", "KEY_B",
        "MM_ABSOLUTE", "MOUSEB_LEFT" }) do replace(name, index) end
    local FusedScene = require("Ocean.FusedScene")
    local sea = FusedScene.Start({ initializeRegions = false })
    check("fused scene retains the original HUD root and appends hidden debug tools", function()
        assert(UI.initialized == 1 and UI.roots == 1 and UI.root.props.id == "oceanRoot")
        assert(UI.root:FindById("seaDebugRoot") and not UI.root:FindById("seaDebugPanel"):IsVisible())
        UI.root:FindById("seaDebugToggle").props.onClick()
        assert(UI.root:FindById("seaDebugPanel"):IsVisible())
    end)
    check("sky clicks do not sail; sea clicks target world meters; UI blocks clicks", function()
        assert(not sea:HandlePointer(960, 100))
        assert(sea:HandlePointer(1200, 648))
        assert(math.abs(sea.runtime.movement.target.x - 10) < 0.00001)
        local x = sea.runtime.movement.target.x
        UI.hit = {}
        assert(not sea:HandlePointer(1300, 648) and sea.runtime.movement.target.x == x)
        UI.hit = nil
    end)
    check("one event owner updates and renders the real simulation at mode-B DPR", function()
        assert(#callbacks == 5)
        sea:Update(0.05)
        sea:Render()
        assert(sea.runtime.time == 0.05 and rendered.runtime == sea.runtime and rendered.clock == nil)
        assert(rendered.width == 960 and rendered.height == 540 and sea.runtime.movement.viewHeight == 45)
    end)
    check("keyboard pause reset and hidden debug visibility keep the HUD synchronized", function()
        sea.tools.handleKey(KEY_SPACE)
        assert(sea.runtime.paused)
        sea.tools.handleKey(KEY_U)
        assert(sea.runtime.world.showUnderwater)
        sea.tools.handleKey(KEY_R)
        assert(not sea.runtime.paused and sea.runtime.time == 0 and sea.runtime.movement.viewWidth == 80)
    end)
    check("shutdown is idempotent and releases only this event owner and UI", function()
        sea:Stop(); sea:Stop()
        assert(unsubscribes == 1 and removals == 1 and deletes == 1 and UI.shutdowns == 1)
        assert(not sea:HandlePointer(1200, 648))
    end)
    check("render receives the live external clock without advancing it", function()
        local GameClock = require("Gameplay.GameClock")
        local firstClock, nextClock = GameClock.New(), GameClock.New()
        firstClock:Update(1.25)
        nextClock:Update(2.5)
        local firstElapsed, nextElapsed = firstClock.elapsed, nextClock.elapsed
        local updateCalls = 0
        local firstUpdate, nextUpdate = firstClock.Update, nextClock.Update
        firstClock.Update = function(self, dt)
            updateCalls = updateCalls + 1
            return firstUpdate(self, dt)
        end
        nextClock.Update = function(self, dt)
            updateCalls = updateCalls + 1
            return nextUpdate(self, dt)
        end

        local currentClock, getterCalls = firstClock, 0
        local clockScene = FusedScene.Start({ initializeRegions = false, ownsUI = false,
            getClock = function()
                getterCalls = getterCalls + 1
                return currentClock
            end,
            uiFactory = function()
                return { refresh = function() end, handleKey = function() return false end }
            end,
        })
        clockScene:Render()
        assert(rendered.calls[#rendered.calls].clock == firstClock)
        clockScene:Render()
        assert(rendered.calls[#rendered.calls].clock == firstClock)
        currentClock = nextClock
        clockScene:Render()
        assert(rendered.calls[#rendered.calls].clock == nextClock)

        assert(getterCalls == 3)
        assert(updateCalls == 0 and firstClock.elapsed == firstElapsed and nextClock.elapsed == nextElapsed)
        clockScene:Stop()
    end)
    check("B may supply a UI factory without replacing or initializing its UI", function()
        local roots, initialized = UI.roots, UI.initialized
        local b = FusedScene.Start({ initializeRegions = false, ownsUI = false,
            uiFactory = function() return { refresh = function() end, handleKey = function() return false end } end })
        assert(UI.roots == roots and UI.initialized == initialized)
        b:Stop()
        assert(UI.shutdowns == 1)
    end)
    for name, entry in pairs(saved) do _G[name] = entry.value end
    package.loaded["urhox-libs/UI"], package.loaded["Ocean.SeaDraw"] = oldUI, oldDraw
    return { results = results }
end

return Tests
