-- B5 persistence/barrel diagnostics tests use fake stores and the real Gameplay modules.
local Config = require("config.gameplay")
local Diagnostics = require("Gameplay.Diagnostics")
local Loop = require("Gameplay.Loop")
local Persistence = require("Gameplay.Persistence")
local Progress = require("Gameplay.Circle1B2Progress")
local Flow = require("tests.Circle1BFishingFlowTests")

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function withLogs(run, failPrint)
    local originalPrint = print
    local logs = {}
    if failPrint then
        print = function() error("injected_diagnostic_print_failure") end
    else
        print = function(...)
            local parts = {}
            for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
            logs[#logs + 1] = table.concat(parts, " ")
        end
    end
    local result = table.pack(xpcall(run, debug.traceback))
    print = originalPrint
    if not result[1] then error(result[2], 0) end
    return logs, table.unpack(result, 2, result.n)
end

local function contains(logs, text)
    for _, line in ipairs(logs) do
        if string.find(line, text, 1, true) then return true end
    end
    return false
end

local function count(logs, text)
    local result = 0
    for _, line in ipairs(logs) do
        if string.find(line, text, 1, true) then result = result + 1 end
    end
    return result
end

local function fixture()
    local f = Flow.Fixture()
    local runtime = f.runtime
    runtime.fixedBarrelId = "barrel-log-safe"
    runtime.fixedBarrelGeneration = 37
    runtime.fixedBarrelPosition = { x = 1, y = 0 }
    function runtime:GetFixedBarrel()
        return { id = self.fixedBarrelId, contentId = "driftwood_barrel",
            generation = self.fixedBarrelGeneration,
            position = { x = self.fixedBarrelPosition.x, y = self.fixedBarrelPosition.y } }
    end
    function runtime:CanInteractWithBarrel(id, generation)
        if id ~= self.fixedBarrelId or generation ~= self.fixedBarrelGeneration then
            return false, "stale_barrel_world"
        end
        return true
    end
    assert(f.loop:Depart())
    return f
end

local function installExecutor(loop)
    local state = { request = nil, done = nil, cancelCalls = 0 }
    loop.options.barrelActionExecutor = function(request, done)
        state.request, state.done = request, done
        return function() state.cancelCalls = state.cancelCalls + 1 end
    end
    return state
end

local function withPatched(target, key, replacement, run)
    local original = target[key]
    target[key] = replacement(original)
    local result = table.pack(xpcall(run, debug.traceback))
    target[key] = original
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("barrel start, evidence rejection, completion and duplicate callback keep action identity", function()
        local logs = withLogs(function()
            local f = fixture()
            local action = installExecutor(f.loop)
            local token = assert(f.loop:BeginBarrelInspection())
            assert(type(token) == "table")
            eq(action.request.id, "barrel-log-safe")
            eq(action.request.generation, 37)
            eq(action.request.stage, 0)

            local rejected, rejectReason = action.done({ completed = true, durationSec = 3,
                payload = "payload-must-not-be-logged" })
            eq(rejected, false)
            eq(rejectReason, "barrel_action_not_completed")
            eq(f.loop.player.stamina, 100)
            eq(f.loop:GetBarrelState().active, true)

            local completed, outcome = action.done({ completed = true, durationSec = Config.barrel.durationSec,
                payload = { marker = "payload-must-not-be-logged" } })
            eq(completed, true)
            eq(outcome, "rewarded")
            eq(f.loop.player.stamina, 60)
            eq(f.loop:GetBarrelState().stage, 1)
            local replay, replayOutcome = action.done({ completed = true, durationSec = Config.barrel.durationSec })
            eq(replay, true)
            eq(replayOutcome, outcome)
        end)
        assert(contains(logs, "[Jam][barrel][begin_started]"))
        assert(contains(logs, "[Jam][barrel][completion_rejected]"))
        assert(contains(logs, 'id="barrel-log-safe"'))
        assert(contains(logs, 'generation="37"'))
        assert(contains(logs, 'stage="0"'))
        assert(contains(logs, "actionId="))
        assert(contains(logs, "loopGeneration="))
        assert(contains(logs, "[Jam][barrel][completed]"))
        eq(count(logs, "[Jam][barrel][callback_ignored]"), 1)
        eq(count(logs, 'kind="exception"'), 0)
        assert(not contains(logs, "payload-must-not-be-logged"))
    end)

    test("barrel cancellation and commit exception roll back without changing failure results", function()
        local logs = withLogs(function()
            local cancelled = fixture()
            local first = installExecutor(cancelled.loop)
            local stamina = cancelled.loop.player.stamina
            assert(cancelled.loop:BeginBarrelInspection())
            assert(cancelled.loop:CancelBarrelInspection())
            eq(first.cancelCalls, 1)
            eq(cancelled.loop.player.stamina, stamina)
            eq(cancelled.loop:GetBarrelState().stage, 0)
            local late, lateReason = first.done({ completed = true, durationSec = Config.barrel.durationSec })
            eq(late, false)
            eq(lateReason, "cancelled")

            local failed = fixture()
            local second = installExecutor(failed.loop)
            local beforeItems = failed.loop.player.inventory:GetItems()
            local beforeStamina = failed.loop.player.stamina
            assert(failed.loop:BeginBarrelInspection())
            withPatched(Progress, "SetBarrelStage", function(original)
                return function(player, stage)
                    if stage == 1 then error("injected_barrel_commit_exception") end
                    return original(player, stage)
                end
            end, function()
                local accepted, reason = second.done({ completed = true, durationSec = Config.barrel.durationSec })
                eq(accepted, false)
                eq(reason, "barrel_commit_failed")
            end)
            eq(failed.loop.player.stamina, beforeStamina)
            eq(failed.loop:GetBarrelState().stage, 0)
            local afterItems = failed.loop.player.inventory:GetItems()
            eq(#afterItems, #beforeItems)
            for index, item in ipairs(beforeItems) do eq(afterItems[index], item) end
            eq(failed.loop:GetBarrelState().active, false)
        end)
        assert(contains(logs, "[Jam][barrel][cancelled]"))
        assert(contains(logs, "[Jam][barrel][action_failed]"))
        assert(contains(logs, 'kind="exception"'))
        assert(contains(logs, "injected_barrel_commit_exception"))
        assert(contains(logs, "[Jam][barrel][rollback_started]"))
        assert(contains(logs, "[Jam][barrel][rollback_completed]"))
        assert(contains(logs, "[Jam][barrel][callback_ignored]"))
    end)

    test("barrel rollback tick failures are logged once until recovery changes state", function()
        local logs = withLogs(function()
            local f = fixture()
            local action = installExecutor(f.loop)
            local beforeItems = f.loop.player.inventory:GetItems()
            assert(f.loop:BeginBarrelInspection())
            withPatched(Progress, "SetBarrelStage", function(original)
                return function(player, stage)
                    if stage == 1 then return false, "injected_stage_rejection" end
                    return original(player, stage)
                end
            end, function()
                withPatched(Loop, "RestoreActionResources", function()
                    return function() return false, "injected_rollback_rejection" end
                end, function()
                    local accepted, reason = action.done({ completed = true,
                        durationSec = Config.barrel.durationSec })
                    eq(accepted, false)
                    eq(reason, "barrel_commit_failed")
                    assert(f.loop:GetBarrelState().active)
                    f.loop.barrel:Tick()
                    f.loop.barrel:Tick()
                end)
            end)
            f.loop.barrel:Tick()
            eq(f.loop:GetBarrelState().active, false)
            eq(f.loop.player.stamina, 100)
            eq(f.loop:GetBarrelState().stage, 0)
            local afterItems = f.loop.player.inventory:GetItems()
            eq(#afterItems, #beforeItems)
            for index, item in ipairs(beforeItems) do eq(afterItems[index], item) end
        end)
        eq(count(logs, "[Jam][barrel][rollback_failed]"), 1)
        eq(count(logs, "[Jam][barrel][rollback_recovered]"), 1)
        eq(count(logs, 'kind="exception"'), 0)
    end)

    test("cloud save/load report only outcomes and ignore asynchronous failure replays", function()
        local logs = withLogs(function()
            local key = Config.persistence.key
            local snapshot = { schemaVersion = Config.persistence.schemaVersion,
                day = 1, privateMarker = "private-save-payload-must-not-be-logged" }
            local backend = { stored = nil }
            function backend:Set(_, value, events)
                self.stored = copy(value)
                self.saveEvents = events
            end
            function backend:Get(_, events) self.loadEvents = events end

            local store = Persistence.Cloud(backend)
            local saveCalls, saveOk = 0, nil
            eq(store:Save(snapshot, function(ok)
                saveCalls, saveOk = saveCalls + 1, ok
            end), true)
            eq(saveCalls, 0)
            backend.saveEvents.ok()
            backend.saveEvents.error(-7, "late-save-callback")
            backend.saveEvents.timeout()
            eq(saveCalls, 1)
            eq(saveOk, true)

            local loadCalls, loaded = 0, nil
            eq(store:Load(function(ok, value)
                loadCalls = loadCalls + 1
                eq(ok, true)
                loaded = value
            end), true)
            backend.loadEvents.ok({ [key] = backend.stored }, {})
            eq(loadCalls, 1)
            eq(loaded.privateMarker, snapshot.privateMarker)

            local failedBackend = {}
            function failedBackend:Set(_, _, events) self.events = events end
            local failedStore = Persistence.Cloud(failedBackend)
            local failedCalls, failedOk, failedReason = 0, nil, nil
            eq(failedStore:Save(snapshot, function(ok, reason)
                failedCalls, failedOk, failedReason = failedCalls + 1, ok, reason
            end), true)
            failedBackend.events.error("offline-code", "service-unavailable")
            failedBackend.events.ok()
            eq(failedCalls, 1)
            eq(failedOk, false)
            eq(failedReason, "offline-code:service-unavailable")

            local memory = { data = nil }
            function memory:Save(value, done)
                self.data = copy(value)
                if done then done(true) end
                return true
            end
            function memory:Load(done)
                if done then done(self.data ~= nil, copy(self.data)) end
                return true
            end
            local loop = Loop.New({ store = memory })
            assert(loop:NewRun())
            eq(loop.initialSaveStatus, "saved")
            local savedMoney = memory.data.money
            loop.player.money = savedMoney + 100
            assert(loop:LoadSaved())
            eq(loop.loadStatus, "loaded")
            eq(loop.player.money, savedMoney)
        end)
        assert(contains(logs, "[Jam][persistence][save_result]"))
        assert(contains(logs, "[Jam][persistence][load_result]"))
        assert(contains(logs, "[Jam][persistence][callback_ignored]"))
        assert(contains(logs, "[Jam][Loop][initial_save]"))
        assert(contains(logs, "[Jam][Loop][load]"))
        assert(contains(logs, 'kind="failure" operation="save"'))
        eq(count(logs, 'kind="exception"'), 0)
        assert(not contains(logs, "private-save-payload-must-not-be-logged"))
    end)

    test("raw exception identity and failed diagnostic printing do not alter business outcomes", function()
        local logs = withLogs(function()
            local sentinel = {}
            local ok, rawError = Diagnostics.Call("test", "raw_exception", function()
                error(sentinel, 0)
            end)
            eq(ok, false)
            eq(rawError, sentinel, "raw error object")

            local f = fixture()
            local action = installExecutor(f.loop)
            local beforeStamina = f.loop.player.stamina
            assert(f.loop:BeginBarrelInspection())
            local accepted, outcome = action.done({ completed = true, durationSec = Config.barrel.durationSec })
            eq(accepted, true)
            eq(outcome, "rewarded")
            eq(f.loop.player.stamina, beforeStamina - Config.barrel.cost)
            eq(f.loop:GetBarrelState().stage, 1)

            local backend = { writes = 0 }
            function backend:Set(_, _, events)
                self.writes = self.writes + 1
                events.ok()
            end
            local callbackCount = 0
            eq(Persistence.Cloud(backend):Save({ day = 1 }, function(saved)
                assert(saved)
                callbackCount = callbackCount + 1
            end), true)
            eq(backend.writes, 1)
            eq(callbackCount, 1)
        end, true)
        eq(#logs, 0)
    end)

    return { results = results }
end

return Tests
