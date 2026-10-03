-- Pure-Lua/Lupa tests with fake engine globals and event nodes; not native UrhoX/Maker verification.
local Tests = {}

local function near(actual, expected, epsilon)
    assert(math.abs(actual - expected) <= (epsilon or 0.0001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

local function withEngineStubs(run)
    local globalNames = {
        "graphics", "input", "Node", "nvgCreate", "nvgDelete", "nvgSetRenderOrder",
        "nvgBeginFrame", "nvgEndFrame", "KEY_A", "KEY_D", "KEY_W", "KEY_S",
        "KEY_LEFT", "KEY_RIGHT", "KEY_UP", "KEY_DOWN", "KEY_F3", "KEY_SPACE",
        "MM_ABSOLUTE", "MOUSEB_LEFT", "MOUSEB_RIGHT",
    }
    local savedGlobals = {}
    for _, name in ipairs(globalNames) do
        savedGlobals[name] = { present = rawget(_G, name) ~= nil, value = rawget(_G, name) }
    end
    local oldUI = package.loaded["urhox-libs/UI"]
    local oldBootstrap = package.loaded["Ocean.Bootstrap"]
    local oldScene = package.loaded["Ocean.SeaDraw"]

    local tracker = { rows = {}, activeCount = 0, unsubscriptions = 0, removals = 0, deletes = 0 }
    local screen = { width = 1920, height = 1080, dpr = 2 }
    local pointer = { x = 0, y = 0 }
    local pressedKeys = {}
    local uiState = { scale = 3, hit = false, focus = nil, lastHit = nil }
    local ui = {
        GetScale = function() return uiState.scale end,
        GetFocus = function() return uiState.focus end,
        FindWidgetAt = function(x, y)
            uiState.lastHit = { x = x, y = y }
            return uiState.hit and {} or nil
        end,
    }
    package.loaded["urhox-libs/UI"] = ui
    package.loaded["Ocean.Bootstrap"] = nil

    for index, name in ipairs({ "KEY_A", "KEY_D", "KEY_W", "KEY_S", "KEY_LEFT", "KEY_RIGHT",
        "KEY_UP", "KEY_DOWN", "KEY_F3", "KEY_SPACE", "MM_ABSOLUTE", "MOUSEB_LEFT", "MOUSEB_RIGHT" }) do
        _G[name] = index
    end

    _G.graphics = {
        windowTitle = "",
        GetWidth = function() return screen.width end,
        GetHeight = function() return screen.height end,
        GetDPR = function() return screen.dpr end,
    }
    _G.input = {
        mouseMode = MM_ABSOLUTE,
        mouseVisible = true,
        GetMousePosition = function() return { x = pointer.x, y = pointer.y } end,
        GetKeyDown = function(_, key) return pressedKeys[key] == true end,
    }
    _G.nvgCreate = function() return {} end
    _G.nvgDelete = function() tracker.deletes = tracker.deletes + 1 end
    _G.nvgSetRenderOrder = function() end
    _G.nvgBeginFrame = function() end
    _G.nvgEndFrame = function() end

    local function register(owner, eventName, callback)
        local row = { owner = owner, event = eventName, callback = callback, active = true }
        tracker.rows[#tracker.rows + 1] = row
        owner.rows[#owner.rows + 1] = row
        tracker.activeCount = tracker.activeCount + 1
        return row
    end

    _G.Node = function()
        local node = {}
        function node:CreateScriptObject()
            local object = { rows = {}, unsubscribed = false }
            function object:SubscribeToEvent(first, second, third)
                local eventName, callback
                if third ~= nil then
                    eventName, callback = second, third
                else
                    eventName, callback = first, second
                end
                assert(type(eventName) == "string" and type(callback) == "function")
                register(self, eventName, callback)
            end
            function object:UnsubscribeFromAllEvents()
                if self.unsubscribed then return end
                self.unsubscribed = true
                tracker.unsubscriptions = tracker.unsubscriptions + 1
                for _, row in ipairs(self.rows) do
                    if row.active then
                        row.active = false
                        tracker.activeCount = tracker.activeCount - 1
                    end
                end
            end
            return object
        end
        function node:Remove() tracker.removals = tracker.removals + 1 end
        return node
    end
    local environment = {
        screen = screen,
        pointer = pointer,
        pressedKeys = pressedKeys,
        uiState = uiState,
        tracker = tracker,
    }
    local ok, err = pcall(run, environment)
    for _, name in ipairs(globalNames) do
        local previous = savedGlobals[name]
        if previous.present then rawset(_G, name, previous.value) else rawset(_G, name, nil) end
    end
    package.loaded["urhox-libs/UI"] = oldUI
    package.loaded["Ocean.Bootstrap"] = oldBootstrap
    package.loaded["Ocean.SeaDraw"] = oldScene
    if not ok then error(err) end
end

local function latestRow(tracker, owner, eventName)
    for index = #tracker.rows, 1, -1 do
        local row = tracker.rows[index]
        if row.owner == owner and row.event == eventName then return row end
    end
    return nil
end

local function fire(tracker, object, eventName, data)
    local row = latestRow(tracker, object, eventName)
    assert(row ~= nil, "missing " .. eventName .. " subscription")
    return row.callback(object, eventName, data)
end

local function eventData(values)
    return {
        GetInt = function(_, name) return values[name] end,
        GetBool = function(_, name) return values[name] == true end,
        GetFloat = function(_, name) return values[name] end,
    }
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("mouse and touch respect UI hits, callback consumption, and default sailing", function()
        withEngineStubs(function(env)
            local Bootstrap = require("Ocean.Bootstrap")
            local runtimeCalls = { before = 0, pointer = 0 }
            ---@type boolean?
            local consume = true
            local instance = Bootstrap.Start({ initializeRegions = false, ownsUI = false,
                pointerMinY = 0.35,
                uiFactory = function()
                    return { refresh = function() end, handleKey = function() return false end }
                end,
                beforePointer = function() runtimeCalls.before = runtimeCalls.before + 1 end,
                onSeaPointer = function(position, runtime, ocean)
                    runtimeCalls.pointer = runtimeCalls.pointer + 1
                    runtimeCalls.position = { x = position.x, y = position.y }
                    runtimeCalls.runtime, runtimeCalls.ocean = runtime, ocean
                    return consume
                end,
            })
            local targetPoint = { x = 5, y = -3 }
            local screenX, screenY = instance.runtime.movement:WorldToScreen(targetPoint)
            env.pointer.x, env.pointer.y = screenX * env.screen.dpr, screenY * env.screen.dpr
            instance.runtime.movement:SetTarget({ x = -5, y = 0 })
            local oldTarget = instance.runtime.movement.target

            fire(env.tracker, instance.eventObject, "MouseButtonDown", eventData({ Button = MOUSEB_LEFT }))
            assert(runtimeCalls.pointer == 1 and runtimeCalls.before == 1)
            assert(runtimeCalls.runtime == instance.runtime and runtimeCalls.ocean == instance)
            near(runtimeCalls.position.x, targetPoint.x)
            near(runtimeCalls.position.y, targetPoint.y)
            assert(instance.runtime.movement.target == oldTarget,
                "onSeaPointer true should consume the pointer without changing navigation")
            near(env.uiState.lastHit.x, env.pointer.x / env.uiState.scale)
            near(env.uiState.lastHit.y, env.pointer.y / env.uiState.scale)

            env.uiState.hit = true
            fire(env.tracker, instance.eventObject, "TouchBegin", eventData({ X = env.pointer.x, Y = env.pointer.y }))
            assert(runtimeCalls.pointer == 1 and runtimeCalls.before == 2,
                "a touch on UI should sync bridge state without passing through to sea callbacks")
            assert(instance.runtime.movement.target == oldTarget,
                "a touch on UI changed the ship target")
            env.uiState.hit = false

            consume = false
            fire(env.tracker, instance.eventObject, "TouchBegin", eventData({ X = env.pointer.x, Y = env.pointer.y }))
            assert(runtimeCalls.pointer == 2 and runtimeCalls.before == 3)
            near(instance.runtime.movement.target.x, targetPoint.x)
            near(instance.runtime.movement.target.y, targetPoint.y)

            consume = nil
            fire(env.tracker, instance.eventObject, "MouseButtonDown", eventData({ Button = MOUSEB_LEFT }))
            assert(runtimeCalls.pointer == 3 and runtimeCalls.before == 4)
            near(instance.runtime.movement.target.x, targetPoint.x)
            near(instance.runtime.movement.target.y, targetPoint.y)

            local targetAfterSeaClick = instance.runtime.movement.target
            fire(env.tracker, instance.eventObject, "MouseButtonDown", eventData({ Button = MOUSEB_RIGHT }))
            assert(runtimeCalls.pointer == 3 and instance.runtime.movement.target == targetAfterSeaClick,
                "non-left mouse buttons should not steer the ship")
            instance:Stop()
        end)
    end)

    check("DPR and screen dimension changes update viewport before mapping pointers", function()
        withEngineStubs(function(env)
            local Bootstrap = require("Ocean.Bootstrap")
            local instance = Bootstrap.Start({ initializeRegions = false, ownsUI = false,
                uiFactory = function() return { refresh = function() end, handleKey = function() return false end } end })
            near(instance.runtime.movement.viewportWidth, 960)
            near(instance.runtime.movement.viewportHeight, 540)
            near(instance.dpr, 2)

            env.screen.width, env.screen.height, env.screen.dpr = 1440, 960, 1.5
            fire(env.tracker, instance.eventObject, "Update", eventData({ TimeStep = 0 }))
            near(instance.runtime.movement.viewportWidth, 960)
            near(instance.runtime.movement.viewportHeight, 640)
            near(instance.dpr, 1.5)

            local point = { x = 6, y = -4 }
            local logicalX, logicalY = instance.runtime.movement:WorldToScreen(point)
            env.pointer.x, env.pointer.y = logicalX * env.screen.dpr, logicalY * env.screen.dpr
            fire(env.tracker, instance.eventObject, "MouseButtonDown", eventData({ Button = MOUSEB_LEFT }))
            near(instance.runtime.movement.target.x, point.x)
            near(instance.runtime.movement.target.y, point.y)

            env.screen.width, env.screen.height, env.screen.dpr = 1280, 800, 2
            fire(env.tracker, instance.eventObject, "Update", eventData({ TimeStep = 0 }))
            near(instance.runtime.movement.viewportWidth, 640)
            near(instance.runtime.movement.viewportHeight, 400)
            near(instance.dpr, 2)
            instance:Stop()
        end)
    end)

    check("invalid coordinates, viewport, focus, or water cannot become sea targets", function()
        withEngineStubs(function(env)
            local Bootstrap = require("Ocean.Bootstrap")
            local keyCalls = 0
            local instance = Bootstrap.Start({ initializeRegions = false, ownsUI = false,
                uiFactory = function()
                    return { refresh = function() end, handleKey = function() keyCalls = keyCalls + 1; return true end }
                end,
                onSeaPointer = function() error("invalid pointer reached callback") end,
            })
            local initialTarget = instance.runtime.movement.target
            assert(not instance:HandlePointer(0 / 0, 400), "NaN pointer was accepted")
            assert(not instance:HandlePointer(math.huge, 400), "infinite pointer was accepted")
            assert(instance.runtime.movement.target == initialTarget)

            env.uiState.scale = 0
            assert(not instance:HandlePointer(300, 300), "invalid UI scale was accepted")
            env.uiState.scale = 3

            local originalFree = instance.runtime.IsPositionFree
            instance.runtime.IsPositionFree = function() return false end
            assert(not instance:HandlePointer(700, 700), "blocked water was accepted")
            assert(instance.runtime.movement.target == initialTarget)
            instance.runtime.IsPositionFree = originalFree

            env.uiState.focus = { _className = "Button", state = { focused = true } }
            env.pressedKeys[KEY_D] = true
            local shipX, shipY = instance.runtime.ship.position.x, instance.runtime.ship.position.y
            fire(env.tracker, instance.eventObject, "KeyDown", eventData({ Key = KEY_F3, Repeat = false }))
            assert(keyCalls == 1, "ordinary button focus incorrectly blocked the UI shortcut")
            fire(env.tracker, instance.eventObject, "Update", eventData({ TimeStep = 0.05 }))
            assert(instance.runtime.ship.position.x > shipX,
                "ordinary button focus incorrectly blocked keyboard steering")
            near(instance.runtime.ship.position.y, shipY)

            env.uiState.focus = { _className = "TextField", state = { focused = true } }
            env.pressedKeys[KEY_D] = false
            fire(env.tracker, instance.eventObject, "KeyDown", eventData({ Key = KEY_F3, Repeat = false }))
            assert(keyCalls == 1, "text input focus should reserve shortcuts for the text field")
            local shipAfterButton = instance.runtime.ship.position.x
            fire(env.tracker, instance.eventObject, "Update", eventData({ TimeStep = 0.05 }))
            near(instance.runtime.ship.position.x, shipAfterButton)

            env.uiState.focus = nil
            env.pressedKeys[KEY_D] = true
            fire(env.tracker, instance.eventObject, "KeyDown", eventData({ Key = KEY_F3, Repeat = false }))
            assert(keyCalls == 2, "unfocused UI should receive the debug key handler")
            fire(env.tracker, instance.eventObject, "Update", eventData({ TimeStep = 0.05 }))
            assert(instance.runtime.ship.position.x > shipAfterButton,
                "keyboard steering should move when a text field is not focused")
            instance:Stop()
        end)
    end)

    check("pointer bridge syncs stale pause state before sea guards", function()
        withEngineStubs(function()
            local Bootstrap = require("Ocean.Bootstrap")
            local callbackCalls = 0
            local syncPause = false
            local instance = Bootstrap.Start({ initializeRegions = false, ownsUI = false,
                beforePointer = function(runtime)
                    runtime.paused = syncPause
                end,
                onSeaPointer = function() callbackCalls = callbackCalls + 1; return false end,
                uiFactory = function() return { refresh = function() end, handleKey = function() return false end } end,
            })
            local initialTarget = instance.runtime.movement.target

            -- A newly paused bridge must block the pointer even if Runtime was stale.
            syncPause = true
            instance.runtime.paused = false
            assert(not instance:HandlePointer(600, 400), "bridge pause did not block pointer handling")
            assert(callbackCalls == 0 and instance.runtime.movement.target == initialTarget,
                "paused sea pointer reached interaction or navigation")

            -- Conversely, an unpaused bridge must be able to clear stale Runtime state.
            syncPause = false
            instance.runtime.paused = true
            assert(instance:HandlePointer(600, 400), "bridge unpause did not allow pointer handling")
            assert(callbackCalls == 1, "unpaused pointer did not reach the sea callback")
            instance:Stop()
        end)
    end)

    check("Render forwards the clock, fishing view, and seventh recognition callback", function()
        withEngineStubs(function(env)
            local Bootstrap = require("Ocean.Bootstrap")
            local SeaDraw = require("Ocean.SeaDraw")
            local oldScene = SeaDraw.Scene
            local received = nil
            local clock = { phase = "night" }
            local fishingView = { phase = "aim" }
            local recognized = function(contentId) return contentId == "driftwood_barrel" end
            SeaDraw.Scene = function(...) received = table.pack(...) end
            local instance = Bootstrap.Start({ initializeRegions = false, ownsUI = false,
                getClock = function() return clock end,
                getFishingView = function() return fishingView end,
                isLocationRecognized = recognized,
                uiFactory = function() return { refresh = function() end, handleKey = function() return false end } end,
            })
            instance:Render()
            assert(received and received.n == 7, "SeaDraw.Scene did not receive seven ordered arguments")
            assert(received[4] == instance.runtime)
            assert(received[5] == clock and received[6] == fishingView,
                "the existing clock/fishing view argument positions changed")
            assert(received[7] == recognized, "recognition callback was not forwarded by identity")
            instance:Stop()
            SeaDraw.Scene = oldScene
            assert(env.tracker.activeCount == 0)
        end)
    end)

    check("repeated Start/Stop owns one event set, cleans idempotently, and silences stale callbacks", function()
        withEngineStubs(function(env)
            local Bootstrap = require("Ocean.Bootstrap")
            local expectedEvents = { "Update", "NanoVGRender", "MouseButtonDown", "TouchBegin", "KeyDown" }
            for cycle = 1, 12 do
                local keyCalls = 0
                local instance = Bootstrap.Start({ initializeRegions = false, ownsUI = false,
                    uiFactory = function()
                        return { refresh = function() end, handleKey = function() keyCalls = keyCalls + 1; return true end }
                    end,
                    beforePointer = function() error("stale pointer callback ran after Stop") end,
                })
                assert(env.tracker.activeCount == #expectedEvents,
                    "Start registered an unexpected number of event handlers on cycle " .. cycle)
                for _, eventName in ipairs(expectedEvents) do
                    local count = 0
                    for _, row in ipairs(instance.eventObject.rows) do
                        if row.active and row.event == eventName then count = count + 1 end
                    end
                    assert(count == 1, "expected one active " .. eventName .. " handler")
                end

                local oldShip = instance.runtime.ship
                local oldTime = instance.runtime.time
                instance:Stop()
                local unsubscribes, removals, deletes = env.tracker.unsubscriptions,
                    env.tracker.removals, env.tracker.deletes
                instance:Stop()
                assert(env.tracker.unsubscriptions == unsubscribes and env.tracker.removals == removals
                    and env.tracker.deletes == deletes, "Stop was not idempotent")
                assert(env.tracker.activeCount == 0, "Stop left live engine subscriptions")

                env.pressedKeys[KEY_D] = true
                env.pointer.x, env.pointer.y = 500, 500
                for _, eventName in ipairs(expectedEvents) do
                    local data
                    if eventName == "Update" then data = eventData({ TimeStep = 0.05 })
                    elseif eventName == "MouseButtonDown" then data = eventData({ Button = MOUSEB_LEFT })
                    elseif eventName == "TouchBegin" then data = eventData({ X = 500, Y = 500 })
                    else data = eventData({ Key = KEY_F3, Repeat = false }) end
                    fire(env.tracker, instance.eventObject, eventName, data)
                end
                near(instance.runtime.time, oldTime)
                assert(instance.runtime.ship == oldShip and keyCalls == 0,
                    "a stopped callback changed runtime or dispatched a UI key")

                -- Drop the fake event registry's retained closures after checking stale callbacks.
                env.tracker.rows = {}
            end
            assert(env.tracker.activeCount == 0 and env.tracker.unsubscriptions == 12,
                "repeated scene rebuild leaked subscriptions")
        end)
    end)

    return { results = results }
end

return Tests
