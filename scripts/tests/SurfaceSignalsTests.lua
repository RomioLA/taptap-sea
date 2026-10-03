local Config = require("Ocean.Config")
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

local function countBySource(birds, sourceId)
    local count = 0
    for _, bird in ipairs(birds) do
        if bird.sourceId == sourceId then count = count + 1 end
    end
    return count
end

function Tests.Run()
    local results = {}
    local function test(name, callback)
        local ok, err = pcall(callback)
        results[#results + 1] = {
            name = name,
            passed = ok,
            error = not ok and tostring(err) or nil,
        }
    end

    test("active sardines receive deterministic read-only bird groups", function()
        local world, signals = newWorldWithSignals()
        local fish = spawnFish(world, "sardine", { x = 600, y = 600 })
        local fsm = { updates = 0 }
        fish.fsm = fsm
        local originalState = fish.state
        local originalPosition = { x = fish.position.x, y = fish.position.y }
        local originalEntityCount = #world.entities

        world:Update(0.05)
        local birds = signals:GetBirds()
        assert(#birds == 2 and countBySource(birds, fish.id) == 2)
        local centerX = (birds[1].position.x + birds[2].position.x) * 0.5
        local centerY = (birds[1].position.y + birds[2].position.y) * 0.5
        near(math.sqrt((centerX - fish.position.x)^2 + (centerY - fish.position.y)^2), 9)
        for _, bird in ipairs(birds) do
            local distance = math.sqrt((bird.position.x - fish.position.x)^2
                + (bird.position.y - fish.position.y)^2)
            assert(distance > 6 and distance < 12, "bird cue must stay in the nearby signal area")
            assert(world:isPositionFree(bird.position, 0), "bird cue must stay over open sea")
        end

        local firstPosition = { x = birds[1].position.x, y = birds[1].position.y }
        local firstDive = birds[1].diveProgress
        birds[1].position.x = -999
        local repeated = signals:GetBirds()
        near(repeated[1].position.x, firstPosition.x)
        near(repeated[1].position.y, firstPosition.y)
        near(repeated[1].diveProgress, firstDive)
        assert(fish.state == originalState and fish.fsm == fsm and fsm.updates == 0)
        near(fish.position.x, originalPosition.x)
        near(fish.position.y, originalPosition.y)
        assert(#world.entities == originalEntityCount and world:GetEntity(fish.id) == fish)
    end)

    test("bird polling is bounded and invalid sources disappear immediately", function()
        local world, signals = newWorldWithSignals()
        local first = spawnFish(world, "sardine", { x = 600, y = 600 })
        world:Update(0.05)
        assert(#signals:GetBirds() == 2)

        local second = spawnFish(world, "sardine", { x = 650, y = 650 })
        world:Update(0.10)
        assert(countBySource(signals:GetBirds(), second.id) == 0,
            "new groups wait for the quarter-second association poll")
        world:Update(0.15)
        assert(#signals:GetBirds() == 4)

        second.active = false
        world:Update(0)
        assert(countBySource(signals:GetBirds(), second.id) == 0)
        first.frozen = true
        world:Update(0)
        assert(#signals:GetBirds() == 0)

        first.frozen, first.active = false, true
        first.captureLocked = true
        world:Update(0.25)
        assert(#signals:GetBirds() == 0, "capture-locked fish do not create a bird cue")

        first.captureLocked = nil
        world:Update(0.25)
        assert(#signals:GetBirds() == 2)
        assert(world:remove(first.id, "removed"))
        assert(#signals:GetBirds() == 0,
            "standard removal immediately revokes the source cue")
    end)

    test("normal tuna splash cadence snapshots position and expires after removal", function()
        local world, signals = newWorldWithSignals()
        local tuna = spawnFish(world, "tuna", { x = 600, y = 600 }, "Wander")
        world:Update(0.5)
        assert(#signals:GetSplashes() == 0)

        tuna.position = { x = 605, y = 600 }
        tuna.rotation = math.pi * 0.5
        world:Update(0.5)
        local splashes = signals:GetSplashes()
        assert(#splashes == 1)
        near(splashes[1].position.x, 605)
        near(splashes[1].position.y, 600)
        near(splashes[1].heading, math.pi * 0.5)
        near(splashes[1].remaining, 0.6)
        near(splashes[1].lifetime, 0.6)
        near(splashes[1].trailLength, 2)

        tuna.position = { x = 700, y = 700 }
        local afterMove = signals:GetSplashes()
        near(afterMove[1].position.x, 605)
        near(afterMove[1].position.y, 600)
        world:remove(tuna.id, "caught")
        assert(#signals:GetSplashes() == 0, "removal immediately revokes source water cues")
    end)

    test("chasing tuna splash twice per second and zero dt never emits", function()
        local world, signals = newWorldWithSignals()
        spawnFish(world, "tuna", { x = 600, y = 600 }, "Chase")
        world:Update(0.25)
        world:Update(0)
        assert(#signals:GetSplashes() == 0)
        world:Update(0.25)
        assert(#signals:GetSplashes() == 1)
        world:Update(0.25)
        assert(#signals:GetSplashes() == 1)
        world:Update(0.25)
        assert(#signals:GetSplashes() == 2)
    end)

    test("frozen tuna stops emitting while clear empties signal state", function()
        local world, signals = newWorldWithSignals()
        local tuna = spawnFish(world, "tuna", { x = 600, y = 600 }, "Flee")
        world:Update(0.5)
        tuna.active, tuna.frozen = false, true
        world:Update(0)
        world:Update(1)
        assert(#signals:GetSplashes() == 0)

        tuna.active, tuna.frozen = true, false
        world:Update(1)
        assert(#signals:GetSplashes() == 1,
            "ordinary splash timing is independent of the fish being in Flee")
        local worldTime = world.time
        signals:Clear()
        assert(#signals:GetBirds() == 0 and #signals:GetSplashes() == 0)
        assert(world.time == worldTime, "clearing cues never advances world time")
    end)

    test("missing signal config stays disabled for legacy worlds", function()
        local settings = Config.surfaceSignals
        Config.surfaceSignals = nil
        local ok, err = pcall(function()
            local world, signals = newWorldWithSignals()
            spawnFish(world, "sardine", { x = 600, y = 600 })
            spawnFish(world, "tuna", { x = 650, y = 650 }, "Chase")
            world:Update(2)
            assert(#signals:GetBirds() == 0 and #signals:GetSplashes() == 0)
        end)
        Config.surfaceSignals = settings
        assert(ok, err)
    end)

    return { results = results }
end

return Tests
