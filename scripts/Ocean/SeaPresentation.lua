-- Distance-based appearance only. World registration and visibility stay authoritative.
local Config = require("Ocean.Config")
local Geometry = require("Ocean.ProjectedGeometry")
local Presentation = {}

local function smooth(value)
    local t = math.max(0, math.min(1, value))
    return t * t * (3 - 2 * t)
end

local function opacityLoss(air)
    if air.enabled == false then return 0 end
    return math.max(0, math.min(0.8, air.maxOpacityLoss or 0))
end

function Presentation.State(movement, point, radius, height)
    local x, y, scale = movement:WorldToScreen(point)
    if not x then return end
    local depth = point.y - movement.camera.y
    local emergence = Config.visual.emergence
    local air = Config.visual.aerialPerspective
    local progress = emergence.enabled and smooth((emergence.endDepthMeters - depth)
        / math.max(1, emergence.endDepthMeters - emergence.startDepthMeters)) or 1
    local haze = air.enabled and smooth((depth - air.startDepthMeters)
        / math.max(1, air.endDepthMeters - air.startDepthMeters)) or 0
    local airMix = opacityLoss(air) * haze
    local state = {
        progress = progress,
        airMix = airMix,
        alpha = progress * (1 - airMix),
        risePixels = 0,
    }

    if progress < 1 then
        local objectHeight = math.max(0, height or 0)
        local top, bottom = y - objectHeight * scale, y
        for _, sample in ipairs(Geometry.SampleCircle(point, math.max(0, radius or 0), 16)) do
            local _, low = movement:WorldToScreen(sample)
            local _, high = movement:WorldToScreen(sample, objectHeight)
            if low then bottom = math.max(bottom, low + 3) end
            if high then top = math.min(top, high - 3) end
        end

        local screenHeight = math.max(0, bottom - top)
        state.top = top
        state.bottom = bottom
        state.screenHeight = screenHeight
        state.risePixels = screenHeight * (1 - progress)
        -- Keep the fade clip on screen and inside the sea area. The object art
        -- itself rises from below this fixed clip as progress increases.
        state.clipTop = math.max(0, movement:GetHorizonY(), top)
        state.clipBottom = math.min(movement.viewportHeight, bottom)
    end
    return state
end

function Presentation.Draw(ctx, movement, point, radius, height, draw)
    local state = Presentation.State(movement, point, radius, height)
    if not state or state.alpha <= 0 then return false end
    nvgSave(ctx)
    nvgGlobalAlpha(ctx, state.alpha)
    if state.progress < 1 then
        nvgIntersectScissor(ctx, 0, state.clipTop, movement.viewportWidth,
            math.max(0, state.clipBottom - state.clipTop))
        nvgTranslate(ctx, 0, state.risePixels)
    end
    draw(state)
    nvgRestore(ctx)
    return true
end

return Presentation
