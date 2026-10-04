-- Pure presentation math shared by the ocean renderer and focused tests.
-- Every animated value is sampled from voyage time; rendering never accumulates state.
local Effects = {}
local TWO_PI = math.pi * 2

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function numberOr(value, fallback)
    return finite(value) and value or fallback
end

function Effects.SurfacePhase(settings, time, cellX, cellY)
    settings = type(settings) == "table" and settings or {}
    local spacing = math.max(0.1, numberOr(settings.spacing, 12))
    local driftSpeed = math.max(0, numberOr(settings.driftSpeed, 0.6))
    local period = math.max(0.1, numberOr(settings.period, 5))
    time = numberOr(time, 0)
    cellX, cellY = numberOr(cellX, 0), numberOr(cellY, 0)
    return TWO_PI * ((cellX * 0.61803398875 + cellY * 0.41421356237) % 1)
        - time * driftSpeed * TWO_PI / spacing
        + time * TWO_PI / period
end

function Effects.SmoothStep(edge0, edge1, value)
    edge0, edge1, value = numberOr(edge0, 0), numberOr(edge1, 1), numberOr(value, 0)
    if edge1 <= edge0 then return value >= edge1 and 1 or 0 end
    local amount = clamp((value - edge0) / (edge1 - edge0), 0, 1)
    return amount * amount * (3 - 2 * amount)
end

function Effects.SurfaceLayerWeights(distance, transitionStart, transitionEnd)
    local farWeight = Effects.SmoothStep(transitionStart, transitionEnd, distance)
    return 1 - farWeight, farWeight
end

-- Return integer world-grid indices. Grid positions remain index * spacing even
-- while the camera moves; a cell enters or leaves the view only at its boundary.
function Effects.CellRange(minimum, maximum, spacing)
    if not finite(minimum) or not finite(maximum) or not finite(spacing) or spacing <= 0 then
        return 1, 0
    end
    return math.ceil(minimum / spacing - 1e-8), math.floor(maximum / spacing + 1e-8)
end

function Effects.BoatAttitude(motion, time, worldX, worldY, surfaceSettings, visualTurnRate)
    motion = type(motion) == "table" and motion or {}
    if motion.enabled == false then return 0, 0 end

    surfaceSettings = type(surfaceSettings) == "table" and surfaceSettings or {}
    local spacing = math.max(0.1, numberOr(surfaceSettings.spacing, 12))
    local heaveMeters = math.max(0, numberOr(motion.heaveMeters, 0.12))
    local phase = Effects.SurfacePhase(surfaceSettings, time,
        numberOr(worldX, 0) / spacing, numberOr(worldY, 0) / spacing)
    local heave = heaveMeters * math.sin(phase)

    local maximumRoll = math.max(0, numberOr(motion.maxRollDegrees, 3)) * math.pi / 180
    local fullRate = math.max(0.001, numberOr(motion.turnRateForMaxRoll, math.pi))
    local turnAmount = clamp(-numberOr(visualTurnRate, 0) / fullRate, -1, 1)
    return heave, turnAmount * maximumRoll
end

-- A short foam arc stays on the world's circular shore and expands into the
-- water over one voyage-time cycle. It creates no simulation entities.
function Effects.ShoreFoamArc(center, shorelineRadius, index, count, time, settings)
    if type(center) ~= "table" or not finite(center.x) or not finite(center.y)
        or not finite(shorelineRadius) or shorelineRadius <= 0
        or not finite(index) or not finite(count) or count < 1 then
        return nil
    end
    settings = type(settings) == "table" and settings or {}
    local period = math.max(0.1, numberOr(settings.pulsePeriodSec, 3.2))
    local radiusRatio = clamp(numberOr(settings.ringRatio, 1), 0.89, 1)
    local bubbleRadius = math.max(0.05, numberOr(settings.bubbleRadiusMeters, 0.3))
    local expansionMeters = math.max(0, numberOr(settings.expansionMeters, bubbleRadius * 2.5))
    local arcLengthMeters = math.max(0.2, numberOr(settings.arcLengthMeters, bubbleRadius * 3))
    local strokeWidthMeters = math.max(0.01,
        numberOr(settings.strokeWidthMeters, bubbleRadius * 0.2))
    local originPhase = (center.x * 0.17320508075 + center.y * 0.22360679775) % 1
    local progress = (numberOr(time, 0) / period + (index - 1) / count + originPhase) % 1
    local strength = Effects.SmoothStep(0.04, 0.18, progress)
        * (1 - Effects.SmoothStep(0.74, 0.97, progress))
    local angle = TWO_PI * (index - 1) / count
    local centerRadius = shorelineRadius * radiusRatio + expansionMeters * Effects.SmoothStep(0, 1, progress)
    local halfArc = clamp(arcLengthMeters / (2 * math.max(centerRadius, 0.1)), 0.01, 0.28)
    local points = {}
    for pointIndex = 0, 4 do
        local pointAngle = angle - halfArc + halfArc * pointIndex * 0.5
        points[#points + 1] = {
            x = center.x + math.cos(pointAngle) * centerRadius,
            y = center.y + math.sin(pointAngle) * centerRadius,
        }
    end
    return {
        points = points,
        radiusMeters = centerRadius,
        strokeWidthMeters = strokeWidthMeters,
        strength = strength,
        progress = progress,
    }
end

return Effects
