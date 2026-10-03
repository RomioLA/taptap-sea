-- Offline actual Lua modules; print/cloud/UI bindings here are test doubles.
local Diagnostics = require('Gameplay.Diagnostics')
local Runtime = require('Ocean.SeaRuntime')
local Bridge = require('Integration.Bridge')
local Loop = require('Gameplay.Loop')
local Persistence = require('Gameplay.Persistence')
local Tests = {}
local function memoryStore()
    return { Save=function(_, _, done) done(true) end,
        Load=function(_, done) done(true, nil) end }
end

function Tests.Run()
    local results = {}
    local originalPrint = print
    local function check(name, fn)
        local ok, err = xpcall(fn, debug.traceback)
        print = originalPrint
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end
    check('diagnostics preserve nil return arity and original error object', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        ---@type table
        local values = table.pack(Diagnostics.Call('test', 'tuple', function() return nil, false, nil, 7 end))
        assert(values.n == 5 and values[1] and values[2] == nil and values[3] == false and values[5] == 7)
        local raw = {}
        local ok, err = Diagnostics.Call('test', 'exception', function() error(raw) end)
        assert(not ok and err == raw and #lines == 1)
        assert(lines[1]:find('kind="exception"', 1, true) and lines[1]:find('stack=', 1, true))
    end)
    check('scalar allowlist and sensitive text redaction omit save contents', function()
        local line = ''
        print = function(value) line = value end
        Diagnostics.Event('test', 'privacy', {kind='failure', reason='Bearer SECRET token=ABC password=PWD userId=123 "api_key":"KEY"', snapshot='SAVE_CONTENTS', payload={nested='SAVE_CONTENTS'}, account='ACCOUNT_CONTENTS'})
        assert(line and not line:find('SECRET', 1, true) and not line:find('ABC', 1, true)
            and not line:find('PWD', 1, true) and not line:find('SAVE_CONTENTS', 1, true)
            and not line:find('ACCOUNT_CONTENTS', 1, true) and not line:find('123', 1, true)
            and not line:find('KEY', 1, true))
    end)
    check('formatter print and traceback failures cannot change operation results', function()
        print = function() error('output sink broken') end
        Diagnostics.Event('test', 'rejected', setmetatable({}, {__pairs=function() error('formatter broken') end}))
        local ok, value = Diagnostics.Call('test', 'success', function() return 23 end)
        assert(ok and value == 23)
        local trace = debug.traceback
        debug.traceback = function() error('trace broken') end
        local failed, raw = Diagnostics.Call('test', 'failure', function() error('original failure', 0) end)
        debug.traceback = trace
        assert(not failed and raw == 'original failure')
    end)
    check('SDK failure details are preserved for callbacks but withheld from operation logs', function()
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        local backend = {
            Get=function(_, _, events) events.error(401, 'PRIVATE_ACCOUNT_DETAILS') end,
            Set=function(_, _, _, events) events.error(500, 'PRIVATE_SAVE_CONTENTS') end,
        }
        local loop = Loop.New({store=Persistence.Cloud(backend)})
        local callbackReason = ''
        assert(loop:LoadSaved(function(ok, reason)
            assert(not ok)
            callbackReason = reason
        end))
        assert(callbackReason == '401:PRIVATE_ACCOUNT_DETAILS', 'diagnostics altered backend result')
        loop:BeginEntry()
        loop:SaveInitialState()
        assert(loop.initialSaveStatus == 'error')
        local log = table.concat(lines, '\n')
        assert(not log:find('PRIVATE_ACCOUNT_DETAILS', 1, true) and not log:find('PRIVATE_SAVE_CONTENTS', 1, true))
        assert(not log:find('kind="exception"', 1, true), 'SDK error callback classified as program exception')
    end)
    check('per-frame integration getter exception logs once until recovery', function()
        local runtime = Runtime.New({initializeRegions=false})
        local bridge = Bridge.New(runtime, {store=memoryStore()})
        local getter = runtime.GetFixedBarrel
        local lines = {}
        print = function(line) lines[#lines + 1] = line end
        runtime.GetFixedBarrel = function() error('original barrel read failure', 0) end
        for _ = 1, 12 do assert(bridge:Update(0)) end
        assert(#lines == 1 and lines[1]:find('original barrel read failure', 1, true))
        runtime.GetFixedBarrel = getter
        assert(bridge:Update(0))
        runtime.GetFixedBarrel = function() error('second failure', 0) end
        assert(bridge:Update(0))
        assert(#lines == 2)
    end)
    for _, target in ipairs({{x=0,y=0}, {x=10,y=0}}) do
        check('actual normal-navigation return at target ' .. target.x, function()
            local runtime = Runtime.New({departure={x=30,y=0}})
            local bridge = Bridge.New(runtime, {store=memoryStore()})
            local loop = bridge.loop
            assert(loop:Depart())
            runtime.ResetShipAtPort = function() error('normal return must not teleport') end
            runtime.movement:SetTarget(target)
            for _ = 1, 600 do assert(bridge:Update(1/60, 0, 0)) end
            local ship, port = runtime:GetShipPosition(), runtime:GetPortPosition()
            local x, y = ship.x, ship.y
            local distance = math.sqrt((x-port.x)^2+(y-port.y)^2)
            assert(runtime.movement.target == nil)
            local accepted, reason = loop:ReturnToPort()
            if target.x == 0 then assert(accepted and distance <= 10)
            else assert(not accepted and reason == 'port_out_of_range' and distance > 11 and distance < 12) end
            local after = runtime:GetShipPosition()
            assert(after.x == x and after.y == y, 'normal port request moved ship')
        end)
    end
    return {results=results, evidenceKind='offline real Runtime/Movement/Bridge/Loop; print and store doubles; no native engine'}
end
return Tests
