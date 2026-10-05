-- Circle 1 A3 stability regressions. These tests run the real pure-Lua sea
-- runtime with its configured fish density and movement values; no engine UI
-- or native-runtime behavior is emulated here.
local Runtime = require("Ocean.SeaRuntime")
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local Math = require("Ocean.Math")
local SpawnStrategy = require("Ocean.SpawnStrategy")
local EntityStateSystem = require("Systems.EntityStateSystem")
local Game = require("Game.Game")

local Tests = {}
local LONG_VOYAGE_SEEDS = { 271828, 314159, 161803 }
local FIXED_STEP = 0.05

local function near(actual, expected, tolerance)
    assert(math.abs(actual - expected) <= (tolerance or 0.00001),
        string.format("%.9f != %.9f", actual, expected))
end

local function advance(runtime, seconds)
    local steps = math.floor(seconds / FIXED_STEP + 0.0000001)
    for _ = 1, steps do runtime:Update(FIXED_STEP) end
    local remainder = seconds - steps * FIXED_STEP
    if remainder > 0.000001 then runtime:Update(remainder) end
end

local function fishCounts(runtime)
    local counts = runtime.world:getCounts()
    return counts.sardine + counts.tuna, counts
end

---@return SeaEntity?
local function findFish(runtime, species)
    for _, entity in ipairs(runtime.world.entities) do
        if entity.ordinaryFish and not entity.removed
            and (species == nil or entity.species == species) then
            return entity
        end
    end
    return nil
end

local function countKeys(values)
    local count = 0
    for _ in pairs(values) do count = count + 1 end
    return count
end

local function countingStrategy(calls, observedSeeds)
    -- Test-only observation wrapper: all placements still come from the
    -- production strategy with unchanged Config and FishData.
    return {
        GenerateRegion = function(world, seed, regionX, regionY, departure, fishData, shipPosition)
            local key = regionX .. ":" .. regionY
            calls[key] = (calls[key] or 0) + 1
            observedSeeds[seed] = true
            return SpawnStrategy.GenerateRegion(world, seed, regionX, regionY,
                departure, fishData, shipPosition)
        end,
    }
end

local function sailTo(runtime, target, maxSteps)
    runtime.movement:SetTarget(target)
    local steps = 0
    while runtime.movement.target ~= nil do
        assert(steps < (maxSteps or 6000), "ship did not reach voyage waypoint")
        runtime:Update(FIXED_STEP)
        steps = steps + 1
    end
    return steps
end

local function birdsFor(signals, sourceId)
    local count = 0
    for _, bird in ipairs(signals:GetBirds()) do
        if sourceId == nil or bird.sourceId == sourceId then count = count + 1 end
    end
    return count
end

local function splashesFor(signals, sourceId)
    local count = 0
    for _, splash in ipairs(signals:GetSplashes()) do
        if sourceId == nil or splash.sourceId == sourceId then count = count + 1 end
    end
    return count
end

local function longVoyage(seed)
    local regionCalls = {}
    local observedSeeds = {}
    local runtime = Runtime.New({ daySeed = seed,
        strategy = countingStrategy(regionCalls, observedSeeds) })
    local initialFishCount, initialCounts = fishCounts(runtime)
    assert(initialFishCount > 0, "default first-day initialization must create ordinary fish")
    local initialRegions = countKeys(runtime.initializedRegions)
    local removedFish = assert(findFish(runtime), "normal population should provide a catch candidate")
    local removedId = removedFish.id
    local captureOwner = {}
    assert(runtime:LockFishingTarget(removedId, captureOwner))
    assert(runtime:RemoveFishingTarget(removedId, captureOwner))

    local fixedBarrel = assert(runtime:GetFixedBarrel())
    local barrelEntity = runtime.world.fixedBarrel
    local totalSteps = 0
    local peakFishCount = initialFishCount
    local waypoints = {
        { x = 35, y = 5 }, { x = 60, y = 25 }, { x = 85, y = 25 },
        { x = 180, y = 0 }, { x = -180, y = 0 }, { x = 0, y = 0 },
    }
    for index, target in ipairs(waypoints) do
        totalSteps = totalSteps + sailTo(runtime, target)
        if index == 2 or index == 3 then
            local snapshot = assert(runtime:GetFixedBarrel())
            assert(snapshot.id == fixedBarrel.id and snapshot.generation == fixedBarrel.generation)
            assert(runtime.world.fixedBarrel == barrelEntity)
        end
        local currentFishCount = fishCounts(runtime)
        peakFishCount = math.max(peakFishCount, currentFishCount)
    end

    local generatedRegionCount = 0
    local maxCallsPerRegion = 0
    for _, calls in pairs(regionCalls) do
        generatedRegionCount = generatedRegionCount + 1
        maxCallsPerRegion = math.max(maxCallsPerRegion, calls)
        assert(calls == 1, "same-day region generation repeated during the out-and-back voyage")
    end
    assert(runtime:GetFishingTarget(removedId) == nil,
        "caught fish must not reappear when its original region is revisited on the same day")
    assert(countKeys(runtime.initializedRegions) >= initialRegions,
        "region history must retain the first-day initialized markers")
    assert(runtime.daySeed == seed and observedSeeds[seed] and countKeys(observedSeeds) == 1,
        "same-day region generation must keep using the original Runtime seed")
    assert(runtime.world.fixedBarrel == barrelEntity)

    return {
        seed = seed,
        worldDaySeedMirror = runtime.world.daySeed,
        initialFishCount = initialFishCount,
        initialSardines = initialCounts.sardine,
        initialTuna = initialCounts.tuna,
        peakFishCount = peakFishCount,
        initialRegions = initialRegions,
        regionsVisited = generatedRegionCount,
        maxGenerationCallsPerRegion = maxCallsPerRegion,
        totalSteps = totalSteps,
        simulatedSeconds = runtime.world.time,
        removedFishId = removedId,
        caughtFishStayedRemoved = runtime:GetFishingTarget(removedId) == nil,
        barrelId = fixedBarrel.id,
        barrelGeneration = fixedBarrel.generation,
    }
end

function Tests.Run()
    local results = {}
    local metrics = {
        longVoyages = {},
        configuredDensityTargets = {
            sardine = FishData.sardine.targetActiveCount,
            tuna = FishData.tuna.targetActiveCount,
        },
        speedAndCollision = {},
        repeatedRebuilds = 0,
    }

    local function check(name, fn)
        local ok, value = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(value) }
        if ok and value ~= nil then metrics[name] = value end
    end

    check("normal density multi-seed long out-and-back voyage never regenerates a visited region", function()
        assert(FishData.sardine.targetActiveCount == 20 and FishData.tuna.targetActiveCount == 4,
            "the established density targets changed during this regression")
        local reports, failures = {}, {}
        for _, seed in ipairs(LONG_VOYAGE_SEEDS) do
            local ok, report = pcall(longVoyage, seed)
            if ok then
                reports[#reports + 1] = report
            else
                failures[#failures + 1] = { seed = seed, error = tostring(report) }
            end
        end
        metrics.longVoyages = reports
        metrics.longVoyageFailures = failures
        metrics.normalRuntimeFishLimitRaised = false
        assert(#reports > 0, "no normal-population voyage completed; see per-seed placement errors")
        assert(#failures == 0, "one or more normal-population voyages failed; see per-seed details")
        local totalUpdates = 0
        for _, report in ipairs(reports) do totalUpdates = totalUpdates + report.totalSteps end
        return { requestedSeeds = #LONG_VOYAGE_SEEDS, completedSeeds = #reports,
            totalUpdates = totalUpdates }
    end)

    check("new day clears ordinary fish and temporary items but keeps the exact fixed barrel", function()
        local seed = 314159
        local runtime = Runtime.New({ daySeed = seed })
        local oldFish = assert(findFish(runtime), "normal initialization should create a fish")
        local oldFishId = oldFish.id
        local barrel = runtime.world.fixedBarrel
        ---@type OceanFixedBarrelSnapshot?
        local barrelSnapshot = runtime:GetFixedBarrel()
        assert(barrelSnapshot, "fixed barrel snapshot is unavailable")
        local bait = assert(runtime:spawnDroppedItem({ itemId = "sardine",
            worldEffect = "ATTRACT_BIG_FISH", lifetimeSec = 60 },
            { x = runtime.ship.position.x + 2, y = runtime.ship.position.y }))
        runtime:revealWithScope(runtime.ship.position, 30)
        runtime:Update(0.25)
        assert(bait.age > 0 and #runtime.world.reveals == 1)

        runtime:refreshOrdinaryFish(seed + 1, runtime.ship.position)
        assert(runtime.daySeed == seed + 1 and runtime.world.daySeed == seed + 1)
        assert(runtime:GetFishingTarget(oldFishId) == nil and oldFish.removeReason == "clearOrdinaryFish")
        assert(runtime:GetFishingTarget(bait.id) == nil and bait.removeReason == "newDay")
        assert(runtime.world.fixedBarrel == barrel and runtime:GetFishingTarget(barrel.id) == barrel)
        ---@type OceanFixedBarrelSnapshot?
        local nextBarrel = runtime:GetFixedBarrel()
        assert(nextBarrel, "new-day fixed barrel snapshot is unavailable")
        assert(nextBarrel.id == barrelSnapshot.id and nextBarrel.generation == barrelSnapshot.generation)
        assert(nextBarrel.position.x == barrelSnapshot.position.x
            and nextBarrel.position.y == barrelSnapshot.position.y)
        assert(#runtime.world.reveals == 0, "timed visibility state should not leak into the new day")
        local nextFishCount = fishCounts(runtime)
        assert(nextFishCount > 0, "new day should initialize its ordinary local population")
        return { seedBefore = seed, seedAfter = runtime.daySeed,
            oldFishRemoved = oldFishId, newDayFishCount = nextFishCount,
            temporaryItemReason = bait.removeReason, fixedBarrelId = nextBarrel.id }
    end)

    check("manual pause freezes ship, fish AI, bait lifetime, cooldowns, and surface signals", function()
        local runtime = Runtime.New({ initializeRegions = false, departure = { x = 500, y = 500 } })
        local predator = runtime:spawnFish("tuna", { x = 505, y = 500 }, 0)
        local prey = runtime:spawnFish("sardine", { x = 506, y = 500 }, 0)
        local bait = assert(runtime:spawnDroppedItem({ itemId = "sardine",
            worldEffect = "ATTRACT_BIG_FISH", lifetimeSec = 30 }, { x = 500, y = 500 }))
        local attractedTuna = runtime:spawnFish("tuna", { x = 488, y = 500 }, 0)
        local birdSource = runtime:spawnFish("sardine", { x = 560, y = 500 }, 0)
        local predatorBehavior = runtime.behaviors[predator.id]
        local attractedBehavior = runtime.behaviors[attractedTuna.id]
        runtime.movement:SetTarget({ x = 510, y = 500 })

        advance(runtime, 1.1)
        assert(prey.removed and prey.removeReason == "eaten")
        local cooldownRemaining = predatorBehavior.predationCooldownUntil - runtime.world.time
        assert(cooldownRemaining > 0 and cooldownRemaining <= Config.predation.cooldownSeconds,
            "the cooldown begins when the successful capture happens, not at a fixed update")
        assert(attractedBehavior.state == "Attracted", "the real bait item should attract the real tuna")
        assert(bait.age > 0 and bait.age < bait.lifetimeSec)
        assert(birdsFor(runtime.surfaceSignals, birdSource.id) > 0,
            "a live ordinary sardine should produce real-source bird cues")
        assert(splashesFor(runtime.surfaceSignals, attractedTuna.id) > 0,
            "a live ordinary tuna should produce a real-source splash")

        local shipPosition = Math.copy(runtime.ship.position)
        local predatorPosition = Math.copy(predator.position)
        local attractedPosition = Math.copy(attractedTuna.position)
        local birdPosition = Math.copy(birdSource.position)
        local baitAge = bait.age
        local worldTime, runtimeTime = runtime.world.time, runtime.time
        local cooldownUntil = predatorBehavior.predationCooldownUntil
        local attractionCooldownUntil = attractedBehavior.predationCooldownUntil
        local birdPollRemaining = runtime.surfaceSignals.birdPollRemaining
        local bird = runtime.surfaceSignals:GetBirds()[1]
        local splash = runtime.surfaceSignals:GetSplashes()[1]
        local birdX, birdY = bird.position.x, bird.position.y
        local splashRemaining = splash.remaining
        local splashTimer = runtime.surfaceSignals.splashTimers[attractedTuna.id].remaining

        runtime:TogglePause()
        advance(runtime, 2)
        near(runtime.world.time, worldTime)
        near(runtime.time, runtimeTime)
        near(runtime.ship.position.x, shipPosition.x)
        near(runtime.ship.position.y, shipPosition.y)
        near(predator.position.x, predatorPosition.x)
        near(predator.position.y, predatorPosition.y)
        near(attractedTuna.position.x, attractedPosition.x)
        near(attractedTuna.position.y, attractedPosition.y)
        near(birdSource.position.x, birdPosition.x)
        near(birdSource.position.y, birdPosition.y)
        near(bait.age, baitAge)
        near(predatorBehavior.predationCooldownUntil, cooldownUntil)
        near(attractedBehavior.predationCooldownUntil, attractionCooldownUntil)
        near(runtime.surfaceSignals.birdPollRemaining, birdPollRemaining)
        near(runtime.surfaceSignals:GetBirds()[1].position.x, birdX)
        near(runtime.surfaceSignals:GetBirds()[1].position.y, birdY)
        near(runtime.surfaceSignals:GetSplashes()[1].remaining, splashRemaining)
        near(runtime.surfaceSignals.splashTimers[attractedTuna.id].remaining, splashTimer)
        assert(predatorBehavior.predationCooldownUntil == cooldownUntil,
            "pause must not consume a predation cooldown")
        assert(bait.age < bait.lifetimeSec, "paused bait must not expire")
        runtime:TogglePause()
        runtime:Update(FIXED_STEP)
        assert(runtime.world.time > worldTime and bait.age > baitAge,
            "world clocks resume after unpausing")
        return { pausedWallDelta = 2, worldDeltaWhilePaused = 0,
            baitAge = baitAge, cooldownRemainingAtPause = cooldownUntil - worldTime,
            birdCount = birdsFor(runtime.surfaceSignals, birdSource.id),
            splashCount = splashesFor(runtime.surfaceSignals, attractedTuna.id) }
    end)

    check("cancel, predation, catch removal, and reset leave no stale locks or signal cues", function()
        local runtime = Runtime.New({ initializeRegions = false, departure = { x = 600, y = 600 } })
        local sardine = runtime:spawnFish("sardine", { x = 560, y = 600 }, 0)
        local tuna = runtime:spawnFish("tuna", { x = 650, y = 600 }, 0)
        local tunaBehavior = runtime.behaviors[tuna.id] --[[@as FishBehavior]]
        advance(runtime, 1.1)
        assert(birdsFor(runtime.surfaceSignals, sardine.id) > 0)
        assert(splashesFor(runtime.surfaceSignals, tuna.id) > 0)

        local cancelOwner = {}
        assert(runtime:LockFishingTarget(sardine.id, cancelOwner))
        assert(birdsFor(runtime.surfaceSignals, sardine.id) == 0,
            "a locked fish must immediately lose its bird hint")
        assert(runtime:UnlockFishingTarget(sardine.id, cancelOwner))
        assert(not sardine.captureLocked and sardine.captureOwnerToken == nil)
        advance(runtime, 0.25)
        assert(birdsFor(runtime.surfaceSignals, sardine.id) > 0,
            "cancel returns a live fish to its normal signal source state")

        local catchOwner = {}
        assert(runtime:LockFishingTarget(sardine.id, catchOwner))
        assert(runtime:RemoveFishingTarget(sardine.id, catchOwner))
        assert(runtime:GetFishingTarget(sardine.id) == nil)
        assert(not sardine.captureLocked and sardine.captureOwnerToken == nil)
        assert(birdsFor(runtime.surfaceSignals, sardine.id) == 0,
            "a caught fish cannot leave a stale bird hint")

        local prey = runtime:spawnFish("sardine", { x = 590, y = 620 }, 0)
        runtime:Update(FIXED_STEP)
        advance(runtime, 0.25)
        assert(birdsFor(runtime.surfaceSignals, prey.id) > 0)
        tuna.position = { x = prey.position.x + 1, y = prey.position.y }
        assert(tunaBehavior:_tryEat(prey), "the real Tuna behavior should remove its prey")
        assert(prey.removeReason == "eaten" and runtime:GetFishingTarget(prey.id) == nil)
        assert(not prey.captureLocked and prey.captureOwnerToken == nil)
        assert(birdsFor(runtime.surfaceSignals, prey.id) == 0,
            "predation cannot leave a stale bird hint")

        local resetOwner = {}
        assert(runtime:LockFishingTarget(tuna.id, resetOwner))
        local oldWorld, oldSignals, oldShip = runtime.world, runtime.surfaceSignals, runtime.ship
        runtime:Reset()
        assert(not tuna.captureLocked and tuna.captureOwnerToken == nil,
            "reset clears a lock on the retired fish entity")
        assert(runtime.world ~= oldWorld and runtime.surfaceSignals ~= oldSignals and runtime.ship ~= oldShip)
        assert(runtime.world.scopeShip == runtime.ship and runtime.surfaceSignals.world == runtime.world)
        assert(oldWorld.scopeShip == nil and oldWorld.surfaceSignals == nil and oldSignals.world == nil,
            "retired scope and signal systems must not keep the old ship/world attached")
        assert(#oldWorld.systems == 0, "retired world must release registered frame/simulation systems")
        assert(#runtime.surfaceSignals:GetBirds() == 0 and #runtime.surfaceSignals:GetSplashes() == 0)
        return { cancelUnlocked = true, caughtHintCount = birdsFor(runtime.surfaceSignals, sardine.id),
            eatenHintCount = birdsFor(runtime.surfaceSignals, prey.id), resetSignalsCleared = true }
    end)

    check("repeated Runtime rebuilds retire old worlds and never reschedule a shared frame System", function()
        local runtime = Runtime.New({ initializeRegions = false, departure = { x = 400, y = 400 } })
        local frameLoop = { calls = 0, clock = { IsPaused = function() return false end },
            player = { boatSpeedLevel = 1 } }
        function frameLoop:Update(dt)
            self.calls = self.calls + 1
            self.lastDt = dt
        end
        local game = Game.New(runtime, frameLoop)
        local oldWorlds = {}
        local oldShips = {}
        local oldSignals = {}

        for cycle = 1, 5 do
            local previousWorld, previousShip, previousSignals = runtime.world, runtime.ship, runtime.surfaceSignals
            oldWorlds[#oldWorlds + 1] = previousWorld
            oldShips[#oldShips + 1] = previousShip
            oldSignals[#oldSignals + 1] = previousSignals
            runtime:Reset()
            local currentWorld = game:GetWorld()
            for _ = 1, 3 do assert(game:GetWorld() == currentWorld) end
            assert(currentWorld == runtime.world and currentWorld ~= previousWorld)
            assert(#previousWorld:GetEntities() == 0 and #previousWorld.entities == 0,
                "retired World must not retain its old entity array")
            assert(previousWorld:GetEntity(previousShip.id) == nil and not previousShip.alive)
            assert(runtime.ship ~= previousShip and runtime.world.scopeShip == runtime.ship)
            assert(runtime.surfaceSignals ~= previousSignals and runtime.surfaceSignals.world == currentWorld)
            assert(currentWorld.surfaceSignals == runtime.surfaceSignals)
            assert(#currentWorld.systems == 3)

            local entityStateRegistrations, signalRegistrations, frameRegistrations = 0, 0, 0
            for _, system in ipairs(currentWorld.systems) do
                if system == EntityStateSystem then entityStateRegistrations = entityStateRegistrations + 1 end
                if system == runtime.surfaceSignals then signalRegistrations = signalRegistrations + 1 end
                if system == game.gameplaySystem then frameRegistrations = frameRegistrations + 1 end
            end
            assert(entityStateRegistrations == 1 and signalRegistrations == 1 and frameRegistrations == 1,
                "rebuild must register each live System exactly once")

            local frameCount = frameLoop.calls
            previousWorld:Update(0.05, "frame")
            assert(frameLoop.calls == frameCount,
                "an externally retained retired World must not advance the current Gameplay loop")
            currentWorld:Update(0.05, "frame")
            assert(frameLoop.calls == frameCount + 1,
                "the current World advances the shared Gameplay loop exactly once")
        end
        metrics.repeatedRebuilds = #oldWorlds
        return { rebuilds = #oldWorlds, eachCurrentWorldSystemCount = 3,
            retiredEntityArraysEmpty = true, staleFrameAdvances = 0,
            currentFrameAdvances = frameLoop.calls }
    end)

    check("ship levels 9, 12, and 16 use real configured speed, turning, and swept island collision", function()
        local reports = {}
        ---@type integer[]
        local levels = { 1, 2, 3 }
        for _, level in ipairs(levels) do
            local runtime = Runtime.New({ initializeRegions = false,
                departure = { x = 0, y = 25 }, shipLevel = level })
            local expectedSpeed = Config.ship.speedByLevel[level]
            assert(expectedSpeed == ({ 9, 12, 16 })[level])
            near(runtime.movement.speed, expectedSpeed)
            local beforeX, beforeY = runtime.ship.position.x, runtime.ship.position.y
            runtime:Update(0.25, 1, 0)
            near(Math.distance(runtime.ship.position, { x = beforeX, y = beforeY }), expectedSpeed * 0.25)

            local island = runtime.world.entities[2]
            assert(island.entityType == "island" and island.blocking)
            local collisionCount = 0
            local originalMoveEntity = runtime.world.moveEntity
            runtime.world.moveEntity = function(world, entity, dx, dy)
                local collided, normalX, normalY = originalMoveEntity(world, entity, dx, dy)
                if entity == runtime.ship and collided then collisionCount = collisionCount + 1 end
                return collided, normalX, normalY
            end
            runtime.movement:SetTarget({ x = 60, y = 25 })
            for _ = 1, 64 do runtime:Update(0.25) end
            local combinedRadius = runtime.ship.radius + island.radius
            local islandDistance = Math.distance(runtime.ship.position, island.position)
            assert(collisionCount > 0, "the configured island should produce a real hull collision")
            assert(islandDistance >= combinedRadius - 0.005,
                "swept circle collision must keep the ship outside the island")

            local rotationBeforeTurn = runtime.ship.rotation
            local turnStart = Math.copy(runtime.ship.position)
            runtime.movement:SetTarget({ x = turnStart.x - 10, y = turnStart.y + 30 })
            advance(runtime, 1)
            local turnDelta = (runtime.ship.rotation - rotationBeforeTurn + math.pi) % (2 * math.pi) - math.pi
            assert(math.abs(turnDelta) > 0.2,
                "the levelled ship must turn through Movement rather than teleport its heading")
            assert(Math.distance(runtime.ship.position, turnStart) > 0.1)
            assert(Math.distance(runtime.ship.position, island.position) >= combinedRadius - 0.005)

            runtime.world.moveEntity = originalMoveEntity
            reports[#reports + 1] = { level = level, speedMetersPerSecond = runtime.movement.speed,
                expectedQuarterSecondTravel = expectedSpeed * 0.25,
                collisionCalls = collisionCount, islandClearance = islandDistance - combinedRadius,
                finalTurnRadians = runtime.ship.rotation }
        end
        metrics.speedAndCollision = reports
        return { levels = #reports, speeds = { reports[1].speedMetersPerSecond,
            reports[2].speedMetersPerSecond, reports[3].speedMetersPerSecond } }
    end)

    return { results = results, metrics = metrics }
end

return Tests
