-- Capability-only authored content coverage. Fixtures never enter Content.fixed.
local Content = require "data.content"
local Config = require "Ocean.Config"
local Runtime = require "Ocean.SeaRuntime"

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value mismatch") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

function Tests.Run()
    local results, names = {}, {}
    local function test(name, run)
        assert(not names[name], "duplicate test name: " .. name)
        names[name] = true
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("authored island and wreck relations resolve without changing production content", function()
        local productionCount = #Content.fixed
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local island = assert(runtime:RegisterWorldContent({
            contentId = "fixture_capability_island", entityType = "island", kind = "fixed",
            position = { x = 120, y = 80 }, radius = 6, layer = "surface", blocking = true,
        }))
        local islandTreasure = assert(runtime:RegisterWorldContent({
            contentId = "fixture_capability_island_treasure", entityType = "treasure", kind = "fixed",
            at = { kind = "island", contentId = "fixture_capability_island" },
            localOffset = { x = 2, y = -3 }, radius = 0.5, layer = "underwater", blocking = false,
        }))
        local wreck = assert(runtime:RegisterWorldContent({
            contentId = "fixture_capability_wreck", entityType = "wreck", kind = "fixed",
            position = { x = 250, y = 200 }, radius = 8, layer = "underwater", blocking = false,
        }))
        local wreckTreasure = assert(runtime:RegisterWorldContent({
            contentId = "fixture_capability_wreck_treasure", entityType = "treasure", kind = "fixed",
            at = { kind = "wreck", contentId = "fixture_capability_wreck" },
            radius = 0.5, layer = "underwater", blocking = false,
        }))

        eq(island.position.x, 120)
        eq(island.position.y, 80)
        eq(islandTreasure.position.x, 122, "island offset x")
        eq(islandTreasure.position.y, 77, "island offset y")
        eq(wreckTreasure.position.x, wreck.position.x, "omitted offset uses container center x")
        eq(wreckTreasure.position.y, wreck.position.y, "omitted offset uses container center y")
        eq(#Content.fixed, productionCount, "test fixtures must not enter production content")
    end)

    test("reef and coral use regular radius, location, and scope queries", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local reef = assert(runtime:RegisterWorldContent({
            contentId = "fixture_capability_reef", entityType = "reef", kind = "fixed",
            position = { x = 10, y = 0 }, radius = 2, layer = "underwater", blocking = false,
        }))
        local coral = assert(runtime:RegisterWorldContent({
            contentId = "fixture_capability_coral", entityType = "coral", kind = "fixed",
            position = { x = 8, y = 3 }, radius = 1, layer = "underwater", blocking = false,
        }))

        local reefs = runtime:queryEntitiesInRadius({ x = 0, y = 0 }, 20, { entityType = "reef" })
        local corals = runtime:queryEntitiesInRadius({ x = 0, y = 0 }, 20, { entityType = "coral" })
        eq(#reefs, 1)
        eq(reefs[1].contentId, reef.contentId)
        eq(#corals, 1)
        eq(corals[1].contentId, coral.contentId)

        local reefAccess = assert(runtime:GetWorldContentAccess(reef.contentId))
        local coralAccess = assert(runtime:GetWorldContentAccess(coral.contentId))
        eq(reefAccess.distance, 10)
        eq(coralAccess.distance, math.sqrt(73))
        runtime:SetScopeEnabled(true)
        eq(runtime:IsWorldContentInScope(reef.contentId), true)
        eq(runtime:IsWorldContentInScope(coral.contentId), true)
        local snapshots = runtime:GetFixedWorldContentSnapshots()
        eq(#snapshots, #Content.fixed + 2, "registered fixed content snapshot count")
    end)

    test("invalid relative content does not register", function()
        local runtime = Runtime.New({ departure = Config.ship.start, initializeRegions = false })
        local result, reason = runtime:RegisterWorldContent({
            contentId = "fixture_capability_missing_offset_target", entityType = "treasure", kind = "fixed",
            at = { kind = "island", contentId = "missing_fixture_container" },
            localOffset = { x = 1, y = 0 }, radius = 0.5, layer = "underwater", blocking = false,
        })
        eq(result, nil)
        eq(reason, "content_container_unavailable")
        eq(runtime:GetWorldContent("fixture_capability_missing_offset_target"), nil)
    end)

    return results
end

return Tests
