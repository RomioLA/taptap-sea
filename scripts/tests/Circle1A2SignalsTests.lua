local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local World = require("Ocean.World")
local SurfaceSignals = require("Ocean.SurfaceSignals")

local Tests = {}

local function near(actual, expected, epsilon)
    assert(math.abs(actual - expected) <= (epsilon or 0.00001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

local function newWorldWithSignals()
    local world = World.New()
    local signals = SurfaceSignals.New(world)
    world.surfaceSignals = signals
    world:AddSystem(signals)
    return world, signals
end

local function spawnFish(world, species, position, state)
    return world:spawn({
        entityType = "fish",
        kind = "dynamic",
        layer = "underwater",
        position = position,
        species = species,
        ordinaryFish = true,
        active = true,
        frozen = false,
        state = state or "Wander",
    })
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("Circle1A2 birds preserve confirmed geometry and legal water", function()
        local world, signals = newWorldWithSignals()
        local fish = spawnFish(world, "sardine", { x = 600, y = 600 }, "Wander")
        local fsm = { updateCount = 0 }
        fish.fsm = fsm
        local position = { x = fish.position.x, y = fish.position.y }
        local count = #world.entities

        world:Update(0.05)
        local birds = signals:GetBirds()
        assert(#birds == 2, "one live sardine receives the confirmed pair of birds")
        near(Config.surfaceSignals.birdOffset, 9)
        near(Config.surfaceSignals.birdRadius, 3)
        near(Config.surfaceSignals.birdDiveSeconds, 1.5)

        local centerX = (birds[1].position.x + birds[2].position.x) * 0.5
        local centerY = (birds[1].position.y + birds[2].position.y) * 0.5
        near(math.sqrt((centerX - fish.position.x)^2 + (centerY - fish.position.y)^2), 9)
        for _, bird in ipairs(birds) do
            local dx = bird.position.x - fish.position.x
            local dy = bird.position.y - fish.position.y
            local distance = math.sqrt(dx * dx + dy * dy)
            assert(distance <= 18, "bird location remains inside the sardine bait-sense radius")
            assert(world:isPositionFree(bird.position, 0), "bird location must remain in legal water")
        end
        assert(fish.state == "Wander" and fish.fsm == fsm and fsm.updateCount == 0,
            "bird cues do not require a flee state or drive fish AI")
        near(fish.position.x, position.x)
        near(fish.position.y, position.y)
        assert(#world.entities == count, "bird cues do not create world entities")
    end)

    check("Circle1A2 first bird dive lasts 1.5 seconds and getters are read-only", function()
        local world, signals = newWorldWithSignals()
        spawnFish(world, "sardine", { x = 600, y = 600 })
        world:Update(0.05)
        world:Update(0.95)
        local beforeEnd = signals:GetBirds()
        assert(beforeEnd[1].diveProgress < 1, "the first dive is still active before 1.5 seconds")
        world:Update(0.5)
        local birds = signals:GetBirds()
        near(birds[1].diveProgress, 1)

        local saved = { x = birds[1].position.x, y = birds[1].position.y }
        local savedTime = world.time
        birds[1].position.x = -9999
        birds[1].diveProgress = -1
        local repeated = signals:GetBirds()
        near(repeated[1].position.x, saved.x)
        near(repeated[1].position.y, saved.y)
        near(repeated[1].diveProgress, 1)
        near(world.time, savedTime)
    end)

    check("Circle1A2 getters reject stale or illegal current fish positions", function()
        local world, signals = newWorldWithSignals()
        local sardine = spawnFish(world, "sardine", { x = 600, y = 600 })
        local tuna = spawnFish(world, "tuna", { x = 630, y = 600 })
        world:Update(1)
        assert(#signals:GetBirds() == 2 and #signals:GetSplashes() == 1)

        sardine.position = { x = 700, y = 600 }
        assert(#signals:GetBirds() == 0,
            "a stale cue cannot point more than 18 m from its associated fish")
        sardine.position = { x = 10000, y = 600 }
        world:Update(0)
        sardine.position = { x = 600, y = 600 }
        tuna.position = { x = 10000, y = 600 }
        assert(#signals:GetBirds() == 0 and #signals:GetSplashes() == 0,
            "fish outside legal water cannot keep an old surface clue visible")
        world:Update(0)
        assert(#signals.splashes == 0)
    end)

    check("Circle1A2 locked, frozen, inactive, invalid, and removed sources lose cues", function()
        local world, signals = newWorldWithSignals()
        local sardine = spawnFish(world, "sardine", { x = 600, y = 600 })
        local tuna = spawnFish(world, "tuna", { x = 630, y = 600 })
        world:Update(1)
        assert(#signals:GetBirds() == 2 and #signals:GetSplashes() == 1,
            "fixture needs both surface cue types")

        sardine.active = false
        tuna.frozen = true
        assert(#signals:GetBirds() == 0 and #signals:GetSplashes() == 0,
            "getters hide inactive and frozen sources before the next update")
        world:Update(0)
        sardine.active, tuna.frozen = true, false
        world:Update(0.25)
        assert(#signals:GetBirds() == 2)

        sardine.captureLocked = true
        tuna.captureLocked = true
        signals:OnCaptureLocked(sardine.id)
        signals:OnCaptureLocked(tuna.id)
        assert(#signals:GetBirds() == 0 and #signals:GetSplashes() == 0,
            "capture lock immediately removes both source cues and timers")
        world:Update(0)
        sardine.captureLocked, tuna.captureLocked = false, false
        world:Update(1)
        assert(#signals:GetBirds() == 2 and #signals:GetSplashes() == 1)

        sardine.position = { x = 0 / 0, y = 600 }
        tuna.position = { x = 0 / 0, y = 600 }
        assert(#signals:GetBirds() == 0 and #signals:GetSplashes() == 0,
            "non-finite source positions are rejected by read-only getters")
        world:Update(0)
        assert(#signals.splashes == 0, "zero-delta update prunes invalid-position splashes")

        sardine.position, tuna.position = { x = 600, y = 600 }, { x = 630, y = 600 }
        world:Update(0.25)
        assert(#signals:GetBirds() == 2)
        assert(world:remove(sardine.id, "caught"))
        assert(world:remove(tuna.id, "eaten"))
        assert(#signals:GetBirds() == 0 and #signals:GetSplashes() == 0,
            "caught or eaten sources revoke cues immediately")

        local liveTuna = spawnFish(world, "tuna", { x = 640, y = 600 })
        world:Update(1)
        assert(#signals:GetSplashes() == 1)
        liveTuna.active = false
        assert(#signals:GetSplashes() == 0)
        world:Update(0)
        liveTuna.active = true
        world:Update(1)
        assert(#signals:GetSplashes() == 1)
        assert(world:remove(liveTuna.id, "removed"))
        assert(#signals:GetSplashes() == 0)
    end)

    check("Circle1A2 pause freezes splash timers and reset clears cues", function()
        local runtime = Runtime.New({ initializeRegions = false, departure = { x = 0, y = 0 } })
        local tuna = runtime:spawnFish("tuna", { x = 10, y = 0 }, 0)
        runtime:Update(0.25)
        runtime:Update(0.5)
        assert(#runtime.surfaceSignals:GetSplashes() == 0)
        local remaining = runtime.surfaceSignals.splashTimers[tuna.id].remaining
        local worldTime = runtime.world.time
        runtime:TogglePause()
        runtime:Update(2)
        near(runtime.surfaceSignals.splashTimers[tuna.id].remaining, remaining)
        near(runtime.world.time, worldTime)
        runtime:TogglePause()
        runtime:Update(0.25)
        runtime:Update(0.25)
        assert(#runtime.surfaceSignals:GetSplashes() == 1,
            "paused wall time does not advance the one-second splash timer")

        local splash = runtime.surfaceSignals:GetSplashes()[1]
        local splashRemaining = splash.remaining
        local currentWorldTime = runtime.world.time
        splash.position.x = -10000
        splash.remaining = -10
        local repeated = runtime.surfaceSignals:GetSplashes()[1]
        near(repeated.position.x, tuna.position.x)
        near(repeated.remaining, splashRemaining)
        near(runtime.world.time, currentWorldTime)

        runtime:Reset()
        assert(#runtime.surfaceSignals:GetBirds() == 0 and #runtime.surfaceSignals:GetSplashes() == 0,
            "reset clears cached surface cues")
    end)

    check("Circle1A2 chase splashes follow the confirmed half-second cadence", function()
        local world, signals = newWorldWithSignals()
        local tuna = spawnFish(world, "tuna", { x = 600, y = 600 }, "Chase")
        world:Update(0.25)
        assert(#signals:GetSplashes() == 0)
        world:Update(0.25)
        assert(#signals:GetSplashes() == 1)
        near(signals:GetSplashes()[1].lifetime, 0.6)
        near(signals:GetSplashes()[1].trailLength, 2)
        world:Update(0.5)
        assert(#signals:GetSplashes() == 2)
        tuna.state = "Wander"
        world:Update(0.5)
        local splashes = signals:GetSplashes()
        assert(#splashes == 2, "the third chase splash replaces the one whose 0.6 second life elapsed")
        near(splashes[#splashes].lifetime, 0.6)

        local ordinaryWorld, ordinarySignals = newWorldWithSignals()
        spawnFish(ordinaryWorld, "tuna", { x = 600, y = 600 }, "Wander")
        ordinaryWorld:Update(0.5)
        assert(#ordinarySignals:GetSplashes() == 0)
        ordinaryWorld:Update(0.5)
        assert(#ordinarySignals:GetSplashes() == 1,
            "ordinary activity emits at the confirmed one-second interval")
    end)

    check("Circle1A2 clearing cues does not advance or reset world time", function()
        local world, signals = newWorldWithSignals()
        spawnFish(world, "tuna", { x = 600, y = 600 })
        world:Update(0.5)
        local time = world.time
        signals:Clear()
        assert(#signals:GetBirds() == 0 and #signals:GetSplashes() == 0)
        near(world.time, time)
    end)

    return { results = results }
end

return Tests
