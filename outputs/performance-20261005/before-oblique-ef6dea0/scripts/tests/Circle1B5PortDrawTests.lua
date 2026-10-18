-- Offline draw contract for the authored Circle 1 B5 port location marker.
local Tests = {}

local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local PORT_MARK_RADIUS = 16

local function near(actual, expected, tolerance)
    return type(actual) == "number" and math.abs(actual - expected) <= (tolerance or 0.001)
end

local function assertNear(actual, expected, label, tolerance)
    assert(near(actual, expected, tolerance),
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function createRuntime(width, height)
    local runtime = Runtime.New({
        departure = { x = 12, y = -4 },
        initializeRegions = false,
    })
    assert(runtime.movement:SetViewport(width, height), "offline port viewport was not applied")
    return runtime
end

local function projectedPort(runtime)
    local port = runtime:GetPortPosition()
    local movement = runtime.movement
    local scale = movement.viewportWidth / movement.viewWidth
    return movement.viewportWidth * 0.5 + (port.x - movement.camera.x) * scale,
        movement.viewportHeight * 0.5 - (port.y - movement.camera.y) * scale
end

local function captureState(runtime)
    local entities = {}
    for index, entity in ipairs(runtime.world.entities) do
        entities[index] = {
            id = entity.id,
            x = entity.position.x,
            y = entity.position.y,
            removed = entity.removed,
            active = entity.active,
            frozen = entity.frozen,
        }
    end
    return {
        time = runtime.time,
        worldTime = runtime.world.time,
        shipX = runtime.ship.position.x,
        shipY = runtime.ship.position.y,
        cameraX = runtime.movement.camera.x,
        cameraY = runtime.movement.camera.y,
        viewportWidth = runtime.movement.viewportWidth,
        viewportHeight = runtime.movement.viewportHeight,
        viewWidth = runtime.movement.viewWidth,
        viewHeight = runtime.movement.viewHeight,
        entityCount = #runtime.world.entities,
        revealCount = #runtime.world.reveals,
        mapSize = Config.world.mapSize,
        halfSize = Config.world.halfSize,
        portX = Config.ship.start.x,
        portY = Config.ship.start.y,
        entities = entities,
    }
end

local function assertUnchanged(before, runtime, label)
    local after = captureState(runtime)
    for _, key in ipairs({
        "time", "worldTime", "shipX", "shipY", "cameraX", "cameraY",
        "viewportWidth", "viewportHeight", "viewWidth", "viewHeight",
        "entityCount", "revealCount", "mapSize", "halfSize", "portX", "portY",
    }) do
        assert(after[key] == before[key], label .. " changed " .. key)
    end
    for index, entity in ipairs(after.entities) do
        local old = before.entities[index]
        assert(old and entity.id == old.id, label .. " changed world entity registration")
        assert(entity.x == old.x and entity.y == old.y, label .. " moved a world entity")
        assert(entity.removed == old.removed and entity.active == old.active
            and entity.frozen == old.frozen, label .. " changed a world entity state")
    end
end

local function render(runtime, width, height, recorder)
    local capture = { circles = {}, moves = {}, lines = {} }
    local before = captureState(runtime)
    local originalCircle, originalMove, originalLine = nvgCircle, nvgMoveTo, nvgLineTo
    nvgCircle = function(ctx, x, y, radius)
        capture.circles[#capture.circles + 1] = { x = x, y = y, radius = radius }
        return originalCircle(ctx, x, y, radius)
    end
    nvgMoveTo = function(ctx, x, y)
        capture.moves[#capture.moves + 1] = { x = x, y = y }
        return originalMove(ctx, x, y)
    end
    nvgLineTo = function(ctx, x, y)
        capture.lines[#capture.lines + 1] = { x = x, y = y }
        return originalLine(ctx, x, y)
    end
    local ok, err = pcall(function()
        recorder.reset()
        SeaDraw.Scene({}, width, height, runtime)
    end)
    nvgCircle, nvgMoveTo, nvgLineTo = originalCircle, originalMove, originalLine
    if not ok then error(err) end
    assertUnchanged(before, runtime, "port marker rendering")
    return capture
end

local function ringCount(capture, x, y)
    local count = 0
    for _, circle in ipairs(capture.circles) do
        if near(circle.radius, PORT_MARK_RADIUS) and near(circle.x, x) and near(circle.y, y) then
            count = count + 1
        end
    end
    return count
end

local function hasPoint(points, x, y)
    for _, point in ipairs(points) do
        if near(point.x, x) and near(point.y, y) then return true end
    end
    return false
end

local function assertAnchorAt(capture, x, y)
    assert(ringCount(capture, x, y) == 2,
        "the port marker must draw both contrast rings at the projected harbor point")
    assert(hasPoint(capture.moves, x, y - 8) and hasPoint(capture.lines, x, y + 5),
        "the anchor shaft did not stay at the projected harbor point")
    assert(hasPoint(capture.moves, x - 8, y - 2) and hasPoint(capture.lines, x + 8, y - 2),
        "the anchor crossbar did not stay at the projected harbor point")
end

function Tests.Run(recorder)
    local tests = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        tests[#tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("authored_port_uses_current_world_to_screen_projection", function()
        local width, height = 1920, 1080
        local runtime = createRuntime(width, height)
        local port = runtime:GetPortPosition()
        assert(port.x == Config.ship.start.x and port.y == Config.ship.start.y,
            "the runtime port position diverged from the authored harbor anchor")
        assert(runtime.ship.position.x ~= port.x or runtime.ship.position.y ~= port.y,
            "fixture departure must be distinct from the harbor anchor")
        local expectedX, expectedY = projectedPort(runtime)
        local capture = render(runtime, width, height, recorder)
        assertAnchorAt(capture, expectedX, expectedY)
    end)

    check("camera_motion_reprojects_the_marker_without_moving_the_world", function()
        local width, height = 1920, 1080
        local runtime = createRuntime(width, height)
        runtime.movement.camera.x = 4
        runtime.movement.camera.y = 3
        local expectedX, expectedY = projectedPort(runtime)
        assert(expectedX ~= width * 0.5 or expectedY ~= height * 0.5,
            "camera fixture did not move the harbor projection")
        local capture = render(runtime, width, height, recorder)
        assertAnchorAt(capture, expectedX, expectedY)
    end)

    check("resize_and_dpr_keep_the_marker_in_logical_screen_coordinates", function()
        local runtime = createRuntime(1920, 1080)
        local physicalWidth, physicalHeight, dpr = 1800, 2400, 2
        local logicalWidth, logicalHeight = physicalWidth / dpr, physicalHeight / dpr
        assert(runtime.movement:SetViewport(logicalWidth, logicalHeight),
            "logical resize was not applied to the camera")
        assertNear(runtime.movement.viewHeight, Config.camera.viewHeight, "resized camera view height")
        assertNear(runtime.movement.viewWidth,
            Config.camera.viewHeight * logicalWidth / logicalHeight, "resized camera view width")
        local expectedX, expectedY = projectedPort(runtime)
        local capture = render(runtime, logicalWidth, logicalHeight, recorder)
        assertAnchorAt(capture, expectedX, expectedY)
        assertNear(expectedX * dpr,
            physicalWidth * 0.5 + (runtime:GetPortPosition().x - runtime.movement.camera.x)
                * (physicalWidth / runtime.movement.viewWidth), "DPR-scaled port X")
        assertNear(expectedY * dpr,
            physicalHeight * 0.5 - (runtime:GetPortPosition().y - runtime.movement.camera.y)
                * (physicalHeight / runtime.movement.viewHeight), "DPR-scaled port Y")
    end)

    check("offscreen_port_is_culled_without_edge_snapping_or_view_expansion", function()
        local width, height = 1920, 1080
        local runtime = createRuntime(width, height)
        local port = runtime:GetPortPosition()
        local movement = runtime.movement
        local scale = movement.viewportWidth / movement.viewWidth
        movement.camera.x = port.x + (width * 0.5 + PORT_MARK_RADIUS + 20) / scale
        movement.camera.y = port.y + height * 0.1 / scale
        local projectedX, projectedY = projectedPort(runtime)
        assert(projectedX < -(PORT_MARK_RADIUS + 2), "offscreen fixture left the port partially visible")
        assertNear(projectedY, height * 0.6, "offscreen fixture water position")
        local viewWidth, viewHeight = movement.viewWidth, movement.viewHeight
        local capture = render(runtime, width, height, recorder)
        local edgeRings = 0
        for _, circle in ipairs(capture.circles) do
            if near(circle.radius, PORT_MARK_RADIUS) then edgeRings = edgeRings + 1 end
        end
        assert(edgeRings == 0, "an offscreen harbor marker was snapped to a viewport edge")
        assert(movement.viewWidth == viewWidth and movement.viewHeight == viewHeight,
            "offscreen culling expanded the ocean display range")
    end)

    local passed = true
    for _, test in ipairs(tests) do
        if not test.passed then passed = false end
    end
    return {
        status = passed and "PASS" or "FAIL",
        tests = tests,
        metrics = {
            markerRadius = PORT_MARK_RADIUS,
            projection = "runtime:GetPortPosition() -> Movement:WorldToScreen()",
            resolutionMode = "logical pixels with DPR scaling at NanoVG frame boundary",
            offscreenBehavior = "culled at original projection; no edge snapping",
        },
    }
end

return Tests
