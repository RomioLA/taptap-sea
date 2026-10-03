local Effects = require("Ocean.SeaSurfaceEffects")

local Tests = {}

local function near(actual, expected, epsilon)
    assert(math.abs(actual - expected) <= (epsilon or 0.00001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

function Tests.Run(recorder)
    local results = {}
    local function check(name, callback)
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("near and far surface detail blend smoothly with complementary weights", function()
        local nearWeight, farWeight = Effects.SurfaceLayerWeights(35, 35, 110)
        near(nearWeight, 1)
        near(farWeight, 0)

        nearWeight, farWeight = Effects.SurfaceLayerWeights(72.5, 35, 110)
        near(nearWeight + farWeight, 1)
        near(nearWeight, 0.5)
        near(farWeight, 0.5)

        nearWeight, farWeight = Effects.SurfaceLayerWeights(110, 35, 110)
        near(nearWeight, 0)
        near(farWeight, 1)
    end)

    check("surface lattice positions stay on fixed world cells while the view drifts", function()
        local firstMin, firstMax = Effects.CellRange(10.2, 40.2, 6)
        local driftedMin, driftedMax = Effects.CellRange(10.5, 40.5, 6)
        assert(firstMin == 2 and firstMax == 6)
        assert(driftedMin == firstMin and driftedMax == firstMax,
            "sub-cell camera movement must not shift the lattice")
        near(firstMin * 6, driftedMin * 6)
        near(firstMax * 6, driftedMax * 6)

        local crossedMin = Effects.CellRange(12.01, 40.5, 6)
        assert(crossedMin == 3, "crossing a cell boundary adds the next fixed world cell")
    end)

    check("boat heave and roll are pure samples of voyage time and turn rate", function()
        local motion = {
            enabled = true,
            heaveMeters = 0.12,
            maxRollDegrees = 3,
            turnRateForMaxRoll = math.pi,
        }
        local surface = { spacing = 12, driftSpeed = 0.6, period = 5 }
        local position = { x = 18, y = 42 }
        local originalX, originalY = position.x, position.y
        local heave1, roll1 = Effects.BoatAttitude(motion, 7.5,
            position.x, position.y, surface, math.pi)
        local heave2, roll2 = Effects.BoatAttitude(motion, 7.5,
            position.x, position.y, surface, math.pi)
        near(heave1, heave2)
        near(roll1, roll2)
        near(roll1, -3 * math.pi / 180)
        assert(position.x == originalX and position.y == originalY,
            "visual motion sampling must not mutate the ship position")

        local _, oppositeRoll = Effects.BoatAttitude(motion, 7.5,
            position.x, position.y, surface, -math.pi * 4)
        near(oppositeRoll, 3 * math.pi / 180, 0.000001)
        local _, straightRoll = Effects.BoatAttitude(motion, 7.5,
            position.x, position.y, surface, 0)
        near(straightRoll, 0)
    end)

    check("shoreline foam arcs expand, fade, and repeat in world space", function()
        local center = { x = -80, y = 90 }
        local radius = 20
        local index, count = 4, 36
        local settings = {
            ringRatio = 1.0,
            bubbleRadiusMeters = 0.30,
            pulsePeriodSec = 3.2,
            expansionMeters = 0.75,
            arcLengthMeters = 1.0,
        }
        local originPhase = (center.x * 0.17320508075 + center.y * 0.22360679775) % 1
        local phaseOffset = (index - 1) / count + originPhase
        local function timeAtPhase(progress)
            return ((progress - phaseOffset) % 1) * settings.pulsePeriodSec
        end
        local shore = Effects.ShoreFoamArc(center, radius, index, count, timeAtPhase(0), settings)
        local early = Effects.ShoreFoamArc(center, radius, index, count, timeAtPhase(0.1), settings)
        local middle = Effects.ShoreFoamArc(center, radius, index, count, timeAtPhase(0.5), settings)
        local late = Effects.ShoreFoamArc(center, radius, index, count, timeAtPhase(0.99), settings)
        local repeated = Effects.ShoreFoamArc(center, radius, index, count,
            timeAtPhase(0.5) + settings.pulsePeriodSec, settings)
        assert(shore and early and middle and late and repeated)
        near(shore.radiusMeters, radius)
        assert(#early.points == 5 and #middle.points == 5)
        assert(early.radiusMeters < middle.radiusMeters and middle.radiusMeters < late.radiusMeters,
            "foam should spread outward during its cycle")
        assert(early.strength < middle.strength and late.strength < middle.strength,
            "foam should bloom and fade before the next cycle")
        near(middle.radiusMeters, repeated.radiusMeters)
        near(middle.strength, repeated.strength)
        for pointIndex = 1, #middle.points do
            near(middle.points[pointIndex].x, repeated.points[pointIndex].x)
            near(middle.points[pointIndex].y, repeated.points[pointIndex].y)
            near(math.sqrt((middle.points[pointIndex].x - center.x) ^ 2
                + (middle.points[pointIndex].y - center.y) ^ 2), middle.radiusMeters)
        end
        assert(center.x == -80 and center.y == 90, "shore effects must not move the island")
    end)

    check("water mark budget is enforced even within a single row", function()
        local Config = require("Ocean.Config")
        local Art = require("Ocean.SeaViewArt")
        local runtime = require("Ocean.SeaRuntime").New({ initializeRegions = false })
        runtime.movement:SetViewport(1280, 720)
        local oldLimit = Config.visual.surface.maxMarks
        Config.visual.surface.maxMarks = 3
        local ok, err = pcall(function()
            recorder.reset()
            Art.Surface({}, runtime.movement, 1.5)
            -- The fill and horizon each have one initial move; every wave mark
            -- has one additional move even when many share a batched row path.
            local marks = recorder.callCount("nvgMoveTo") - 2
            assert(marks > 0 and marks <= 3, "a batched row exceeded the configured mark budget")
        end)
        Config.visual.surface.maxMarks = oldLimit
        assert(ok, tostring(err))
    end)
    check("turn bank eases back when stopped and freezes while paused", function()
        local Runtime = require("Ocean.SeaRuntime")
        local runtime = Runtime.New({ initializeRegions = false })
        runtime:Update(0.25, 0, 1)
        local turning = runtime.ship.visualTurnRate
        assert(turning and turning > 0, "sailing turn did not produce a bank input")
        runtime:TogglePause()
        runtime:Update(0.25, 0, -1)
        assert(runtime.ship.visualTurnRate == turning, "pause changed the bank input")
        runtime:TogglePause()
        runtime:Update(0.25, 0, 0)
        assert(runtime.ship.visualTurnRate > 0 and runtime.ship.visualTurnRate < turning,
            "stopping should ease the bank back toward level")
        assert(runtime:ResetShipAtPort())
        assert(runtime.ship.visualTurnRate == 0, "returning to port retained the turn bank")
    end)
    return { results = results }
end

return Tests
