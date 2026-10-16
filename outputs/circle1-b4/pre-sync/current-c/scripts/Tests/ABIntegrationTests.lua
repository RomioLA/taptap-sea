-- Real A (Ocean) and B (Gameplay) modules joined by the production integration bridge.
-- Only the engine, UI and persistence boundary are mocked; this does not simulate
-- the four-second fishing wait. CompleteFishing is invoked explicitly as a contract.
local Runtime = require("Ocean.SeaRuntime")
local Config = require("Ocean.Config")
local GameplayConfig = require("config.gameplay")
local Items = require("data.items")
local Player = require("Gameplay.PlayerState")
local Persistence = require("Gameplay.Persistence")
local Bridge = require("Integration.Bridge")

local Tests = {}

local function copyTable(source)
    local result = {}
    for key, value in pairs(source) do
        if type(value) == "table" then
            result[key] = copyTable(value)
        else
            result[key] = value
        end
    end
    return result
end

local function near(actual, expected, epsilon, label)
    assert(type(actual) == "number", (label or "value") .. " should be a number")
    assert(math.abs(actual - expected) <= (epsilon or 0.000001),
        (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function memoryStore()
    local store = { saves = {}, saveCallbacks = {}, loadCallbacks = {} }
    function store:Save(snapshot, done)
        self.saves[#self.saves + 1] = copyTable(snapshot)
        self.saveCallbacks[#self.saveCallbacks + 1] = done
    end
    function store:Load(done)
        self.loadCallbacks[#self.loadCallbacks + 1] = done
    end
    return store
end

local FREE_SEA = { x = -20, y = -20 }

local function fixture(settings)
    settings = settings or {}
    local store = settings.store
    if not settings.noStore and not store then store = memoryStore() end
    local runtime = Runtime.New({
        departure = copyTable(FREE_SEA),
        initializeRegions = settings.initializeRegions == true,
        daySeed = settings.daySeed or 314159,
        shipLevel = settings.shipLevel or 1,
    })
    local hooks = { newDays = {}, resets = 0 }
    local options = {
        onNewDay = function(day)
            hooks.newDays[#hooks.newDays + 1] = day
            if settings.onNewDay then settings.onNewDay(day) end
        end,
        resetDynamicWorld = function()
            hooks.resets = hooks.resets + 1
            if settings.resetDynamicWorld then settings.resetDynamicWorld() end
        end,
    }
    if store then options.store = store end
    if settings.dropReceiver then options.dropReceiver = settings.dropReceiver end
    local bridge = Bridge.New(runtime, options)
    assert(bridge and bridge.runtime == runtime and bridge.loop, "Bridge.New must retain A runtime and B loop")
    bridge:Sync()
    return { runtime = runtime, bridge = bridge, loop = bridge.loop, store = store, hooks = hooks }
end

local function depart(env)
    local ok, reason = env.loop:Depart()
    assert(ok, tostring(reason or "could not depart"))
    env.bridge:Sync()
    assert(not env.runtime.paused, "departing must release the A world pause")
end

local function liveFish(runtime)
    return runtime:queryEntitiesInRadius(runtime.ship.position, 100000, { entityType = "fish" })
end

local function findDrop(runtime, itemId)
    for _, entity in ipairs(runtime.world.entities) do
        if not entity.removed and entity.entityType == "droppedItem" and entity.itemId == itemId then
            return entity
        end
    end
    return nil
end

local function readonlyPoint(x, y)
    return setmetatable({}, {
        __index = function(_, key)
            if key == "x" then return x end
            if key == "y" then return y end
            return nil
        end,
        __newindex = function() error("world position is read-only", 2) end,
        __pairs = function()
            local values = { x = x, y = y }
            return next, values, nil
        end,
    })
end

local function sameItems(player, expected)
    local items = player.inventory:GetItems()
    assert(#items == #expected, "inventory item count changed unexpectedly")
    for index, itemId in ipairs(expected) do
        assert(items[index] == itemId, "inventory changed at slot " .. tostring(index))
    end
end

local function sameValue(actual, expected, path)
    assert(type(actual) == type(expected), (path or "value") .. " type changed")
    if type(expected) ~= "table" then
        assert(actual == expected, (path or "value") .. " changed")
        return
    end
    for key, value in pairs(expected) do sameValue(actual[key], value, (path or "value") .. "." .. tostring(key)) end
    for key in pairs(actual) do assert(expected[key] ~= nil, (path or "value") .. " gained " .. tostring(key)) end
end

local function sceneHarness()
    local savedGlobals, savedModules = {}, {}
    local moduleNames = {
        "urhox-libs/UI", "Integration.Scene", "Gameplay.HUD", "Gameplay.Debug",
        "Ocean.Bootstrap", "Ocean.FusedScene", "Ocean.SeaDraw", "Ocean.SeaDebug", "Ocean.HUD",
    }
    for _, name in ipairs(moduleNames) do
        savedModules[name] = { value = package.loaded[name] }
        package.loaded[name] = nil
    end
    local function replaceGlobal(name, value)
        savedGlobals[name] = { value = _G[name] }
        _G[name] = value
    end
    local function restore()
        for name, entry in pairs(savedGlobals) do _G[name] = entry.value end
        for name, entry in pairs(savedModules) do package.loaded[name] = entry.value end
    end

    local ok, result = xpcall(function()
        local UI = { Scale = { DEFAULT = 1 }, initialized = 0, roots = 0, shutdowns = 0, hit = nil }
        local function widget(props)
            props = props or {}
            local self = {
                props = props,
                children = {},
                visible = props.visible ~= false,
                disabled = false,
                destroyed = false,
                value = props.value or "",
            }
            function self:AddChild(child)
                self.children[#self.children + 1] = child
                child.parent = self
                return child
            end
            function self:RemoveChild(child)
                for index = #self.children, 1, -1 do
                    if self.children[index] == child then
                        table.remove(self.children, index)
                        child.parent = nil
                        return true
                    end
                end
                return false
            end
            function self:GetChildren()
                local children = {}
                for index, child in ipairs(self.children) do children[index] = child end
                return children
            end
            function self:GetChildAt(index)
                return self.children[index]
            end
            function self:ClearChildren()
                for _, child in ipairs(self.children) do child.parent = nil end
                self.children = {}
            end
            function self:SetVisible(value) self.visible = value == true end
            function self:IsVisible() return self.visible end
            function self:Hide() self.visible = false end
            function self:Show() self.visible = true end
            function self:SetDisabled(value) self.disabled = value == true end
            function self:IsDisabled() return self.disabled end
            function self:SetText(value) self.props.text = tostring(value or "") end
            function self:GetText() return self.props.text end
            function self:SetValue(value) self.value = value end
            function self:GetValue() return self.value end
            function self:SetStyle(style)
                for key, value in pairs(style) do self.props[key] = value end
            end
            function self:SetFontColor(color) self.props.fontColor = color end
            function self:FindById(id)
                if self.props.id == id then return self end
                for _, child in ipairs(self.children) do
                    local found = child:FindById(id)
                    if found then return found end
                end
                return nil
            end
            function self:Destroy()
                if self.destroyed then return end
                self.destroyed = true
                local children = self:GetChildren()
                for _, child in ipairs(children) do child:Destroy() end
                self:ClearChildren()
                if self.parent then self.parent:RemoveChild(self) end
            end
            function self:Click()
                if not self.disabled and type(self.props.onClick) == "function" then
                    return self.props.onClick(self)
                end
                return false
            end
            for _, child in ipairs(props.children or {}) do self:AddChild(child) end
            return self
        end
        for _, kind in ipairs({ "Panel", "SafeAreaView", "Button", "Label", "Row", "ScrollView", "Spacer", "TextField" }) do
            UI[kind] = widget
        end
        UI.Init = function() UI.initialized = UI.initialized + 1 end
        UI.SetRoot = function(root) UI.root = root; UI.roots = UI.roots + 1 end
        UI.GetRoot = function() return UI.root end
        UI.GetScale = function() return 1 end
        UI.FindWidgetAt = function() return UI.hit end
        UI.Shutdown = function() UI.shutdowns = UI.shutdowns + 1 end
        package.loaded["urhox-libs/UI"] = UI

        local oceanHud = require("Ocean.HUD")
        local originalOceanHudCreate = oceanHud.Create
        local oceanHudCreateCalls = 0
        oceanHud.Create = function(...)
            oceanHudCreateCalls = oceanHudCreateCalls + 1
            return originalOceanHudCreate(...)
        end

        local events, eventNode = {}, { removed = 0, unsubscribed = 0 }
        function eventNode:CreateScriptObject()
            local object = {}
            function object:SubscribeToEvent(eventOrSender, eventOrHandler, handler)
                local event = handler and eventOrHandler or eventOrSender
                local callback = handler or eventOrHandler
                events[#events + 1] = { name = event, callback = callback }
            end
            function object:UnsubscribeFromAllEvents() eventNode.unsubscribed = eventNode.unsubscribed + 1 end
            return object
        end
        function eventNode:Remove() self.removed = self.removed + 1 end
        replaceGlobal("Node", function() return eventNode end)
        replaceGlobal("graphics", {
            width = 1920,
            height = 1080,
            dpr = 2,
            GetWidth = function(self) return self.width end,
            GetHeight = function(self) return self.height end,
            GetDPR = function(self) return self.dpr end,
        })
        replaceGlobal("input", {
            GetKeyDown = function() return false end,
            GetMousePosition = function() return { x = 0, y = 0 } end,
        })
        for index, name in ipairs({
            "KEY_A", "KEY_D", "KEY_W", "KEY_S", "KEY_LEFT", "KEY_RIGHT", "KEY_UP", "KEY_DOWN",
            "KEY_SPACE", "KEY_R", "KEY_F3", "KEY_U", "KEY_H", "KEY_P", "KEY_J", "KEY_1", "KEY_2",
            "KEY_C", "KEY_B", "MM_ABSOLUTE", "MOUSEB_LEFT",
        }) do replaceGlobal(name, index) end
        local nvgDeletes = 0
        local drawCalls = 0
        local lastDraw = {}
        for _, name in ipairs({ "nvgSetRenderOrder", "nvgBeginFrame", "nvgEndFrame" }) do
            replaceGlobal(name, function() end)
        end
        replaceGlobal("nvgCreate", function() return {} end)
        replaceGlobal("nvgDelete", function() nvgDeletes = nvgDeletes + 1 end)
        package.loaded["Ocean.SeaDraw"] = {
            Scene = function(_, width, height, runtime)
                drawCalls = drawCalls + 1
                lastDraw = { width = width, height = height, runtime = runtime }
            end,
        }

        local Scene = require("Integration.Scene")
        local sea = Scene.Start({
            departure = copyTable(FREE_SEA),
            initializeRegions = false,
            loadSaved = false,
            debugUI = false,
        })
        return {
            ui = UI,
            sea = sea,
            events = events,
            eventNode = eventNode,
            nvgDeletes = function() return nvgDeletes end,
            drawCalls = function() return drawCalls end,
            lastDraw = function() return lastDraw end,
            oceanHudCreateCalls = function() return oceanHudCreateCalls end,
            originalOceanHudCreate = originalOceanHudCreate,
            oceanHud = oceanHud,
            cleanup = function()
                pcall(sea.Stop, sea)
                oceanHud.Create = originalOceanHudCreate
                restore()
            end,
        }
    end, debug.traceback)
    if not ok then
        restore()
        error(result, 0)
    end
    return result
end

local function findByText(widget, text)
    if widget.props and widget.props.text == text then return widget end
    for _, child in ipairs(widget.children or {}) do
        local found = findByText(child, text)
        if found then return found end
    end
    return nil
end

local function eventHandler(context, name)
    for _, event in ipairs(context.events) do
        if event.name == name then return event.callback end
    end
    return nil
end

function Tests.Run()
    local results = {}
    local function check(name, run)
        local ok, err = pcall(run)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("Bridge construction uses the real A runtime and starts paused at port", function()
        local env = fixture()
        assert(env.loop.inPort and env.loop.clock.pauseReasons.port)
        assert(env.runtime.paused, "B's port pause must stop A at startup")
        assert(env.runtime.ship == env.bridge.runtime.ship)
        assert(env.runtime.ship.level == env.loop.player.boatSpeedLevel)
    end)

    check("one bridge Update advances B's clock and A's world by the same delta", function()
        local env = fixture()
        depart(env)
        local beforeX = env.runtime.ship.position.x
        assert(env.bridge:Update(0.2, 1, 0))
        near(env.loop.clock.elapsed, 0.2, 0.000001, "B clock")
        near(env.runtime.time, 0.2, 0.000001, "A runtime")
        assert(env.runtime.ship.position.x > beforeX, "A must receive the steering input once")
    end)

    check("B clock keeps raw dt while A simulation applies its own frame clamp", function()
        local env = fixture()
        depart(env)
        assert(env.bridge:Update(1, 0, 0))
        near(env.loop.clock.elapsed, 1, 0.000001, "B clock raw dt")
        near(env.runtime.time, Config.world.maxFrameSec, 0.000001, "A runtime frame clamp")
    end)

    check("large dt forces the B return pause before A can simulate that frame", function()
        local env = fixture()
        depart(env)
        assert(env.bridge:Update(GameplayConfig.clock.daySec + GameplayConfig.clock.nightSec, 1, 0))
        assert(env.loop.clock.exhausted and env.loop.forcedReturnPending)
        assert(env.loop.clock.pauseReasons.forced_return and env.runtime.paused,
            "B must synchronize forced-return pause before forwarding dt to A")
        near(env.loop.clock.elapsed, GameplayConfig.clock.nightSec, 0.000001, "exhausted B clock")
        near(env.runtime.time, 0, 0.000001, "paused A runtime")
    end)

    check("multiple pause reasons stop both layers until the final reason resumes", function()
        local env = fixture()
        depart(env)
        assert(env.bridge:Update(0.25, 1, 0))
        local clockTime, seaTime = env.loop.clock.elapsed, env.runtime.time
        env.loop.clock:Pause("inventory")
        env.bridge:Sync()
        env.loop.clock:Pause("elder")
        env.bridge:Sync()
        env.loop.clock:Resume("inventory")
        env.bridge:Sync()
        assert(env.runtime.paused and env.loop.clock:IsPaused())
        assert(env.bridge:Update(0.5, 1, 0))
        near(env.loop.clock.elapsed, clockTime, 0.000001, "B clock while paused")
        near(env.runtime.time, seaTime, 0.000001, "A world while paused")
        env.loop.clock:Resume("elder")
        env.bridge:Sync()
        assert(not env.runtime.paused)
        assert(env.bridge:Update(0.1, 0, 0))
        near(env.loop.clock.elapsed, clockTime + 0.1, 0.000001, "B clock after all reasons clear")
        near(env.runtime.time, seaTime + 0.1, 0.000001, "A world after all reasons clear")
    end)

    check("manual pause is a named B clock reason and coexists with UI pauses", function()
        local env = fixture()
        depart(env)
        local toggled, paused = env.bridge:TogglePause()
        assert(toggled and paused and env.loop.clock.pauseReasons.manual)
        assert(env.runtime.paused)
        env.loop.clock:Pause("inventory")
        env.bridge:Sync()
        env.bridge:TogglePause()
        assert(not env.loop.clock.pauseReasons.manual and env.loop.clock.pauseReasons.inventory)
        assert(env.runtime.paused, "removing the manual reason must preserve inventory pause")
        env.loop.clock:Resume("inventory")
        env.bridge:Sync()
        assert(not env.runtime.paused)
    end)

    check("drop requires a selected copied position and spawns a 20-second world item", function()
        local env = fixture()
        depart(env)
        local before = env.loop.player.inventory:GetItems()
        assert(not env.loop:DropItem(1), "dropping without explicit pointer selection must fail")
        sameItems(env.loop.player, before)
        local point = readonlyPoint(-8, -20) -- exactly twelve meters from the ship
        assert(env.bridge:SetDropTarget(point))
        assert(not pcall(function() point.x = -7 end), "test point must reject writes")
        local ok = env.loop:DropItem(1)
        assert(ok, "a twelve-meter throw should be accepted")
        local dropped = findDrop(env.runtime, "apple")
        assert(dropped, "A should own the spawned dropped item")
        near(dropped.position.x, -8, 0.000001, "drop x")
        near(dropped.position.y, -20, 0.000001, "drop y")
        assert(dropped.lifetimeSec == 20 and dropped.age == 0)
        assert(#env.loop.player.inventory:GetItems() == #before - 1)
    end)

    check("throwing farther than twelve meters rejects the handoff without losing the item", function()
        local env = fixture()
        depart(env)
        local before = env.loop.player.inventory:GetItems()
        assert(env.bridge:SetDropTarget({ x = -6.9, y = -20 }))
        local ok = env.loop:DropItem(1)
        assert(not ok, "a 13.1-meter throw must be rejected")
        sameItems(env.loop.player, before)
        assert(not findDrop(env.runtime, "apple"))
    end)

    check("invalid drop selection clears the prior target and receiver reentry stays single-flight", function()
        ---@type {loop: GameplayLoop, runtime: table, bridge: GameplayOceanBridge}
        local env
        local receiverCalls = 0
        env = fixture({ dropReceiver = function(payload, position)
            receiverCalls = receiverCalls + 1
            assert(env.loop.dropInFlight, "the bridge receiver only accepts an active B handoff")
            assert(payload.itemId == "apple" and position.x == -8 and position.y == -20)
            local reentrant = env.loop:DropItem(1)
            assert(not reentrant, "a reentrant handoff must be rejected while one drop is in flight")
            return true
        end })
        depart(env)
        local before = env.loop.player.inventory:GetItems()
        assert(env.bridge:SetDropTarget({ x = -8, y = -20 }))
        assert(not env.bridge:SetDropTarget({ x = 100000, y = 100000 }), "off-map targets are invalid")
        local rejected = env.loop:DropItem(1)
        assert(not rejected, "an invalid new target must clear the older valid target")
        sameItems(env.loop.player, before)
        assert(not findDrop(env.runtime, "apple"))

        assert(env.bridge:SetDropTarget(readonlyPoint(-8, -20)))
        assert(env.loop:DropItem(1))
        assert(receiverCalls == 1 and #env.loop.player.inventory:GetItems() == 1)
        assert(findDrop(env.runtime, "apple"))
    end)

    check("all four B inventory items become real A drops with category, effect and TTL", function()
        local env = fixture()
        depart(env)
        while #env.loop.player.inventory:GetItems() > 0 do
            assert(env.loop.player.inventory:Remove(1))
        end
        for _, itemId in ipairs({ "apple", "bait", "sardine", "tuna" }) do
            local definition = assert(Items.GetDefinition(itemId))
            assert(env.loop.player.inventory:Add(itemId))
            assert(env.bridge:SetDropTarget(readonlyPoint(-8, -20)))
            assert(env.loop:DropItem(1), "B could not hand off " .. itemId)
            local dropped = assert(findDrop(env.runtime, itemId), "A did not create " .. itemId)
            assert(dropped.category == definition.category, itemId .. " category was lost in the handoff")
            assert(dropped.worldEffect == (definition.worldEffect or "NONE"), itemId .. " world effect was lost")
            assert(dropped.lifetimeSec == (definition.lifetimeSec or Config.world.temporaryLifetimeSec),
                itemId .. " temporary lifetime was lost")

            assert(env.loop.player.inventory:Add(itemId))
            local beforeItems = env.loop.player.inventory:GetItems()
            assert(env.bridge:SetDropTarget({ x = -7.999, y = -20 })) -- 12.001 meters
            local ok = env.loop:DropItem(1)
            assert(not ok, "an over-twelve-meter " .. itemId .. " drop must be rejected")
            sameItems(env.loop.player, beforeItems)
            assert(dropped.age == 0 and not dropped.removed)
            while #env.loop.player.inventory:GetItems() > 0 do
                assert(env.loop.player.inventory:Remove(1))
            end
        end
        assert(env.runtime.world:getCounts().temp == 4, "failed throws must not create extra world objects")
    end)

    check("exact thirty-meter fishing cast works and anything beyond it is rejected", function()
        local env = fixture()
        depart(env)
        local fish = env.runtime:spawnFish("tuna", { x = 10, y = -20 })
        local token = env.bridge:BeginFishing(readonlyPoint(10, -20))
        assert(token, "a cast at the thirty-meter limit should return a token")
        local ok, result, itemId = env.bridge:CompleteFishing(token)
        assert(ok and result == "caught" and itemId == "tuna")
        assert(fish.removed)

        local outside = env.runtime:spawnFish("sardine", { x = 10.001, y = -20 })
        local stamina, itemCount = env.loop.player.stamina, #env.loop.player.inventory:GetItems()
        local rejected = env.bridge:BeginFishing({ x = 10.001, y = -20 })
        assert(not rejected, "a cast beyond thirty meters must fail")
        assert(not outside.removed and env.loop.player.stamina == stamina)
        assert(#env.loop.player.inventory:GetItems() == itemCount)
    end)

    check("net includes its eight-meter boundary and a single cast catches only one fish", function()
        local env = fixture()
        depart(env)
        local boundary = env.runtime:spawnFish("tuna", { x = -12, y = -20 })
        local outside = env.runtime:spawnFish("sardine", { x = -11.99, y = -20 })
        -- Move the second fish beyond the fixed eight-meter radius while remaining nearby.
        outside.position = { x = -11.9, y = -20 }
        local token = env.bridge:BeginFishing(readonlyPoint(-20, -20))
        assert(token)
        local ok, result, itemId = env.bridge:CompleteFishing(token)
        assert(ok and result == "caught" and itemId == "tuna")
        assert(boundary.removed and not outside.removed)
        assert(#env.loop.player.inventory:GetItems() == 3, "one cast may add at most one fish")
    end)

    check("hidden fish remain selectable and the nearest of several candidates is caught", function()
        local env = fixture()
        depart(env)
        local nearest = env.runtime:spawnFish("tuna", { x = -19, y = -20 })
        local second = env.runtime:spawnFish("sardine", { x = -17, y = -20 })
        local third = env.runtime:spawnFish("sardine", { x = -15, y = -20 })
        assert(not env.runtime.world:isVisible(nearest), "ordinary fish start hidden")
        local beforeTime, beforeStamina = env.runtime.time, env.loop.player.stamina
        local token = env.bridge:BeginFishing(readonlyPoint(-20, -20))
        assert(token, "hidden fish should still be actionable")
        assert(env.loop.player.stamina == beforeStamina, "beginning only reserves the action")
        local ok, result, itemId = env.bridge:CompleteFishing(token)
        assert(ok and result == "caught" and itemId == "tuna")
        assert(nearest.removed and not second.removed and not third.removed)
        assert(env.runtime.time == beforeTime, "this contract check must not fake the four-second wait")
        assert(env.loop.player.stamina == beforeStamina - 40)
        assert(#env.loop.player.inventory:GetItems() == 3)
    end)

    check("empty-water casts receive a valid token and repeated completion only charges once", function()
        local env = fixture()
        depart(env)
        local beforeStamina = env.loop.player.stamina
        local beforeItems = env.loop.player.inventory:GetItems()
        local token = env.bridge:BeginFishing(readonlyPoint(-20, -20))
        assert(token, "an empty cast still represents a valid future action")
        assert(env.loop.player.stamina == beforeStamina)
        local ok, result = env.bridge:CompleteFishing(token)
        assert(ok and result == "empty")
        local again, againResult = env.bridge:CompleteFishing(token)
        assert(again and againResult == "empty", "completed token replay must return the same outcome")
        assert(env.loop.player.stamina == beforeStamina - 40)
        sameItems(env.loop.player, beforeItems)
        assert(#liveFish(env.runtime) == 0)
        assert(env.runtime.time == 0, "Begin/Complete are action boundaries; no timer was simulated")
    end)

    check("fishing prechecks require sea access, forty stamina and one free inventory slot", function()
        local env = fixture()
        local fish = env.runtime:spawnFish("tuna", { x = -19, y = -20 })
        local token = env.bridge:BeginFishing(FREE_SEA)
        assert(not token, "fishing in port must be rejected")
        depart(env)
        env.loop.player.stamina = 39
        token = env.bridge:BeginFishing(FREE_SEA)
        assert(not token, "less than forty stamina must be rejected")
        env.loop.player.stamina = 100
        while env.loop.player.inventory:HasSpace() do
            assert(env.loop.player.inventory:Add("sardine"))
        end
        local stamina, itemCount = env.loop.player.stamina, #env.loop.player.inventory:GetItems()
        token = env.bridge:BeginFishing(FREE_SEA)
        assert(not token, "a full hold must reject even when a fish is in range")
        assert(env.loop.player.stamina == stamina and #env.loop.player.inventory:GetItems() == itemCount)
        assert(not fish.removed)
    end)

    check("B fishing failures run before the A fish selector", function()
        local env = fixture()
        local fish = env.runtime:spawnFish("tuna", { x = -19, y = -20 })
        local originalSelector = env.runtime.selectFishingTarget
        local selectorCalls = 0
        env.runtime.selectFishingTarget = function(runtime, ...)
            selectorCalls = selectorCalls + 1
            return originalSelector(runtime, ...)
        end
        assert(not env.bridge:BeginFishing(FREE_SEA), "port precheck should reject")
        depart(env)
        env.loop.player.stamina = 39
        assert(not env.bridge:BeginFishing(FREE_SEA), "stamina precheck should reject")
        env.loop.player.stamina = 100
        while env.loop.player.inventory:HasSpace() do assert(env.loop.player.inventory:Add("sardine")) end
        assert(not env.bridge:BeginFishing(FREE_SEA), "inventory precheck should reject")
        assert(selectorCalls == 0, "B must reject before asking A to find a fish")
        assert(not fish.removed and env.loop.player.stamina == 100)
    end)

    check("single-flight and cancellation leave fish, stamina and inventory untouched", function()
        local env = fixture()
        depart(env)
        local fish = env.runtime:spawnFish("sardine", { x = -19, y = -20 })
        local beforeItems = env.loop.player.inventory:GetItems()
        local beforeStamina = env.loop.player.stamina
        local bypass, bypassError = env.loop:CompleteFishing(1)
        assert(not bypass and bypassError == "fishing_requires_bridge_token")
        local token = env.bridge:BeginFishing(FREE_SEA)
        assert(token)
        local second = env.bridge:BeginFishing(FREE_SEA)
        assert(not second, "only one fishing action may be pending")
        assert(not fish.removed and env.loop.player.stamina == beforeStamina)
        sameItems(env.loop.player, beforeItems)
        assert(env.bridge:CancelFishing(token))
        local complete = env.bridge:CompleteFishing(token)
        assert(not complete, "a cancelled token cannot complete")
        assert(not fish.removed and env.loop.player.stamina == beforeStamina)
        sameItems(env.loop.player, beforeItems)
    end)

    check("fishing charge and partially failed delivery roll back player and fish state", function()
        local env = fixture()
        depart(env)
        local fish = env.runtime:spawnFish("tuna", { x = -19, y = -20 })
        local token = env.bridge:BeginFishing(FREE_SEA)
        assert(token)
        local beforeItems = env.loop.player.inventory:GetItems()
        local beforeStamina = env.loop.player.stamina

        local originalCharge = env.loop.actions._completeLoopFishing
        env.loop.actions._completeLoopFishing = function() error("injected charge failure") end
        local chargeOk = env.bridge:CompleteFishing(token)
        env.loop.actions._completeLoopFishing = originalCharge
        assert(not chargeOk and env.loop.player.stamina == beforeStamina)
        assert(not fish.removed and env.runtime.world:get(fish.id) == fish)
        sameItems(env.loop.player, beforeItems)

        local inventory = env.loop.player.inventory
        local originalAdd = inventory.Add
        inventory.Add = function(self, itemId)
            assert(originalAdd(self, itemId))
            error("injected post-add failure")
        end
        local addOk = env.bridge:CompleteFishing(token)
        inventory.Add = originalAdd
        assert(not addOk and env.loop.player.stamina == beforeStamina)
        assert(not fish.removed and env.runtime.world:get(fish.id) == fish)
        sameItems(env.loop.player, beforeItems)

        local world = env.runtime.world
        local originalRemove = world.remove
        world.remove = function(self, id, reason)
            originalRemove(self, id, reason)
            error("injected post-remove failure")
        end
        local removeOk = env.bridge:CompleteFishing(token)
        world.remove = originalRemove
        assert(not removeOk and env.loop.player.stamina == beforeStamina)
        assert(not fish.removed and env.runtime.world:get(fish.id) == fish)
        sameItems(env.loop.player, beforeItems)

        local completed, result, itemId = env.bridge:CompleteFishing(token)
        assert(completed and result == "caught" and itemId == "tuna", "rolled-back token remains retryable")
        assert(fish.removed and env.loop.player.stamina == beforeStamina - 40)
        assert(#env.loop.player.inventory:GetItems() == #beforeItems + 1)
    end)

    check("stale targets and a pause at completion reject without partial costs", function()
        local stale = fixture()
        depart(stale)
        local fish = stale.runtime:spawnFish("tuna", { x = -19, y = -20 })
        local staleToken = stale.bridge:BeginFishing(FREE_SEA)
        assert(staleToken)
        stale.runtime.world:remove(fish.id, "test_stale_target")
        local beforeItems = stale.loop.player.inventory:GetItems()
        local beforeStamina = stale.loop.player.stamina
        local staleOk = stale.bridge:CompleteFishing(staleToken)
        assert(not staleOk and stale.loop.player.stamina == beforeStamina)
        sameItems(stale.loop.player, beforeItems)

        local paused = fixture()
        depart(paused)
        local pausedFish = paused.runtime:spawnFish("sardine", { x = -19, y = -20 })
        local pausedToken = paused.bridge:BeginFishing(FREE_SEA)
        assert(pausedToken)
        paused.loop.clock:Pause("special_event")
        paused.bridge:Sync()
        local pausedOk = paused.bridge:CompleteFishing(pausedToken)
        assert(not pausedOk and paused.runtime.paused)
        assert(not pausedFish.removed and paused.loop.player.stamina == 100)
        assert(#paused.loop.player.inventory:GetItems() == 2)
        assert(paused.bridge:CancelFishing(pausedToken))
    end)

    check("recognition accepts twenty meters, rejects farther points and reads immutable coordinates", function()
        local env = fixture()
        local accepted = env.bridge:RecognizeLocation("reef-20", readonlyPoint(0, -20))
        assert(accepted)
        assert(env.loop.player:IsRecognized("reef-20"))
        local tooFar = env.bridge:RecognizeLocation("reef-20.01", readonlyPoint(0.01, -20))
        assert(not tooFar and not env.loop.player:IsRecognized("reef-20.01"))
    end)

    check("moving A fish and ship state cannot alter the B-only save snapshot", function()
        local env = fixture()
        env.loop.player:MarkRecognized("saved-harbor")
        local before = Persistence.Snapshot(env.loop.player)
        local fish = env.runtime:spawnFish("sardine", { x = -19, y = -20 })
        fish.position = { x = -18, y = -20 }
        fish.state, fish.active, fish.frozen = "Flee", false, true
        local dropped = assert(env.runtime:spawnDroppedItem({ itemId = "world-only", lifetimeSec = 20 }, { x = -19, y = -20 }))
        dropped.age, dropped.worldEffect = 4, "ATTRACT_SMALL_FISH"
        env.runtime.ship.position = { x = -17, y = -20 }
        local after = Persistence.Snapshot(env.loop.player)
        sameValue(after, before, "snapshot")
        assert(after.recognizedLocations["saved-harbor"] == true, "B discovery remains saveable")
        assert(after.fish == nil and after.world == nil and after.shipPosition == nil,
            "A coordinates and entity state must not enter B persistence")
    end)

    check("new run resets B discovery and A temporary fish while preserving fixed objects and ship", function()
        local env = fixture({ initializeRegions = true, daySeed = 4096 })
        env.loop.player:MarkRecognized("known-island")
        local oldFish = liveFish(env.runtime)
        assert(#oldFish > 0, "fixture should have generated regional fish")
        local oldFishIds = {}
        for _, fish in ipairs(oldFish) do oldFishIds[fish.id] = true end
        local temporary = assert(env.runtime:spawnDroppedItem({ itemId = "test", lifetimeSec = 20 }, { x = -19, y = -20 }))
        local fixed, ship = {}, env.runtime.ship
        for _, entity in ipairs(env.runtime.world.entities) do
            if entity.kind == "fixed" then fixed[entity.id] = entity end
        end
        local ok = env.bridge:NewRun()
        assert(ok and env.hooks.resets == 1)
        assert(not env.loop.player:IsRecognized("known-island"))
        assert(env.runtime.ship == ship and env.runtime.world:get(ship.id) == ship)
        assert(not env.runtime.world:get(temporary.id))
        local counts = env.runtime.world:getCounts()
        assert(counts.temp == 0 and counts.sardine + counts.tuna > 0)
        for id in pairs(oldFishIds) do assert(not env.runtime.world:get(id), "old fish survived NewRun") end
        for id, entity in pairs(fixed) do assert(env.runtime.world:get(id) == entity, "fixed object changed") end
        assert(env.runtime.paused and env.loop.inPort)
    end)

    check("new-day world refresh waits for save success and retry is idempotent", function()
        local store = memoryStore()
        local env = fixture({ initializeRegions = true, daySeed = Config.world.seed, store = store })
        local initialSeed = env.runtime.daySeed
        local oldFish = liveFish(env.runtime)
        assert(#oldFish > 0)
        local oldFishIds = {}
        for _, fish in ipairs(oldFish) do oldFishIds[fish.id] = true end
        local fixed, ship = {}, env.runtime.ship
        for _, entity in ipairs(env.runtime.world.entities) do
            if entity.kind == "fixed" then fixed[entity.id] = entity end
        end
        local temporary = assert(env.runtime:spawnDroppedItem({ itemId = "test", lifetimeSec = 20 }, { x = -19, y = -20 }))
        assert(env.loop:EndToday())
        assert(env.loop:ConfirmSettlement())
        assert(#store.saves == 1 and env.loop.player.day == 2)
        store.saveCallbacks[1](false, "offline")
        assert(env.loop.saveStatus == "error" and env.runtime.daySeed == initialSeed)
        assert(env.runtime.world:get(temporary.id) and #liveFish(env.runtime) == #oldFish)
        assert(#env.hooks.newDays == 0)

        assert(env.loop:ConfirmSettlement())
        assert(#store.saves == 2 and store.saves[1].day == store.saves[2].day)
        store.saveCallbacks[2](true)
        local expectedSeed = Config.world.seed + env.loop.player.day - 1
        assert(env.runtime.daySeed == expectedSeed and env.runtime.world.daySeed == expectedSeed)
        assert(env.runtime.ship == ship and env.runtime.world:get(ship.id) == ship)
        assert(not env.runtime.world:get(temporary.id) and env.runtime.world:getCounts().temp == 0)
        assert(env.runtime.world:getCounts().sardine + env.runtime.world:getCounts().tuna > 0)
        assert(#env.hooks.newDays == 1 and env.hooks.newDays[1] == 2)
        for id in pairs(oldFishIds) do assert(not env.runtime.world:get(id), "old day's fish survived refresh") end
        for id, entity in pairs(fixed) do assert(env.runtime.world:get(id) == entity, "fixed object changed") end
        store.saveCallbacks[1](true)
        store.saveCallbacks[2](true)
        assert(#env.hooks.newDays == 1 and env.runtime.daySeed == expectedSeed)
    end)

    check("explicit unsaved continuation refreshes the sea once and releases settlement pause", function()
        local store = memoryStore()
        local env = fixture({ initializeRegions = true, daySeed = Config.world.seed, store = store })
        local oldFish = liveFish(env.runtime)
        local temporary = assert(env.runtime:spawnDroppedItem({ itemId = "test", lifetimeSec = 20 }, { x = -19, y = -20 }))
        assert(env.loop:EndToday()); assert(env.loop:ConfirmSettlement())
        store.saveCallbacks[1](false, "offline")
        assert(env.loop:ContinueWithoutSaving())
        assert(env.loop.player.day == 2 and env.loop.saveStatus == "skipped")
        assert(env.runtime.daySeed == Config.world.seed + 1)
        assert(not env.runtime.world:get(temporary.id) and #liveFish(env.runtime) > 0)
        for _, fish in ipairs(oldFish) do assert(not env.runtime.world:get(fish.id)) end
        assert(#env.hooks.newDays == 1 and #store.saves == 1)
        assert(not env.loop:ContinueWithoutSaving())
        store.saveCallbacks[1](true)
        assert(#env.hooks.newDays == 1 and env.loop.saveStatus == "skipped")
        assert(env.runtime.paused and env.loop.inPort)
        assert(env.loop:Depart()); assert(not env.runtime.paused)
    end)

    check("successful load restores saved boat speed and refreshes A before one callback", function()
        local store = memoryStore()
        local env = fixture({ initializeRegions = true, store = store })
        local oldFish = liveFish(env.runtime)
        assert(#oldFish > 0)
        local oldFishIds = {}
        for _, fish in ipairs(oldFish) do oldFishIds[fish.id] = true end
        local temporary = assert(env.runtime:spawnDroppedItem({ itemId = "test", lifetimeSec = 20 }, { x = -19, y = -20 }))
        local savedPlayer = assert(Player.New())
        savedPlayer.day, savedPlayer.boatSpeedLevel = 7, 3
        savedPlayer:MarkRecognized("saved-location")
        local snapshot = Persistence.Snapshot(savedPlayer)
        local callbackCount, callbackOk = 0, false
        local started = env.bridge:LoadSaved(function(ok, data)
            callbackCount, callbackOk = callbackCount + 1, ok
            assert(data == snapshot or data == nil)
        end)
        assert(started and env.loop.loading)
        assert(env.runtime.daySeed ~= Config.world.seed + 6)
        store.loadCallbacks[1](true, snapshot)
        local expectedSeed = Config.world.seed + 6
        assert(callbackCount == 1 and callbackOk)
        assert(env.loop.player.day == 7 and env.loop.player.boatSpeedLevel == 3)
        assert(env.runtime.movement.level == 3 and env.runtime.ship.level == 3)
        assert(env.runtime.daySeed == expectedSeed and env.runtime.world.daySeed == expectedSeed)
        assert(not env.runtime.world:get(temporary.id) and env.runtime.world:getCounts().temp == 0)
        assert(env.runtime.world:getCounts().sardine + env.runtime.world:getCounts().tuna > 0)
        for id in pairs(oldFishIds) do assert(not env.runtime.world:get(id), "saved-day load kept stale fish") end
        store.loadCallbacks[1](false, "late callback")
        assert(callbackCount == 1 and env.runtime.movement.level == 3)
    end)

    check("offline load fails explicitly without calling a cloud adapter", function()
        local calls = 0
        local previousCloud = _G.clientCloud
        _G.clientCloud = nil
        local env = fixture({ noStore = true })
        _G.clientCloud = {
            Get = function() calls = calls + 1; error("cloud must not be called") end,
            Set = function() calls = calls + 1; error("cloud must not be called") end,
        }
        local callbackCount, callbackOk, callbackError = 0, true, ""
        local callOk, started = pcall(env.bridge.LoadSaved, env.bridge, function(ok, data)
            callbackCount, callbackOk, callbackError = callbackCount + 1, ok, tostring(data)
        end)
        _G.clientCloud = previousCloud
        assert(callOk and started and callbackCount == 1 and not callbackOk)
        assert(calls == 0 and callbackError:find("cloud_unavailable", 1, true))
        assert(env.loop.loading == false and env.loop.player.day == 1)
    end)

    local scene = { ready = false }
    check("Scene starts one B HUD over A renderer and shows offline status without legacy HUD", function()
        scene.context = sceneHarness()
        scene.ready = true
        local context, sea = scene.context, scene.context.sea
        assert(context.ui.initialized == 1 and context.ui.roots == 1)
        assert(sea.loop == sea.bridge.loop and sea.hud and sea.uiRoot)
        assert(sea.loop.inPort and sea.loop.clock.pauseReasons.port and sea.runtime.paused)
        assert(sea.uiRoot.props.pointerEvents == "box-none")
        assert(context.oceanHudCreateCalls() == 0, "legacy Ocean.HUD must not create a second subtree")
        assert(not sea.uiRoot:FindById("oceanRoot"), "legacy ocean HUD subtree must be absent")
        assert(sea.uiRoot:FindById("offlinePersistenceNotice"), "offline mode must explain save availability")
        assert(sea.uiRoot:FindById("offlinePersistenceNotice").props.pointerEvents == "none")
        assert(sea.uiRoot:FindById("seaDebugRoot"), "original sea debug tools should share the root")
        assert(not sea.uiRoot:FindById("seaDebugPanel").visible, "the debug panel starts hidden")
        local hudChildren = sea.hud.root:GetChildren()
        assert(hudChildren[1].props.width <= 620 and hudChildren[1].props.maxWidth <= 620)
        assert(hudChildren[6].props.pointerEvents == "box-none", "empty sea clicks must pass through the content scroll")
        assert(#context.events == 5, "one event owner should install five engine handlers")
    end)

    check("Scene ticks B once, gates pointer input immediately and records the sea pointer drop target", function()
        assert(scene.ready, "Scene startup failed in its own test")
        local context, sea = scene.context, scene.context.sea
        assert(sea.loop:Depart()) -- Bridge wraps loop actions and synchronizes A immediately.
        assert(not sea.runtime.paused)
        local debugPause = sea.uiRoot:FindById("seaDebugPause")
        assert(debugPause, "the original hidden A debug panel remains available")
        debugPause:Click()
        assert(sea.loop.clock.pauseReasons.manual and sea.runtime.paused,
            "A debug pause must route through the B manual clock reason")
        debugPause:Click()
        assert(not sea.loop.clock.pauseReasons.manual and not sea.runtime.paused)
        sea:Update(0.1)
        near(sea.loop.clock.elapsed, 0.1, 0.000001, "B clock after Scene Update")
        near(sea.runtime.time, 0.1, 0.000001, "A world after Scene Update")

        local inventoryButton = findByText(sea.hud.root, "背包")
        assert(inventoryButton)
        inventoryButton:Click()
        assert(sea.loop.inventoryOpen and sea.runtime.paused, "inventory should pause A immediately")
        assert(not sea:HandlePointer(1200, 648), "paused inventory must block pointer input immediately")
        inventoryButton:Click()
        assert(not sea.loop.inventoryOpen and not sea.runtime.paused)
        assert(sea.loop:SetElderOpen(true))
        assert(sea.loop.elderOpen and sea.runtime.paused, "elder pause must sync to A immediately")
        assert(not sea:HandlePointer(1200, 648))
        assert(sea.loop:SetElderOpen(false) and not sea.runtime.paused)

        local keyDown = eventHandler(context, "KeyDown")
        assert(keyDown)
        keyDown(nil, nil, {
            GetBool = function(_, key) return key == "Repeat" and false or false end,
            GetInt = function(_, key) return key == "Key" and KEY_SPACE or 0 end,
        })
        assert(sea.loop.clock.pauseReasons.manual and sea.runtime.paused,
            "scene pause input must use the B clock's manual reason")
        assert(not sea:HandlePointer(1200, 648))
        sea.tools.handleKey(KEY_SPACE)
        assert(not sea.loop.clock.pauseReasons.manual and not sea.runtime.paused)

        context.ui.hit = {}
        assert(not sea:HandlePointer(1200, 648), "a UI overlay hit must not become a sea target")
        local before = sea.loop.player.inventory:GetItems()
        assert(not sea.loop:DropItem(1), "the blocked UI click must leave no selected drop target")
        sameItems(sea.loop.player, before)
        context.ui.hit = nil

        local target = sea.runtime.movement:ScreenToWorld(600, 324)
        assert(sea:HandlePointer(1200, 648), "empty sea click should select the drop target")
        assert(sea.loop:DropItem(1))
        local dropped = findDrop(sea.runtime, "apple")
        assert(dropped)
        near(dropped.position.x, target.x, 0.000001, "scene pointer drop x")
        near(dropped.position.y, target.y, 0.000001, "scene pointer drop y")

        sea:Render()
        assert(context.drawCalls() == 1 and context.lastDraw().runtime == sea.runtime,
            "the existing SeaDraw scene remains the renderer contract")
        assert(context.lastDraw().width == 960 and context.lastDraw().height == 540)
    end)

    check("Scene offline store returns a clear error and never touches cloud or auto-loads", function()
        assert(scene.ready, "Scene startup failed in its own test")
        local context, sea = scene.context, scene.context.sea
        assert(not sea.loop.loading and sea.loop.player.day == 1,
            "loadSaved defaults off in a fresh offline scene")
        assert(sea.loop:ReturnToPort(), "LoadSaved requires the sea loop to be at port")
        local calls, callbackCount, callbackOk, reason = 0, 0, true, ""
        local previousCloud = _G.clientCloud
        _G.clientCloud = {
            Get = function() calls = calls + 1; error("cloud must not be called") end,
            Set = function() calls = calls + 1; error("cloud must not be called") end,
        }
        local callOk, started = pcall(sea.bridge.LoadSaved, sea.bridge, function(ok, data)
            callbackCount, callbackOk, reason = callbackCount + 1, ok, tostring(data)
        end)
        _G.clientCloud = previousCloud
        assert(callOk and started and callbackCount == 1 and not callbackOk)
        assert(reason:find("offline_persistence_unavailable", 1, true))
        assert(calls == 0)
        assert(sea.uiRoot:FindById("offlinePersistenceNotice"))
    end)

    check("Scene Stop releases five subscriptions, renderer, HUD and UI exactly once", function()
        assert(scene.ready, "Scene startup failed in its own test")
        local context, sea = scene.context, scene.context.sea
        local hudRoot = sea.hud.root
        sea:Stop()
        sea:Stop()
        assert(context.eventNode.unsubscribed == 1 and context.eventNode.removed == 1)
        assert(context.nvgDeletes() == 1 and context.ui.shutdowns == 1)
        assert(hudRoot.destroyed)
        assert(hudRoot.parent == nil, "stopped B HUD root must be detached")
        assert(not sea:HandlePointer(1200, 648))
    end)

    if scene.context and scene.context.cleanup then pcall(scene.context.cleanup) end
    return { results = results }
end

return Tests
