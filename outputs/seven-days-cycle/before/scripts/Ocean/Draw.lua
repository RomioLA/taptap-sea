-- 矢量场景绘制模块：只负责画面，不修改游戏状态，也不依赖外部图片。
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local Draw = {}

---@param ctx NVGContextWrapper
local function Fill(ctx, color)
    nvgFillColor(ctx, nvgRGBA(color[1], color[2], color[3], color[4] or 255))
    nvgFill(ctx)
end

---@param ctx NVGContextWrapper
local function Ellipse(ctx, x, y, rx, ry, color)
    nvgBeginPath(ctx)
    nvgEllipse(ctx, x, y, rx, ry)
    Fill(ctx, color)
end

---@param ctx NVGContextWrapper
local function Rect(ctx, x, y, w, h, radius, color)
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, x, y, w, h, radius)
    Fill(ctx, color)
end

---@param ctx NVGContextWrapper
local function Stroke(ctx, color, width)
    nvgStrokeColor(ctx, nvgRGBA(color[1], color[2], color[3], color[4] or 255))
    nvgStrokeWidth(ctx, width)
    nvgStroke(ctx)
end

---@param ctx NVGContextWrapper
local function Cloud(ctx, x, y, scale)
    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    nvgScale(ctx, scale, scale)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -57, 8)
    nvgBezierTo(ctx, -67, -4, -43, -20, -27, -13)
    nvgBezierTo(ctx, -20, -41, 18, -44, 28, -18)
    nvgBezierTo(ctx, 52, -27, 74, -1, 56, 8)
    nvgClosePath(ctx)
    Fill(ctx, { 249, 252, 235, 110 })
    nvgRestore(ctx)
end

---@param ctx NVGContextWrapper
local function Background(ctx, w, h, time)
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, w, h)
    nvgFillPaint(ctx, nvgLinearGradient(ctx, 0, 0, 0, h,
        nvgRGBA(216, 239, 229, 255), nvgRGBA(46, 138, 150, 255)))
    nvgFill(ctx)

    local sunX, sunY = w * 0.76, h * 0.13
    local sunRadius = math.min(w * 0.055, h * 0.065)
    Ellipse(ctx, sunX, sunY, sunRadius * 1.7, sunRadius * 1.7, { 255, 241, 177, 30 })
    Ellipse(ctx, sunX, sunY, sunRadius * 1.28, sunRadius * 1.28, { 255, 241, 177, 55 })
    Ellipse(ctx, sunX, sunY, sunRadius, sunRadius, { 255, 237, 177, 255 })

    local cloudScale = math.min(w / 560, h / 680)
    Cloud(ctx, w * 0.2 + math.sin(time * 0.12) * 8, h * 0.15, cloudScale)
    Cloud(ctx, w * 0.86 + math.sin(time * 0.1 + 2) * 6, h * 0.25, cloudScale * 0.67)

    -- 远景的浅色海岸剪影，衬托中央五层场景。
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, 0, h * 0.32)
    nvgBezierTo(ctx, w * 0.07, h * 0.32, w * 0.12, h * 0.27, w * 0.17, h * 0.32)
    nvgBezierTo(ctx, w * 0.23, h * 0.29, w * 0.25, h * 0.33, w * 0.3, h * 0.33)
    nvgLineTo(ctx, 0, h * 0.36)
    nvgClosePath(ctx)
    Fill(ctx, { 105, 170, 156, 70 })
end

---@param ctx NVGContextWrapper
local function WaveBand(ctx, w, h, y, amplitude, phase, topColor, bottomColor)
    nvgBeginPath(ctx)
    for i = 1, 81 do
        local x = (i - 1) / 80 * w
        local waveY = y + math.sin(x / w * math.pi * 6 + phase) * amplitude
            + math.sin(x / w * math.pi * 11 - phase * 0.4) * amplitude * 0.35
        if i == 1 then nvgMoveTo(ctx, x, waveY) else nvgLineTo(ctx, x, waveY) end
    end
    nvgLineTo(ctx, w, h)
    nvgLineTo(ctx, 0, h)
    nvgClosePath(ctx)
    nvgFillPaint(ctx, nvgLinearGradient(ctx, 0, y, 0, h,
        nvgRGBA(topColor[1], topColor[2], topColor[3], 255),
        nvgRGBA(bottomColor[1], bottomColor[2], bottomColor[3], 255)))
    nvgFill(ctx)
end

---@param ctx NVGContextWrapper
local function Sea(ctx, w, h, time)
    local y = h * Config.layers.waves
    WaveBand(ctx, w, h, y, h * 0.007, time * 0.6,
        { 156, 222, 207 }, { 42, 134, 149 })
    WaveBand(ctx, w, h, y + h * 0.023, h * 0.009, time * 0.75 + 1,
        { 90, 189, 188 }, { 33, 121, 142 })
    WaveBand(ctx, w, h, y + h * 0.055, h * 0.006, time * 0.5 + 2,
        { 70, 164, 177 }, { 26, 106, 132 })

    -- 水中光束保持低对比度，不遮挡鱼群和船只。
    for i = 1, 4 do
        local x = w * (0.22 + i * 0.12)
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, x, y + h * 0.04)
        nvgLineTo(ctx, x + w * 0.03, y + h * 0.04)
        nvgLineTo(ctx, x - w * 0.06, h * 0.9)
        nvgLineTo(ctx, x - w * 0.16, h * 0.9)
        nvgClosePath(ctx)
        Fill(ctx, { 194, 238, 216, 12 })
    end

    for i = 1, 37 do
        local x = ((i * 0.173 + time * 0.004) % 1) * w
        local lineY = h * (0.39 + ((i * 0.137) % 0.52))
        local length = 10 + (i % 4) * 5
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, x, lineY)
        nvgQuadTo(ctx, x + length * 0.5, lineY + 2, x + length, lineY)
        Stroke(ctx, { 204, 241, 225, 35 }, 1.2)
    end
end

---@param ctx NVGContextWrapper
local function Bird(ctx, x, y, scale, time, phase)
    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    nvgScale(ctx, scale, scale)
    local flap = math.sin(time * 3 + phase) * 11
    -- 飞鸟身体与上下扑动的双翼。
    Ellipse(ctx, 1, 1, 16, 6, { 248, 248, 225, 255 })
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -4, 0)
    nvgBezierTo(ctx, -16, -19 - flap, -38, -23 - flap, -51, -8 - flap * 0.4)
    nvgBezierTo(ctx, -31, -11 - flap, -24, 10, 1, 4)
    nvgMoveTo(ctx, 2, 0)
    nvgBezierTo(ctx, 15, -25 + flap, 38, -23 + flap, 51, -11 + flap * 0.4)
    nvgBezierTo(ctx, 29, -13 + flap, 26, 6, 4, 4)
    Fill(ctx, { 255, 254, 239, 255 })
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -7, 4)
    nvgLineTo(ctx, -26, 13)
    nvgLineTo(ctx, -20, 1)
    nvgClosePath(ctx)
    Fill(ctx, { 235, 241, 223, 255 })
    Ellipse(ctx, 16, -1, 7, 6, { 255, 254, 239, 255 })
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, 21, -2)
    nvgLineTo(ctx, 31, 1)
    nvgLineTo(ctx, 21, 3)
    nvgClosePath(ctx)
    Fill(ctx, { 220, 148, 74, 255 })
    Ellipse(ctx, 18, -2, 1.4, 1.4, { 36, 81, 81, 255 })
    nvgRestore(ctx)
end

---@param ctx NVGContextWrapper
local function Fish(ctx, x, y, scale, direction, color, time, phase)
    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    nvgScale(ctx, scale * direction, scale)
    local sway = math.sin(time * 4 + phase) * 3
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -21, 0)
    nvgLineTo(ctx, -40, -13 + sway)
    nvgQuadTo(ctx, -35, 0, -40, 13 + sway)
    nvgClosePath(ctx)
    Fill(ctx, color)
    Ellipse(ctx, 0, 0, 27, 14, color)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -5, -10)
    nvgLineTo(ctx, 3, -21)
    nvgLineTo(ctx, 11, -10)
    nvgClosePath(ctx)
    Fill(ctx, color)
    Ellipse(ctx, 3, 4, 9, 4, { 255, 249, 221, 105 })
    Ellipse(ctx, 15, -3, 4, 4, { 255, 252, 237, 255 })
    Ellipse(ctx, 16, -3, 1.8, 1.8, { 30, 74, 85, 255 })
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, 7, -6)
    nvgQuadTo(ctx, 3, 0, 7, 6)
    Stroke(ctx, { 50, 106, 113, 90 }, 1.2)
    nvgRestore(ctx)
end

---@param ctx NVGContextWrapper
local function Ripple(ctx, x, y, rx, ry, alpha)
    nvgBeginPath(ctx)
    nvgEllipse(ctx, x, y, rx, ry)
    Stroke(ctx, { 199, 240, 222, alpha }, 1.5)
end

---@param ctx NVGContextWrapper
local function Boat(ctx, x, y, scale, time)
    Ripple(ctx, x, y + 28 * scale, 112 * scale, 13 * scale, 80)
    Ripple(ctx, x, y + 28 * scale, 135 * scale, 21 * scale, 35)
    nvgSave(ctx)
    nvgTranslate(ctx, x, y + math.sin(time * 1.7) * 3 * scale)
    nvgRotate(ctx, math.sin(time * 1.1) * 0.018)
    nvgScale(ctx, scale, scale)
    Ellipse(ctx, 0, 30, 92, 11, { 11, 79, 99, 85 })

    -- 白色船舱、暖色烟囱和深蓝船体。
    Rect(ctx, -47, -28, 83, 34, 5, { 251, 244, 219, 255 })
    Rect(ctx, -28, -48, 58, 24, 4, { 255, 251, 230, 255 })
    Rect(ctx, -18, -54, 58, 7, 3, { 46, 88, 98, 255 })
    Rect(ctx, 43, -41, 18, 42, 2, { 223, 141, 104, 255 })
    Rect(ctx, 41, -45, 22, 7, 2, { 51, 86, 91, 255 })
    for i = 1, 4 do
        Rect(ctx, -38 + (i - 1) * 17, -18, 11, 12, 2, { 68, 133, 147, 255 })
    end
    Rect(ctx, -17, -40, 17, 10, 2, { 68, 133, 147, 255 })
    Rect(ctx, 8, -40, 13, 10, 2, { 68, 133, 147, 255 })
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -100, 0)
    nvgLineTo(ctx, 100, 0)
    nvgQuadTo(ctx, 84, 39, 58, 40)
    nvgLineTo(ctx, -64, 40)
    nvgQuadTo(ctx, -85, 32, -100, 0)
    nvgClosePath(ctx)
    Fill(ctx, { 39, 78, 92, 255 })
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -94, 9)
    nvgLineTo(ctx, 94, 9)
    Stroke(ctx, { 226, 151, 105, 255 }, 5)
    for i = 1, 3 do
        Ellipse(ctx, -34 + (i - 1) * 29, 24, 4, 4, { 255, 229, 178, 255 })
    end
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -64, -2)
    nvgLineTo(ctx, -64, -62)
    Stroke(ctx, { 50, 88, 96, 255 }, 2.5)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -63, -60)
    nvgLineTo(ctx, -39, -53)
    nvgLineTo(ctx, -63, -45)
    nvgClosePath(ctx)
    Fill(ctx, { 222, 149, 103, 255 })
    for i = 1, 3 do
        local drift = (time * 0.34 + i * 0.31) % 1
        Ellipse(ctx, 53 + drift * 29, -58 - drift * 35,
            5 + drift * 8, 4 + drift * 5, { 225, 241, 221, math.floor((1 - drift) * 70) })
    end
    nvgRestore(ctx)
end

---@param ctx NVGContextWrapper
local function Palm(ctx, x, y, scale, lean)
    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    nvgScale(ctx, scale, scale)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -7, 0)
    nvgBezierTo(ctx, -2, -35, lean - 10, -62, lean - 2, -96)
    nvgLineTo(ctx, lean + 7, -96)
    nvgBezierTo(ctx, lean + 1, -57, 7, -30, 7, 0)
    nvgClosePath(ctx)
    Fill(ctx, { 175, 126, 83, 255 })
    for i = 1, 4 do
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, -1 + lean * i / 6, -i * 19)
        nvgLineTo(ctx, 6 + lean * i / 6, -i * 19 - 2)
        Stroke(ctx, { 119, 99, 68, 130 }, 2)
    end
    local crownX, crownY = lean + 3, -96
    for i = 1, 6 do
        local angle = -math.pi + (i - 1) * math.pi / 5
        local endX = crownX + math.cos(angle) * 55
        local endY = crownY + math.sin(angle) * 32 + 20
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, crownX, crownY)
        nvgQuadTo(ctx, (crownX + endX) * 0.5, crownY - 26, endX, endY)
        nvgQuadTo(ctx, (crownX + endX) * 0.5, crownY + 7, crownX, crownY)
        nvgClosePath(ctx)
        Fill(ctx, i % 2 == 0 and { 52, 128, 103, 255 } or { 76, 155, 114, 255 })
    end
    Ellipse(ctx, crownX - 3, crownY + 6, 5, 5, { 123, 93, 61, 255 })
    Ellipse(ctx, crownX + 5, crownY + 8, 5, 5, { 141, 103, 65, 255 })
    nvgRestore(ctx)
end

---@param ctx NVGContextWrapper
local function Island(ctx, x, y, scale, time)
    Ripple(ctx, x, y + 16 * scale, 158 * scale, 43 * scale, 90)
    Ripple(ctx, x, y + 16 * scale, (176 + math.sin(time) * 4) * scale, 53 * scale, 35)
    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    nvgScale(ctx, scale, scale)
    Ellipse(ctx, 0, 16, 149, 40, { 69, 171, 162, 255 })
    Ellipse(ctx, 0, 8, 129, 36, { 205, 169, 113, 255 })
    Ellipse(ctx, 0, 0, 130, 33, { 244, 220, 169, 255 })
    Ellipse(ctx, -13, -6, 94, 22, { 255, 234, 185, 255 })
    Ellipse(ctx, -5, -13, 54, 16, { 129, 167, 104, 255 })
    Palm(ctx, -32, -8, 1, -10 + math.sin(time * 0.8) * 1.8)
    Palm(ctx, 37, -10, 0.7, 15 + math.sin(time * 0.8 + 1) * 2)
    Ellipse(ctx, 68, 4, 13, 7, { 185, 178, 147, 255 })
    Ellipse(ctx, 77, 7, 8, 5, { 208, 196, 158, 255 })
    for i = 1, 8 do
        Ellipse(ctx, -92 + (i - 1) * 24, 17 + math.sin(i * 3) * 5, 1.8, 1.2,
            { 185, 149, 99, 120 })
    end
    nvgRestore(ctx)
end

--- Draw the existing side-view fishing boat at a projected world position.
---@param ctx NVGContextWrapper
---@param x number
---@param y number
---@param pixelsPerUnit number
---@param ship table
---@param time number
function Draw.WorldBoat(ctx, x, y, pixelsPerUnit, ship, time)
    if not ctx or not ship then return end

    local visual = Config.visual
    local scaleX = (visual.shipLength or 5) * pixelsPerUnit / 200
    -- The legacy hull, cabin, and flag span about 102 art units vertically.
    local scaleY = (visual.shipWidth or 2.4) * pixelsPerUnit / 102
    local direction = ship.direction
    local facingX = type(direction) == "table" and direction.x or nil
    if type(facingX) ~= "number" or math.abs(facingX) < 0.000001 then
        facingX = math.cos(ship.rotation or 0)
    end
    local horizontalFacing = facingX < 0 and -1 or 1

    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    -- Keep the side-view upright; only mirror it when the ship faces left.
    nvgScale(ctx, scaleX * horizontalFacing, scaleY)
    Boat(ctx, 0, 0, 1, time or 0)
    nvgRestore(ctx)
end

--- Draw the existing fish silhouette at its real projected heading and render length.
---@param ctx NVGContextWrapper
---@param x number
---@param y number
---@param pixelsPerUnit number
---@param entity table
---@param time number
function Draw.WorldFish(ctx, x, y, pixelsPerUnit, entity, time)
    if not ctx or not entity then return end
    local fishConfig = FishData[entity.species]
    if not fishConfig then return end

    -- The legacy shape spans 67 art units from its tail to its nose.
    local scale = (fishConfig.renderLength or fishConfig.radius or 1) * pixelsPerUnit / 67
    local heading = entity.rotation or 0
    local direction = entity.direction
    if type(direction) == "table"
        and type(direction.x) == "number"
        and type(direction.y) == "number"
        and (math.abs(direction.x) + math.abs(direction.y)) > 0.000001 then
        heading = math.atan(direction.y, direction.x)
    end

    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    -- Screen Y is inverted relative to world Y; this rotates the fish along its world heading.
    nvgRotate(ctx, -heading)
    Fish(ctx, 0, 0, scale, 1, fishConfig.color, time or 0, entity.phase or 0)
    nvgRestore(ctx)
end

--- Draw the legacy palm-island art around the unchanged circular world radius.
---@param ctx NVGContextWrapper
---@param x number
---@param y number
---@param pixelsPerUnit number
---@param entity table
---@param time number
function Draw.WorldIsland(ctx, x, y, pixelsPerUnit, entity, time)
    if not ctx or not entity then return end
    local radius = (entity.radius or 1) * pixelsPerUnit
    if radius <= 0 then return end

    -- Match the old shoreline width to the world's circular island radius.
    Island(ctx, x, y, radius / 149, time or 0)
end

local function clamp01(value)
    return math.max(0, math.min(1, value))
end

--- Draw a rising fish as a dark, depth-sensitive silhouette and surface ring.
---@param ctx NVGContextWrapper
---@param x number Screen-space center in logical pixels.
---@param y number Screen-space center in logical pixels.
---@param pixelsPerUnit number Screen pixels per meter.
---@param entity table Fish entity with species, direction/rotation, and surfaceDepth.
---@param time number Animation time; this function does not advance it.
function Draw.WorldRise(ctx, x, y, pixelsPerUnit, entity, time)
    if not ctx or not entity or type(pixelsPerUnit) ~= "number" or pixelsPerUnit <= 0 then return end
    local fishConfig = FishData[entity.species]
    if not fishConfig then return end
    local surfaceDepth = tonumber(entity.surfaceDepth)
    if not surfaceDepth then return end

    local depth = clamp01(surfaceDepth)
    local scale = (fishConfig.renderLength or fishConfig.radius or 1) * pixelsPerUnit / 67
        * (1 + 0.2 * depth)
    local heading = entity.rotation or 0
    local direction = entity.direction
    if type(direction) == "table"
        and type(direction.x) == "number"
        and type(direction.y) == "number"
        and (math.abs(direction.x) + math.abs(direction.y)) > 0.000001 then
        heading = math.atan(direction.y, direction.x)
    end

    -- Keep the local fish silhouette proportions, but omit its eye and belly marks.
    local alpha = math.floor(255 * depth)
    local sway = math.sin((time or 0) * 4 + (entity.phase or 0)) * 3
    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    -- Screen Y is inverted relative to world Y, matching WorldFish's heading convention.
    nvgRotate(ctx, -heading)
    nvgScale(ctx, scale, scale)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -21, 0)
    nvgLineTo(ctx, -40, -13 + sway)
    nvgQuadTo(ctx, -35, 0, -40, 13 + sway)
    nvgClosePath(ctx)
    Fill(ctx, { 14, 34, 52, alpha })
    Ellipse(ctx, 0, 0, 27, 14, { 14, 34, 52, alpha })
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -5, -10)
    nvgLineTo(ctx, 3, -21)
    nvgLineTo(ctx, 11, -10)
    nvgClosePath(ctx)
    Fill(ctx, { 14, 34, 52, alpha })
    nvgRestore(ctx)

    local ringAlpha = math.floor(150 * depth)
    nvgBeginPath(ctx)
    nvgEllipse(ctx, x, y, 1.5 * pixelsPerUnit, 1.0 * pixelsPerUnit)
    Stroke(ctx, { 235, 250, 248, ringAlpha }, 1.6)
end

--- Draw a short-lived expanding splash and a short wake behind its heading.
---@param ctx NVGContextWrapper
---@param x number Screen-space center in logical pixels.
---@param y number Screen-space center in logical pixels.
---@param pixelsPerUnit number Screen pixels per meter.
---@param remaining number Remaining lifetime in seconds.
---@param lifetime number Total lifetime in seconds.
---@param heading number Radians in world space, with forward along positive X.
---@param trailLength number? Requested wake length in meters; capped at 2m.
function Draw.WorldSplash(ctx, x, y, pixelsPerUnit, remaining, lifetime, heading, trailLength)
    if not ctx or type(pixelsPerUnit) ~= "number" or pixelsPerUnit <= 0 then return end
    lifetime = tonumber(lifetime) or 0.6
    remaining = tonumber(remaining) or 0
    if lifetime <= 0 or remaining <= 0 then return end

    local lifeRatio = clamp01(remaining / lifetime)
    local age = 1 - lifeRatio
    local alpha = math.floor(lifeRatio * 230)
    local length = math.min(2, math.max(0, tonumber(trailLength) or 2)) * pixelsPerUnit
    if length > 0 and alpha > 0 then
        nvgSave(ctx)
        nvgTranslate(ctx, x, y)
        -- Screen Y is inverted relative to world Y, as in WorldFish.
        nvgRotate(ctx, -(tonumber(heading) or 0))
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, -length, 0)
        nvgQuadTo(ctx, -length * 0.55, -pixelsPerUnit * 0.08,
            -length * 0.15, pixelsPerUnit * 0.02)
        nvgLineTo(ctx, 0, 0)
        Stroke(ctx, { 240, 252, 250, math.floor(alpha * 0.72) },
            math.max(1.25, math.min(4, pixelsPerUnit * 0.08)))
        nvgRestore(ctx)
    end

    nvgBeginPath(ctx)
    nvgEllipse(ctx, x, y, (0.5 + age * 3.2) * pixelsPerUnit,
        (0.3 + age * 2.0) * pixelsPerUnit)
    Stroke(ctx, { 240, 252, 250, alpha }, 2.5)
end

--- Draw a top-down seabird silhouette whose wings fold during its dive.
---@param ctx NVGContextWrapper
---@param x number Screen-space center in logical pixels.
---@param y number Screen-space center in logical pixels.
---@param pixelsPerUnit number Screen pixels per meter.
---@param heading number Radians in world space, with forward along positive X.
---@param diveProgress number? Dive progress from 0 (gliding) to 1 (folded dive).
function Draw.WorldSeabird(ctx, x, y, pixelsPerUnit, heading, diveProgress)
    if not ctx or type(pixelsPerUnit) ~= "number" or pixelsPerUnit <= 0 then return end

    local dive = clamp01(tonumber(diveProgress) or 0)
    local size = pixelsPerUnit * 0.9
    local wingSpan = 1 - 0.62 * dive
    local wingSweep = 0.18 * dive
    local tipX = (-0.55 - wingSweep) * size
    local tipY = 0.50 * wingSpan * size
    local innerX = -0.15 * size
    local innerY = 0.10 * wingSpan * size

    nvgSave(ctx)
    nvgTranslate(ctx, x, y)
    -- Screen Y is inverted relative to world Y, matching WorldFish.
    nvgRotate(ctx, -(tonumber(heading) or 0))
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, 0.10 * size, 0)
    nvgLineTo(ctx, tipX, -tipY)
    nvgLineTo(ctx, innerX, -innerY)
    nvgClosePath(ctx)
    nvgMoveTo(ctx, 0.10 * size, 0)
    nvgLineTo(ctx, tipX, tipY)
    nvgLineTo(ctx, innerX, innerY)
    nvgClosePath(ctx)
    nvgFillColor(ctx, nvgRGBA(250, 250, 240, 238))
    nvgFill(ctx)

    -- The body shortens slightly with the folded wings to make dive progress readable.
    nvgBeginPath(ctx)
    nvgEllipse(ctx, 0, 0, 0.48 * size, (0.15 - 0.025 * dive) * size)
    nvgFillColor(ctx, nvgRGBA(255, 255, 248, 245))
    nvgFill(ctx)
    nvgBeginPath(ctx)
    nvgEllipse(ctx, 0.43 * size, 0, 0.12 * size, 0.10 * size)
    nvgFillColor(ctx, nvgRGBA(255, 255, 248, 245))
    nvgFill(ctx)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, 0.52 * size, -0.045 * size)
    nvgLineTo(ctx, 0.72 * size, 0)
    nvgLineTo(ctx, 0.52 * size, 0.045 * size)
    nvgClosePath(ctx)
    nvgFillColor(ctx, nvgRGBA(235, 190, 130, 255))
    nvgFill(ctx)
    nvgRestore(ctx)
end

---@param ctx NVGContextWrapper
local function Arrow(ctx, x, y, scale, alpha)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, x, y - 7 * scale)
    nvgLineTo(ctx, x, y + 5 * scale)
    nvgMoveTo(ctx, x - 5 * scale, y)
    nvgLineTo(ctx, x, y + 5 * scale)
    nvgLineTo(ctx, x + 5 * scale, y)
    Stroke(ctx, { 246, 246, 215, alpha }, 1.5 * scale)
end

--- Draw the reusable sky, sun, birds, and layered sea backdrop.
---@param ctx NVGContextWrapper
---@param w number
---@param h number
---@param time number
function Draw.SceneBackdrop(ctx, w, h, time, skyOnly)
    if not ctx or w <= 0 or h <= 0 then return end
    time = time or 0
    local scale = math.min(w / 520, h / 800)
    Background(ctx, w, h, time)
    if not skyOnly then Sea(ctx, w, h, time) end
    for _, bird in ipairs(Config.birds) do
        local x = w * bird.x + math.sin(time * 0.4 + bird.phase) * 15 * scale
        local y = h * Config.layers.birds + math.sin(time * 1.2 + bird.phase) * 5 * scale
        Bird(ctx, x, y, scale * bird.scale, time, bird.phase)
    end
end

--- Remote STEP-5 night tint, drawn below the boat and the separate UI context.
--- The caller owns clipping/layer order and supplies the existing gameplay clock.
---@param ctx NVGContextWrapper
---@param w number
---@param h number
---@param clock table?
function Draw.NightOverlay(ctx, w, h, clock)
    if not ctx or w <= 0 or h <= 0 or not clock or clock.phase ~= "night" then return end
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, w, h)
    Fill(ctx, Config.visual.nightOverlay)
end

---@param ctx NVGContextWrapper
---@param state table
function Draw.Scene(ctx, w, h, state)
    local time = state.time
    local scale = math.min(w / 520, h / 800)
    Draw.SceneBackdrop(ctx, w, h, time)
    for _, fish in ipairs(Config.fish) do
        local x = w * fish.x + math.sin(time * 0.65 + fish.phase) * 23 * scale
        local y = h * Config.layers.fish + math.sin(time * 1.4 + fish.phase) * 6 * scale
        Fish(ctx, x, y, scale * 0.84, fish.direction, fish.color, time, fish.phase)
        for i = 1, 2 do
            local rise = (time * 0.17 + i * 0.39 + fish.phase * 0.1) % 1
            Ripple(ctx, x + 33 * scale, y - rise * 27 * scale, 2 * scale, 2 * scale,
                math.floor((1 - rise) * 85))
        end
    end
    Boat(ctx, w * state.boatX, h * Config.layers.boat, scale, time)
    Island(ctx, w * 0.5, h * Config.layers.island, scale, time)
    local arrowAlpha = math.floor(85 + math.sin(time * 1.5) * 20)
    Arrow(ctx, w * 0.5, h * 0.275, scale, arrowAlpha)
    Arrow(ctx, w * 0.5, h * 0.52, scale, arrowAlpha)
    Arrow(ctx, w * 0.5, h * 0.705, scale, arrowAlpha)
end

return Draw
