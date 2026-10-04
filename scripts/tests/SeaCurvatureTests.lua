-- Analytic contracts for the presentation-only far-water curvature.
local Config = require("Ocean.Config")
local Geometry = require("Ocean.ProjectedGeometry")
local Projection = require("Ocean.Projection")
local Tests = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function assertNear(actual, expected, label, tolerance)
    tolerance = tolerance or 1e-6
    assert(finite(actual) and math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.9f, got %s", label, expected, tostring(actual)))
end

local function ratio()
    local curvature = Config.visual and Config.visual.curvature
    assert(type(curvature) == "table" and finite(curvature.heightRatio),
        "Config.visual.curvature.heightRatio is required")
    return curvature.heightRatio
end

local function distance()
    local camera = Config.camera
    return camera.viewHeight * (camera.anchorY - camera.horizonY) / camera.depthCompression
end

local function makeView(width, height)
    return {
        camera = { x = 137.25, y = -43.5 },
        viewportWidth = width,
        viewportHeight = height,
    }
end

local function pointAtScreenXDepth(view, screenX, depth)
    local camera = Config.camera
    local q = distance() / (distance() + depth)
    local base = view.viewportHeight / camera.viewHeight
    return {
        x = view.camera.x + (screenX - view.viewportWidth * camera.anchorX) / (base * q),
        y = view.camera.y + depth,
    }, q
end

local function expectedBend(view, screenX)
    local u = math.max(-1, math.min(1, (screenX - view.viewportWidth * 0.5) / (view.viewportWidth * 0.5)))
    return view.viewportHeight * ratio() * u * u
end

local function checkRoundTripView(view)
    local camera = Config.camera
    local height = view.viewportHeight
    local horizon = height * camera.horizonY
    local anchorHeight = height * (camera.anchorY - camera.horizonY)
    local screenFractions = { 0.08, 0.5, 0.92 }
    local depths = { -5, 0, 13, 80, camera.farDepth - 1 }
    for _, fraction in ipairs(screenFractions) do
        local targetX = view.viewportWidth * fraction
        for _, depth in ipairs(depths) do
            local point, q = pointAtScreenXDepth(view, targetX, depth)
            local x, y, scale = Projection.Project(view, point)
            assert(x and y and scale, "visible ground point failed projection")
            assertNear(x, targetX, "screen X", 1e-7)
            assert(y > Projection.Horizon(view,x), "visible ground must remain below the local horizon")
            local restored = Projection.Unproject(view, x, y)
            assert(restored, "projected ground point was rejected by inverse")
            assertNear(restored.x, point.x, "round-trip world X", 1e-5)
            assertNear(restored.y, point.y, "round-trip world Y", 1e-5)
        end
    end
end

local function assertDirectionalDerivative(view, point, dx, dy)
    local actualX, actualY = Projection.Vector(view, point, dx, dy)
    assert(finite(actualX) and finite(actualY), "projected vector must be finite")
    local step = 0.001
    local beforeX, beforeY = Projection.Project(view, {
        x = point.x - dx * step, y = point.y - dy * step,
    })
    local afterX, afterY = Projection.Project(view, {
        x = point.x + dx * step, y = point.y + dy * step,
    })
    assert(beforeX and afterX, "finite-difference sample fell outside the projection")
    local numericX = (afterX - beforeX) / (2 * step)
    local numericY = (afterY - beforeY) / (2 * step)
    assertNear(actualX, numericX, "vector X derivative", 0.002)
    assertNear(actualY, numericY, "vector Y derivative", 0.002)
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("formula and exact inverse across DPR and landscape/portrait viewports", function()
        assert(ratio() > 0, "curvature height ratio must be positive")
        local physicalViews = {
            { width = 1920, height = 1080, dpr = 1 },
            { width = 3840, height = 2160, dpr = 2 },
            { width = 1170, height = 2532, dpr = 3 },
            { width = 2400, height = 2300, dpr = 2 },
        }
        for _, item in ipairs(physicalViews) do
            checkRoundTripView(makeView(item.width / item.dpr, item.height / item.dpr))
        end
    end)

    check("screen-space horizon rejects sky according to its lateral curve", function()
        local view = makeView(1920, 1080)
        local baseline = view.viewportHeight * Config.camera.horizonY
        local leftX, rightX = view.viewportWidth * 0.01, view.viewportWidth * 0.99
        local leftHorizon, rightHorizon = Projection.Horizon(view, leftX), Projection.Horizon(view, rightX)
        assert(leftHorizon > baseline and rightHorizon > baseline,
            "outer horizon should rise above its center baseline")
        assertNear(Projection.Horizon(view), baseline, "scissor-safe baseline", 1e-8)

        local farDepth = Config.camera.farDepth
        Config.camera.farDepth = 10000
        local ok, err = pcall(function()
            assert(Projection.Unproject(view, leftX, leftHorizon) == nil,
                "the curved horizon itself must be rejected")
            assert(Projection.Unproject(view, rightX, rightHorizon - 0.01) == nil,
                "pixels above the right horizon must be rejected")
            local betweenHorizons = baseline + (rightHorizon - baseline) * 0.5
            assert(Projection.Unproject(view, view.viewportWidth * 0.5, betweenHorizons),
                "the same row should remain valid at the lower center horizon")
            assert(Projection.Unproject(view, rightX, betweenHorizons) == nil,
                "the same row should be sky near the raised horizon")
        end)
        Config.camera.farDepth = farDepth
        if not ok then error(err) end
    end)

    check("vector derivatives match the curved projection finite difference", function()
        local view = makeView(1600, 900)
        local camera = Config.camera
        for _, q in ipairs({ 0.55, 1, 1.45 }) do
            local depth = distance() * (1 / q - 1)
            for _, fraction in ipairs({ 0.22, 0.5, 0.78 }) do
                local point = pointAtScreenXDepth(view, view.viewportWidth * fraction, depth)
                assertDirectionalDerivative(view, point, 0.7, -0.35)
            end
        end
        -- A purely lateral far-water vector also has a vertical component away
        -- from center because the curved horizon changes with screen X.
        local point = pointAtScreenXDepth(view, view.viewportWidth * 0.22,
            distance() * (1 / 0.55 - 1))
        local _, vertical = Projection.Vector(view, point, 1, 0)
        assert(math.abs(vertical) > 1e-6, "lateral curvature derivative was omitted")
    end)

    check("finite ground plane reaches the horizon while elevated silhouettes pass it", function()
        local view = makeView(1920, 1080)
        local x = view.viewportWidth * 0.87
        local delta = 1e-5
        local samples = {}
        for index, q in ipairs({ 1 - delta, 1, 1 + delta }) do
            local point = pointAtScreenXDepth(view, x, distance() * (1 / q - 1))
            local _, screenY = Projection.Project(view, point)
            assert(screenY, "near-field continuity sample failed")
            samples[index] = screenY
        end
        local slopeLeft = (samples[2] - samples[1]) / delta
        local slopeRight = (samples[3] - samples[2]) / delta
        assertNear(samples[2], view.viewportHeight * Config.camera.anchorY,
            "q=1 joins the original anchor", 1e-8)
        assertNear(slopeLeft, slopeRight, "q=1 screen derivative", 0.001)

        local polygon = Projection.ViewPolygon(view)
        assert(#polygon == 4, "view frustum must remain a finite quadrilateral")
        local camera = Config.camera
        local nearX, nearY = Projection.Project(view, polygon[1])
        assertNear(nearY, view.viewportHeight, "view polygon projects to viewport bottom", 1e-7)
        local nearDepth = polygon[1].y - view.camera.y
        assertNear(polygon[3].y, view.camera.y + camera.farDepth, "fixed far cap", 1e-8)
        assertNear(polygon[4].y, view.camera.y + camera.farDepth, "fixed far cap", 1e-8)
        local extended = Projection.ViewPolygon(view, 0, 25)
        assertNear(extended[3].y, view.camera.y + camera.farDepth + 25,
            "optional silhouette query extension", 1e-8)

        local clippedNear = Geometry.ClipLine(view,
            { x = view.camera.x, y = view.camera.y - 40 },
            { x = view.camera.x, y = view.camera.y })
        assert(clippedNear, "near-cap test line should intersect the view polygon")
        assertNear(clippedNear.y, view.camera.y + nearDepth, "projected geometry near clip", 1e-6)
        local clippedFar = Geometry.ClipLine(view,
            { x = view.camera.x, y = view.camera.y + camera.farDepth + 50 },
            { x = view.camera.x, y = view.camera.y + camera.farDepth - 50 })
        assert(clippedFar, "far-cap test line should intersect the view polygon")
        assertNear(clippedFar.y, view.camera.y + camera.farDepth, "projected geometry far clip", 1e-6)
        local farGroundX, farGroundY = Projection.Project(view,
            { x = view.camera.x, y = view.camera.y + camera.farDepth })
        assertNear(farGroundY, Projection.Horizon(view, farGroundX), "finite ground reaches curved horizon", 1e-8)
        local beyondGroundX, beyondGroundY = Projection.Project(view,
            { x = view.camera.x, y = view.camera.y + camera.farDepth + 50 })
        assert(beyondGroundY > Projection.Horizon(view,beyondGroundX)
            and Projection.OccludedAltitude(view,{x=view.camera.x,y=view.camera.y+camera.farDepth+50}) > 0,
            "continued ground must sink behind intervening water")
        local _, elevatedY = Projection.Project(view,
            { x = view.camera.x, y = view.camera.y + camera.farDepth + 10 }, 5)
        assert(elevatedY < Projection.Horizon(view, view.viewportWidth * 0.5),
            "elevated silhouettes must naturally project above the far-water horizon")
    end)

    local passed = true
    for _, result in ipairs(results) do passed = passed and result.passed end
    return { status = passed and "PASS" or "FAIL", results = results }
end

return Tests
