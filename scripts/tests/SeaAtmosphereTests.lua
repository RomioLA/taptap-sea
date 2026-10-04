-- Offline contract tests for deterministic, presentation-only sea atmosphere.
-- A caller may run Tests.Run(recorder) with the existing NVGCapture binding.
local Tests = {}

local Config = require("Ocean.Config")
local Projection = require("Ocean.Projection")
local SeaAtmosphere = require("Ocean.SeaAtmosphere")

local function copyCircles(source)
    local copy = {}
    for index, circle in ipairs(source) do
        copy[index] = {
            x = circle.x, y = circle.y,
            radiusX = circle.radiusX, radiusY = circle.radiusY,
        }
    end
    return copy
end

local function assertSameCircles(first, second, label)
    assert(#first == #second, label .. " changed puff count")
    for index, circle in ipairs(first) do
        local other = second[index]
        assert(other and math.abs(circle.x - other.x) < 0.0001
            and math.abs(circle.y - other.y) < 0.0001
            and math.abs(circle.radiusX - other.radiusX) < 0.0001
            and math.abs(circle.radiusY - other.radiusY) < 0.0001,
            label .. " changed world-seeded screen geometry")
    end
end

local function assertHorizonClips(circles, clips, movement, label)
    assert(#clips == #circles, label .. " puffs must each use an intersecting horizon scissor")
    local clippedCrossing = false
    for index, circle in ipairs(circles) do
        local clip = clips[index]
        local left = math.max(0, circle.x - circle.radiusX)
        local right = math.min(movement.viewportWidth, circle.x + circle.radiusX)
        for sample = 0, 8 do
            local x = left + (right - left) * sample / 8
            local horizon = Projection.Horizon(movement, x)
            assert(clip.y >= horizon + 2,
                label .. " scissor allowed a radial puff to leak above the curved horizon")
        end
        assert(clip.x <= left + 0.001 and clip.x + clip.width >= right - 0.001,
            label .. " scissor did not cover the visible puff width")
        assert(clip.height > 0, label .. " scissor has no visible water area")
        local plane = clip.y
        if circle.y - circle.radiusY < plane and circle.y + circle.radiusY > plane then
            clippedCrossing = true
        end
    end
    return clippedCrossing
end

local function maxRadius(circles)
    local radius = 0
    for _, circle in ipairs(circles) do radius = math.max(radius, circle.radiusX) end
    return radius
end

local function worldCenters(circles, movement)
    local centers = {}
    for _, circle in ipairs(circles) do
        local point = Projection.Unproject(movement, circle.x, circle.y)
        if point then centers[#centers + 1] = point end
    end
    return centers
end

local function countSharedWorldCenters(first, second)
    local shared = 0
    for _, point in ipairs(first) do
        for _, other in ipairs(second) do
            if math.abs(point.x - other.x) < 0.001 and math.abs(point.y - other.y) < 0.001 then
                shared = shared + 1
                break
            end
        end
    end
    return shared
end

function Tests.Run(recorder)
    -- Lupa exposes bound Python recorder methods to Lua as userdata, so check
    -- availability rather than Lua's `type(...)=function` result.
    assert(recorder and recorder.reset ~= nil
        and recorder.callCount ~= nil, "NVGCapture recorder is required")
    assert(nvgRadialGradient ~= nil, "NVGCapture radial-gradient API is required")
    assert(nvgIntersectScissor ~= nil, "NVGCapture intersect-scissor API is required")
    assert(nvgTranslate ~= nil and nvgScale ~= nil,
        "NVGCapture transform APIs are required for the soft fog ellipse")
    assert(nvgSave ~= nil and nvgRestore ~= nil, "NVGCapture state-stack APIs are required")

    local previousAtmosphere = Config.visual.atmosphere
    local previousCircle = nvgCircle
    local previousRadialGradient = nvgRadialGradient
    local previousIntersectScissor = nvgIntersectScissor
    local previousTranslate, previousScale = nvgTranslate, nvgScale
    local previousSave, previousRestore = nvgSave, nvgRestore
    local circles, radialAlphas, clips = {}, {}, {}
    local transform = { x = 0, y = 0, scaleX = 1, scaleY = 1 }
    local transformStack = {}

    local function copyTransform(source)
        return { x = source.x, y = source.y, scaleX = source.scaleX, scaleY = source.scaleY }
    end

    nvgCircle = function(ctx, x, y, radius)
        circles[#circles + 1] = {
            x = transform.x + transform.scaleX * x,
            y = transform.y + transform.scaleY * y,
            radiusX = math.abs(transform.scaleX) * radius,
            radiusY = math.abs(transform.scaleY) * radius,
        }
        return previousCircle(ctx, x, y, radius)
    end
    nvgRadialGradient = function(ctx, x, y, innerRadius, outerRadius, innerColor, outerColor)
        radialAlphas[#radialAlphas + 1] = innerColor.a
        return previousRadialGradient(ctx, x, y, innerRadius, outerRadius, innerColor, outerColor)
    end
    nvgIntersectScissor = function(ctx, x, y, width, height)
        clips[#clips + 1] = { x = x, y = y, width = width, height = height }
        return previousIntersectScissor(ctx, x, y, width, height)
    end
    nvgSave = function(ctx)
        transformStack[#transformStack + 1] = copyTransform(transform)
        return previousSave(ctx)
    end
    nvgRestore = function(ctx)
        local result = previousRestore(ctx)
        transform = transformStack[#transformStack] or { x = 0, y = 0, scaleX = 1, scaleY = 1 }
        transformStack[#transformStack] = nil
        return result
    end
    nvgTranslate = function(ctx, x, y)
        transform.x = transform.x + transform.scaleX * x
        transform.y = transform.y + transform.scaleY * y
        return previousTranslate(ctx, x, y)
    end
    nvgScale = function(ctx, x, y)
        transform.scaleX = transform.scaleX * x
        transform.scaleY = transform.scaleY * y
        return previousScale(ctx, x, y)
    end

    local ok, result = pcall(function()
        Config.visual.atmosphere = {
            cloudShadowsEnabled = true,
            cloudShadowCount = 10,
            cloudShadowOpacity = 40,
            cloudShadowDriftMps = 0.55,
            cloudShadowRadiusMeters = 24,
            fogEnabled = true,
            fogCount = 10,
            fogOpacity = 46,
            fogDriftMps = 0.30,
            fogRadiusMeters = 22,
            fogNearOpacityScale = 0.12,
        }

        local movement = {
            camera = { x = 11.37, y = 20.22 },
            ship = { position = { x = 11.37, y = 20.22 } },
            viewportWidth = 1280,
            viewportHeight = 720,
        }
        local initialCameraX, initialCameraY = movement.camera.x, movement.camera.y
        local initialShipX, initialShipY = movement.ship.position.x, movement.ship.position.y
        local initialTime, seed = 123, 271828

        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.CloudShadows({}, movement, initialTime, seed)
        assert(#circles > 0 and #circles <= 12,
            "cloud-shadow puffs exceeded the twelve-candidate frame budget")
        assert(recorder.callCount("nvgRadialGradient") == #circles,
            "each cloud-shadow puff should use one radial gradient")
        assert(recorder.callCount("nvgIntersectScissor") == #circles,
            "each cloud-shadow puff should use a curved-horizon scissor")
        assert(maxRadius(circles) >= 100, "cloud shadows did not reach the larger readable size")
        local cloudCrossesHorizon = assertHorizonClips(circles, clips, movement, "cloud-shadow")
        assert(cloudCrossesHorizon,
            "cloud shadows crossing the horizon should be clipped instead of dropped")
        local firstCloudFrame = copyCircles(circles)

        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.CloudShadows({}, movement, initialTime, seed)
        assertSameCircles(firstCloudFrame, circles, "same time and seed")

        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.CloudShadows({}, movement, initialTime + 10, seed)
        local drifted = false
        for index, circle in ipairs(circles) do
            if math.abs(circle.x - firstCloudFrame[index].x) > 0.01 then
                drifted = true
                break
            end
        end
        assert(drifted, "cloud shadows should drift from the supplied runtime time")
        assertHorizonClips(circles, clips, movement, "drifting cloud-shadow")

        -- Existing seeded cells remain in place across both world-grid axes.
        -- Count=8 is a stable density filter, not a newly ranked list of eight
        -- camera-relative slots.
        Config.visual.atmosphere.cloudShadowCount = 8
        movement.camera.x = initialTime * Config.visual.atmosphere.cloudShadowDriftMps + 32 - 0.1
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.CloudShadows({}, movement, initialTime, seed)
        local beforeCloudColumnCrossing = worldCenters(circles, movement)
        movement.camera.x = initialTime * Config.visual.atmosphere.cloudShadowDriftMps + 32 + 0.1
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.CloudShadows({}, movement, initialTime, seed)
        local afterCloudColumnCrossing = worldCenters(circles, movement)
        assert(countSharedWorldCenters(beforeCloudColumnCrossing, afterCloudColumnCrossing) > 0,
            "crossing a world-column boundary moved or reselected every shared cloud cell")
        movement.camera.x = initialCameraX

        movement.camera.y = 54.9
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.CloudShadows({}, movement, initialTime, seed)
        local beforeRowCrossing = worldCenters(circles, movement)
        movement.camera.y = 55.1
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.CloudShadows({}, movement, initialTime, seed)
        local afterRowCrossing = worldCenters(circles, movement)
        assert(countSharedWorldCenters(beforeRowCrossing, afterRowCrossing) > 0,
            "crossing a world-row boundary moved or reselected every shared cloud cell")

        movement.camera.y = initialCameraY
        Config.visual.atmosphere.cloudShadowCount = 10
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.Fog({}, movement, initialTime, seed)
        assert(#circles > 0 and #circles <= 36,
            "fog slices exceeded the thirty-six-puff frame budget")
        assert(recorder.callCount("nvgRadialGradient") == #circles,
            "each fog puff should use one radial gradient")
        assert(recorder.callCount("nvgIntersectScissor") == #circles,
            "each fog puff should use a curved-horizon scissor")
        assert(#radialAlphas == #circles, "fog gradients did not reach the recorder")
        assert(maxRadius(circles) >= 100, "fog slices did not reach the larger readable size")
        assertHorizonClips(circles, clips, movement, "fog")

        -- The normal flattened fog sits below the horizon and may not intersect
        -- it in this fixture. Use a larger test-only radius to exercise the
        -- partial-crossing clip path, then restore the configured effect size.
        local configuredFogRadius = Config.visual.atmosphere.fogRadiusMeters
        Config.visual.atmosphere.fogRadiusMeters = 60
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.Fog({}, movement, initialTime, seed)
        local fogCrossesHorizon = assertHorizonClips(circles, clips, movement, "crossing fog fixture")
        assert(fogCrossesHorizon,
            "fog slices crossing the horizon should be clipped instead of dropped")
        Config.visual.atmosphere.fogRadiusMeters = configuredFogRadius

        Config.visual.atmosphere.fogCount = 8
        movement.camera.x = initialTime * Config.visual.atmosphere.fogDriftMps + 32 - 0.1
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.Fog({}, movement, initialTime, seed)
        local beforeFogColumnCrossing = worldCenters(circles, movement)
        movement.camera.x = initialTime * Config.visual.atmosphere.fogDriftMps + 32 + 0.1
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.Fog({}, movement, initialTime, seed)
        local afterFogColumnCrossing = worldCenters(circles, movement)
        assert(countSharedWorldCenters(beforeFogColumnCrossing, afterFogColumnCrossing) > 0,
            "crossing a world-column boundary moved or reselected every shared fog cell")
        movement.camera.x = initialCameraX

        movement.camera.y = 54.9
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.Fog({}, movement, initialTime, seed)
        local beforeFogRowCrossing = worldCenters(circles, movement)
        movement.camera.y = 55.1
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.Fog({}, movement, initialTime, seed)
        local afterFogRowCrossing = worldCenters(circles, movement)
        assert(countSharedWorldCenters(beforeFogRowCrossing, afterFogRowCrossing) > 0,
            "crossing a world-row boundary moved or reselected every shared fog cell")
        movement.camera.y = initialCameraY
        Config.visual.atmosphere.fogCount = 10

        -- Compare the same puff with the ship far away and centered on that
        -- puff. This isolates near-boat attenuation from seed-driven size noise.
        movement.ship.position.x, movement.ship.position.y = 10000, 10000
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.Fog({}, movement, initialTime, seed)
        local farFogCircles, farFogAlphas = copyCircles(circles), radialAlphas
        local nearPoint = worldCenters(farFogCircles, movement)[1]
        assert(nearPoint and #farFogAlphas > 0, "fog did not produce a near-ship attenuation fixture")

        movement.ship.position.x, movement.ship.position.y = nearPoint.x, nearPoint.y
        recorder.reset()
        circles, radialAlphas, clips = {}, {}, {}
        SeaAtmosphere.Fog({}, movement, initialTime, seed)
        assertSameCircles(farFogCircles, circles, "moving only the boat")
        assert(radialAlphas[1] < farFogAlphas[1],
            "fog opacity should fall for a puff centered on the ship")
        local closeOpacity, distantOpacity = radialAlphas[1], farFogAlphas[1]
        movement.ship.position.x, movement.ship.position.y = initialShipX, initialShipY

        assert(recorder.callCount("nvgSave") == recorder.callCount("nvgRestore"),
            "atmosphere left the NanoVG save/restore stack unbalanced")
        assert(movement.camera.x == initialCameraX and movement.camera.y == initialCameraY
            and movement.ship.position.x == initialShipX and movement.ship.position.y == initialShipY,
            "atmosphere changed movement or ship state")

        return {
            status = "PASS",
            tests = {
                "cloud_shadows_are_repeatable_for_same_seed_and_time",
                "cloud_shadows_drift_only_from_supplied_time",
                "cloud_and_fog_world_cells_remain_stable_across_camera_cell_boundaries",
                "fog_and_cloud_shadows_clip_to_curved_horizon_without_dropping_crossing_puffs",
                "fog_is_sparse_and_near_ship_opacity_is_reduced",
                "atmosphere_respects_expanded_puff_budgets_and_nvg_state_stack",
                "atmosphere_does_not_change_movement_state",
            },
            metrics = {
                maxCloudPuffsPerPass = 12,
                maxFogPuffsPerPass = 36,
                cloudShadows = #firstCloudFrame,
                fog = #circles,
                cloudCrossesHorizon = cloudCrossesHorizon,
                fogCrossesHorizon = fogCrossesHorizon,
                closeFogAlpha = closeOpacity,
                distantFogAlpha = distantOpacity,
            },
        }
    end)

    Config.visual.atmosphere = previousAtmosphere
    nvgCircle = previousCircle
    nvgRadialGradient = previousRadialGradient
    nvgIntersectScissor = previousIntersectScissor
    nvgTranslate, nvgScale = previousTranslate, previousScale
    nvgSave, nvgRestore = previousSave, previousRestore
    recorder.reset()
    if not ok then error(result) end
    return result
end

return Tests
