-- Sea Runtime vector art for the oblique world projection.
-- All world silhouettes stay in meters so later image assets can replace these paths.
local Config = require("Ocean.Config")
local Draw = require("Ocean.Draw")
local Projection = require("Ocean.Projection")
local SurfaceEffects = require("Ocean.SeaSurfaceEffects")

local SeaViewArt = {}
local TWO_PI = math.pi * 2
local VIEW_PADDING_METERS = 0.8
local AIR_PERSPECTIVE_TINT = { 174, 209, 211 }

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function rgba(color, fallback, alpha, airMix)
    local source = color or fallback or { 255, 255, 255, 255 }
    local a = alpha
    if not finite(a) then a = source[4] or 255 end
    local r, g, b = source[1] or 255, source[2] or 255, source[3] or 255
    if finite(airMix) and airMix > 0 then
        local mix = clamp(airMix, 0, 1)
        r = math.floor(r + (AIR_PERSPECTIVE_TINT[1] - r) * mix + 0.5)
        g = math.floor(g + (AIR_PERSPECTIVE_TINT[2] - g) * mix + 0.5)
        b = math.floor(b + (AIR_PERSPECTIVE_TINT[3] - b) * mix + 0.5)
    end
    return nvgRGBA(r, g, b, clamp(math.floor(a + 0.5), 0, 255))
end

local function screenPoint(movement, position, altitudeMeters)
    if type(movement) ~= "table" or type(movement.WorldToScreen) ~= "function" then return nil end
    local x, y, scale = movement:WorldToScreen(position, altitudeMeters or 0)
    if not finite(x) or not finite(y) then return nil end
    return { x = x, y = y, scale = finite(scale) and scale or 0 }
end

local function newScreenBounds()
    return { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
end

local function includeScreenPoint(bounds, point, padding)
    if not point then return end
    padding = padding or 0
    bounds.minX = math.min(bounds.minX, point.x - padding)
    bounds.minY = math.min(bounds.minY, point.y - padding)
    bounds.maxX = math.max(bounds.maxX, point.x + padding)
    bounds.maxY = math.max(bounds.maxY, point.y + padding)
end

local function finishScreenBounds(bounds)
    if bounds.minX == math.huge then return nil end
    bounds.x = bounds.minX
    bounds.y = bounds.minY
    bounds.width = bounds.maxX - bounds.minX
    bounds.height = bounds.maxY - bounds.minY
    return bounds
end

local function cross(ax, ay, bx, by)
    return ax * by - ay * bx
end

-- Clip a world-space footprint against Projection.ViewPolygon before projecting it.
-- This preserves partial islands and hulls at the near/far and side boundaries.
local function clipConvexPolygon(subject, clipper)
    local output = subject
    if #output < 3 or #clipper < 3 then return {} end

    for edgeIndex = 1, #clipper do
        local a = clipper[edgeIndex]
        local b = clipper[edgeIndex % #clipper + 1]
        local edgeX, edgeY = b.x - a.x, b.y - a.y
        local input = output
        output = {}
        if #input == 0 then return output end

        local previous = input[#input]
        local previousSide = cross(edgeX, edgeY, previous.x - a.x, previous.y - a.y)
        for _, current in ipairs(input) do
            local currentSide = cross(edgeX, edgeY, current.x - a.x, current.y - a.y)
            local previousInside = previousSide >= -1e-8
            local currentInside = currentSide >= -1e-8
            if previousInside ~= currentInside then
                local denominator = previousSide - currentSide
                if math.abs(denominator) > 1e-12 then
                    local t = previousSide / denominator
                    local intersection = {
                        x = previous.x + (current.x - previous.x) * t,
                        y = previous.y + (current.y - previous.y) * t,
                    }
                    if finite(previous.altitude) and finite(current.altitude) then
                        intersection.altitude = previous.altitude + (current.altitude - previous.altitude) * t
                    end
                    output[#output + 1] = intersection
                end
            end
            if currentInside then output[#output + 1] = current end
            previous, previousSide = current, currentSide
        end
    end
    return output
end

local function projectWorldPolygon(movement, worldPoints, bounds, altitudeMeters)
    local points = {}
    if #worldPoints < 3 then return points end
    for _, worldPoint in ipairs(worldPoints) do
        local altitude = finite(altitudeMeters) and altitudeMeters
            or (finite(worldPoint.altitude) and worldPoint.altitude or 0)
        local point = screenPoint(movement, worldPoint, altitude)
        if not point then return {} end
        includeScreenPoint(bounds, point)
        points[#points + 1] = point
    end
    return points
end

local function fillPolygon(ctx, points, color)
    if #points < 3 then return end
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, points[1].x, points[1].y)
    for index = 2, #points do
        nvgLineTo(ctx, points[index].x, points[index].y)
    end
    nvgClosePath(ctx)
    nvgFillColor(ctx, color)
    nvgFill(ctx)
end

local function strokePolygon(ctx, points, color, width)
    if #points < 3 then return end
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, points[1].x, points[1].y)
    for index = 2, #points do
        nvgLineTo(ctx, points[index].x, points[index].y)
    end
    nvgClosePath(ctx)
    nvgStrokeColor(ctx, color)
    nvgStrokeWidth(ctx, width)
    nvgStroke(ctx)
end

local function fillWorldPolygon(ctx, movement, points, color, bounds, altitudeMeters)
    local clipped = clipConvexPolygon(points, Projection.ViewPolygon(movement, VIEW_PADDING_METERS))
    local projected = projectWorldPolygon(movement, clipped, bounds, altitudeMeters or 0)
    fillPolygon(ctx, projected, color)
    return projected
end

local function strokeWorldPolygon(ctx, movement, points, color, width, bounds, altitudeMeters)
    local clipped = clipConvexPolygon(points, Projection.ViewPolygon(movement, VIEW_PADDING_METERS))
    local projected = projectWorldPolygon(movement, clipped, bounds, altitudeMeters or 0)
    strokePolygon(ctx, projected, color, width)
    return projected
end

local function addPoint(x, y)
    return { x = x, y = y }
end


-- The legacy scene backdrop owns the established sun, sky, and decorative birds.
function SeaViewArt.Backdrop(ctx, width, height, time)
    if not ctx or not finite(width) or not finite(height) or width <= 0 or height <= 0 then return end
    Draw.SceneBackdrop(ctx, width, height, time, true)

end

local function getSurfaceSettings()
    local visual = Config.visual or {}
    local settings = visual.surface or {}
    local nearSpacing = math.max(1, settings.nearSpacingMeters
        or settings.spacingMeters or visual.waveSpacing or 12)
    local transitionStart = math.max(0, settings.detailTransitionStartMeters or 35)
    local transitionEnd = math.max(transitionStart + 0.1,
        settings.detailTransitionEndMeters or 110)
    return {
        spacing = nearSpacing,
        nearSpacing = nearSpacing,
        farSpacing = math.max(1, settings.farSpacingMeters or nearSpacing * 0.5),
        length = math.max(0.1, settings.lengthMeters or visual.waveLength or 3),
        driftSpeed = math.max(0, settings.driftSpeed or visual.waveSpeed or 0.6),
        amplitude = math.max(0, settings.amplitudeMeters or 0.18),
        period = math.max(0.1, settings.periodSec or 5),
        transitionStart = transitionStart,
        transitionEnd = transitionEnd,
        nearLengthScale = clamp(settings.nearLengthScale or 1.8, 1, 3),
        farLengthScale = clamp(settings.farLengthScale or 0.78, 0.25, 1),
        nearAmplitudeScale = clamp(settings.nearAmplitudeScale or 1.35, 0.5, 2.5),
        farAmplitudeScale = clamp(settings.farAmplitudeScale or 0.82, 0.25, 1.5),
        nearStrokeWidthMeters = clamp(settings.nearStrokeWidthMeters or 0.12, 0.02, 0.3),
        farStrokeWidthMeters = clamp(settings.farStrokeWidthMeters or 0.055, 0.01, 0.16),
        maxMarks = math.max(1, math.floor(settings.maxMarks or 2400)),
    }
end

-- Continuous world phase shared by wave marks and boat heave. Voyage time
-- freezes with pause; sampling never changes the ship's world position.
local function surfacePhase(settings, time, cellX, cellY)
    return SurfaceEffects.SurfacePhase(settings, time, cellX, cellY)
end

local function projectVector(movement, position, dx, dy)
    if type(movement.ProjectVector) == "function" then
        local x, y = movement:ProjectVector(position, dx, dy)
        if finite(x) and finite(y) then return x, y end
    end
    local origin = screenPoint(movement, position, 0)
    local endpoint = screenPoint(movement, addPoint(position.x + dx, position.y + dy), 0)
    if not origin or not endpoint then return nil end
    return endpoint.x - origin.x, endpoint.y - origin.y
end

local function surfaceMark(movement, position, settings, time, indexX, indexY,
    viewportWidth, viewportHeight, horizonAtX, lengthScale, amplitudeScale, strokeWidthMeters)
    local center = screenPoint(movement, position, 0)
    if not center then return nil end
    local phase = surfacePhase(settings, time, indexX, indexY)
    local shape = math.sin(phase)

    local markLength = settings.length * lengthScale
        * (0.72 + 0.28 * (0.5 + 0.5 * math.cos(phase * 0.83)))
    local alongX, alongY = projectVector(movement, position, markLength, 0)
    if not alongX then return nil end
    local alongLength = math.sqrt(alongX * alongX + alongY * alongY)
    if alongLength < 1 then return nil end

    local waveX, waveY = projectVector(movement, position, 0,
        settings.amplitude * amplitudeScale * shape)
    if not waveX then return nil end
    local startX, startY = center.x - alongX * 0.5, center.y - alongY * 0.5
    local middleX, middleY = center.x + waveX, center.y + waveY
    local endX, endY = center.x + alongX * 0.5, center.y + alongY * 0.5

    local strokePadding = clamp(center.scale * strokeWidthMeters, 0.55, 3.2) * 0.75
    local minX = math.min(startX, middleX, endX)
    local maxX = math.max(startX, middleX, endX)
    local minY = math.min(startY, middleY, endY)
    local maxY = math.max(startY, middleY, endY)
    if maxX + strokePadding < 0 or minX - strokePadding > viewportWidth
        or maxY + strokePadding < horizonAtX(center.x)
        or minY - strokePadding > viewportHeight then
        return nil
    end

    return {
        startX = startX, startY = startY,
        middleX = middleX, middleY = middleY,
        endX = endX, endY = endY,
    }, center.scale
end

local function drawSurfaceRow(ctx, marks, scale, settings, layerWeight, isFarLayer)
    if #marks == 0 or layerWeight <= 0 then return end
    local visual = Config.visual or {}
    local color = visual.wave or { 109, 207, 216, 145 }
    local widthMeters = isFarLayer and settings.farStrokeWidthMeters or settings.nearStrokeWidthMeters
    local lineWidth = isFarLayer
        and clamp(scale * widthMeters, 0.55, 1.15)
        or clamp(scale * widthMeters, 1.05, 3.2)
    local haloWidth = lineWidth + (isFarLayer and 0.55 or 1.15)
    local alpha = (color[4] or 145) * layerWeight
    nvgBeginPath(ctx)
    for _, mark in ipairs(marks) do
        nvgMoveTo(ctx, mark.startX, mark.startY)
        nvgLineTo(ctx, mark.middleX, mark.middleY)
        nvgLineTo(ctx, mark.endX, mark.endY)
    end
    nvgStrokeColor(ctx, nvgRGBA(10, 87, 110, math.floor(math.min(68, alpha * 0.38) + 0.5)))
    nvgStrokeWidth(ctx, haloWidth)
    nvgStroke(ctx)
    nvgStrokeColor(ctx, rgba(color, nil, alpha))
    nvgStrokeWidth(ctx, lineWidth)
    nvgStroke(ctx)
end

local function drawSurfaceLayer(ctx, movement, time, settings, bounds, horizonAtX,
    spacing, isFarLayer, drawn)
    local camera = movement.camera
    local firstY, lastY = SurfaceEffects.CellRange(bounds.minY, bounds.maxY, spacing)
    if isFarLayer then
        firstY = math.max(firstY, math.ceil((camera.y + settings.transitionStart) / spacing - 1e-8))
    else
        lastY = math.min(lastY, math.floor((camera.y + settings.transitionEnd) / spacing + 1e-8))
    end
    if firstY > lastY then return drawn end

    -- Near detail is drawn first. The far grid is visited from the horizon back
    -- toward the transition so a bounded mark budget keeps the distant plane covered.
    local indexY = isFarLayer and lastY or firstY
    local terminalY = isFarLayer and firstY or lastY
    local yStep = isFarLayer and -1 or 1
    local lengthScale = isFarLayer and settings.farLengthScale or settings.nearLengthScale
    local amplitudeScale = isFarLayer and settings.farAmplitudeScale or 1
    if not isFarLayer then amplitudeScale = settings.nearAmplitudeScale end
    local strokeWidthMeters = isFarLayer
        and settings.farStrokeWidthMeters or settings.nearStrokeWidthMeters
    local worldMargin = settings.length * lengthScale * 0.75

    while true do
        if drawn >= settings.maxMarks then return drawn end
        local worldY = indexY * spacing
        local nearWeight, farWeight = SurfaceEffects.SurfaceLayerWeights(
            worldY - camera.y, settings.transitionStart, settings.transitionEnd)
        local layerWeight = isFarLayer and farWeight or nearWeight
        local rowAnchor = layerWeight > 0.001
            and screenPoint(movement, addPoint(camera.x, worldY), 0) or nil
        if rowAnchor and rowAnchor.scale > 1e-8 then
            local rowLeft = camera.x - rowAnchor.x / rowAnchor.scale - worldMargin
            local rowRight = camera.x + (movement.viewportWidth - rowAnchor.x) / rowAnchor.scale + worldMargin
            local firstX, lastX = SurfaceEffects.CellRange(rowLeft, rowRight, spacing)
            local rowMarks = {}
            for indexX = firstX, lastX do
                -- Static world-cell offsets break up straight grid lanes without
                -- making marks jump or swim when the camera moves.
                local jitterX = ((indexX * 0.754877666 + indexY * 0.569840291) % 1 - 0.5) * spacing * 0.55
                local jitterY = ((indexX * 0.438579021 + indexY * 0.819172513) % 1 - 0.5) * spacing * 0.55
                local mark = surfaceMark(movement, addPoint(indexX * spacing + jitterX, worldY + jitterY), settings,
                    time, indexX, indexY, movement.viewportWidth, movement.viewportHeight,
                    horizonAtX, lengthScale, amplitudeScale, strokeWidthMeters)
                if mark then
                    rowMarks[#rowMarks + 1] = mark
                    if drawn + #rowMarks >= settings.maxMarks then break end
                end
            end
            drawSurfaceRow(ctx, rowMarks, rowAnchor.scale, settings, layerWeight, isFarLayer)
            drawn = drawn + #rowMarks
        end
        if indexY == terminalY then break end
        indexY = indexY + yStep
    end
    return drawn
end

local function surfaceHorizonAt(movement, x, width, height, fallback)
    local y = Projection.Horizon(movement, clamp(x, 0, width))
    if finite(y) then return clamp(y, 0, height) end
    return fallback
end

-- A screen-fixed gradient follows the projected horizon while world-grid
-- crests transition from broad near marks to finer distant detail.
function SeaViewArt.Surface(ctx, movement, time)
    if not ctx or type(movement) ~= "table" then return end
    local width, height = movement.viewportWidth, movement.viewportHeight
    if not finite(width) or not finite(height) or width <= 0 or height <= 0 then return end
    time = finite(time) and time or 0
    local fallbackHorizon = height * (Config.camera.horizonY or 0.24)
    if type(movement.GetHorizonY) == "function" then
        fallbackHorizon = movement:GetHorizonY() or fallbackHorizon
    end
    local centerHorizon = surfaceHorizonAt(movement, width * 0.5, width, height, fallbackHorizon)
    local horizonPoints = {}
    local segmentCount = 24
    for index = 0, segmentCount do
        local x = width * index / segmentCount
        horizonPoints[#horizonPoints + 1] = {
            x = x,
            y = surfaceHorizonAt(movement, x, width, height, centerHorizon),
        }
    end
    local function horizonAtX(x)
        return surfaceHorizonAt(movement, x, width, height, centerHorizon)
    end

    nvgBeginPath(ctx)
    nvgMoveTo(ctx, horizonPoints[1].x, horizonPoints[1].y)
    for index = 2, #horizonPoints do
        nvgLineTo(ctx, horizonPoints[index].x, horizonPoints[index].y)
    end
    nvgLineTo(ctx, width, height)
    nvgLineTo(ctx, 0, height)
    nvgClosePath(ctx)
    nvgFillPaint(ctx, nvgLinearGradient(ctx, 0, centerHorizon, 0, height,
        nvgRGBA(54, 151, 165, 255), nvgRGBA(13, 73, 105, 255)))
    nvgFill(ctx)

    -- Draw the same sampled curve over the fill so the two edges stay aligned.
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, horizonPoints[1].x, horizonPoints[1].y)
    for index = 2, #horizonPoints do
        nvgLineTo(ctx, horizonPoints[index].x, horizonPoints[index].y)
    end
    nvgStrokeColor(ctx, nvgRGBA(242, 242, 213, 170))
    nvgStrokeWidth(ctx, 1.5)
    nvgStroke(ctx)

    local settings = getSurfaceSettings()
    if type(movement.GetViewBounds) ~= "function" then return end
    local bounds = movement:GetViewBounds(settings.length * 0.75)
    if type(bounds) ~= "table" or not finite(bounds.minY) or not finite(bounds.maxY) then
        return
    end

    local camera = movement.camera
    if type(camera) ~= "table" or not finite(camera.x) or not finite(camera.y) then return end

    local drawn = drawSurfaceLayer(ctx, movement, time, settings, bounds, horizonAtX,
        settings.nearSpacing, false, 0)
    drawSurfaceLayer(ctx, movement, time, settings, bounds, horizonAtX,
        settings.farSpacing, true, drawn)
end

local function circlePoints(center, radius, segmentCount)
    local points = {}
    for index = 0, segmentCount - 1 do
        local angle = TWO_PI * index / segmentCount
        points[#points + 1] = addPoint(center.x + math.cos(angle) * radius, center.y + math.sin(angle) * radius)
    end
    return points
end

local function localIslandPoint(center, x, y)
    return addPoint(center.x + x, center.y + y)
end

local function drawHill(ctx, movement, center, radius, bounds, airMix)
    if radius < 3 then return end
    local back = {
        { position = localIslandPoint(center, -radius * 0.42, radius * 0.08), altitude = 0.15 },
        { position = localIslandPoint(center, radius * 0.35, radius * 0.04), altitude = 0.15 },
        { position = localIslandPoint(center, -radius * 0.05, radius * 0.03), altitude = math.min(4.4, radius * 0.27) },
    }
    local front = {
        { position = localIslandPoint(center, -radius * 0.48, -radius * 0.10), altitude = 0.08 },
        { position = localIslandPoint(center, radius * 0.43, -radius * 0.12), altitude = 0.08 },
        { position = localIslandPoint(center, radius * 0.11, -radius * 0.07), altitude = math.min(3.4, radius * 0.19) },
    }
    for _, shape in ipairs({ back, front }) do
        local worldPoints, screenPoints = {}, {}
        for _, item in ipairs(shape) do
            worldPoints[#worldPoints + 1] = {
                x = item.position.x, y = item.position.y, altitude = item.altitude,
            }
        end
        local clipped = clipConvexPolygon(worldPoints, Projection.ViewPolygon(movement, VIEW_PADDING_METERS))
        if #clipped >= 3 then
            for _, point in ipairs(clipped) do
                local screen = screenPoint(movement, point, point.altitude or 0)
                if screen then
                    screenPoints[#screenPoints + 1] = screen
                    includeScreenPoint(bounds, screen)
                end
            end
            if #screenPoints >= 3 then
                fillPolygon(ctx, screenPoints, rgba({ 102, 143, 91, 255 }, nil, nil, airMix))
                strokePolygon(ctx, screenPoints, rgba({ 77, 118, 83, 210 }, nil, nil, airMix), 1.1)
            end
        end
    end
end

local TREE_LAYOUT = {
    { x = -0.44, y = 0.12, size = 0.88 },
    { x = -0.13, y = -0.34, size = 0.72 },
    { x = 0.20, y = 0.27, size = 1.00 },
    { x = 0.43, y = -0.08, size = 0.79 },
}

local function drawTree(ctx, movement, base, heightMeters, bounds, paletteShift, airMix)
    local crownWidth = heightMeters * 0.38
    local topAltitude = heightMeters
    local trunkTop = screenPoint(movement, base, topAltitude * 0.44)
    local trunkBottom = screenPoint(movement, base, 0)
    local leftBase = screenPoint(movement, addPoint(base.x - crownWidth * 0.48, base.y), topAltitude * 0.40)
    local rightBase = screenPoint(movement, addPoint(base.x + crownWidth * 0.48, base.y), topAltitude * 0.40)
    local crownTop = screenPoint(movement, base, topAltitude)
    if not trunkTop or not trunkBottom or not leftBase or not rightBase or not crownTop then return end

    includeScreenPoint(bounds, trunkBottom, 1)
    includeScreenPoint(bounds, crownTop, 1)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, trunkBottom.x, trunkBottom.y)
    nvgLineTo(ctx, trunkTop.x, trunkTop.y)
    nvgStrokeColor(ctx, rgba({ 111, 72, 47, 255 }, nil, nil, airMix))
    nvgStrokeWidth(ctx, clamp(trunkTop.scale * 0.13, 1, 4))
    nvgStroke(ctx)

    local leafColor = paletteShift == 1
        and rgba({ 57, 123, 91, 255 }, nil, nil, airMix)
        or rgba({ 72, 141, 93, 255 }, nil, nil, airMix)
    fillPolygon(ctx, { leftBase, rightBase, crownTop }, leafColor)
    local middleLeft = { x = (leftBase.x + crownTop.x) * 0.5, y = (leftBase.y + crownTop.y) * 0.5 }
    local middleRight = { x = (rightBase.x + crownTop.x) * 0.5, y = (rightBase.y + crownTop.y) * 0.5 }
    fillPolygon(ctx, { middleLeft, middleRight, crownTop }, rgba({ 91, 163, 102, 245 }, nil, nil, airMix))
end

local function drawShoreFoam(ctx, movement, center, shorelineRadius, time, bounds)
    local settings = (Config.visual and Config.visual.shoreFoam) or {}
    if settings.enabled == false then return end
    local count = clamp(math.floor(settings.bubbleCount or 24), 1, 64)
    local baseOpacity = clamp(settings.opacity or 165, 0, 255)
    for index = 1, count do
        local arc = SurfaceEffects.ShoreFoamArc(center, shorelineRadius, index, count, time, settings)
        if arc and arc.strength > 0.02 then
            local screenPoints, valid = {}, true
            for _, worldPoint in ipairs(arc.points) do
                local point = screenPoint(movement, worldPoint, 0)
                if not point then
                    valid = false
                    break
                end
                includeScreenPoint(bounds, point, 1.2)
                screenPoints[#screenPoints + 1] = point
            end
            if valid and #screenPoints >= 3 then
                local scale = screenPoints[math.ceil(#screenPoints * 0.5)].scale
                local alpha = math.floor(baseOpacity * arc.strength + 0.5)
                nvgBeginPath(ctx)
                nvgMoveTo(ctx, screenPoints[1].x, screenPoints[1].y)
                for pointIndex = 2, #screenPoints do
                    nvgLineTo(ctx, screenPoints[pointIndex].x, screenPoints[pointIndex].y)
                end
                nvgStrokeColor(ctx, nvgRGBA(239, 250, 246, alpha))
                nvgStrokeWidth(ctx, clamp(scale * arc.strokeWidthMeters, 0.65, 1.9))
                nvgStroke(ctx)
            end
        end
    end
end

-- World-space island disc with a projected shoreline and raised, screen-scaled landmarks.
-- Returns a screen-space envelope for optional depth/occlusion checks.
function SeaViewArt.Island(ctx, movement, entity, time, airMix)
    if not ctx or type(movement) ~= "table" or type(entity) ~= "table"
        or type(entity.position) ~= "table" or not finite(entity.position.x) or not finite(entity.position.y) then
        return nil
    end
    local center = entity.position
    local radius = math.max(0.5, finite(entity.radius) and entity.radius or 4)
    local settings = Config.visual and Config.visual.projection or {}
    local segmentCount = math.max(16, math.floor(settings.circleSegments or 48))
    local shoreColor = rgba(Config.visual and Config.visual.shore,
        { 209, 193, 137, 255 }, nil, airMix)
    local landColor = rgba(Config.visual and Config.visual.island,
        { 135, 171, 110, 255 }, nil, airMix)
    local bounds = newScreenBounds()

    local outerWorld = circlePoints(center, radius, segmentCount)
    local outerScreen = fillWorldPolygon(ctx, movement, outerWorld, shoreColor, bounds)
    if #outerScreen >= 3 then
        strokePolygon(ctx, outerScreen, rgba({ 167, 154, 112, 190 }, nil, nil, airMix), 1.25)
    end

    local landWorld = circlePoints(center, radius * 0.89, segmentCount)
    local landScreen = fillWorldPolygon(ctx, movement, landWorld, landColor, bounds)
    if #landScreen >= 3 then
        strokePolygon(ctx, landScreen, rgba({ 105, 145, 92, 170 }, nil, nil, airMix), 1)
    end
    drawShoreFoam(ctx, movement, center, radius, finite(time) and time or 0, bounds)

    drawHill(ctx, movement, center, radius, bounds, airMix)
    if radius >= 5 then
        local treeHeight = clamp(radius * 0.30, 2.2, 5.4)
        for index, layout in ipairs(TREE_LAYOUT) do
            local x, y = layout.x * radius, layout.y * radius
            if x * x + y * y < radius * radius * 0.38 then
                drawTree(ctx, movement, localIslandPoint(center, x, y),
                    treeHeight * layout.size, bounds, index % 2, airMix)
            end
        end
    end
    return finishScreenBounds(bounds)
end

local function raisedBoatPoint(position, forwardX, forwardY, sideX, sideY,
    along, across, height, heave, rollSin)
    local lateralShift = -height * rollSin
    return {
        x = position.x + forwardX * along + sideX * (across + lateralShift),
        y = position.y + forwardY * along + sideY * (across + lateralShift),
        altitude = heave + height + across * rollSin,
    }
end

local function boatFootprint(position, forwardX, forwardY, sideX, sideY, length, width, scale,
    heave, rollSin)
    local halfLength, halfWidth = length * 0.5 * scale, width * 0.5 * scale
    local shape = {
        { halfLength, 0 }, { halfLength * 0.56, halfWidth * 0.72 },
        { halfLength * 0.16, halfWidth }, { -halfLength * 0.86, halfWidth },
        { -halfLength, halfWidth * 0.86 }, { -halfLength, -halfWidth * 0.86 },
        { -halfLength * 0.86, -halfWidth }, { halfLength * 0.16, -halfWidth },
        { halfLength * 0.56, -halfWidth * 0.72 },
    }
    local points = {}
    for _, vertex in ipairs(shape) do
        points[#points + 1] = raisedBoatPoint(position, forwardX, forwardY, sideX, sideY,
            vertex[1], vertex[2], 0, heave, rollSin)
    end
    return points
end

local function drawSail(ctx, movement, position, forwardX, forwardY, sideX, sideY,
    length, bounds, heave, rollSin)
    local mastAlong = -length * 0.08
    local mastBaseWorld = raisedBoatPoint(position, forwardX, forwardY, sideX, sideY,
        mastAlong, 0, 0, heave, rollSin)
    local mastTopWorld = raisedBoatPoint(position, forwardX, forwardY, sideX, sideY,
        mastAlong, 0, 3.3, heave, rollSin)
    local mastBase = screenPoint(movement, mastBaseWorld, mastBaseWorld.altitude)
    local mastTop = screenPoint(movement, mastTopWorld, mastTopWorld.altitude)
    if not mastBase or not mastTop then return end
    includeScreenPoint(bounds, mastTop, 1.5)

    local sailPointsWorld = {
        { along = mastAlong, across = 0, height = 3.05 },
        { along = length * 0.27, across = 0, height = 0.45 },
        { along = -length * 0.34, across = 0, height = 0.45 },
    }
    local sailPoints = {}
    for _, item in ipairs(sailPointsWorld) do
        local worldPoint = raisedBoatPoint(position, forwardX, forwardY, sideX, sideY,
            item.along, item.across, item.height, heave, rollSin)
        local point = screenPoint(movement, worldPoint, worldPoint.altitude)
        if not point then return end
        includeScreenPoint(bounds, point, 1)
        sailPoints[#sailPoints + 1] = point
    end
    fillPolygon(ctx, sailPoints, nvgRGBA(247, 242, 218, 242))
    strokePolygon(ctx, sailPoints, nvgRGBA(104, 115, 112, 205), 1)

    local smallSailWorld = {
        { along = mastAlong, across = 0, height = 2.45 },
        { along = -length * 0.36, across = 0, height = 0.42 },
        { along = mastAlong, across = 0, height = 0.42 },
    }
    local smallSail = {}
    for _, item in ipairs(smallSailWorld) do
        local worldPoint = raisedBoatPoint(position, forwardX, forwardY, sideX, sideY,
            item.along, item.across, item.height, heave, rollSin)
        local point = screenPoint(movement, worldPoint, worldPoint.altitude)
        if not point then return end
        includeScreenPoint(bounds, point)
        smallSail[#smallSail + 1] = point
    end
    fillPolygon(ctx, smallSail, nvgRGBA(239, 221, 174, 238))

    nvgBeginPath(ctx)
    nvgMoveTo(ctx, mastBase.x, mastBase.y)
    nvgLineTo(ctx, mastTop.x, mastTop.y)
    nvgStrokeColor(ctx, nvgRGBA(90, 74, 58, 255))
    nvgStrokeWidth(ctx, clamp(mastBase.scale * 0.055, 1.2, 3.2))
    nvgStroke(ctx)
end

-- Full-direction small boat silhouette. Heading follows atan(direction.y, direction.x).
function SeaViewArt.Boat(ctx, movement, ship, time)
    if not ctx or type(movement) ~= "table" or type(ship) ~= "table"
        or type(ship.position) ~= "table" or not finite(ship.position.x) or not finite(ship.position.y) then
        return nil
    end
    local visual = Config.visual or {}
    local length = math.max(1, visual.shipLength or 5)
    local width = math.max(0.5, visual.shipWidth or 2.4)
    local motion = visual.boatMotion or {}
    local settings = getSurfaceSettings()
    local heave, roll = SurfaceEffects.BoatAttitude(motion, finite(time) and time or 0,
        ship.position.x, ship.position.y, settings, ship.visualTurnRate)
    local rollSin = math.sin(roll)
    local rotation = finite(ship.rotation) and ship.rotation or 0
    local forwardX, forwardY = math.cos(rotation), math.sin(rotation)
    local sideX, sideY = -forwardY, forwardX
    local bounds = newScreenBounds()
    local hullWorld = boatFootprint(ship.position, forwardX, forwardY, sideX, sideY,
        length, width, 1, heave, rollSin)
    local clippedHull = clipConvexPolygon(hullWorld, Projection.ViewPolygon(movement, VIEW_PADDING_METERS))
    local hullScreen = projectWorldPolygon(movement, clippedHull, bounds)
    if #hullScreen < 3 then return nil end

    local shadow = {}
    -- The shadow stays on the water while every part of the boat heaves together.
    for _, point in ipairs(projectWorldPolygon(movement, clippedHull, bounds, 0)) do
        shadow[#shadow + 1] = { x = point.x + 1.5, y = point.y + 3, scale = point.scale }
    end
    fillPolygon(ctx, shadow, nvgRGBA(9, 44, 62, 75))
    fillPolygon(ctx, hullScreen, rgba(visual.ship, { 251, 222, 139, 255 }))
    strokePolygon(ctx, hullScreen, nvgRGBA(100, 67, 51, 245), 1.5)

    local deckWorld = boatFootprint(ship.position, forwardX, forwardY, sideX, sideY,
        length * 0.77, width * 0.62, 1, heave, rollSin)
    local deck = clipConvexPolygon(deckWorld, Projection.ViewPolygon(movement, VIEW_PADDING_METERS))
    local deckScreen = projectWorldPolygon(movement, deck, bounds)
    fillPolygon(ctx, deckScreen, nvgRGBA(226, 158, 89, 255))
    if #deckScreen >= 3 then strokePolygon(ctx, deckScreen, nvgRGBA(143, 94, 61, 205), 1) end

    local center = screenPoint(movement, ship.position, heave)
    if center then includeScreenPoint(bounds, center, 1) end
    drawSail(ctx, movement, ship.position, forwardX, forwardY, sideX, sideY,
        length, bounds, heave, rollSin)
    return finishScreenBounds(bounds)
end

local function wakeSettings(wake)
    if type(wake) == "table" and type(wake.settings) == "table" then return wake.settings end
    local settings = (Config.visual and Config.visual.wake) or {}
    return {
        lifetimeSec = settings.lifetimeSec or 3,
        initialWidth = settings.initialWidth or 0.65,
        spreadPerSec = settings.spreadPerSec or 0.45,
        opacity = settings.opacity or 125,
    }
end

-- Draws stored, world-space wake samples. Rendering never changes sample ages.
function SeaViewArt.Wake(ctx, movement, wake)
    if not ctx or type(movement) ~= "table" or type(wake) ~= "table"
        or type(wake.records) ~= "table" then return end
    local settings = wakeSettings(wake)
    local lifetime = math.max(0.1, settings.lifetimeSec or 3)
    local baseWidth = math.max(0.05, settings.initialWidth or 0.65)
    local spread = math.max(0, settings.spreadPerSec or 0.45)
    local opacity = clamp(settings.opacity or 125, 0, 255)

    for _, record in ipairs(wake.records) do
        local position = record.position
        local age = record.age or 0
        if type(position) == "table" and finite(position.x) and finite(position.y)
            and finite(age) and age >= 0 and age < lifetime then
            local center = screenPoint(movement, position, 0)
            local rotation = finite(record.rotation) and record.rotation or 0
            if center then
                local fade = clamp(1 - age / lifetime, 0, 1)
                local halfWidth = (baseWidth + spread * age) * 0.5
                local sideX, sideY = -math.sin(rotation) * halfWidth, math.cos(rotation) * halfWidth
                local widthX, widthY = projectVector(movement, position, sideX, sideY)
                if widthX then
                    local alpha = opacity * fade ^ 1.35
                    local strokeWidth = clamp(center.scale * 0.08, 0.7, 2.8)
                    nvgBeginPath(ctx)
                    nvgMoveTo(ctx, center.x - widthX, center.y - widthY)
                    nvgLineTo(ctx, center.x + widthX, center.y + widthY)
                    nvgStrokeColor(ctx, nvgRGBA(221, 245, 238, math.floor(alpha * 0.66)))
                    nvgStrokeWidth(ctx, strokeWidth * 2.2)
                    nvgStroke(ctx)

                    nvgBeginPath(ctx)
                    nvgMoveTo(ctx, center.x - widthX * 0.58, center.y - widthY * 0.58)
                    nvgLineTo(ctx, center.x + widthX * 0.58, center.y + widthY * 0.58)
                    nvgStrokeColor(ctx, nvgRGBA(247, 255, 245, math.floor(alpha)))
                    nvgStrokeWidth(ctx, strokeWidth)
                    nvgStroke(ctx)
                end
            end
        end
    end
end

return SeaViewArt
