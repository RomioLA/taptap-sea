-- B5 gameplay diagnostics and port-access checks; all UI, cloud, and print
-- bindings are local test doubles. No native engine or remote service is used.
local Loop = require('Gameplay.Loop')
local Persistence = require('Gameplay.Persistence')

local Tests = {}

local function memoryStore()
    return {
        Save = function(_, _, done) done(true) end,
        Load = function(_, done) done(true, nil) end,
    }
end

local function portRuntime(distance)
    local runtime = { ship = { x = distance or 0, y = 0 }, port = { x = 0, y = 0 } }
    function runtime:GetShipPosition() return { x = self.ship.x, y = self.ship.y } end
    function runtime:GetPortPosition() return { x = self.port.x, y = self.port.y } end
    function runtime:ClearMovementTarget() return true end
    function runtime:ResetShipAtPort() self.ship = { x = self.port.x, y = self.port.y }; return true end
    return runtime
end

local function uiHost()
    local UI = { Scale = { DEFAULT = 1 } }
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
    function Widget:GetChildren() return self.children end
    function Widget:ClearChildren() self.children = {} end
    function Widget:SetText(value) self.props.text = value end
    function Widget:SetDisabled(value) self.disabled = value end
    function Widget:SetVisible(value) self.visible = value end
    function Widget:IsVisible() return self.visible end
    function Widget:Show() self.visible = true end
    function Widget:Hide() self.visible = false end
    function Widget:Destroy()
        self.destroyed = true
        if self.parent then self.parent:RemoveChild(self) end
    end
    local function makeWidget(kind)
        return function(props)
            props = props or {}
            local widget = setmetatable({
                kind = kind, props = props, children = {}, visible = props.visible ~= false,
            }, Widget)
            for _, child in ipairs(props.children or {}) do widget:AddChild(child) end
            return widget
        end
    end
    for _, kind in ipairs({ 'Panel', 'SafeAreaView', 'Label', 'Button', 'Spacer', 'ScrollView', 'TextField' }) do
        UI[kind] = makeWidget(kind)
    end
    function UI.Init() end
    function UI.Shutdown() end
    function UI.GetScale() return 1 end
    UI.Input = { On = function() return 1 end, Off = function() end }
    return UI
end

local function findWidget(widget, predicate)
    if predicate(widget) then return widget end
    for _, child in ipairs(widget.children or {}) do
        local found = findWidget(child, predicate)
        if found then return found end
    end
end

local function countLines(lines, fragment)
    local count = 0
    for _, line in ipairs(lines) do
        if line:find(fragment, 1, true) then count = count + 1 end
    end
    return count
end

local function countEvent(lines, event, kind, result)
    local count = 0
    for _, line in ipairs(lines) do
        if line:find('[Loop][' .. event .. ']', 1, true)
            and line:find('kind="' .. kind .. '"', 1, true)
            and line:find('result="' .. result .. '"', 1, true) then
            count = count + 1
        end
    end
    return count
end

function Tests.Run()
    local results = {}
    local originalPrint = print
    local function check(name, fn)
        local ok, err = xpcall(fn, debug.traceback)
        print = originalPrint
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check('port boundary, HUD readout, and return gate agree at 9.999, 10, and 10.001 meters', function()
        local oldUI, oldHUD = package.loaded['urhox-libs/UI'], package.loaded['Gameplay.HUD']
        package.loaded['urhox-libs/UI'] = uiHost()
        package.loaded['Gameplay.HUD'] = nil
        local ok, err = xpcall(function()
            local HUD = require('Gameplay.HUD')
            local loop = Loop.New({ store = memoryStore() })
            local runtime = portRuntime(0)
            loop.runtime, loop.inPort = runtime, false
            local hud = HUD.Create(loop)
            for _, distance in ipairs({ 9.999, 10, 10.001 }) do
                runtime.ship = { x = distance, y = 0 }
                loop.inPort = false
                local access, reason, details = loop:CanAccessPort()
                assert(details and math.abs(details.distance - distance) < 1e-9 and details.radius == 10)
                local expected = distance <= details.radius
                assert(access == expected)
                assert((reason == nil) == expected)
                hud.Refresh()
                local label = assert(findWidget(hud.root, function(widget)
                    return widget.kind == 'Label' and type(widget.props.text) == 'string'
                        and widget.props.text:find('锚形标记=港口', 1, true) == 1
                end), 'port access label missing')
                assert(label.props.text:find(string.format('%.3f', distance), 1, true))
                assert(label.props.text:find(expected and '范围内，可返港/交易' or '范围外，需≤10米才可返港/交易', 1, true))
                local returned, returnReason = loop:ReturnToPort()
                assert(returned == expected)
                assert((returnReason == nil) == expected)
                if not expected then assert(returnReason == 'port_out_of_range') end
            end
            hud.Destroy()
        end, debug.traceback)
        package.loaded['urhox-libs/UI'], package.loaded['Gameplay.HUD'] = oldUI, oldHUD
        assert(ok, err)
    end)

    check('busy and pending-catch port gates retain position details; claim logs use the original action ID', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local loop = Loop.New({ store = memoryStore() })
        loop.runtime = portRuntime(2)
        loop.busy = true
        local accepted, reason = loop:ReturnToPort()
        assert(not accepted and reason == 'busy')
        assert(lines[#lines]:find('reason="busy"', 1, true))
        assert(lines[#lines]:find('position_status="available"', 1, true))
        loop.busy = false
        local actions = loop:EnableWorldActions()
        local token = {}
        actions._fishingTokens[token] = { id = 91, generation = loop.generation, seaGeneration = 3, targetId = 'fish-91' }
        actions._pendingCatch = { itemIds = {}, token = token, claiming = true }
        accepted, reason = loop:ReturnToPort()
        assert(not accepted and reason == 'pending_catch_required')
        assert(lines[#lines]:find('reason="pending_catch_required"', 1, true))
        local claimOk, claimReason = actions:ClaimPendingCatch()
        assert(not claimOk and claimReason == 'busy')
        assert(lines[#lines]:find('pending_catch_claim', 1, true))
        assert(lines[#lines]:find('action_id="91"', 1, true))
    end)

    check('inventory rollback exception is logged once with stack and recovery is logged after success', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local loop = Loop.New({ store = memoryStore() })
        loop.inventoryRollback = { items = {}, stamina = 10 }
        local attempts = 0
        loop.RestoreActionResources = function()
            attempts = attempts + 1
            if attempts <= 2 then error('inventory_restore_first_failure', 0) end
            return true
        end
        local ok, reason = loop:RetryInventoryRollback()
        assert(not ok and reason == 'inventory_rollback_pending')
        assert(not loop:RetryInventoryRollback())
        assert(countLines(lines, 'inventory_restore_first_failure') == 1)
        assert(lines[1]:find('stack=', 1, true))
        assert(loop:RetryInventoryRollback())
        assert(loop.inventoryRollback == nil)
        assert(countLines(lines, 'result="recovered"') == 1)
    end)

    check('return-to-port performs one diagnosed position read after a transient exception', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local loop = Loop.New({ store = memoryStore() })
        local runtime = portRuntime(0)
        local reads = 0
        runtime.GetShipPosition = function(self)
            reads = reads + 1
            if reads == 1 then error('first_position_read_failure', 0) end
            return { x = self.ship.x, y = self.ship.y }
        end
        loop.runtime, loop.inPort = runtime, false
        local returned, reason = loop:ReturnToPort()
        assert(not returned and reason == 'port_interface_unavailable' and reads == 1)
        assert(countLines(lines, 'first_position_read_failure') == 1)
        assert(lines[1]:find('stack=', 1, true))

        lines = {}
        local cargoLoop = Loop.New({ store = memoryStore() })
        local inventory = cargoLoop.player.inventory
        local originalGetItems = inventory.GetItems
        inventory.GetItems = function() error('cargo_snapshot_original_failure', 0) end
        local removed, removeReason = cargoLoop:RemoveCargo(1)
        inventory.GetItems = originalGetItems
        assert(not removed and removeReason == 'inventory_snapshot_failed')
        assert(countLines(lines, 'cargo_snapshot_original_failure') == 1)
        assert(lines[1]:find('stack=', 1, true))
    end)

    check('selection cancellation is logged once and exhausted updates without a selection stay quiet', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local loop = Loop.New({ store = memoryStore() })
        local runtime = portRuntime(20)
        loop.runtime, loop.inPort = runtime, false
        local actions = loop:EnableWorldActions()
        actions:BindRuntime(runtime)
        loop.clock:Resume('port')
        assert(actions:BeginSelection())
        assert(loop:CancelFishingAction())
        assert(countLines(lines, 'fishing_selection_cancelled') == 1)
        lines = {}
        loop.clock.exhausted = true
        loop.dayExhausted = true
        loop.clock:Pause('forced_return')
        for _ = 1, 8 do loop:Update(1 / 60) end
        assert(#lines == 0)
    end)

    check('false rollback and unlock steps log once, then emit a recovered rollback and terminal event', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local loop = Loop.New({ store = memoryStore() })
        local actions = loop:EnableWorldActions()
        local resourceRestored, worldRestored, unlocked = false, false, false
        loop.RestoreActionResources = function() return resourceRestored end
        local runtime = {
            GetFishingGeneration = function() return 4 end,
            RestoreFishingTarget = function() return worldRestored end,
            UnlockFishingTarget = function() return unlocked end,
        }
        local record = {
            id = 74, token = {}, runtime = runtime, generation = loop.generation, seaGeneration = 4,
            targetId = 'fish-74', state = 'rollback_pending', reason = 'cancelled', elapsed = 0,
            rollback = { items = {}, stamina = 10, target = {}, snapshot = {} },
        }
        actions._pendingFishing = record
        local ok, reason = actions:FinishAbort(record)
        assert(not ok and reason == 'fishing_rollback_pending')
        assert(not actions:FinishAbort(record))
        assert(countLines(lines, 'stage="resource_restore"') == 1)
        resourceRestored = true
        ok, reason = actions:FinishAbort(record)
        assert(not ok and reason == 'fishing_rollback_pending')
        assert(not actions:FinishAbort(record))
        assert(countLines(lines, 'stage="world_restore"') == 1)
        worldRestored = true
        ok, reason = actions:FinishAbort(record)
        assert(not ok and reason == 'fishing_cleanup_pending')
        assert(countLines(lines, 'result="recovered"') == 1)
        assert(countLines(lines, 'stage="target_unlock"') == 1)
        assert(not actions:FinishAbort(record))
        assert(countLines(lines, 'stage="target_unlock"') == 1)
        unlocked = true
        assert(actions:FinishAbort(record))
        assert(countLines(lines, 'result="cancelled"') == 1)
    end)

    check('save/load callback reasons remain raw to callers while Loop logs use fixed categories', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local cloud = {
            Set = function(_, _, _, events) events.error(403, 'PRIVATE_SAVE_CONTENTS') end,
            Get = function(_, _, events) events.error(403, 'PRIVATE_LOAD_CONTENTS') end,
        }
        local store = Persistence.Cloud(cloud)
        local saveOk, saveReason
        store:Save({}, function(ok, reason) saveOk, saveReason = ok, reason end)
        assert(saveOk == false and saveReason == '403:PRIVATE_SAVE_CONTENTS')
        local loop = Loop.New({ store = store })
        loop:BeginEntry()
        assert(loop:SaveInitialState())
        assert(loop.initialSaveStatus == 'error')
        local loadOk, loadReason
        assert(loop:LoadSaved(function(ok, reason) loadOk, loadReason = ok, reason end))
        assert(loadOk == false and loadReason == '403:PRIVATE_LOAD_CONTENTS')
        assert(loop.loadStatus == 'error')
        local joined = table.concat(lines, '\n')
        assert(joined:find('reason="backend_failure"', 1, true))
        assert(not joined:find('PRIVATE_SAVE_CONTENTS', 1, true))
        assert(not joined:find('PRIVATE_LOAD_CONTENTS', 1, true))
    end)

    check('operation wrapper captures the original stack and output failures cannot change results', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local expectedError = 'wrapped_original_failure'
        local loop = Loop.New({ store = memoryStore() })
        loop.NewRun = function() error(expectedError, 0) end
        loop:SetStateObserver(function() end)
        local ok, err = pcall(function() loop:NewRun() end)
        assert(not ok and err == expectedError)
        local joined = table.concat(lines, '\n')
        assert(joined:find('operation_NewRun', 1, true))
        assert(joined:find('error="wrapped_original_failure"', 1, true))
        assert(joined:find('stack=', 1, true))

        loop = Loop.New({ store = memoryStore() })
        loop.runtime, loop.inPort = portRuntime(9.999), false
        print = function() error('output sink failure') end
        local returned, reason = loop:ReturnToPort()
        print = originalPrint
        assert(returned and reason == nil)
    end)

    check('new-day and new-run preparation log start, rejection, and success', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local loop = Loop.New({ store = memoryStore() })
        local started, reason = loop:BeginNewDay()
        assert(not started and reason == 'settlement_required')
        assert(countEvent(lines, 'new_day_preparation', 'operation', 'started') == 1)
        assert(countEvent(lines, 'new_day_preparation', 'rejected', 'rejected') == 1)
        lines = {}
        loop.settlementPending, loop.portPreparedForSettlement = true, true
        assert(loop:BeginNewDay())
        assert(countLines(lines, 'result="started"') == 1)
        assert(countLines(lines, 'result="prepared"') == 1)

        lines = {}
        local fresh = Loop.New({ store = memoryStore() })
        assert(fresh:NewRun())
        assert(countEvent(lines, 'new_run_preparation', 'operation', 'started') == 1)
        assert(countEvent(lines, 'new_run_preparation', 'operation', 'prepared') == 1)
        assert(fresh.initialSaveStatus == 'saved')
        lines = {}
        fresh.closed = true
        local newRunOk, newRunReason = fresh:NewRun()
        assert(not newRunOk and newRunReason == 'scene_closed')
        assert(countEvent(lines, 'new_run_preparation', 'operation', 'started') == 1)
        assert(countEvent(lines, 'new_run_preparation', 'rejected', 'rejected') == 1)
    end)

    print = originalPrint
    return { results = results, evidenceKind = 'offline Lua 5.4 gameplay/Loop/HUD checks with local print, UI, cloud, and Runtime doubles' }
end

return Tests
