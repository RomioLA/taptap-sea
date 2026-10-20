-- Sea Runtime vector art for the oblique world projection.
-- All world silhouettes stay in meters so later image assets can replace these paths.
local Config = require("Ocean.Config")
local Draw = require("Ocean.Draw")
local Projection = require("Ocean.Projection")
local Geometry = require("Ocean.ProjectedGeometry")
local SurfaceEffects = require("Ocean.SeaSurfaceEffects")
local ImageArt = require("Ocean.ImageArt")
local PerfProbe = require("Ocean.PerfProbe")
local WaterFX = require("Ocean.WaterFX")

local SeaViewArt = {}
local TWO_PI = math.pi * 2
local VIEW_PADDING_METERS = 0.8
local AIR_PERSPECTIVE_TINT = { 181, 212, 203 }
-- Presentation palette only: do not rewrite shared world/config tuning.
local PAPER_WAVE = { 233, 243, 223, 255 }
local SAND_SHORE = { 226, 207, 158, 255 }
local SAGE_LAND = { 149, 171, 133, 255 }
local islandGeometry = setmetatable({}, {__mode="k"})

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

local function fillWorldPolygon(ctx, movement, points, color, bounds, altitudeMeters,frame)
    if not Geometry.WorldBoundsVisible(movement,points,altitudeMeters) then return {} end
    local projected = Geometry.ProjectPolygon(movement, points, altitudeMeters,nil,frame)
    for _, point in ipairs(projected) do includeScreenPoint(bounds, point) end
    fillPolygon(ctx, projected, color)
    return projected
end

local function strokeWorldPolygon(ctx, movement, points, color, width, bounds, altitudeMeters,frame)
    for index, point in ipairs(points) do
        Geometry.StrokeWorldLine(ctx, movement, point, points[index % #points+1], color, width, altitudeMeters,frame)
    end
end

local function addPoint(x, y)
    return { x = x, y = y }
end


-- The legacy scene backdrop owns the established sun, sky, and decorative birds.
function SeaViewArt.Backdrop(ctx, width, height, time, clock, movement)
    if not ctx or not finite(width) or not finite(height) or width <= 0 or height <= 0 then return end
    ---@type (fun(x: number): number?)?
    local horizonAtX
    if type(movement) == "table" and type(movement.viewportWidth) == "number"
        and type(movement.viewportHeight) == "number" and movement.viewportWidth > 0
        and movement.viewportHeight > 0 then
        horizonAtX = function(x)
            local horizon = Projection.Horizon(movement, x)
            if finite(horizon) then return clamp(horizon, 0, height) end
            return nil
        end
    end
    -- 天空图图层（2026-10-18 读海美术接入）：绘于渐变之上、日月云鸟之下（方案 B）。
    local function drawSky(c, w, h)
        SeaViewArt.Sky(c, movement, w, h, time, clock)
    end
    Draw.SceneBackdrop(ctx, width, height, time, true, clock, horizonAtX, drawSky)
end

local function getSurfaceSettings()
    local visual = Config.visual or {}
    local settings = visual.surface or {}
    -- 程序 crest 贴图样式（2026-10-20 用户裁定「波纹改回程序 crests 但参考贴图
    -- 样式」）：以 sea_ripple_overlay 水彩笔触为参照——白沫色、两端渐细、水彩
    -- 晕染柔边、主弧旁伴生小笔、疏朗分布。缺省值全部向内收敛到本文件历史口径，
    -- 保证缺配置/旧配置零回归（width 0 → 不拆分、haloAlpha 0 → 不描晕染）。
    local crest = visual.crest or {}
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
        crestSkipRatio = clamp(crest.skipRatio or 0, 0, 0.9),
        crestLengthJitter = clamp(crest.lengthJitter or 0, 0, 2),
        crestSkewMax = clamp(crest.skewMax or 0.16, 0.05, 0.6),
        crestSkewMin = 0.06,
        crestTaperAt = clamp(crest.taperAt or 0, 0, 0.9),
        crestTaperTip = clamp(crest.taperTip or 1, 0.1, 1),
        crestHaloWidth = clamp(crest.haloWidth or 1, 1, 4),
        crestHaloAlpha = clamp(crest.haloAlpha or 0, 0, 1),
        crestCompanionChance = clamp(crest.companionChance or 0, 0, 1),
        crestCompanionScale = clamp(crest.companionScale or 0.55, 0.1, 1),
        crestColor = crest.color,
        crestAltColor = crest.altColor,
        crestAlpha = (crest.color and crest.color[4]) or nil,
    }
end

-- Continuous world phase shared by wave marks and boat heave. Voyage time
-- freezes with pause; sampling never changes the ship's world position.
local function surfacePhase(settings, time, cellX, cellY)
    return SurfaceEffects.SurfacePhase(settings, time, cellX, cellY)
end

-- Split a projected mark at the curved water/sky edge. Small screen-space
-- samples keep the straight NanoVG segments safely on the water side.
local function clipWaveToHorizon(points, horizonAtX, margin, centerX)
    -- The clamped parabola's extrema bound the complete mark, including
    -- straight segments. Preserve its three original vertices when separated;
    -- only marks touching the horizon require 8px samples and root finding.
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, point in ipairs(points) do
        minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
        minY, maxY = math.min(minY, point.y), math.max(maxY, point.y)
    end
    local left, right = horizonAtX(minX), horizonAtX(maxX)
    local minH, maxH = math.min(left, right), math.max(left, right)
    if minX <= centerX and maxX >= centerX then minH = math.min(minH, horizonAtX(centerX)) end
    if minY - margin > maxH + 1e-7 then return { points } end
    if maxY - margin < minH - 1e-7 then return {} end
    local fragments, active = {}, nil
    local function signed(point)
        return point.y - horizonAtX(point.x) - margin
    end
    local function closeFragment()
        if active and #active >= 2 then fragments[#fragments + 1] = active end
        active = nil
    end
    for pointIndex = 1, #points - 1 do
        local from, to = points[pointIndex], points[pointIndex + 1]
        local dx, dy = to.x - from.x, to.y - from.y
        local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / 8))
        local previous = { x = from.x, y = from.y }
        local previousSide = signed(previous)
        for step = 1, steps do
            local fraction = step / steps
            local current = { x = from.x + dx * fraction, y = from.y + dy * fraction }
            local currentSide = signed(current)
            if (previousSide >= 0) ~= (currentSide >= 0) then
                local low, high = 0, 1
                for _ = 1, 14 do
                    local middle = (low + high) * 0.5
                    local candidate = {
                        x = previous.x + (current.x - previous.x) * middle,
                        y = previous.y + (current.y - previous.y) * middle,
                    }
                    if (signed(candidate) >= 0) == (previousSide >= 0) then low = middle else high = middle end
                end
                local t = (low + high) * 0.5
                local crossing = {
                    x = previous.x + (current.x - previous.x) * t,
                    y = previous.y + (current.y - previous.y) * t,
                }
                crossing.y = horizonAtX(crossing.x) + margin
                if previousSide >= 0 then
                    if not active then active = { previous } end
                    active[#active + 1] = crossing
                    closeFragment()
                else
                    closeFragment()
                    active = { crossing, current }
                end
            elseif currentSide >= 0 then
                if not active then active = { previous } end
                if active[#active].x ~= current.x or active[#active].y ~= current.y then
                    active[#active + 1] = current
                end
            else
                closeFragment()
            end
            previous, previousSide = current, currentSide
        end
    end
    closeFragment()
    return fragments
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

-- isCompanion：标记本笔为「伴生小笔」（贴图参照：主弧旁常见的卫星短笔），
-- 伴生笔不再派生下一级伴生笔（防递归）。
local function surfaceMark(movement, position, settings, time, indexX, indexY,
    viewportWidth, viewportHeight, horizonAtX, lengthScale, amplitudeScale, strokeWidthMeters,
    isCompanion)
    local center = screenPoint(movement, position, 0)
    if not center then return nil end
    local phase = surfacePhase(settings, time, indexX, indexY)
    local shape = math.sin(phase)

    -- 贴图式长短错落：贴图里既有长扫弧也有短笔触，等长会显机械。jitter=0 时
    -- 完全退回历史口径（0.72~1.0），保证无 crest 配置零回归。
    local jitter = settings.crestLengthJitter or 0
    local lengthMix = 0.5 + 0.5 * math.cos(phase * 0.83)
    local markLength = settings.length * lengthScale
        * ((jitter > 0) and (1 - 0.45 * jitter + 0.55 * jitter * lengthMix)
            or (0.72 + 0.28 * lengthMix))
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
    -- Reject an entire offscreen mark before allocating its samples or clipping.
    -- Keep a conservative extra pixel for the horizon solver's snapped roots.
    -- A partial mark still follows the complete original clipping path.
    local minX = math.min(startX, middleX, endX)
    local maxX = math.max(startX, middleX, endX)
    local minY = math.min(startY, middleY, endY)
    if maxX + strokePadding < -1 or minX - strokePadding > viewportWidth + 1
        or minY - strokePadding > viewportHeight + 1 then return nil end
    local points = {
        { x = startX, y = startY }, { x = middleX, y = middleY }, { x = endX, y = endY },
    }
    local fragments = clipWaveToHorizon(points, horizonAtX,
        math.max(0.55, strokePadding * 0.5), viewportWidth * 0.5)
    if #fragments == 0 then return nil end
    minX, maxX, minY = math.huge, -math.huge, math.huge
    for _, fragment in ipairs(fragments) do
        for _, point in ipairs(fragment) do
            minX = math.min(minX, point.x)
            maxX = math.max(maxX, point.x)
            minY = math.min(minY, point.y)
        end
    end
    if maxX + strokePadding < 0 or minX - strokePadding > viewportWidth
        or minY - strokePadding > viewportHeight then
        return nil
    end

    -- Only the separated-horizon fast path returns the original points table.
    -- Smooth inside that proven-safe convex hull; clipped fragments retain the
    -- existing line samples/root solver and cannot curve back across the edge.
    local skewHash = (indexX * 0.618033989 + indexY * 0.414213562) % 1
    local skew = (settings.crestSkewMin or 0.06) + skewHash * (settings.crestSkewMax or 0.16)
    -- 色相档：主白沫/冷调变体按格哈希二选一，避免同屏笔触一个色（贴图有冷暖笔）。
    local tintHash = (indexX * 0.569840291 + indexY * 0.754877666) % 1
    local mark = { fragments = fragments, curved = #fragments == 1 and fragments[1] == points,
        skew = skew, variant = (tintHash < 0.5) and 0 or 1 }
    if isCompanion then
        mark.companion = true
        return mark, nil, center.scale
    end
    local companionChance = settings.crestCompanionChance or 0
    local companionHash = (indexX * 0.286863528 + indexY * 0.824151931) % 1
    if companionHash < companionChance then
        local offset = companionHash / companionChance - 0.5
        local companion = surfaceMark(movement,
            addPoint(position.x + offset * settings.length * 1.6,
                position.y + (offset * 2 - 1) * settings.spacing * 0.22),
            settings, time, indexX + 0.25, indexY + 0.75, viewportWidth, viewportHeight,
            horizonAtX, lengthScale * (settings.crestCompanionScale or 0.55),
            amplitudeScale * 0.85, strokeWidthMeters * 0.72, true)
        if companion then return mark, companion, center.scale end
    end
    return mark, nil, center.scale
end

-- 贴图样式笔触（2026-10-20 用户裁定「波纹改回程序 crests 但参考贴图样式」）。
-- 以 sea_ripple_overlay 水彩波纹贴图的笔触特征为参照目标，三处改造：
--   ① halo：整条再描一遍更宽更淡的同色笔 → 水彩晕染的柔边（贴图笔触有渗色边）；
--   ② taper：在 crestTaperAt 处拆分三次贝塞尔，尾段线宽 ×taperTip → 贴图笔触
--      的两端渐细（单纯等宽描边是「线」不是「笔」）；
--   ③ companion：主弧旁的卫星短笔（贴图里常见主笔+小笔成组），只走单笔细描。
-- 同款（笔型 × 色相档）合并为一条 path 一次 stroke：逐笔 stroke 会把 draw call
-- 放大到千级，合并后回到十级量级（与历史「整行一笔」同数量级）。
-- 关闭口径：taperAt=0 不拆分、haloAlpha=0 不描晕染、companionChance=0 无伴生笔，
-- 三者皆关即退回历史单笔（且因缺 crest 配置时缺省正是如此，零回归）。
local function splitCubic(p0, c1, c2, p3, t)
    local q0x, q0y = p0.x + (c1.x - p0.x) * t, p0.y + (c1.y - p0.y) * t
    local q1x, q1y = c1.x + (c2.x - c1.x) * t, c1.y + (c2.y - c1.y) * t
    local q2x, q2y = c2.x + (p3.x - c2.x) * t, c2.y + (p3.y - c2.y) * t
    local r0x, r0y = q0x + (q1x - q0x) * t, q0y + (q1y - q0y) * t
    local r1x, r1y = q1x + (q2x - q1x) * t, q1y + (q2y - q1y) * t
    local sx, sy = r0x + (r1x - r0x) * t, r0y + (r1y - r0y) * t
    return { p0, { x = q0x, y = q0y }, { x = r0x, y = r0y }, { x = sx, y = sy } },
        { { x = sx, y = sy }, { x = r1x, y = r1y }, { x = q2x, y = q2y }, p3 }
end

local CREST_PART_RANK = { halo = 1, line = 2, companion = 3, root = 4, tip = 5 }

local function drawSurfaceRow(ctx, marks, scale, settings, layerWeight, isFarLayer)
    if #marks == 0 or layerWeight <= 0 then return end
    local visual = Config.visual or {}
    local color = visual.wave or { 109, 207, 216, 145 }
    local widthMeters = isFarLayer and settings.farStrokeWidthMeters or settings.nearStrokeWidthMeters
    local lineWidth = isFarLayer
        and clamp(scale * widthMeters, 0.55, 1.15)
        or clamp(scale * widthMeters, 1.05, 3.2)
    local alpha = (settings.crestAlpha or color[4] or 145) * layerWeight * 0.66

    local taperAt = settings.crestTaperAt or 0
    local taperTip = settings.crestTaperTip or 1
    local haloAlpha = settings.crestHaloAlpha or 0
    local haloWidth = settings.crestHaloWidth or 1
    local groups, order = {}, {}

    local function groupFor(kind, variant)
        local key = kind .. "|" .. tostring(variant)
        local entry = groups[key]
        if not entry then
            entry = { kind = kind, variant = variant, parts = {} }
            groups[key] = entry
            order[#order + 1] = entry
        end
        return entry
    end

    -- 色相档只在配了 altColor 时才分桶：否则 0/1 两档同色却各占一次 stroke，
    -- 白白翻倍 draw call（缺 crest 配置时按此自动退回历史批次数）。
    local splitTint = settings.crestAltColor ~= nil
    for _, mark in ipairs(marks) do
        local variant = splitTint and (mark.variant or 0) or 0
        for _, fragment in ipairs(mark.fragments) do
            if not mark.curved then
                local entry = groupFor("line", variant)
                entry.parts[#entry.parts + 1] = fragment
            else
                local a, b, c = fragment[1], fragment[2], fragment[3]
                -- Unequal controls give a quiet, hand-drawn crest, still wholly
                -- inside the old three-point envelope. No extra marks/samples.
                local c1 = { x = b.x + (a.x - b.x) * mark.skew, y = b.y + (a.y - b.y) * mark.skew }
                local c2 = { x = b.x + (c.x - b.x) * 0.04, y = b.y + (c.y - b.y) * 0.04 }
                if mark.companion then
                    local entry = groupFor("companion", variant)
                    entry.parts[#entry.parts + 1] = { a, c1, c2, c }
                else
                    if haloAlpha > 0 then
                        local entry = groupFor("halo", variant)
                        entry.parts[#entry.parts + 1] = { a, c1, c2, c }
                    end
                    if taperAt > 0 then
                        local root, tip = splitCubic(a, c1, c2, c, taperAt)
                        local rootEntry = groupFor("root", variant)
                        rootEntry.parts[#rootEntry.parts + 1] = root
                        local tipEntry = groupFor("tip", variant)
                        tipEntry.parts[#tipEntry.parts + 1] = tip
                    else
                        local entry = groupFor("root", variant)
                        entry.parts[#entry.parts + 1] = { a, c1, c2, c }
                    end
                end
            end
        end
    end
    -- 晕染在最底、主体与尾尖在上：与贴图的「渗色边包着实笔」同序。
    table.sort(order, function(left, right)
        local leftRank = CREST_PART_RANK[left.kind] or 9
        local rightRank = CREST_PART_RANK[right.kind] or 9
        if leftRank ~= rightRank then return leftRank < rightRank end
        return (left.variant or 0) < (right.variant or 0)
    end)

    for _, entry in ipairs(order) do
        if #entry.parts > 0 then
            nvgBeginPath(ctx)
            for _, part in ipairs(entry.parts) do
                nvgMoveTo(ctx, part[1].x, part[1].y)
                if entry.kind == "line" then
                    for index = 2, #part do
                        nvgLineTo(ctx, part[index].x, part[index].y)
                    end
                else
                    nvgBezierTo(ctx, part[2].x, part[2].y, part[3].x, part[3].y,
                        part[4].x, part[4].y)
                end
            end
            local width, partAlpha = lineWidth, alpha
            if entry.kind == "halo" then
                width, partAlpha = lineWidth * haloWidth, alpha * haloAlpha
            elseif entry.kind == "tip" then
                width = lineWidth * taperTip
            elseif entry.kind == "companion" then
                width, partAlpha = lineWidth * 0.72, alpha * 0.55
            end
            -- A single matte paper-light brush stroke, not a dark halo/neon core.
            nvgStrokeColor(ctx, rgba(
                (entry.variant == 1 and settings.crestAltColor) or settings.crestColor,
                PAPER_WAVE, partAlpha))
            nvgStrokeWidth(ctx, width * 0.86)
            nvgStroke(ctx)
        end
    end
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
                -- 贴图式疏朗：按格哈希跳过一批格位（贴图笔触并非满屏等密，
                -- 留白本身就是海面的一部分）。skipRatio=0 时等同历史口径。
                local skipHash = (indexX * 0.121669 + indexY * 0.947474) % 1
                if skipHash >= (settings.crestSkipRatio or 0) then
                    local mark, companion = surfaceMark(movement,
                        addPoint(indexX * spacing + jitterX, worldY + jitterY), settings,
                        time, indexX, indexY, movement.viewportWidth, movement.viewportHeight,
                        horizonAtX, lengthScale, amplitudeScale, strokeWidthMeters)
                    if mark then
                        rowMarks[#rowMarks + 1] = mark
                        if companion then rowMarks[#rowMarks + 1] = companion end
                        if drawn + #rowMarks >= settings.maxMarks then break end
                    end
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

-- 纯海面贴图相位选择（2026-10-17 C2，方案 A 夜罩不动）：纯函数，不读 nvg。
-- day 相 progress<duskFrom：昼图独显；[duskFrom,1] smoothstep 交叉淡入黄昏图；
-- night 相前 nightFade 段由黄昏图 smoothstep 淡回昼图——夜罩瞬间全量叠加时
-- 海面已回到昼图状态，与全体实体染色一致（overlay(昼图)≈正确夜间水色，
-- overlay(预调色夜图)≈死黑），无跳变；nightFade 之后昼图直接过夜罩。
-- 夜图（sea_surface_night）不接入自动映射，留作 SeaDebug/后续方案
-- （catalog preload=false，无自动加载路径）。无 clock / 非法相位退化为
-- 昼图独显：headless 与三参旧调用路径零回归。
---@param clock table?
---@return {base: string, over: string?, blend: number}
function SeaViewArt.SeaSurfaceFrame(clock)
    local phase, progress = Draw.ClockVisualState(clock)
    if not phase then
        return { base = "sea_surface_day", over = nil, blend = 0 }
    end
    local settings = Config.visual.seaSurface or {}
    local function smoothstep(t)
        t = clamp(t, 0, 1)
        return t * t * (3 - 2 * t)
    end
    if phase == "day" then
        local from = clamp(settings.duskFrom or 0.8, 0, 1)
        local span = math.max(0.001, clamp(settings.duskSpan or 0.2, 0.001, 1))
        local blend = smoothstep((progress - from) / span)
        if blend <= 0 then return { base = "sea_surface_day", over = nil, blend = 0 } end
        return { base = "sea_surface_day", over = "sea_surface_dusk", blend = blend }
    end
    local fade = math.max(0, settings.nightFade or 0.1)
    if fade <= 0 or progress >= fade then
        return { base = "sea_surface_day", over = nil, blend = 0 }
    end
    local blend = 1 - smoothstep(progress / fade)
    if blend <= 0 then return { base = "sea_surface_day", over = nil, blend = 0 } end
    return { base = "sea_surface_day", over = "sea_surface_dusk", blend = blend }
end

-- 天空图相位（2026-10-18 读海美术接入）：直接复用海面相位映射（SeaSurfaceFrame），
-- 仅把键名 sea_surface_day/dusk 改写为天空资产 sky_day/sky_dusk。夜间海面回落到
-- 昼图、由夜罩统一染色，故天空同步用 sky_day 过夜罩，无独立夜天图（catalog 无
-- sky_night，加载失败静默回退渐变）。纯函数，不读 nvg。
---@param clock table?
---@return {base: string, over: string?, blend: number}
function SeaViewArt.SkyFrame(clock)
    local frame = SeaViewArt.SeaSurfaceFrame(clock)
    local function mapKey(key)
        if key == "sea_surface_dusk" then return "sky_dusk" end
        return "sky_day"  -- sea_surface_day 与回落夜态均用昼天图
    end
    return { base = mapKey(frame.base), over = frame.over and mapKey(frame.over) or nil, blend = frame.blend }
end

-- 天空图图层绘制（2026-10-18 读海美术接入）：满幅天空贴图，绘于 Draw.Background
-- 的渐变之后、日月云鸟之前（方案 B，零 scissor）。base/over 交叉淡入复用 SkyFrame，
-- 由 Config.visual.skyLayer 门控（enabled=false 时整层跳过，回退程序渐变）。
-- scroll 默认开启、scrollScale 提供视差（天空无天区世界实体，横移仅微移纹理）。
-- 复用 Art.Sky 懒加载口径；零状态改写（不触碰相机/世界）。
---@param ctx NVGContextWrapper
---@param movement table
---@param width number
---@param height number
---@param time number
---@param clock table?
function SeaViewArt.Sky(ctx, movement, width, height, time, clock)
    local cfg = (Config.visual and Config.visual.skyLayer) or {}
    if cfg.enabled == false then return false end
    if not ctx or not finite(width) or not finite(height) or width <= 0 or height <= 0 then return false end
    local frame = SeaViewArt.SkyFrame(clock)
    local baseName, overName = frame.base, frame.over
    if not ImageArt.GetSpec(baseName) then return false end
    local layerAlpha = finite(cfg.alpha) and cfg.alpha or 1.0
    local scrollX = 0
    if cfg.scroll ~= false then
        local camera = movement and movement.camera
        local cameraX = type(camera) == "table" and camera.x or 0
        if not finite(cameraX) then cameraX = 0 end
        local scale = finite(cfg.scrollScale) and cfg.scrollScale or 1
        local base = height / (Config.camera.viewHeight or 45)
        scrollX = -((cameraX * base * scale) % width)
    end
    -- 交叉淡入与海面同构（方案 A 夜罩不动）：base 满幅、over 按 blend 叠加，
    -- 由 Art.Sky 的 alpha 控制；blend 越界已由 SeaSurfaceFrame 钳制在 [0,1]。
    local drew = false
    drew = ImageArt.Sky(ctx, baseName, width, height, layerAlpha, scrollX) or drew
    if overName and frame.blend and frame.blend > 0 then
        drew = ImageArt.Sky(ctx, overName, width, height, layerAlpha * frame.blend, scrollX) or drew
    end
    return drew
end

-- A screen-fixed gradient follows the projected horizon; the tiled ripple layer
-- (2026-10-18 C4) replaces world-grid crests when its art is available, otherwise
-- crests transition from broad near marks to finer distant detail.
function SeaViewArt.Surface(ctx, movement, time, clock)
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
    local horizon = Projection.HorizonFunction(movement)
    local function horizonAtX(x)
        if horizon then return clamp(horizon(clamp(x, 0, width)), 0, height) end
        return centerHorizon
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
        nvgRGBA(86, 178, 180, 255), nvgRGBA(43, 148, 162, 255)))
    nvgFill(ctx)
    -- 纯海面贴图层（2026-10-17 C2，方案 A）：渐变保留为最终兜底；贴图可用时
    -- 叠加（base + 按相位交叉淡入的 over），只有加载失败/显式关闭才走纸纹层，
    -- 避免贴图与纸纹双重颗粒叠加。底图默认固定（scroll=false，2026-10-18 真机
    -- 验收裁定）：海面是屏幕空间材质层，跟随相机横移会与世界实体速率脱节；
    -- scroll=true 时按近水速率偏移（1 世界米 = base 屏距，anchor 深度 q=1，
    -- 与 Projection.parameters 同口径），负向偏移，REPEATX 横向无缝循环；
    -- 暂停时相机冻结，偏移自然静止。
    local seaSettings = Config.visual.seaSurface or {}
    local seaDrawn = false
    if seaSettings.enabled ~= false and type(ImageArt.SeaSurface) == "function" then
        local frame = SeaViewArt.SeaSurfaceFrame(clock)
        local alpha = seaSettings.alpha
        if type(alpha) ~= "number" or alpha < 0 or alpha > 1 then alpha = 1 end
        local scrollX = 0
        if seaSettings.scroll ~= false then
            local camera = movement.camera
            local cameraX = type(camera) == "table" and camera.x or 0
            if not finite(cameraX) then cameraX = 0 end
            local scale = seaSettings.scrollScale
            if type(scale) ~= "number" or scale < 0 then scale = 1 end
            local viewHeight = Config.camera and Config.camera.viewHeight or 45
            local base = height / viewHeight
            scrollX = -((cameraX * base * scale) % width)
        end
        seaDrawn = ImageArt.SeaSurface(ctx, movement, width, height, frame.base, alpha, scrollX)
        if seaDrawn and frame.over and frame.blend > 0 then
            ImageArt.SeaSurface(ctx, movement, width, height, frame.over, alpha * frame.blend, scrollX)
        end
    end
    -- Optional flat paper material supplied by ImageArt; world crests below
    -- still own motion, fixed cell density and the bounded mark budget.
    if not seaDrawn and type(ImageArt.WaterPaper) == "function" then
        ImageArt.WaterPaper(ctx, movement, width, height)
    end
    -- 波纹平铺层（2026-10-18 C4，用户提供水彩波纹纹理 sea_ripple_overlay）：
    -- 屏幕空间双向平铺，叠加于海面底图之上，替换程序 crest marks——本层绘制
    -- 成功即跳过 crests（2026-10-19 起波纹按近水速率随船横移，scrollScale 可关），
    -- 加载失败/显式关闭则 crests 照旧（贴图优先、失败回退，零回归）。
    -- alpha/瓦片缩放/滚动速率经 Config.visual.seaRipple 透传。
    local rippleDrawn = false
    local rippleSettings = Config.visual.seaRipple or {}
    if rippleSettings.enabled ~= false and type(ImageArt.SeaRipple) == "function" then
        rippleDrawn = ImageArt.SeaRipple(ctx, movement, width, height,
            rippleSettings.alpha, rippleSettings.tileScale)
    end

    -- 近景海面动态效果（2026-10-20 焦散 + DuDv）：世界米制网格分片贴焦散图，
    -- 区域以相机（在 Movement 里跟随船）为中心，逐顶点 UV 含 DuDv 位移，
    -- 画在底图/波纹层之上、程序 crests 之下（水纹笔触仍压在最上层）。
    -- 与海面底图、波纹层完全解耦：enabled=false 或贴图加载失败即整层跳过，
    -- 原有表现一字不变（零回归）。纯读状态，不碰相机/世界。
    local nearWater = Config.visual.nearWaterFX
    if type(nearWater) == "table" and nearWater.enabled == true then
        WaterFX.Draw(ctx, movement, nil, time, clock, nearWater)
    end

    -- Draw the same sampled curve over the fill so the two edges stay aligned.
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, horizonPoints[1].x, horizonPoints[1].y)
    for index = 2, #horizonPoints do
        nvgLineTo(ctx, horizonPoints[index].x, horizonPoints[index].y)
    end
    nvgStrokeColor(ctx, nvgRGBA(234, 235, 206, 145))
    nvgStrokeWidth(ctx, 1.15)
    nvgStroke(ctx)

    -- 波纹平铺层已承接海面细节：跳过程序 crest marks（GetViewBounds 是 crest 段
    -- 入口，测试以此断言是否进入浪脊格绘制）。
    if rippleDrawn then return end
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

local function hillShapes(center,radius)
    if radius<3 then return {} end
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
    local shapes={}
    for _, shape in ipairs({ back, front }) do
        local worldPoints={}
        for _, item in ipairs(shape) do
            worldPoints[#worldPoints + 1] = {
                x = item.position.x, y = item.position.y, altitude = item.altitude,
            }
        end
        shapes[#shapes+1]=worldPoints
    end
    return shapes
end

-- 岛饰贴图接入常数（2026-10-15 接入，2026-10-16 方案 A 投影模式修正）。
-- 山/树是正视图素材：10-15 曾按 Plane 平铺进世界平面，被斜投影压扁剪切、丢失矢量版
-- 的立体高度（SeaFusionRenderTests 的 hasGreenFillAboveY 契约要求岛饰高出地平线，
-- 平铺在真机上做不到，只因离线测试图片加载失败走矢量兜底才没红）。现改走
-- ImageArt.Upright 竖幅公告板：世界锚点+深度缩放，高度直接沿用矢量版口径
-- （丘峰 min(4.4, r*0.27)、树高 clamp(r*0.30, 2.2, 5.4)），底沿坐世界锚点，
-- 宽度按源图内容宽高比推导——正视图素材无需重绘。
-- 泡沫环（foam_ring 贴图 + 程序弧）：2026-10-18 真机反馈「所有岛屿外围的白色
-- 泡沫效果不好」→ 全体岛屿移除。drawShoreFoam 与 FOAM_RING_* 常数一并下线；
-- SurfaceEffects.ShoreFoamArc 数学函数保留（SeaMotionEffectsTests 契约直测），
-- 立牌口径常数见下（变体岛贴图竖幅公告板高度）。
local HILL_PEAK_MAX, HILL_PEAK_RATIO = 4.4, 0.27
local VARIANT_BILLBOARD_RATIO, VARIANT_BILLBOARD_MIN, VARIANT_BILLBOARD_MAX = 0.55, 2.6, 6.0
-- 2026-10-19：变体岛贴图覆盖矢量轮廓时的外扩比例（按矢量岛投影高的百分比）。
local VARIANT_BILLBOARD_COVER_PAD = 0.04

local function drawHill(ctx, movement, center, radius, bounds, airMix,shapes,frame,imageName)
    if imageName and radius >= 3 then
        -- 方案 A（2026-10-16）：沙丘/草坡是正视图素材，走竖幅公告板；
        -- 丘高沿用矢量丘峰口径 min(4.4, r*0.27)，底沿坐岛心。
        if ImageArt.Upright(ctx, imageName, movement, center,
            math.min(HILL_PEAK_MAX, radius * HILL_PEAK_RATIO), 1) then
            return
        end
        -- Upright 返回 false 仅发生于加载失败（不缓存重试），保持矢量回退。
    end
    for _,worldPoints in ipairs(shapes or hillShapes(center,radius)) do
        if Geometry.WorldBoundsVisible(movement,worldPoints) then
            local projected = Geometry.ProjectPolygon(movement, worldPoints,nil,nil,frame)
            for _, point in ipairs(projected) do includeScreenPoint(bounds, point) end
            fillPolygon(ctx, projected, rgba({211,191,147,255}, nil, nil, airMix))
            strokeWorldPolygon(ctx,movement,worldPoints,rgba({140,124,98,210},nil,nil,airMix),1.1,bounds,nil,frame)
        end
    end
end

local TREE_LAYOUT = {
    { x = -0.44, y = 0.12, size = 0.88 },
    { x = -0.13, y = -0.34, size = 0.72 },
    { x = 0.20, y = 0.27, size = 1.00 },
    { x = 0.43, y = -0.08, size = 0.79 },
}

-- C2（2026-10-17）：island_01（设计宝藏岛）固定岛饰——OceanComponents sign_* 七件
-- oblique 海面组件（宝箱/金币/破木板/岩石/海草 + 棕榈/阔叶点缀）。2026-10-17 深夜
-- 用户仲裁批准「sign_* 作岛饰」方案：此前的 D3-A「保持素材库不放置」经人类裁决
-- 解除，跨渠道指令冲突（另一渠道宽口径「海面以外其他的组件进入c2渲染」）以本
-- 裁定为准。坐标为岛半径归一化（乘 r 得世界偏移）：全部落在陆地圈 0.89r 内，
-- 且与 TREE_LAYOUT 四个树位保持 ≥1.4m 间距（r=12 口径实测）；size 为内容主体
-- 沿 +X 的世界长度（米）。
-- 纯装饰：零碰撞、零半径、零玩法改动；单件加载失败由 Component 返回 false 静默跳过，
-- 不影响其余饰件与矢量岛体（守卫见 Circle1B5ComponentPlacementTests）。
local ISLAND_01_DECOR = {
    { name = "sign_chest_v1",     x =  0.02, y =  0.40, size = 1.6 },
    { name = "sign_coins_v1",     x = -0.30, y =  0.34, size = 1.1 },
    { name = "sign_planks_v1",    x =  0.34, y =  0.05, size = 1.8 },
    { name = "sign_rock_v1",      x =  0.12, y = -0.42, size = 1.5 },
    { name = "sign_seaweed_v1",   x =  0.46, y =  0.30, size = 1.2 },
    { name = "sign_palm_v1",      x = -0.38, y = -0.30, size = 2.2 },
    { name = "sign_broadleaf_v1", x = -0.10, y =  0.52, size = 1.8 },
}

-- 岛屿底图映射（2026-10-18 真机验收）：海岸/礁石 oblique 组件由独立海面投放
-- （Config.world.fixedComponents 平铺，呈漂浮贴图块）改为既有岛屿底图试配——
-- island_01←海岸底图（主岛沙滩底）、island_02←礁石（远岛礁石底）。经 Plane
-- 世界锚定平铺于岛位（oblique 资产与斜投影同口径，内容比换算同 island 口径），
-- 程序丘/树/泡沫/岛饰保持叠绘；加载失败回退既有 island.png，再失败走矢量兜底。
-- 未映射岛走原 island.png 口径不变；映射可一行调整（换岛/增减/试配反转），
-- 契约由 Circle1B5ComponentPlacementTests 守护。
local ISLAND_BASE_TEXTURES = {
    island_01 = "coast_base_v3",
    island_02 = "reef_rocks_v1",
}

-- ISLAND_VARIANTS：6 座新岛屿矢量变体数据（2026-10-18，用户指令按图比例矢量化）。
-- 归一化坐标（[-1,1]）乘各岛世界 radius 得世界偏移；y 为世界北向。
-- 轮廓按贴图形态手工布点（自动提取被水纹桥接否决，实验记录见工作区
-- .tmp/island_mask_check2.png）；外接半径锚定贴图实测实体外接半径。
-- hills: 丘位+h 峰比例（丘高换算 min(4.4, r*0.27)*h）；trees: 树位+s 尺寸比例
-- （树高 clamp(r*0.30,2.2,5.4)*s）；rocks: 散石+s；pillar: 中央石柱（stele）。
local ISLAND_VARIANTS = {
    island_peak_v1 = {
        radius = 7,
        landInset = 0.82,
        outline = {
            { {x=-0.05, y=0.95}, {x=0.25, y=0.62}, {x=0.55, y=0.30}, {x=0.85, y=0.05}, {x=0.80, y=-0.25}, {x=0.55, y=-0.45}, {x=0.20, y=-0.52}, {x=-0.25, y=-0.50}, {x=-0.60, y=-0.38}, {x=-0.85, y=-0.10}, {x=-0.80, y=0.22}, {x=-0.55, y=0.50}, {x=-0.30, y=0.72} },
        },
        hills = { {x=-0.05, y=0.05, h=1.00}, {x=0.35, y=0.25, h=0.45} },
        trees = { {x=-0.35, y=0.15, s=0.80}, {x=0.25, y=0.45, s=0.70}, {x=-0.15, y=-0.30, s=0.65} },
        rocks = { {x=0.72, y=0.58, s=0.10}, {x=-0.68, y=0.62, s=0.08} },
    },
    island_reefcluster_v1 = {
        radius = 9,
        outline = {
            { {x=-0.68, y=0.48}, {x=-0.52, y=0.58}, {x=-0.38, y=0.50}, {x=-0.42, y=0.34}, {x=-0.60, y=0.32} },
            { {x=0.02, y=0.62}, {x=0.20, y=0.68}, {x=0.34, y=0.56}, {x=0.22, y=0.44}, {x=0.04, y=0.46} },
            { {x=-0.38, y=-0.02}, {x=-0.20, y=0.08}, {x=-0.06, y=0.00}, {x=-0.12, y=-0.16}, {x=-0.32, y=-0.14} },
            { {x=0.28, y=-0.06}, {x=0.46, y=0.02}, {x=0.54, y=-0.14}, {x=0.40, y=-0.26}, {x=0.26, y=-0.20} },
            { {x=-0.16, y=-0.62}, {x=0.02, y=-0.54}, {x=0.16, y=-0.64}, {x=0.08, y=-0.78}, {x=-0.10, y=-0.76} },
        },
    },
    island_cliff_v1 = {
        radius = 9,
        landInset = 0.82,
        outline = {
            { {x=-0.32, y=0.78}, {x=0.32, y=0.78}, {x=0.42, y=0.35}, {x=0.24, y=-0.02}, {x=0.50, y=-0.30}, {x=0.46, y=-0.46}, {x=0.08, y=-0.55}, {x=-0.30, y=-0.50}, {x=-0.50, y=-0.28}, {x=-0.26, y=0.02}, {x=-0.44, y=0.38} },
        },
        hills = { {x=0.00, y=-0.05, h=1.00} },
        trees = { {x=-0.20, y=0.45, s=0.40}, {x=0.25, y=0.40, s=0.35} },
        rocks = { {x=0.62, y=0.55, s=0.10} },
    },
    island_stele_v1 = {
        radius = 4,
        landInset = 0.82,
        outline = {
            { {x=0.00, y=0.42}, {x=0.30, y=0.30}, {x=0.45, y=0.00}, {x=0.30, y=-0.30}, {x=0.00, y=-0.42}, {x=-0.30, y=-0.30}, {x=-0.45, y=0.00}, {x=-0.30, y=0.30} },
        },
        rocks = { {x=0.70, y=0.30, s=0.12}, {x=-0.65, y=-0.35, s=0.10} },
        pillar = {x=0.00, y=0.02, h=0.90},
    },
    island_twinhills_v1 = {
        radius = 10,
        landInset = 0.82,
        outline = {
            { {x=-0.78, y=0.08}, {x=-0.66, y=0.44}, {x=-0.34, y=0.55}, {x=-0.06, y=0.34}, {x=0.22, y=0.50}, {x=0.56, y=0.44}, {x=0.80, y=0.06}, {x=0.58, y=-0.36}, {x=0.05, y=-0.50}, {x=-0.52, y=-0.42} },
        },
        hills = { {x=-0.32, y=0.05, h=0.75}, {x=0.30, y=0.05, h=0.65} },
        trees = { {x=-0.35, y=0.35, s=0.55}, {x=0.30, y=0.35, s=0.50} },
        rocks = { {x=-0.62, y=-0.45, s=0.08} },
    },
    island_sandbar_v1 = {
        radius = 10,
        landInset = 0.82,
        outline = {
            { {x=0.88, y=0.06}, {x=0.72, y=0.34}, {x=0.26, y=0.46}, {x=-0.28, y=0.44}, {x=-0.72, y=0.22}, {x=-0.86, y=-0.12}, {x=-0.48, y=-0.38}, {x=0.24, y=-0.42}, {x=0.70, y=-0.24} },
        },
        trees = { {x=-0.30, y=0.00, s=0.50}, {x=0.10, y=0.15, s=0.45}, {x=0.45, y=-0.10, s=0.40} },
        rocks = { {x=0.55, y=0.35, s=0.09}, {x=-0.55, y=0.30, s=0.07}, {x=0.10, y=-0.45, s=0.06} },
    },
}

local function treeShape(base,heightMeters)
    local crownWidth = heightMeters * 0.38
    local function raised(x,h) return {x=base.x+x,y=base.y,altitude=h} end
    local stem={raised(0,0),raised(0,heightMeters*.44)}
    local left,right,top=raised(-crownWidth*.48,heightMeters*.40),
        raised(crownWidth*.48,heightMeters*.40),raised(0,heightMeters)
    local middleLeft=raised(-crownWidth*.24,heightMeters*.70)
    local middleRight=raised(crownWidth*.24,heightMeters*.70)
    return {stem=stem,leaf={left,right,top},highlight={middleLeft,middleRight,top},
        envelope={stem[1],stem[2],left,right,top}}
end

local function drawTree(ctx, movement, base, heightMeters, bounds, paletteShift, airMix,shape,frame,imageName)
    if imageName then
        -- 方案 A（2026-10-16）：树是正视图素材，走竖幅公告板；高度沿用矢量树口径，
        -- 底沿坐世界树基（与矢量 treeShape 的 stem[1] 同点），宽度按内容宽高比推导。
        if ImageArt.Upright(ctx, imageName, movement, base, heightMeters, 1) then
            return
        end
        -- 加载失败保持矢量回退（下方原路径）。
    end
    shape=shape or treeShape(base,heightMeters)
    if not Geometry.WorldBoundsVisible(movement,shape.envelope) then return end
    Geometry.StrokeWorldLine(ctx,movement,shape.stem[1],shape.stem[2],
        rgba({119,98,73,255},nil,nil,airMix),1.3,nil,frame)
    local leafColor = paletteShift == 1 and {91,126,109,255} or {108,141,117,255}
    local projected=Geometry.ProjectPolygon(movement,shape.leaf,nil,nil,frame)
    for _,point in ipairs(projected) do includeScreenPoint(bounds,point) end
    fillPolygon(ctx,projected,rgba(leafColor,nil,nil,airMix))
    fillPolygon(ctx,Geometry.ProjectPolygon(movement,shape.highlight,nil,nil,frame),
        rgba({142,165,132,245},nil,nil,airMix))
end

-- C2（2026-10-17）：海面组件渲染入口（OceanComponents 藏品：coast_base/reef_rocks 等
-- oblique 海面组件）。此前这批素材只有 catalog 条目、无渲染器（status=ready_not_placed）；
-- 本函数提供与 island/barrel 同构的世界平面放置能力：内容主体尺寸经
-- ImageArt.ContentPlaneSize 按 catalog 内容比换算，走 Plane（懒加载 + LOD + 地平线裁剪），
-- 不做世界生成/实体注册——放置决策（礁石群/海岸补丁放哪）由内容侧另行裁决。
---@param ctx NVGContextWrapper
---@param name string catalog 键（如 reef_rocks_v1）
---@param movement table
---@param center table 世界锚点（内容主体中心）
---@param sizeMeters number 内容主体沿 +X 的世界长度（米）
---@param heading number? 世界弧度，0 朝 +X
---@param alpha number?
---@return boolean 贴图是否绘制（false=目录缺失/尺寸非法/加载失败，调用方走矢量兜底）
function SeaViewArt.Component(ctx, name, movement, center, sizeMeters, heading, alpha)
    if not ctx or type(movement) ~= "table" or type(center) ~= "table" then return false end
    if not finite(center.x) or not finite(center.y) then return false end
    if type(name) ~= "string" or type(sizeMeters) ~= "number" or sizeMeters <= 0 then return false end
    if not ImageArt.GetSpec(name) then return false end
    local canvasLength, canvasWidth = ImageArt.ContentPlaneSize(name, sizeMeters)
    if not canvasLength then return false end
    return ImageArt.Plane(ctx, name, movement, center, canvasLength, canvasWidth, heading or 0, 0, alpha)
end

-- 2026-10-18：6 座新岛屿矢量变体（OceanIslands 藏品，Config.world.fixedIslands 以
-- kind="scenery" 注册）。世界内形态=矢量（用户指令「在世界生成这几张图的矢量图，
-- 参考复用现有实体岛屿，矢量绘画根据图中尺寸比例绘制」）： oblique 贴图独立投放
-- 已被真机验收否决（漂浮贴图块），故变体岛不走贴图层，直接按 ISLAND_VARIANTS
-- 轮廓比例绘制；贴图经 catalog preload=false 入资产库备用。几何缓存复用
-- islandGeometry（与圆形岛同键不同构：variant 标记区分），只读渲染零状态改写。
local function variantGeometry(entity, center, radius, variant)
    local cached = islandGeometry[entity]
    if cached and cached.variant == variant and cached.x == center.x
        and cached.y == center.y and cached.radius == radius then
        return cached
    end
    local geometry = { variant = variant, x = center.x, y = center.y, radius = radius,
        outerPolys = {}, landPolys = {}, hills = {}, trees = {}, rocks = {}, pillar = nil }
    for _, poly in ipairs(variant.outline) do
        local points, land = {}, {}
        for _, p in ipairs(poly) do
            points[#points + 1] = addPoint(center.x + p.x * radius, center.y + p.y * radius)
            land[#land + 1] = addPoint(center.x + p.x * radius * (variant.landInset or 0.82),
                center.y + p.y * radius * (variant.landInset or 0.82))
        end
        geometry.outerPolys[#geometry.outerPolys + 1] = points
        if variant.landInset then
            geometry.landPolys[#geometry.landPolys + 1] = land
        end
    end
    local peak = math.min(HILL_PEAK_MAX, radius * HILL_PEAK_RATIO)
    for _, hill in ipairs(variant.hills or {}) do
        geometry.hills[#geometry.hills + 1] = {
            { x = center.x + (hill.x - 0.42) * radius, y = center.y + (hill.y + 0.08) * radius, altitude = 0.15 },
            { x = center.x + (hill.x + 0.35) * radius, y = center.y + (hill.y + 0.04) * radius, altitude = 0.15 },
            { x = center.x + hill.x * radius, y = center.y + (hill.y + 0.03) * radius, altitude = peak * hill.h },
        }
    end
    local treeHeight = clamp(radius * 0.30, 2.2, 5.4)
    for index, tree in ipairs(variant.trees or {}) do
        local base = localIslandPoint(center, tree.x * radius, tree.y * radius)
        local height = treeHeight * tree.s
        geometry.trees[#geometry.trees + 1] = { base = base, height = height,
            palette = index % 2, name = index % 2 == 0 and "tree_round" or "tree_palm",
            shape = treeShape(base, height) }
    end
    geometry.rocks = variant.rocks or {}
    geometry.pillar = variant.pillar
    islandGeometry[entity] = geometry
    return geometry
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
    -- 2026-10-18：6 座新岛屿变体（ISLAND_VARIANTS）。不走完整岛 PNG 早退
    -- （drewCompleteIsland）；贴图/矢量口径统一在下方底图段（贴图优先、矢量兜底）。
    local variant = ISLAND_VARIANTS[entity.contentId or ""]
    local probeTotalStop = PerfProbe.Timer()
    -- A complete top-down PNG contains beach, hills, vegetation and static shore
    -- decoration. Skip only their draw cost, before constructing vector geometry.
    -- The world entity/radius still owns collision and location rules. Failed image
    -- loading takes the original cached/culled vector path below, unchanged.
    local imageSpec = ImageArt.GetSpec("island")
    local probeCompletePngStop = PerfProbe.Timer()
    local drewCompleteIsland = not ISLAND_BASE_TEXTURES[entity.contentId or ""] and not variant
        and imageSpec and imageSpec.completeIsland
        and ImageArt.Sprite(ctx, "island", movement,
            center, radius * 2, 0, 0, 1, radius * 2)
    PerfProbe.Sample("islandPng", probeCompletePngStop())
    if drewCompleteIsland then
        local imageBounds = newScreenBounds()
        local corners = {
            { x = center.x - radius, y = center.y - radius },
            { x = center.x + radius, y = center.y - radius },
            { x = center.x + radius, y = center.y + radius },
            { x = center.x - radius, y = center.y + radius },
        }
        for _, point in ipairs(Geometry.ProjectPolygon(movement, corners)) do
            includeScreenPoint(imageBounds, point)
        end
        PerfProbe.Sample("islandTotal", probeTotalStop())
        return finishScreenBounds(imageBounds)
    end
    local settings = Config.visual and Config.visual.projection or {}
    local segmentCount = math.max(16, math.floor(settings.circleSegments or 48))
    ---@type table
    local geometry=islandGeometry[entity]
    if variant then
        -- 变体岛：variantGeometry 自带缓存（variant 标记+坐标+半径命中即复用）。
        geometry = variantGeometry(entity, center, radius, variant)
    elseif not geometry or geometry.x~=center.x or geometry.y~=center.y
        or geometry.radius~=radius or geometry.segments~=segmentCount then
        geometry={x=center.x,y=center.y,radius=radius,segments=segmentCount,
            outer=circlePoints(center,radius,segmentCount),
            land=circlePoints(center,radius*.89,segmentCount),
            hills=hillShapes(center,radius),trees={},
            -- 山造型按岛世界位置轮换沙丘/草坡（位置 hash 稳定，相邻岛不同造型）。
            hillName=(math.floor(center.x*7+center.y*13)%2==0) and "hill_sand" or "hill_grass"}
        if radius>=5 then
            local treeHeight=clamp(radius*.30,2.2,5.4)
            for index,layout in ipairs(TREE_LAYOUT) do
                local x,y=layout.x*radius,layout.y*radius
                if x*x+y*y<radius*radius*.38 then
                    local base=localIslandPoint(center,x,y)
                    local height=treeHeight*layout.size
                    geometry.trees[#geometry.trees+1]={base=base,height=height,
                        palette=index%2,
                        name=index%2==0 and "tree_round" or "tree_palm",
                        shape=treeShape(base,height)}
                end
            end
        end
        islandGeometry[entity]=geometry
    end
    local shoreColor = rgba(SAND_SHORE, nil, nil, airMix)
    local landColor = rgba(SAGE_LAND, nil, nil, airMix)
    local bounds = newScreenBounds()

    -- Share projection constants only for this synchronous island draw. The
    -- persistent cache above contains world geometry, never screen coordinates.
    local frame={project=Projection.ProjectFunction(movement),
        horizon=Projection.HorizonFunction(movement)}

    local outerWorld = geometry.outer
    local landWorld = geometry.land
    -- 变体岛轮廓为多边形组（outline 每子多边形一岸块），圆形岛为单点阵。
    local outerPolys = geometry.outerPolys or { outerWorld }
    local landPolys = geometry.landPolys or { landWorld }
    -- 仅替换岛面纹理；保留原岛的高处几何、遮挡、弱键缓存和泡沫。
    -- 方案 A（2026-10-16）：缩放口径从硬编码 0.88（旧版 island.png 的内容比
    -- 900/1024）改为按 catalog 内容主体计算——story 版内容比 730/1024=0.713，
    -- 旧口径令岛贴图只画到世界半径的 0.80，与碰撞/泡沫口径脱节。
    local probePngStop = PerfProbe.Timer()
    -- 内容主体填满世界直径（2r）：catalog 内容比（story 730/739=0.713，
    -- loop 900/901=0.879）→ 画幅 2r*pixel/content，岛贴图边缘与世界岸线对齐。
    -- 走 Plane（懒加载+LOD）而非 Sprite（严格 IsLoaded，SeaDebug 切换变体会漏绘）。
    -- 2026-10-18 真机验收：映射岛（ISLAND_BASE_TEXTURES）以 oblique 底图（海岸/礁石）
    -- 替代 island.png 作岛体底图；底图加载失败回退 island.png，再失败走矢量兜底。
    -- 2026-10-18 晚（用户「对应岛屿素材渲染接入」）：变体岛贴图从备用转正。
    -- 2026-10-18 真机二轮反馈（红框截图）：变体岛贴图走 Plane 世界平面平铺呈
    -- 「漂浮贴图块」观感，与 oblique 独立投放同病——现改竖幅公告板投影
    -- （ImageArt.Upright，与 sign_* 岛饰/丘/树同一投影口径）：contentId 即
    -- catalog 条目名，底沿坐岛心、高度按岛半径比例 clamp，加载失败回退变体
    -- 矢量轮廓（不回退 island.png，形态完全不同）。映射岛（island_01/02）
    -- 维持 Plane 底图口径（用户前轮亲定，本批不涉及）。
    local baseName = ISLAND_BASE_TEXTURES[entity.contentId or ""]
    local canvasLength, canvasWidth
    local hasImage = false
    -- 变体岛零 Plane（贴图走 Upright 立牌，见下方 variantBillboard 段）；
    -- 映射岛 Plane 底图、失败回退 island.png；其余岛走 island.png Plane。
    if not variant then
        canvasLength, canvasWidth = ImageArt.ContentPlaneSize(baseName or "island", radius * 2)
        if canvasLength then
            hasImage = ImageArt.Plane(ctx, baseName or "island", movement, center,
                canvasLength, canvasWidth, 0, 0)
        end
        if baseName and not hasImage then
            canvasLength, canvasWidth = ImageArt.ContentPlaneSize("island", radius * 2)
            if canvasLength then
                hasImage = ImageArt.Plane(ctx, "island", movement, center,
                    canvasLength, canvasWidth, 0, 0)
            end
        end
    end
    PerfProbe.Sample("islandPng", probePngStop())
    -- 矢量岸块。变体岛先用「只投影不填色」探测矢量轮廓的屏幕包围盒（shore+land
    -- 两层都要，外框比内芯大），据此给覆盖立牌定尺（用户指令「矢量图做尺寸的
    -- 标准」）；填色延后到立牌判定之后——覆盖成功则不填，否则贴图内容主体的透明
    -- 留边压不住下层色块，真机呈现「岛心一团贴图 + 四周大块土黄/橄榄矩形」。
    -- 非变体岛（无覆盖立牌）与覆盖失败回退路径仍走原矢量填色。
    local probeVectorStop = PerfProbe.Timer()
    local vectorBounds
    if variant then
        local probe = newScreenBounds()
        local collect = function(polys)
            for _, poly in ipairs(polys) do
                if Geometry.WorldBoundsVisible(movement, poly) then
                    for _, point in ipairs(Geometry.ProjectPolygon(movement, poly, 0, nil, frame)) do
                        includeScreenPoint(probe, point)
                        includeScreenPoint(bounds, point)
                    end
                end
            end
        end
        collect(outerPolys)
        collect(landPolys)
        vectorBounds = probe
    end
    -- 变体岛贴图=竖幅公告板（覆盖模式，以矢量轮廓投影包围盒为尺寸标准）。
    -- 2026-10-19 真机二轮反馈（新接入岛屿全数命中）：上一版无论立牌成败都先填矢量
    -- 岸块，贴图内容主体的透明留边压不住下层色块，真机呈现「岛心一小团贴图 + 四周
    -- 大块土黄(SAND_SHORE)/橄榄(SAGE_LAND)矩形」。现改为：矢量岸块延后到本段之后
    -- 填色——覆盖立牌成功即抑制（贴图自身即完整岛体），失败才回落矢量轮廓。
    local variantBillboard = false
    if variant then
        -- 尺寸标准=矢量岸块（shore+land 外扩）的屏幕包围盒，外扩 4% 掩边。
        local cover
        if vectorBounds.minX ~= math.huge and vectorBounds.minY ~= math.huge then
            local pad = math.max(2, (vectorBounds.maxY - vectorBounds.minY) * VARIANT_BILLBOARD_COVER_PAD)
            cover = {
                minX = vectorBounds.minX - pad, maxX = vectorBounds.maxX + pad,
                minY = vectorBounds.minY - pad, maxY = vectorBounds.maxY + pad,
            }
        end
        if cover and type(ImageArt.UprightCover) == "function" then
            variantBillboard = ImageArt.UprightCover(ctx, entity.contentId, cover, 1)
        end
        if not variantBillboard then
            variantBillboard = ImageArt.Upright(ctx, entity.contentId, movement, center,
                clamp(radius * VARIANT_BILLBOARD_RATIO, VARIANT_BILLBOARD_MIN, VARIANT_BILLBOARD_MAX), 1)
        end
    end
    -- 2026-10-19（用户指令「矢量底图删除不叠加」，范围=变体岛六座新岛）：变体岛改为
    -- 纯贴图渲染——矢量轮廓只作覆盖立牌的**尺寸标准**（上方 vectorBounds），不参与
    -- 任何绘制：岸块（SAND_SHORE/SAGE_LAND）不填色不描边，丘/树/散石/石柱不绘制。
    -- 理由：贴图内容主体四周存在透明留边，压不住下层矢量色块，真机呈现「岛心一小团
    -- 贴图 + 四周大块土黄/橄榄矩形」（01:30 红框 box2/box3/box4，逐通道采样确认即
    -- 矢量岸块本身）。且 UprightCover 无亚像素剔除（仅 catalog 缺失/图片加载失败才返回
    -- false，与 Upright 的 UPRIGHT_MIN_PX 不同），真机已验证六岛贴图均可加载，故矢量
    -- 不保留绘制路径。
    -- 变体岛散石/石柱的矢量绘制函数（drawIslandRock/drawIslandPillar）同步下线；
    -- 布点数据仍留在 ISLAND_VARIANTS（若将来恢复矢量路径可直接复用）。
    -- 映射岛（island_01/02）与圆形岛**不在本次范围**：贴图缺失时仍走矢量岸块兜底。
    if not variant then
        if hasImage then
            for _, poly in ipairs(outerPolys) do
                for _, point in ipairs(Geometry.ProjectPolygon(movement, poly, 0, nil, frame)) do
                    includeScreenPoint(bounds, point)
                end
            end
        else
            for _, poly in ipairs(outerPolys) do
                local outerScreen = fillWorldPolygon(ctx, movement, poly, shoreColor, bounds, nil, frame)
                if #outerScreen >= 3 then
                    strokeWorldPolygon(ctx, movement, poly, rgba({160,139,105,190},nil,nil,airMix),1.25,bounds,0,frame)
                end
            end
            for _, poly in ipairs(landPolys) do
                local landScreen = fillWorldPolygon(ctx, movement, poly, landColor, bounds, nil, frame)
                if #landScreen >= 3 then
                    strokeWorldPolygon(ctx,movement,poly,rgba({107,131,101,170},nil,nil,airMix),1,bounds,0,frame)
                end
            end
        end
        drawHill(ctx, movement, center, radius, bounds, airMix,geometry.hills,frame,geometry.hillName)
        for _,tree in ipairs(geometry.trees) do
            drawTree(ctx,movement,tree.base,tree.height,bounds,tree.palette,airMix,tree.shape,frame,tree.name)
        end
    end
    -- C2（2026-10-17，用户仲裁批准）：island_01 固定岛饰（OceanComponents sign_* 七件）。
    -- 2026-10-18 真机验收改竖幅公告板投影（Upright）：原平铺在世界平面上，棕榈/阔叶
    -- （侧视图树）直接躺倒、预烘焙斜视资产被引擎斜投影二次压扁，视觉融入海面——
    -- 「岛的素材接入进海面了」。现底沿锚定岛上归一化位、立式显示（与树/丘同一
    -- 投影口径），内容主体世界高度=decor.size 透传；仅 island_01 装配，
    -- island_02 与其他岛零改动；加载失败静默跳过（岛体不依赖岛饰绘制成功）。
    -- 与 SeaDraw 的 scenery 体系（reef/coast/wreck，World:Init 注册）互补：不新增实体、
    -- 不碰 fixedContentEntities，资产作用域互不重叠（sign_* vs reef/coast/shipwreck）。
    if entity.contentId == "island_01" and radius >= 5 then
        for _, decor in ipairs(ISLAND_01_DECOR) do
            ImageArt.Upright(ctx, decor.name, movement,
                localIslandPoint(center, decor.x * radius, decor.y * radius), decor.size)
        end
    end
    PerfProbe.Sample("islandVector", probeVectorStop())
    PerfProbe.Sample("islandTotal", probeTotalStop())
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
    fillPolygon(ctx, shadow, nvgRGBA(49, 99, 101, 65))
    -- 2026-10-16 用户裁决：船贴图替换效果不好（竖幅画布被压进横幅世界矩形约 4×
    -- 压扁、艏向偏 90°），还原无贴图矢量形态（艇身+甲板+立帆）。
    -- boat/boat_story 目录项、ArtVariants 映射与素材文件已同步移除，无贴图加载路径。
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
                local forwardX, forwardY = math.cos(rotation) * halfWidth, math.sin(rotation) * halfWidth
                local sideX, sideY = -math.sin(rotation) * halfWidth, math.cos(rotation) * halfWidth
                local alpha = opacity * fade ^ 1.35
                local strokeWidth = clamp(center.scale * 0.08, 0.7, 2.8)
                local function wakeLine(fromAlong, fromSide, toAlong, toSide, tint, width)
                    Geometry.StrokeWorldLine(ctx,movement,
                        addPoint(position.x + forwardX * fromAlong + sideX * fromSide,
                            position.y + forwardY * fromAlong + sideY * fromSide),
                        addPoint(position.x + forwardX * toAlong + sideX * toSide,
                            position.y + forwardY * toAlong + sideY * toSide),
                        tint,width,0)
                end
                -- Two short, uneven water smudges along the recorded heading,
                -- not a wide transverse ladder rung. Keep the same two clipped
                -- world strokes per record and the existing lifetime/spread.
                wakeLine(-.58,-.34,.28,-.16,
                    nvgRGBA(223,239,222,math.floor(alpha*.43)),strokeWidth*1.2)
                wakeLine(-.18,.21,.48,.29,
                    nvgRGBA(246,244,222,math.floor(alpha*.72)),strokeWidth*.86)
            end
        end
    end
end

return SeaViewArt
