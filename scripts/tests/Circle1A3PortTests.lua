-- Pure-Lua/Lupa tests over the sea modules; this is not native UrhoX/Maker verification.
local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local Tests = {}

local function near(actual, expected, epsilon)
    assert(math.abs(actual - expected) <= (epsilon or 0.00001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

local function fresh(departure)
    return Runtime.New({ initializeRegions = false, daySeed = 314159, departure = departure })
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("port getter copies the authored Config anchor instead of departure", function()
        near(Config.ship.start.x, 0)
        near(Config.ship.start.y, 0)
        local departure = { x = 220, y = -140 }
        local runtime = fresh(departure)
        near(runtime.ship.position.x, departure.x)
        near(runtime.ship.position.y, departure.y)

        local port = runtime:GetPortPosition()
        assert(port ~= Config.ship.start, "getter exposed mutable config coordinates")
        near(port.x, 0)
        near(port.y, 0)
        port.x, port.y = 99, 88
        local nextPort = runtime:GetPortPosition()
        near(nextPort.x, 0)
        near(nextPort.y, 0)
        near(Config.ship.start.x, 0)
        near(Config.ship.start.y, 0)
    end)

    check("port reset reuses ship and world while preserving time, fish, signals and barrel", function()
        local runtime = fresh({ x = 220, y = -140 })
        local world, ship = runtime.world, runtime.ship
        local fish = runtime:spawnFish("sardine", { x = 232, y = -140 }, 0.25)
        local fishPosition = { x = fish.position.x, y = fish.position.y }
        local fishState, fishActive, fishFrozen = fish.state, fish.active, fish.frozen
        local barrel = world.fixedBarrel
        local barrelPosition = { x = barrel.position.x, y = barrel.position.y }
        local barrelId, barrelGeneration = barrel.id, world.fixedBarrelGeneration
        local fishingGeneration = runtime:GetFishingGeneration()
        local entityCount = #world.entities

        runtime.time, world.time = 19.25, 42.5
        runtime.daySeed, world.daySeed = 123456, 123456
        runtime.paused = true
        runtime:SetScopeEnabled(true)
        runtime.movement:SetViewport(960, 540)
        runtime.movement:SetTarget({ x = -300, y = 250 })
        runtime.movement.pushRemaining = 0.24
        runtime.movement.pushNormal.x, runtime.movement.pushNormal.y = -1, 0
        runtime.movement.camera.x, runtime.movement.camera.y = 100, -100
        local scopeShip = world.scopeShip
        local signals = runtime.surfaceSignals

        local ok, reason = runtime:ResetShipAtPort()
        assert(ok, tostring(reason))
        assert(runtime.world == world and runtime.ship == ship and world:get(ship.id) == ship,
            "port reset replaced the live World or ship entity")
        assert(world.fixedBarrel == barrel and world:get(barrelId) == barrel,
            "port reset replaced the fixed barrel entity")
        assert(runtime.surfaceSignals == signals and world.surfaceSignals == signals,
            "port reset replaced the live signals system")
        assert(world.scopeShip == scopeShip and scopeShip == ship and runtime:IsScopeEnabled(),
            "port reset changed the persistent scope attachment")
        assert(#world.entities == entityCount, "port reset changed the entity collection")
        assert(runtime:GetFishingGeneration() == fishingGeneration,
            "port reset changed the fishing generation")
        assert(world.fixedBarrelGeneration == barrelGeneration, "port reset changed barrel generation")
        assert(runtime.time == 19.25 and world.time == 42.5, "port reset advanced sea time")
        assert(runtime.daySeed == 123456 and world.daySeed == 123456,
            "port reset changed the current day seed")
        assert(runtime.paused, "port reset changed pause state")
        assert(world:get(fish.id) == fish and not fish.removed,
            "port reset removed or replaced a fish")
        assert(fish.position.x == fishPosition.x and fish.position.y == fishPosition.y
            and fish.state == fishState and fish.active == fishActive and fish.frozen == fishFrozen,
            "port reset changed fish position or behavior state")
        assert(barrel.position.x == barrelPosition.x and barrel.position.y == barrelPosition.y,
            "port reset moved the fixed barrel")
        near(ship.position.x, Config.ship.start.x)
        near(ship.position.y, Config.ship.start.y)
        assert(runtime.movement.target == nil, "port reset kept a stale movement target")
        assert(runtime.movement.pushRemaining == 0
            and runtime.movement.pushNormal.x == 0 and runtime.movement.pushNormal.y == 0,
            "port reset kept collision push feedback")
        near(runtime.movement.camera.x, Config.ship.start.x)
        near(runtime.movement.camera.y, Config.ship.start.y)
        assert(ship.position ~= Config.ship.start, "ship position aliases the config point")

        local secondOk, secondReason = runtime:ResetShipAtPort()
        assert(secondOk, tostring(secondReason))
        assert(runtime.ship == ship and runtime.world == world,
            "repeated port reset replaced the ship or World")
    end)

    check("port reset preserves live region markers and temporary lifetime without resuming stale target", function()
        local runtime = Runtime.New({ daySeed = 271828, departure = { x = 0, y = 0 } })
        local world = runtime.world
        ---@type table<string, boolean>
        local regionMarkers = runtime.initializedRegions
        local markerCount = 0
        for _ in pairs(regionMarkers) do markerCount = markerCount + 1 end
        assert(markerCount > 0, "test requires the normal initialized-region path")

        local dropped = nil
        local maxDistance = Config.interaction.maxThrowDistance - 1
        for x = 2, math.floor(maxDistance) do
            for y = -math.floor(maxDistance), math.floor(maxDistance) do
                local candidate = { x = x, y = y }
                if x * x + y * y <= maxDistance * maxDistance
                    and runtime:IsPositionFree(candidate, 0) then
                    dropped = runtime:spawnDroppedItem({ itemId = "test_item", lifetimeSec = 10 }, candidate)
                    if dropped then break end
                end
            end
            if dropped then break end
        end
        assert(dropped and dropped.kind == "temporary", "could not create a legal temporary sea entity")

        runtime:Update(0.1, 0, 0)
        local ageBeforeReset = dropped.age
        assert(ageBeforeReset > 0, "temporary entity did not enter its normal lifetime")
        assert(runtime.initializedRegions == regionMarkers, "normal update replaced region markers")

        runtime.movement:ResetAtPosition({ x = 40, y = 40 })
        runtime.movement:SetTarget({ x = 80, y = 40 })
        local regionSnapshot = {}
        for key, value in pairs(regionMarkers) do regionSnapshot[key] = value end
        local ok, reason = runtime:ResetShipAtPort()
        assert(ok, tostring(reason))
        assert(runtime.initializedRegions == regionMarkers, "port reset replaced initialized region markers")
        local afterResetCount = 0
        for key, value in pairs(runtime.initializedRegions) do
            afterResetCount = afterResetCount + 1
            assert(regionSnapshot[key] == value, "port reset changed region marker " .. tostring(key))
        end
        assert(afterResetCount == markerCount, "port reset changed the initialized-region count")
        near(dropped.age, ageBeforeReset, 0.000001)
        assert(runtime.movement.target == nil, "port reset kept the old navigation target")

        runtime:Update(0.05, 0, 0)
        near(runtime.ship.position.x, Config.ship.start.x)
        near(runtime.ship.position.y, Config.ship.start.y)
        near(dropped.age, ageBeforeReset + 0.05, 0.00001)
        assert(world:get(dropped.id) == dropped and not dropped.removed,
            "temporary entity was removed by the port reset or short update")
    end)

    check("blocked or malformed port fails without clearing steering state", function()
        local runtime = fresh({ x = 220, y = -140 })
        runtime.movement:ResetAtPosition({ x = 180, y = -180 })
        runtime.movement:SetTarget({ x = 181, y = -180 })
        runtime.movement.pushRemaining = 0.2
        runtime.movement.pushNormal.x, runtime.movement.pushNormal.y = 0, 1
        local target = runtime.movement.target
        local shipPosition = { x = runtime.ship.position.x, y = runtime.ship.position.y }
        runtime.world:spawn({ entityType = "testBlocker", kind = "dynamic", layer = "surface",
            position = Config.ship.start, radius = 3, blocking = true })

        local ok, reason = runtime:ResetShipAtPort()
        assert(not ok and reason == "port_blocked", tostring(reason))
        assert(runtime.movement.target == target and runtime.movement.pushRemaining == 0.2,
            "rejected port reset cleared steering feedback")
        assert(runtime.ship.position.x == shipPosition.x and runtime.ship.position.y == shipPosition.y,
            "rejected port reset moved the ship")

        local originalX = Config.ship.start.x
        Config.ship.start.x = 0 / 0
        local invalidOk, invalidReason = runtime:ResetShipAtPort()
        Config.ship.start.x = originalX
        assert(not invalidOk and invalidReason == "invalid_port_position", tostring(invalidReason))
        assert(runtime.movement.target == target, "invalid port reset changed steering state")
    end)

    check("port reset honors the World's public water predicate", function()
        local runtime = fresh({ x = 220, y = -140 })
        local ship = runtime.ship
        local originalPredicate = runtime.world.isPositionFree
        local predicateCalls = 0
        runtime.world.isPositionFree = function(_, position, radius)
            predicateCalls = predicateCalls + 1
            near(position.x, Config.ship.start.x)
            near(position.y, Config.ship.start.y)
            near(radius, ship.radius)
            return false
        end
        runtime.movement:SetTarget({ x = -200, y = 50 })
        local target = runtime.movement.target
        local ok, reason = runtime:ResetShipAtPort()
        runtime.world.isPositionFree = originalPredicate
        assert(not ok and reason == "port_blocked" and predicateCalls == 1,
            "port check bypassed the World's authoritative water predicate")
        assert(runtime.movement.target == target, "custom water rejection changed steering state")
    end)

    return { results = results }
end

return Tests
