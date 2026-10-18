local World = require("Ocean.World")
local SurfaceSignals = require("Ocean.SurfaceSignals")

---@class Circle1A3VisitedBird
---@field x number
---@field y number
---@field heading number
---@field diveProgress number
---@field id string
---@field sourceId string

---@class Circle1A3VisitedSplash
---@field x number
---@field y number
---@field remaining number
---@field lifetime number
---@field heading number
---@field trailLength number
---@field sourceId string

local Tests = {}

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

    check("A3 scalar visitors match detached snapshots without exposing tables", function()
        local world, signals = newWorldWithSignals()
        spawnFish(world, "sardine", { x = 600, y = 600 })
        spawnFish(world, "sardine", { x = 650, y = 650 })
        spawnFish(world, "tuna", { x = 700, y = 700 }, "Chase")
        world:Update(1)

        local birds = signals:GetBirds()
        ---@type Circle1A3VisitedBird[]
        local visitedBirds = {}
        local birdCount = signals:VisitBirds(function(x, y, heading, diveProgress, id, sourceId)
            assert(type(x) == "number" and type(y) == "number")
            assert(type(heading) == "number" and type(diveProgress) == "number")
            assert(type(id) == "string" and type(sourceId) == "string")
            visitedBirds[#visitedBirds + 1] = {
                x = x, y = y, heading = heading, diveProgress = diveProgress,
                id = id, sourceId = sourceId,
            }
            -- Assignments affect only this callback's scalar locals.
            x, y, heading, diveProgress, id, sourceId = -1, -1, -1, -1, "", ""
        end)
        assert(birdCount == #birds and birdCount == #visitedBirds)
        for index, bird in ipairs(birds) do
            ---@type Circle1A3VisitedBird
            local visited = visitedBirds[index]
            assert(bird.id == visited.id and bird.sourceId == visited.sourceId)
            assert(bird.position.x == visited.x and bird.position.y == visited.y)
            assert(bird.heading == visited.heading and bird.diveProgress == visited.diveProgress)
        end

        local splashes = signals:GetSplashes()
        ---@type Circle1A3VisitedSplash[]
        local visitedSplashes = {}
        local splashCount = signals:VisitSplashes(function(x, y, remaining, lifetime,
            heading, trailLength, sourceId)
            assert(type(x) == "number" and type(y) == "number")
            assert(type(remaining) == "number" and type(lifetime) == "number")
            assert(type(heading) == "number" and type(trailLength) == "number")
            assert(type(sourceId) == "string")
            visitedSplashes[#visitedSplashes + 1] = {
                x = x, y = y, remaining = remaining, lifetime = lifetime,
                heading = heading, trailLength = trailLength, sourceId = sourceId,
            }
            x, y, remaining, lifetime, heading, trailLength, sourceId = -1, -1, -1, -1, -1, -1, ""
        end)
        assert(splashCount == #splashes and splashCount == #visitedSplashes)
        for index, splash in ipairs(splashes) do
            ---@type Circle1A3VisitedSplash
            local visited = visitedSplashes[index]
            assert(splash.sourceId == visited.sourceId)
            assert(splash.position.x == visited.x and splash.position.y == visited.y)
            assert(splash.remaining == visited.remaining and splash.lifetime == visited.lifetime)
            assert(splash.heading == visited.heading and splash.trailLength == visited.trailLength)
        end

        birds[1].position.x = -9999
        splashes[1].position.x = -9999
        assert(signals:GetBirds()[1].position.x ~= -9999)
        assert(signals:GetSplashes()[1].position.x ~= -9999)
    end)

    check("A3 visitors revalidate freeze, removal, fish position, and old splash water", function()
        local world, signals = newWorldWithSignals()
        local sardine = spawnFish(world, "sardine", { x = 600, y = 600 })
        local tuna = spawnFish(world, "tuna", { x = 630, y = 600 }, "Chase")
        world:Update(0.5)
        assert(signals:VisitBirds(function() end) == 2)
        assert(signals:VisitSplashes(function() end) == 1)

        sardine.frozen = true
        tuna.position = { x = 640, y = 600 }
        assert(signals:VisitBirds(function() end) == 0,
            "freezing a source revokes its bird cue in the same frame")

        local splashPosition = signals.splashes[1].position
        local blocker = world:spawn({ entityType = "dynamicBlocker", kind = "dynamic",
            blocking = true, position = { x = splashPosition.x, y = splashPosition.y }, radius = 1 })
        assert(signals:VisitSplashes(function() end) == 0,
            "an old splash over newly blocked water is revoked even while its tuna moved to legal water")
        assert(#signals:GetSplashes() == 0)
        world:Update(0)
        assert(#signals.splashes == 0, "zero-delta pruning drops an invalid water splash")

        sardine.frozen = false
        world:remove(blocker.id, "test cleanup")
        world:remove(tuna.id, "test removal")
        assert(signals:VisitSplashes(function() end) == 0,
            "removing a source revokes its splash before another simulation update")

        tuna.position = { x = 640, y = 600 }
        local liveTuna = spawnFish(world, "tuna", { x = 640, y = 600 }, "Chase")
        world:Update(0.5)
        assert(signals:VisitSplashes(function() end) == 1)
        liveTuna.position = { x = 0 / 0, y = 600 }
        assert(signals:VisitSplashes(function() end) == 0,
            "non-finite current fish position cannot leave an old splash visible")
    end)

    check("A3 reused water-query workspace refreshes blockers and keeps snapshots independent", function()
        local world = World.New()
        local point = { x = 500, y = 500 }
        local snapshot = world:CreateWaterQuery()
        local workspace = {}
        local query = world:CreateWaterQuery(workspace)
        assert(query == world:CreateWaterQuery(workspace), "workspace query closure is reused")

        local blocker = world:spawn({ entityType = "dynamicBlocker", kind = "dynamic",
            blocking = true, position = { x = point.x, y = point.y }, radius = 1 })
        assert(snapshot(point, 0), "an independent snapshot does not see a later blocker")
        query = world:CreateWaterQuery(workspace)
        assert(not query(point, 0), "workspace refresh sees newly added blockers")

        blocker.position = { x = point.x + 10, y = point.y }
        query = world:CreateWaterQuery(workspace)
        assert(query(point, 0), "workspace refresh sees blockers at their current positions")
        world:remove(blocker.id, "test cleanup")
        query = world:CreateWaterQuery(workspace)
        assert(query(point, 0), "workspace refresh excludes removed blockers")
    end)

    return { results = results }
end

return Tests
