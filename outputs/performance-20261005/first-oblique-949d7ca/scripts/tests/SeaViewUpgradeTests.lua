local Config = require("Ocean.Config")
local Math = require("Ocean.Math")
local Runtime = require("Ocean.SeaRuntime")
local Geometry = require("Ocean.ProjectedGeometry")
local Wake = require("Ocean.Wake")

local Tests = {}

local function near(actual, expected, tolerance, label)
    tolerance = tolerance or 1e-6
    assert(type(actual) == "number" and math.abs(actual - expected) <= tolerance,
        (label or "value") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

---@return OceanPoint
local function point(x, y)
    return { x = x, y = y }
end

---@param value OceanPoint
---@return OceanPoint
local function copyPoint(value)
    return { x = value.x, y = value.y }
end

local function distance(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function fresh(width, height)
    local runtime = Runtime.New({ initializeRegions = false })
    assert(runtime.movement:SetViewport(width or 1280, height or 720),
        "logical viewport was not applied")
    return runtime
end

local function project(movement, position, altitude)
    local x, y, scale = movement:WorldToScreen(position, altitude)
    assert(type(x) == "number" and type(y) == "number" and type(scale) == "number"
        and scale > 0, "expected a finite projected point and local scale")
    return x, y, scale
end

local function roundTrip(movement, position)
    local x, y = project(movement, position)
    local world = movement:ScreenToWorld(x, y)
    assert(type(world) == "table" and type(world.x) == "number" and type(world.y) == "number",
        "projected ground point did not unproject")
    near(world.x, position.x, 1e-6, "round-trip world X")
    near(world.y, position.y, 1e-6, "round-trip world Y")
    return world
end

local function recordsCopy(wake)
    local records = {}
    for index, record in ipairs(wake.records) do
        records[index] = {
            position = copyPoint(record.position),
            rotation = record.rotation,
            age = record.age,
        }
    end
    return records
end

local function check(name, fn, results)
    local ok, err = pcall(fn)
    results[#results + 1] = {
        name = name,
        passed = ok,
        error = ok and "" or tostring(err),
    }
end

function Tests.Run()
    local results = {}
    local metrics = {}

    check("camera_configuration_uses_the_confirmed_world_oblique_values", function()
        near(Config.camera.anchorY, 0.72)
        near(Config.camera.horizonY, 0.24)
        near(Config.camera.depthCompression, 0.65)
        near(Config.camera.farDepth, 220)
        near(Config.camera.anchorX, 0.5)
        near(Config.camera.viewHeight, 45)
        near(Config.visual.wake.lifetimeSec, 3)
        near(Config.visual.wake.spacingMeters, 0.6)
        near(Config.visual.wake.minSpeed, 0.15)
        assert(Config.visual.wake.maxSamples == 96)
        near(Config.visual.wake.initialWidth, 0.65)
        near(Config.visual.wake.spreadPerSec, 0.45)
        near(Config.visual.wake.sternOffset, 2.5)
        assert(Config.visual.wake.opacity == 125)
    end, results)

    check("eight_heading_inputs_keep_the_same_meter_speed", function()
        local frame = 0.25
        for directionIndex = 0, 7 do
            local angle = directionIndex * math.pi / 4
            local axisX, axisY = math.cos(angle), math.sin(angle)
            local runtime = fresh(1280, 720)
            runtime.ship.rotation = angle
            local before = copyPoint(runtime.ship.position)
            runtime:Update(frame, axisX, axisY)
            local moved = runtime.ship.position
            local expectedDistance = runtime.movement.speed * frame
            near(distance(before, moved), expectedDistance, 1e-5, "heading travel distance")
            near(moved.x - before.x, math.cos(angle) * expectedDistance, 1e-5, "heading X")
            near(moved.y - before.y, math.sin(angle) * expectedDistance, 1e-5, "heading Y")
        end
        metrics.headingCount = 8
    end, results)

    check("camera_follows_continuously_and_returns_smoothly_when_the_ship_stops", function()
        local runtime = fresh(1280, 720)
        local movement = runtime.movement
        local startX = movement.camera.x
        runtime:Update(0.05, 1, 0)
        local shipX = runtime.ship.position.x
        local cameraX = movement.camera.x
        assert(cameraX > startX and cameraX < shipX,
            "camera must ease toward the ship during the first movement step")
        local blend = 1 - math.exp(-0.05 / Config.camera.followSec)
        near(cameraX, startX + (shipX - startX) * blend, 1e-6, "smooth follow step")
        local screenX = project(movement, runtime.ship.position)
        assert(screenX > movement.viewportWidth * Config.camera.anchorX,
            "ship projection did not move continuously with the lagging camera")

        for _ = 1, 20 do runtime:Update(0.05, 1, 0) end
        local previousOffset = project(movement, runtime.ship.position)
            - movement.viewportWidth * Config.camera.anchorX
        assert(previousOffset > 0, "continuous travel did not retain a small follow lag")

        for _ = 1, 30 do
            runtime:Update(0.05, 0, 0)
            local nextOffset = project(movement, runtime.ship.position)
                - movement.viewportWidth * Config.camera.anchorX
            assert(nextOffset <= previousOffset + 1e-6 and nextOffset >= -1e-6,
                "stopped-ship camera return was discontinuous or moved away")
            previousOffset = nextOffset
        end
        near(previousOffset, 0, 0.01, "stopped ship anchor X")
        local _, screenY = project(movement, runtime.ship.position)
        near(screenY, movement.viewportHeight * Config.camera.anchorY, 0.01,
            "stopped ship anchor Y")
    end, results)

    check("projection_formula_and_inverse_hold_at_multiple_world_depths", function()
        local runtime = fresh(1280, 720)
        local movement = runtime.movement
        local camera = movement.camera
        local view = Config.camera
        local cameraDistance = view.viewHeight * (view.anchorY - view.horizonY)
            / view.depthCompression
        local base = movement.viewportHeight / view.viewHeight
        local depths = { 0, 20, 85, 200 }
        local offsets = { 0, 7, -12, 32 }
        for index, depth in ipairs(depths) do
            local world = point(camera.x + offsets[index], camera.y + depth)
            local x, y, scale = project(movement, world)
            local q = cameraDistance / (cameraDistance + depth)
            near(x, movement.viewportWidth * view.anchorX + offsets[index] * base * q,
                1e-6, "projected X")
            near(y, movement.viewportHeight * view.horizonY
                + movement.viewportHeight * (view.anchorY - view.horizonY) * q,
                1e-6, "projected Y")
            near(scale, base * q, 1e-6, "projected pixels per meter")
            roundTrip(movement, world)
        end
        metrics.projectedDepthsMeters = depths
    end, results)

    check("logical_projection_resizes_correctly_across_aspect_and_dpr", function()
        local runtime = fresh(1280, 720)
        local movement = runtime.movement
        local cameraX, cameraY = movement.camera.x, movement.camera.y
        local cases = {
            { physicalWidth = 1920, physicalHeight = 1080, dpr = 1 },
            { physicalWidth = 1800, physicalHeight = 2400, dpr = 2 },
            { physicalWidth = 1170, physicalHeight = 2532, dpr = 3 },
        }
        for _, sample in ipairs(cases) do
            local logicalWidth = sample.physicalWidth / sample.dpr
            local logicalHeight = sample.physicalHeight / sample.dpr
            assert(movement:SetViewport(logicalWidth, logicalHeight),
                "resize did not update the logical viewport")
            near(movement.camera.x, cameraX, 1e-9, "resize changed camera world X")
            near(movement.camera.y, cameraY, 1e-9, "resize changed camera world Y")
            local world = point(cameraX + 9, cameraY + 55)
            local x, y = project(movement, world)
            roundTrip(movement, world)
            local cameraDistance = Config.camera.viewHeight * (Config.camera.anchorY - Config.camera.horizonY) / Config.camera.depthCompression
            local q = cameraDistance / (cameraDistance + 55)
            near(x * sample.dpr, sample.physicalWidth * Config.camera.anchorX
                + 9 * (sample.physicalHeight / Config.camera.viewHeight) * q,
                1e-5, "DPR-scaled physical X")
            near(y * sample.dpr, sample.physicalHeight * Config.camera.horizonY
                + sample.physicalHeight * (Config.camera.anchorY - Config.camera.horizonY) * q,
                1e-5, "DPR-scaled physical Y")
        end
        metrics.viewportCases = #cases
    end, results)

    check("horizon_far_depth_and_near_singularity_are_rejected", function()
        local runtime = fresh(1280, 720)
        local movement = runtime.movement
        local camera = movement.camera
        local view = Config.camera
        local horizon = movement:GetHorizonY()
        near(horizon, movement.viewportHeight * view.horizonY, 1e-9, "logical horizon")
        assert(movement:ScreenToWorld(movement.viewportWidth * 0.5, horizon) == nil,
            "screen point on the horizon must be rejected")
        assert(movement:ScreenToWorld(movement.viewportWidth * 0.5, horizon - 1) == nil,
            "screen point above the horizon must be rejected")
        assert(movement:ScreenToWorld(-1, horizon + 20) == nil
            and movement:ScreenToWorld(movement.viewportWidth + 1, horizon + 20) == nil,
            "screen points outside the viewport must be rejected")
        assert(movement:ScreenToWorld(movement.viewportWidth * 0.5,
            movement.viewportHeight + 1) == nil, "screen point below the viewport must be rejected")
        assert(movement:WorldToScreen(point(camera.x, camera.y + view.farDepth + 0.01)) == nil,
            "world point beyond farDepth must be rejected")
        local d = view.viewHeight * (view.anchorY - view.horizonY) / view.depthCompression
        assert(movement:WorldToScreen(point(camera.x, camera.y - d)) == nil,
            "world point at the projection singularity must be rejected")
        local beyondFarQ = d / (d + view.farDepth + 1)
        local beyondFarY = movement.viewportHeight * view.horizonY
            + movement.viewportHeight * (view.anchorY - view.horizonY) * beyondFarQ
        assert(movement:ScreenToWorld(movement.viewportWidth * 0.5, beyondFarY) == nil,
            "inverse projection beyond farDepth must be rejected")
        local atFar = point(camera.x, camera.y + view.farDepth)
        roundTrip(movement, atFar)
    end, results)

    check("sampled_net_circles_and_lens_sectors_preserve_world_distance_and_angle", function()
        local runtime = fresh(1280, 720)
        local movement = runtime.movement
        local center = point(movement.camera.x + 0.5, movement.camera.y + 110)
        local radius = Config.fishing.netRadius
        local circle = Geometry.SampleCircle(center, radius, 32)
        assert(#circle == 32, "net circle sample count changed")
        local clippedCircle = Geometry.ClipPolygon(movement, circle)
        assert(#clippedCircle >= 3, "visible net circle was clipped away")
        for _, worldPoint in ipairs(circle) do
            near(distance(center, worldPoint), radius, 1e-6, "world net-circle radius")
            roundTrip(movement, worldPoint)
        end

        local heading, halfAngle = 0.35, math.rad(28)
        local sectorRadius = 18
        local sector = Geometry.SampleSector(center, sectorRadius, heading, halfAngle, 24)
        assert(#sector == 26, "lens sector must include its origin and arc endpoints")
        local clippedSector = Geometry.ClipPolygon(movement, sector)
        assert(#clippedSector >= 3, "visible lens sector was clipped away")
        for _, worldPoint in ipairs(sector) do
            local dx, dy = worldPoint.x - center.x, worldPoint.y - center.y
            local sampleRadius = math.sqrt(dx * dx + dy * dy)
            if sampleRadius > 1e-8 then
                near(sampleRadius, sectorRadius, 1e-6, "world lens-sector radius")
                local angle = math.atan(dy, dx)
                local delta = (angle - heading + math.pi) % (2 * math.pi) - math.pi
                assert(math.abs(delta) <= halfAngle + 1e-6,
                    "world lens sample escaped the authored sector angle")
            end
            roundTrip(movement, worldPoint)
        end

        local farCrossing = Geometry.SampleCircle(
            point(movement.camera.x, movement.camera.y + Config.camera.farDepth + 10), 30, 48)
        local clippedFarCrossing = Geometry.ClipPolygon(movement, farCrossing)
        assert(#clippedFarCrossing >= 3,
            "world-space circle crossing farDepth lost its visible polygon")
        for _, worldPoint in ipairs(clippedFarCrossing) do
            assert(worldPoint.y - movement.camera.y <= Config.camera.farDepth + 1e-6,
                "clipped world geometry extends beyond farDepth")
            project(movement, worldPoint)
        end
        metrics.netCircleSamples = #circle
        metrics.lensSectorSamples = #sector
        metrics.clippedFarCircleSamples = #clippedFarCrossing
    end, results)

    check("world_visibility_and_interaction_distances_do_not_change_with_camera", function()
        local runtime = fresh(1280, 720)
        assert(Config.interaction.operateDistance == 5)
        assert(Config.interaction.portDistance == 10)
        assert(Config.interaction.maxThrowDistance == 12)
        assert(Config.interaction.outlineDistance == 80)
        assert(Config.interaction.recognitionDistance == 20)
        assert(Config.interaction.revealRadius == 20)
        assert(Config.fishing.maxCastDistance == 30 and Config.fishing.netRadius == 8)

        local inside = runtime:spawnFish("sardine", point(20, 0))
        local outside = runtime:spawnFish("tuna", point(-20.001, 0))
        assert(not runtime.world:isVisible(inside) and not runtime.world:isVisible(outside),
            "underwater fish visibility changed before reveal")
        runtime:revealWithScope(point(0, 0), 1)
        assert(runtime.world:isVisible(inside) and not runtime.world:isVisible(outside),
            "existing 20-meter reveal distance changed")
        runtime.movement:Update(0.25, 1, 0)
        assert(runtime.world:isVisible(inside) and not runtime.world:isVisible(outside),
            "camera movement changed world-space visibility")

        runtime.ship.position = point(Config.ship.start.x, Config.ship.start.y)
        assert(runtime:canCastNet(point(30, 0)), "30-meter cast boundary changed")
        assert(not runtime:canCastNet(point(30.001, 0)), "cast accepted beyond 30 meters")
        local barrel = runtime:GetFixedBarrel()
        assert(barrel ~= nil, "fixed barrel fixture unavailable")
        runtime.ship.position = point(barrel.position.x + Config.interaction.operateDistance,
            barrel.position.y)
        assert(runtime:CanInteractWithBarrel(barrel.id, barrel.generation),
            "5-meter barrel interaction boundary changed")
        runtime.ship.position.x = runtime.ship.position.x + 0.001
        local canInteract, reason = runtime:CanInteractWithBarrel(barrel.id, barrel.generation)
        assert(not canInteract and reason == "barrel_out_of_range",
            "barrel interaction accepted beyond 5 meters")
    end, results)

    check("wake_uses_measured_displacement_and_expires_while_stationary", function()
        local ship = { position = point(0, 0), rotation = 0 }
        local wake = Wake.New(ship)
        ship.position = point(0.25, 0)
        wake:Update(1, ship, point(0, 0))
        assert(#wake.records == 0,
            "wake sampled nominal speed instead of the measured 0.25-meter movement")

        wake:Reset(ship)
        local previous = copyPoint(ship.position)
        ship.position = point(0.25, 0.85)
        wake:Update(0.1, ship, previous)
        assert(#wake.records == 1, "wake spacing did not sample the measured path")
        local record = wake.records[1]
        near(record.rotation, math.pi * 0.5, 1e-6, "wake displacement heading")
        near(record.position.x, previous.x, 1e-6, "wake sample X along measured path")
        near(record.position.y, previous.y + Config.visual.wake.spacingMeters
            - Config.visual.wake.sternOffset, 1e-6, "wake sample Y along measured path")

        local ageBefore = record.age
        wake:Update(0.4, ship, copyPoint(ship.position))
        assert(#wake.records == 1 and wake.records[1].age > ageBefore,
            "stationary wake did not age")
        wake:Update(Config.visual.wake.lifetimeSec, ship, copyPoint(ship.position))
        assert(#wake.records == 0, "stationary wake did not expire")
        wake:Reset(ship)
        assert(#wake.records == 0, "wake reset did not clear all samples")
        near(wake.distanceUntilNext, Config.visual.wake.spacingMeters, 1e-9,
            "wake reset did not restore its spacing")
    end, results)

    check("pause_resize_return_port_and_reset_preserve_or_clear_wake_as_required", function()
        local runtime = fresh(1280, 720)
        runtime:Update(0.25, 1, 0)
        local movement = runtime.movement
        assert(#movement.wake.records > 0, "actual ship displacement did not produce a wake")
        local worldBeforePause = runtime.world
        local timeBeforePause = runtime.time
        local shipBeforePause = copyPoint(runtime.ship.position)
        local cameraBeforePause = copyPoint(movement.camera)
        local wakeBeforePause = recordsCopy(movement.wake)

        runtime:TogglePause()
        runtime:Update(0.25, -1, 0)
        near(runtime.time, timeBeforePause, 1e-9, "paused world time")
        near(runtime.ship.position.x, shipBeforePause.x, 1e-9, "paused ship X")
        near(runtime.ship.position.y, shipBeforePause.y, 1e-9, "paused ship Y")
        near(movement.camera.x, cameraBeforePause.x, 1e-9, "paused camera X")
        near(movement.camera.y, cameraBeforePause.y, 1e-9, "paused camera Y")
        assert(#movement.wake.records == #wakeBeforePause, "pause changed wake sample count")
        for index, record in ipairs(movement.wake.records) do
            near(record.age, wakeBeforePause[index].age, 1e-9, "paused wake age")
            near(record.position.x, wakeBeforePause[index].position.x, 1e-9, "paused wake X")
            near(record.position.y, wakeBeforePause[index].position.y, 1e-9, "paused wake Y")
        end

        local oldCameraX, oldCameraY = movement.camera.x, movement.camera.y
        assert(movement:SetViewport(900, 1200), "portrait resize was not applied")
        near(movement.camera.x, oldCameraX, 1e-9, "resize changed camera X")
        near(movement.camera.y, oldCameraY, 1e-9, "resize changed camera Y")
        assert(runtime.world == worldBeforePause, "resize replaced the world")
        runtime:TogglePause()

        assert(runtime:ResetShipAtPort(), "return-to-port reset was rejected")
        assert(runtime.world == worldBeforePause, "return-to-port replaced the world")
        near(runtime.ship.position.x, Config.ship.start.x, 1e-9, "return-port ship X")
        near(runtime.ship.position.y, Config.ship.start.y, 1e-9, "return-port ship Y")
        near(movement.camera.x, runtime.ship.position.x, 1e-9, "return-port camera X")
        near(movement.camera.y, runtime.ship.position.y, 1e-9, "return-port camera Y")
        assert(#movement.wake.records == 0, "return-to-port did not clear wake")

        runtime:Update(0.25, 1, 0)
        assert(#movement.wake.records > 0, "wake did not resume after return-to-port")
        runtime:Reset()
        assert(#runtime.movement.wake.records == 0, "runtime reset retained wake samples")
        near(runtime.movement.camera.x, runtime.ship.position.x, 1e-9, "reset camera X")
        near(runtime.movement.camera.y, runtime.ship.position.y, 1e-9, "reset camera Y")
    end, results)

    local passed = true
    for _, result in ipairs(results) do
        if not result.passed then passed = false end
    end
    return {
        status = passed and "PASS" or "FAIL",
        passed = passed,
        results = results,
        metrics = metrics,
        evidence = {
            kind = "pure Lua logic suite using real project modules",
            nativeEngineVisualAcceptance = "NOT_RUN",
            NanoVGMockVisualAcceptance = false,
        },
    }
end

return Tests
