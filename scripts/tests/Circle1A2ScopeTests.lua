local Runtime = require("Ocean.SeaRuntime")
local Math = require("Ocean.Math")

local Tests = {}

local function fresh()
    return Runtime.New({ initializeRegions = false, daySeed = 31415 })
end

local function pointAt(ship, distance, angleOffset)
    local angle = ship.rotation + angleOffset
    return {
        x = ship.position.x + math.cos(angle) * distance,
        y = ship.position.y + math.sin(angle) * distance,
    }
end

local function marker(runtime, position)
    return runtime.world:spawn({
        entityType = "circle1a2ScopeMarker",
        kind = "fixed",
        layer = "underwater",
        position = position,
        radius = 0,
        active = false,
        frozen = true,
    })
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end
    local function near(actual, expected, tolerance)
        assert(math.abs(actual - expected) <= (tolerance or 0.00001),
            tostring(actual) .. " != " .. tostring(expected))
    end

    check("persistent scope defaults off and accepts only explicit true", function()
        local runtime = fresh()
        assert(runtime:IsScopeEnabled() == false)
        assert(runtime:SetScopeEnabled(true) == true and runtime:IsScopeEnabled())
        assert(runtime:SetScopeEnabled(false) == false and not runtime:IsScopeEnabled())
        assert(runtime:SetScopeEnabled("true") == false and not runtime:IsScopeEnabled())
        assert(runtime:SetScopeEnabled(nil) == false and not runtime:IsScopeEnabled())
    end)

    check("scope includes the 20m forward edge and inclusive 45 degree sides", function()
        local runtime = fresh()
        local forwardEdge = marker(runtime, pointAt(runtime.ship, 20, 0))
        local leftEdge = marker(runtime, pointAt(runtime.ship, 10, math.rad(45)))
        local rightEdge = marker(runtime, pointAt(runtime.ship, 10, math.rad(-45)))
        local justOutsideRange = marker(runtime, pointAt(runtime.ship, 20.01, 0))
        local justOutsideAngle = marker(runtime, pointAt(runtime.ship, 10, math.rad(46)))
        local behind = marker(runtime, pointAt(runtime.ship, 1, math.pi))
        local apex = marker(runtime, pointAt(runtime.ship, 0, 0))

        assert(not runtime.world:isVisible(forwardEdge))
        assert(runtime:SetScopeEnabled(true))
        assert(runtime.world:isVisible(forwardEdge))
        assert(runtime.world:isVisible(leftEdge) and runtime.world:isVisible(rightEdge))
        assert(runtime.world:isVisible(apex))
        assert(not runtime.world:isVisible(justOutsideRange))
        assert(not runtime.world:isVisible(justOutsideAngle))
        assert(not runtime.world:isVisible(behind))
    end)

    check("scope follows ship movement and keeps its last heading while stopped", function()
        local runtime = fresh()
        runtime:SetScopeEnabled(true)

        runtime:Update(0.25, 0, 1)
        assert(runtime.ship.rotation > 0)
        runtime:Update(0.25, 0, 0)
        local stoppedPosition = Math.copy(runtime.ship.position)
        local stoppedRotation = runtime.ship.rotation
        local oldForward = marker(runtime, pointAt(runtime.ship, 10, 0))
        local oldBehind = marker(runtime, pointAt(runtime.ship, 10, math.pi))
        assert(runtime.world:isVisible(oldForward) and not runtime.world:isVisible(oldBehind))

        runtime:Update(0.5, 1, 0)
        assert(Math.distance(runtime.ship.position, stoppedPosition) > 0.1)
        assert(math.abs(runtime.ship.rotation - stoppedRotation) > 0.1)
        runtime:Update(0.5, 0, 0)
        local movedPosition = Math.copy(runtime.ship.position)
        local movedRotation = runtime.ship.rotation
        near(runtime.ship.position.x, movedPosition.x)
        near(runtime.ship.position.y, movedPosition.y)
        near(runtime.ship.rotation, movedRotation)

        local newForward = marker(runtime, pointAt(runtime.ship, 10, 0))
        assert(runtime.world:isVisible(newForward))
        assert(not runtime.world:isVisible(oldForward))
    end)

    check("scope toggle changes visibility only and leaves fish eligible", function()
        local runtime = fresh()
        local fishPosition = pointAt(runtime.ship, 12, 0)
        local fish = runtime:spawnFish("sardine", fishPosition)
        local originalPosition = Math.copy(fish.position)
        local originalState = fish.state
        local originalActive = fish.active
        local originalFrozen = fish.frozen
        local originalCounts = runtime.world:getCounts()
        assert(not runtime.world:isVisible(fish))
        assert(runtime:selectFishingTarget(fish.position) == fish)

        runtime:SetScopeEnabled(true)
        assert(runtime.world:isVisible(fish))
        assert(Math.distance(fish.position, originalPosition) == 0)
        assert(fish.state == originalState and fish.active == originalActive and fish.frozen == originalFrozen)
        assert(runtime.world:getCounts().total == originalCounts.total)
        assert(#runtime:queryEntitiesInRadius(fish.position, 1, { species = "sardine" }) == 1)
        assert(runtime:selectFishingTarget(fish.position) == fish)
    end)

    check("scope does not change same-seed fish behavior", function()
        local hiddenRuntime, scopedRuntime = fresh(), fresh()
        local hiddenFish = hiddenRuntime:spawnFish("sardine", { x = 40, y = 40 }, 0)
        local scopedFish = scopedRuntime:spawnFish("sardine", { x = 40, y = 40 }, 0)
        scopedRuntime:SetScopeEnabled(true)

        for _ = 1, 40 do
            hiddenRuntime:Update(0.05)
            scopedRuntime:Update(0.05)
        end
        assert(hiddenFish.state == scopedFish.state)
        assert(Math.distance(hiddenFish.position, scopedFish.position) == 0)
        assert(hiddenRuntime.world:getCounts().total == scopedRuntime.world:getCounts().total)
    end)

    check("pause retains scope without advancing boat and reset disables it", function()
        local runtime = fresh()
        runtime:SetScopeEnabled(true)
        local visibleMarker = marker(runtime, pointAt(runtime.ship, 10, 0))
        local position = Math.copy(runtime.ship.position)
        local rotation = runtime.ship.rotation
        local time = runtime.time

        runtime:TogglePause()
        runtime:Update(1, 1, 0)
        assert(runtime:IsScopeEnabled() and runtime.world:isVisible(visibleMarker))
        assert(Math.distance(runtime.ship.position, position) == 0)
        near(runtime.ship.rotation, rotation)
        near(runtime.time, time)

        runtime:Reset()
        assert(not runtime:IsScopeEnabled())
        assert(runtime.world.scopeShip == runtime.ship)
    end)

    check("legacy timed circular reveal remains independent and compatible", function()
        local runtime = fresh()
        local center = marker(runtime, { x = -100, y = 0 })
        local outside = marker(runtime, { x = -120.01, y = 0 })
        assert(not runtime:IsScopeEnabled())

        runtime:revealWithScope({ x = -100, y = 0 }, 0.1)
        assert(not runtime:IsScopeEnabled())
        assert(runtime.world:isVisible(center))
        assert(not runtime.world:isVisible(outside))
        runtime.world:updateLifecycle(0.11, runtime.ship)
        assert(not runtime.world:isVisible(center))
    end)

    check("scope safely rejects invalid transforms and tight outside boundaries", function()
        local runtime = fresh()
        runtime:SetScopeEnabled(true)
        local entity = marker(runtime, { x = 20.0001, y = 0 })
        assert(not runtime.world:isVisible(entity))
        entity.position = pointAt(runtime.ship, 10, math.rad(45.001))
        assert(not runtime.world:isVisible(entity))
        entity.position = { x = 0/0, y = 0 }
        assert(not runtime.world:isVisible(entity))
        entity.position = { x = 1, y = 0 }
        runtime.ship.rotation = math.huge
        assert(not runtime.world:isVisible(entity))
    end)

    check("transient water queries match full scans for every current blocker", function()
        local runtime = fresh()
        runtime.world:spawn({ entityType = "testBlocker", kind = "dynamic", blocking = true,
            position = { x = -10, y = -10 }, radius = 2 })
        local query = runtime.world:CreateWaterQuery()
        for _, point in ipairs({ { x = 0, y = 0 }, { x = -10, y = -10 }, { x = -6, y = -10 },
            { x = 35, y = 25 }, { x = 1200, y = 0 }, { x = 1199, y = 0 } }) do
            for _, radius in ipairs({ 0, 2, 3 }) do
                assert(query(point, radius) == runtime.world:isPositionFree(point, radius))
            end
        end
        runtime.world.isPositionFree = function() return false end
        assert(not runtime.world:CreateWaterQuery()({ x = 0, y = 0 }, 0),
            "batch query must respect an embedding world's specialized predicate")
    end)

    return { results = results, metrics = {} }
end

return Tests
