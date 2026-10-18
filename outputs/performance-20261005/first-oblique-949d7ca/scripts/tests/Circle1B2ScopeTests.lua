-- Circle 1B2 scope ownership and A-runtime synchronization tests.
local Flow = require("tests.Circle1BFishingFlowTests")
local Persistence = require("Gameplay.Persistence")
local Progress = require("Gameplay.Circle1B2Progress")

local Tests = {}

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function bindScope(fixture)
    local runtime = fixture.runtime
    runtime.scopeEnabled = false
    runtime.scopeSetCalls = 0
    runtime.scopeGetCalls = 0
    runtime.scopeFault = nil
    runtime.scopeMismatchReads = {}

    function runtime:SetScopeEnabled(enabled)
        self.scopeSetCalls = self.scopeSetCalls + 1
        if self.scopeFault == "reject" then
            return false
        elseif self.scopeFault == "throw" then
            error("injected scope setter failure")
        end
        self.scopeEnabled = enabled == true
        return self.scopeEnabled
    end

    function runtime:IsScopeEnabled()
        self.scopeGetCalls = self.scopeGetCalls + 1
        local mismatch = self.scopeMismatchReads[self.scopeGetCalls]
        if mismatch ~= nil then return mismatch end
        return self.scopeEnabled
    end

    local _, _, synced, reason = fixture.bridge:Sync()
    assert(synced, tostring(reason))
    runtime.scopeSetCalls, runtime.scopeGetCalls = 0, 0
    return runtime
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("scope requires lens ownership and toggling does not pause the voyage", function()
        local fixture = Flow.Fixture()
        local runtime = bindScope(fixture)
        local denied, reason = fixture.loop:ToggleScope()
        eq(denied, false)
        eq(reason, "scope_not_owned")
        eq(runtime.scopeSetCalls, 0)

        assert(fixture.loop:Depart())
        assert(Progress.GrantLens(fixture.loop.player))
        eq(fixture.loop.clock:IsPaused(), false)
        assert(fixture.loop:ToggleScope())
        eq(runtime.scopeEnabled, true)
        eq(fixture.loop:IsScopeEnabled(), true)
        eq(fixture.loop.clock:IsPaused(), false)
        assert(fixture.loop:ToggleScope())
        eq(runtime.scopeEnabled, false)
        eq(fixture.loop:IsScopeEnabled(), false)
        eq(fixture.loop.clock:IsPaused(), false)

        local _, _, synced, syncReason = fixture.bridge:Sync()
        assert(synced, tostring(syncReason))
        eq(syncReason, nil)
    end)

    test("new run and saved-load both synchronize A scope off", function()
        local fresh = Flow.Fixture()
        local freshRuntime = bindScope(fresh)
        assert(fresh.loop:Depart())
        assert(Progress.GrantLens(fresh.loop.player))
        assert(fresh.loop:ToggleScope())
        eq(freshRuntime.scopeEnabled, true)
        assert(fresh.bridge:NewRun())
        eq(fresh.loop.scopeEnabled, false)
        eq(fresh.loop:HasLens(), false)
        eq(freshRuntime.scopeEnabled, false)
        eq(fresh.loop.scopeSyncError, nil)

        local restored = Flow.Fixture()
        local restoredRuntime = bindScope(restored)
        assert(Progress.GrantLens(restored.loop.player))
        restored.store.data = Persistence.Snapshot(restored.loop.player)
        assert(restored.loop:ToggleScope())
        eq(restoredRuntime.scopeEnabled, true)

        local loadOk, loadData
        assert(restored.bridge:LoadSaved(function(ok, data)
            loadOk, loadData = ok, data
        end))
        eq(loadOk, true)
        assert(type(loadData) == "table")
        eq(restored.loop:HasLens(), true)
        eq(restored.loop.scopeEnabled, false)
        eq(restoredRuntime.scopeEnabled, false)
        eq(restored.loop.scopeSyncError, nil)
    end)

    test("false is a valid disabled result while rejection and exceptions fail readback", function()
        do
            local fixture = Flow.Fixture()
            local runtime = bindScope(fixture)
            assert(Progress.GrantLens(fixture.loop.player))
            runtime.scopeEnabled = true
            assert(fixture.loop:DisableScope(), "A returns false after disabling")
            eq(runtime.scopeEnabled, false)
            eq(fixture.loop.scopeSyncError, nil)
        end
        for _, fault in ipairs({ "reject", "throw" }) do
            local fixture = Flow.Fixture()
            local runtime = bindScope(fixture)
            assert(Progress.GrantLens(fixture.loop.player))
            runtime.scopeEnabled = true
            runtime.scopeFault = fault

            local closed, reason = fixture.loop:DisableScope()
            eq(closed, false)
            eq(reason, "scope_sync_failed")
            eq(fixture.loop.scopeEnabled, false)
            eq(fixture.loop.scopeSyncError, reason)
            eq(runtime.scopeEnabled, true)

            runtime.scopeFault = nil
            assert(fixture.loop:DisableScope())
            eq(runtime.scopeEnabled, false)
            eq(fixture.loop.scopeSyncError, nil)
        end
    end)

    test("scope readback mismatch is reported and a later close can recover", function()
        local fixture = Flow.Fixture()
        local runtime = bindScope(fixture)
        assert(Progress.GrantLens(fixture.loop.player))
        -- First toggle verification and rollback verification deliberately lie.
        runtime.scopeMismatchReads = { [2] = false, [4] = true, [6] = true }

        local opened, reason = fixture.loop:ToggleScope()
        eq(opened, false)
        eq(reason, "scope_sync_failed")
        eq(fixture.loop.scopeEnabled, false)
        eq(fixture.loop.scopeSyncError, reason)

        local _, _, synced, syncReason = fixture.bridge:Sync()
        eq(synced, false)
        eq(syncReason, "scope_sync_failed")
        eq(fixture.loop.scopeSyncError, syncReason)

        runtime.scopeMismatchReads = {}
        runtime.scopeEnabled = true
        assert(fixture.loop:DisableScope())
        eq(runtime.scopeEnabled, false)
        eq(fixture.loop.scopeSyncError, nil)
    end)

    test("snapshot and restore reject inconsistent Circle 1B2 progress", function()
        local fixture = Flow.Fixture()
        local validSnapshot = Persistence.Snapshot(fixture.loop.player)

        fixture.loop.player.story.circle1B2.barrelStage = 3
        fixture.loop.player.treasures.scopeLens = false
        local snapshotOk = pcall(Persistence.Snapshot, fixture.loop.player)
        eq(snapshotOk, false)

        validSnapshot.story.circle1B2.barrelStage = 3
        validSnapshot.treasures.scopeLens = false
        local player, reason = Persistence.Restore(validSnapshot)
        eq(player, nil)
        eq(reason, "final_barrel_stage_requires_lens")
    end)

    return { results = results }
end

return Tests
