-- Project world geometry instead of drawing screen-space circles/radii.
-- Clip in the water plane before projection so near-plane crossings stay finite.
local Config = require("Ocean.Config")
local Projection = require("Ocean.Projection")
local Geometry = {}

local function color(value)
    return nvgRGBA(value[1], value[2], value[3], value[4] or 255)
end

local function planes(movement)
    local polygon = Projection.ViewPolygon(movement)
    local result = {}
    for index, point in ipairs(polygon) do
        local nextPoint = polygon[index % #polygon + 1]
        local dx, dy = nextPoint.x - point.x, nextPoint.y - point.y
        result[#result + 1] = { a = -dy, b = dx, c = dy * point.x - dx * point.y }
    end
    return result
end

local function signed(plane, point)
    return plane.a * point.x + plane.b * point.y + plane.c
end

local function between(from, to, fraction)
    return { x = from.x + (to.x - from.x) * fraction,
        y = from.y + (to.y - from.y) * fraction }
end

function Geometry.ClipPolygon(movement, points)
    local clipped = points
    for _, plane in ipairs(planes(movement)) do
        local input = clipped
        clipped = {}
        if #input == 0 then break end
        local previous = input[#input]
        local previousDistance = signed(plane, previous)
        for _, point in ipairs(input) do
            local distance = signed(plane, point)
            if (distance >= 0) ~= (previousDistance >= 0) then
                clipped[#clipped + 1] = between(previous, point,
                    previousDistance / (previousDistance - distance))
            end
            if distance >= 0 then clipped[#clipped + 1] = point end
            previous, previousDistance = point, distance
        end
    end
    return clipped
end

function Geometry.ClipLine(movement, from, to)
    local lo, hi = 0, 1
    for _, plane in ipairs(planes(movement)) do
        local a, b = signed(plane, from), signed(plane, to)
        if a < 0 and b < 0 then return end
        if (a >= 0) ~= (b >= 0) then
            local fraction = a / (a - b)
            if a < 0 then lo = math.max(lo, fraction) else hi = math.min(hi, fraction) end
        end
    end
    if lo > hi then return end
    return between(from, to, lo), between(from, to, hi)
end

function Geometry.SampleCircle(center, radius, segments)
    local points = {}
    for index = 0, (segments or Config.visual.projection.circleSegments) - 1 do
        local angle = index * math.pi * 2 / (segments or Config.visual.projection.circleSegments)
        points[#points + 1] = { x = center.x + radius * math.cos(angle),
            y = center.y + radius * math.sin(angle) }
    end
    return points
end

function Geometry.SampleSector(center, radius, heading, halfAngle, segments)
    local count = segments or Config.visual.projection.sectorSegments
    local points = { { x = center.x, y = center.y } }
    for index = 0, count do
        local angle = heading - halfAngle + halfAngle * 2 * index / count
        points[#points + 1] = { x = center.x + radius * math.cos(angle),
            y = center.y + radius * math.sin(angle) }
    end
    return points
end

local function linePath(ctx, movement, from, to, altitude)
    local a, b = Geometry.ClipLine(movement, from, to)
    if not a then return false end
    local ax, ay = movement:WorldToScreen(a, altitude)
    local bx, by = movement:WorldToScreen(b, altitude)
    if not ax or not bx then return false end
    nvgMoveTo(ctx, ax, ay)
    nvgLineTo(ctx, bx, by)
    return true
end

function Geometry.WorldPolygon(ctx, movement, points, fillColor, strokeColor, strokeWidth, altitude)
    if fillColor then
        local clipped = Geometry.ClipPolygon(movement, points)
        if #clipped >= 3 then
            nvgBeginPath(ctx)
            for index, point in ipairs(clipped) do
                local x, y = movement:WorldToScreen(point, altitude)
                if not x then return end
                if index == 1 then nvgMoveTo(ctx, x, y) else nvgLineTo(ctx, x, y) end
            end
            nvgClosePath(ctx)
            nvgFillColor(ctx, color(fillColor))
            nvgFill(ctx)
        end
    end
    if strokeColor then
        nvgBeginPath(ctx)
        local visible = false
        for index, point in ipairs(points) do
            visible = linePath(ctx, movement, point, points[index % #points + 1], altitude) or visible
        end
        if visible then
            nvgStrokeColor(ctx, color(strokeColor))
            nvgStrokeWidth(ctx, strokeWidth or 1)
            nvgStroke(ctx)
        end
    end
end

function Geometry.WorldCircle(ctx, movement, center, radius, fillColor, strokeColor, strokeWidth, altitude)
    return Geometry.WorldPolygon(ctx, movement, Geometry.SampleCircle(center, radius),
        fillColor, strokeColor, strokeWidth, altitude)
end

function Geometry.WorldSector(ctx, movement, center, radius, heading, halfAngle, fillColor, strokeColor, strokeWidth)
    return Geometry.WorldPolygon(ctx, movement, Geometry.SampleSector(center, radius, heading, halfAngle),
        fillColor, strokeColor, strokeWidth)
end

function Geometry.WorldLine(ctx, movement, from, to, strokeColor, strokeWidth, altitude)
    nvgBeginPath(ctx)
    if linePath(ctx, movement, from, to, altitude) then
        nvgStrokeColor(ctx, color(strokeColor))
        nvgStrokeWidth(ctx, strokeWidth or 1)
        nvgStroke(ctx)
    end
end

return Geometry
