local Tests = {}

local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local Config = require("Ocean.Config")
local Geometry = require("Ocean.ProjectedGeometry")

local BARREL_CONTENT_ID = "driftwood_barrel"

local function near(a, b, tolerance)
    return type(a) == "number" and type(b) == "number"
        and math.abs(a - b) <= (tolerance or 0.001)
end

local function captureState(runtime)
    local entities = {}
    for index, entity in ipairs(runtime.world.entities) do
        entities[index] = {
            id = entity.id,
            x = entity.position.x,
            y = entity.position.y,
            removed = entity.removed,
            alive = entity.alive,
            active = entity.active,
            frozen = entity.frozen,
        }
    end
    return {
        runtimeTime = runtime.time,
        worldTime = runtime.world.time,
        shipX = runtime.ship.position.x,
        shipY = runtime.ship.position.y,
        cameraX = runtime.movement.camera.x,
        cameraY = runtime.movement.camera.y,
        fixedBarrelGeneration = runtime.world.fixedBarrelGeneration,
        entityCount = #runtime.world.entities,
        revealCount = #runtime.world.reveals,
        entities = entities,
    }
end

local function assertStateUnchanged(before, runtime)
    local after = captureState(runtime)
    assert(after.runtimeTime == before.runtimeTime, "barrel rendering advanced runtime time")
    assert(after.worldTime == before.worldTime, "barrel rendering advanced world time")
    assert(after.shipX == before.shipX and after.shipY == before.shipY,
        "barrel rendering moved the ship")
    assert(after.cameraX == before.cameraX and after.cameraY == before.cameraY,
        "barrel rendering moved the camera")
    assert(after.fixedBarrelGeneration == before.fixedBarrelGeneration,
        "barrel rendering changed the fixed-barrel generation")
    assert(after.entityCount == before.entityCount and after.revealCount == before.revealCount,
        "barrel rendering changed world registration or reveals")
    for index, entity in ipairs(after.entities) do
        local old = before.entities[index]
        assert(old and entity.id == old.id, "barrel rendering reordered world entities")
        assert(entity.x == old.x and entity.y == old.y, "barrel rendering moved a world entity")
        assert(entity.removed == old.removed and entity.alive == old.alive
            and entity.active == old.active and entity.frozen == old.frozen,
            "barrel rendering changed an entity state")
    end
end

local function circlesAt(circles, x, y)
    local count = 0
    for _, circle in ipairs(circles) do
        if near(circle.x, x) and near(circle.y, y) then count = count + 1 end
    end
    return count
end

local function ellipsesAt(ellipses, x, y)
    local count = 0
    for _, ellipse in ipairs(ellipses) do
        if near(ellipse.x, x) and near(ellipse.y, y) then count = count + 1 end
    end
    return count
end

local function renderAt(recorder, distance, width, height, addDecoys)
    local fixedPosition = Config.world.fixedBarrel.position
    local runtime = Runtime.New({
        departure = { x = fixedPosition.x + distance, y = fixedPosition.y },
        initializeRegions = false,
    })
    assert(runtime.movement:SetViewport(width, height), "offline barrel viewport was not applied")

    local decoys = {}
    if addDecoys then
        for index, offset in ipairs({ 2, 4 }) do
            local entity = runtime.world:spawn({
                entityType = "float", kind = "fixed", layer = "surface",
                contentId = index == 1 and BARREL_CONTENT_ID or "cork_float",
                position = { x = runtime.ship.position.x + offset, y = runtime.ship.position.y },
                radius = 2, blocking = false,
            })
            local x, y = runtime.movement:WorldToScreen(entity.position)
            decoys[#decoys + 1] = { x = x, y = y }
        end
    end

    local snapshot = runtime:GetFixedBarrel()
    assert(snapshot and snapshot.contentId == BARREL_CONTENT_ID,
        "runtime did not expose the fixed barrel snapshot")
    local idWriteOk = pcall(function() snapshot.id = "changed" end)
    local positionWriteOk = pcall(function() snapshot.position.x = -999 end)
    assert(not idWriteOk and not positionWriteOk, "fixed-barrel snapshot was writable")

    local targetX, targetY = runtime.movement:WorldToScreen(snapshot.position)
    local targetMaxX = -math.huge
    for _, point in ipairs(Geometry.SampleCircle(snapshot.position, Config.world.fixedBarrel.radius)) do
        local px = runtime.movement:WorldToScreen(point)
        if px then targetMaxX = math.max(targetMaxX, px) end
    end
    local before = captureState(runtime)
    local circles, ellipses = {}, {}
    local originalCircle = Geometry.WorldCircle
    Geometry.WorldCircle = function(ctx, movement, center, radius, ...)
        if #Geometry.ClipPolygon(movement, Geometry.SampleCircle(center, radius)) >= 3 then
            local x, y, scale = movement:WorldToScreen(center)
            circles[#circles + 1] = { x = x, y = y, radius = radius * scale }
            if near(center.x, snapshot.position.x) and near(center.y, snapshot.position.y)
                and near(radius, Config.world.fixedBarrel.radius * 0.72) then
                ellipses[#ellipses + 1] = { x = x, y = y }
            end
        end
        return originalCircle(ctx, movement, center, radius, ...)
    end

    recorder.reset()
    local ok, err = pcall(function()
        SeaDraw.Scene({}, width, height, runtime)
    end)
    Geometry.WorldCircle = originalCircle
    if not ok then error(err) end
    assertStateUnchanged(before, runtime)

    local decoyCircleCounts = {}
    for index, point in ipairs(decoys) do
        decoyCircleCounts[index] = circlesAt(circles, point.x, point.y)
    end
    return {
        targetX = targetX,
        targetY = targetY,
        targetMaxX = targetMaxX,
        targetCircles = circlesAt(circles, targetX, targetY),
        targetEllipses = ellipsesAt(ellipses, targetX, targetY),
        decoyCircleCounts = decoyCircleCounts,
        nvgCallCount = recorder.callCount("nvgCircle"),
    }
end

function Tests.Run(recorder)
    local tests = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        tests[#tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("barrel_outline_and_recognition_boundaries_are_inclusive", function()
        local atOutlineLimit = renderAt(recorder, Config.interaction.outlineDistance, 5000, 1080)
        assert(atOutlineLimit.targetCircles == 1 and atOutlineLimit.targetEllipses == 0,
            "the exact outline limit should draw only the barrel outline")

        local beyondOutlineLimit = renderAt(recorder, Config.interaction.outlineDistance + 0.01, 5000, 1080)
        assert(beyondOutlineLimit.targetCircles == 0 and beyondOutlineLimit.targetEllipses == 0,
            "a barrel beyond the outline limit was drawn")

        local atRecognitionLimit = renderAt(recorder, Config.interaction.recognitionDistance, 5000, 1080)
        assert(atRecognitionLimit.targetCircles == 2 and atRecognitionLimit.targetEllipses == 1,
            "the exact recognition limit should draw the recognizable wooden barrel")

        local beyondRecognitionLimit = renderAt(recorder,
            Config.interaction.recognitionDistance + 0.01, 5000, 1080)
        assert(beyondRecognitionLimit.targetCircles == 1 and beyondRecognitionLimit.targetEllipses == 0,
            "just beyond the recognition limit should remain outline-only")
    end)

    check("barrel_screen_culling_keeps_partial_edges_and_skips_fully_offscreen", function()
        local partial = renderAt(recorder, 41.5, 1920, 1080)
        assert(partial.targetX < 0 and partial.targetMaxX > 0,
            "partial-edge fixture did not place the barrel inside its conservative screen margin")
        assert(partial.targetCircles == 1, "a partially visible barrel outline was culled")

        local outside = renderAt(recorder, 44, 1920, 1080)
        assert(outside.targetMaxX < 0, "offscreen fixture did not clear the projected barrel silhouette")
        assert(outside.targetCircles == 0 and outside.targetEllipses == 0,
            "a fully offscreen barrel was drawn")
    end)

    check("only_the_exact_barrel_gets_recognition_and_other_floats_keep_their_shape", function()
        local result = renderAt(recorder, Config.interaction.recognitionDistance,
            5000, 1080, true)
        assert(result.targetEllipses == 1 and result.targetCircles == 2,
            "the exact fixed barrel did not receive its close-range detail")
        assert(#result.decoyCircleCounts == 2
            and result.decoyCircleCounts[1] == 1 and result.decoyCircleCounts[2] == 1,
            "ordinary or contentId-matching non-barrel floats changed their generic drawing")
    end)

    local passed = true
    for _, test in ipairs(tests) do
        if not test.passed then passed = false end
    end
    return {
        status = passed and "PASS" or "FAIL",
        tests = tests,
        metrics = {
            outlineDistance = Config.interaction.outlineDistance,
            recognitionDistance = Config.interaction.recognitionDistance,
            contentId = BARREL_CONTENT_ID,
            offscreenCulling = "partial visible / full margin culled",
        },
    }
end

return Tests
