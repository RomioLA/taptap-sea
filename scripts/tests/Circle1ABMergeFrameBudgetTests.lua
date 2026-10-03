-- Current real A Runtime and B Loop/Game, with fixture placement and memory Store.
-- This suite is offline regression evidence, not native play or real cloud storage.
local Runtime = require("Ocean.SeaRuntime")
local Bridge = require("Integration.Bridge")
local Config = require("Ocean.Config")
local Progress = require("Gameplay.Circle1B2Progress")
local Tests = {}

local function near(actual, expected)
    assert(math.abs(actual - expected) < 1e-9, tostring(actual) .. " ~= " .. tostring(expected))
end

local function fixture()
    local point = Config.world.fixedBarrel.position
    local runtime = Runtime.New({ initializeRegions = false, departure = { x = point.x + 4, y = point.y } })
    local store = { Save = function(_, _, done) done(true) end,
        Load = function(_, done) done(true, nil) end }
    local bridge = Bridge.New(runtime, { store = store })
    assert(bridge.loop:Depart())
    assert(bridge.loop:BeginBarrelInspection())
    return runtime, bridge, bridge.loop
end

local function guardedUpdate(bridge, dt, x)
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 1
        if instructions > 200 then error("update failed to make progress") end
    end, "", 1000)
    local ok, err = pcall(bridge.Update, bridge, dt, x or 0, 0)
    debug.sethook(nil, "")
    assert(ok, tostring(err))
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = xpcall(fn, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("barrel completion slices share one original sea frame budget", function()
        local runtime, bridge, loop = fixture()
        -- Fixture setup places the existing action just before its real boundary.
        loop.barrel.active.elapsed = 3.9
        local sea, clock = runtime.time, loop.clock.elapsed
        guardedUpdate(bridge, 0.5, 1)
        near(runtime.time - sea, Config.world.maxFrameSec)
        near(loop.clock.elapsed - clock, 0.5)
        assert(not loop.barrel:IsBusy() and Progress.GetBarrelStage(loop.player) == 1)
        near(loop.player.stamina, 60)
    end)

    check("four game seconds keep ship locked and preserve fixed barrel identity", function()
        local runtime, bridge, loop = fixture()
        local ship, world, barrel = runtime.ship, runtime.world, runtime:GetFixedBarrel()
        local x, y = ship.position.x, ship.position.y
        guardedUpdate(bridge, 4, 1)
        near(ship.position.x, x); near(ship.position.y, y)
        near(loop.clock.elapsed, 4); near(runtime.time, Config.world.maxFrameSec)
        assert(not loop.barrel:IsBusy() and runtime.world == world and runtime.ship == ship)
        local current = runtime:GetFixedBarrel()
        assert(current.id == barrel.id and current.generation == barrel.generation)
    end)

    check("inventory pause stops clock sea and barrel progress together", function()
        local runtime, bridge, loop = fixture()
        assert(loop:SetInventoryOpen(true))
        guardedUpdate(bridge, 0.5, 1)
        near(runtime.time, 0); near(loop.clock.elapsed, 0); near(loop.barrel.active.elapsed, 0)
        assert(loop:SetInventoryOpen(false))
        guardedUpdate(bridge, 0.1)
        near(runtime.time, 0.1); near(loop.barrel.active.elapsed, 0.1)
    end)

    check("rounded exact night tie settles completed barrel once before forcing port", function()
        for _, dt in ipairs({ 0.1, 0.1000001 }) do
            local runtime, bridge, loop = fixture()
            local record = loop.barrel.active
            record.elapsed = 3.9
            loop.clock:Seek("night", loop.clock.nightSec - 0.1)
            guardedUpdate(bridge, dt, 1)
            assert(loop.clock.exhausted and loop.dayExhausted and runtime.paused)
            assert(not loop.barrel:IsBusy() and record.state == "complete")
            near(record.elapsed, 4); near(loop.player.stamina, 60)
            assert(Progress.GetBarrelStage(loop.player) == 1 and loop.forcedAtPort)
            local port, position = runtime:GetPortPosition(), runtime:GetShipPosition()
            near(position.x, port.x); near(position.y, port.y)
            guardedUpdate(bridge, 0.5, 1)
            near(loop.player.stamina, 60)
            assert(Progress.GetBarrelStage(loop.player) == 1)
        end
    end)

    check("unfinished barrel at night end cancels without charging", function()
        local _, bridge, loop = fixture()
        loop.barrel.active.elapsed = 3.8
        loop.clock:Seek("night", loop.clock.nightSec - 0.1)
        guardedUpdate(bridge, 0.1000001, 1)
        assert(loop.clock.exhausted and not loop.barrel:IsBusy())
        near(loop.player.stamina, 100)
        assert(Progress.GetBarrelStage(loop.player) == 0)
    end)
    return { results = results, evidenceKind = "real modules with explicit offline fixtures" }
end

return Tests
