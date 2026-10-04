-- Distance-based appearance only. World registration and visibility stay authoritative.
local Config = require("Ocean.Config")
local Projection = require("Ocean.Projection")
local Presentation = {}

local function smooth(value)
    local t = math.max(0, math.min(1, value))
    return t * t * (3 - 2 * t)
end

local function opacityLoss(air)
    if air.enabled == false then return 0 end
    return math.max(0, math.min(0.8, air.maxOpacityLoss or 0))
end

function Presentation.State(movement, point, radius, height, options)
    local x, y, scale = movement:WorldToScreen(point)
    if not x then return end
    local depth = point.y - movement.camera.y
    local air = Config.visual.aerialPerspective
    -- Broad phase uses a complete height/footprint bound. Each drawing path
    -- then clips its actual geometry, including parts whose center is hidden.
    if depth - math.max(0, radius or 0) > Projection.VisibleDepth(movement, height or 0) then return end
    -- Test the two lateral frustum planes against the whole circular footprint,
    -- retaining edge crossings while rejecting fully offscreen callbacks.
    local polygon = Projection.ViewPolygon(movement)
    for _, index in ipairs({2,4}) do
        local a, b = polygon[index], polygon[index % 4 + 1]
        local dx, dy = b.x-a.x, b.y-a.y
        local distance = -dy*(point.x-a.x)+dx*(point.y-a.y)
        if distance < -(radius or 0)*math.sqrt(dx*dx+dy*dy) then return end
    end
    local haze = air.enabled and smooth((depth - air.startDepthMeters)
        / math.max(1, air.endDepthMeters - air.startDepthMeters)) or 0
    local airMix = opacityLoss(air) * haze
    local state = {
        progress = 1,
        airMix = airMix,
        horizonFade = 1,
        alpha = 1 - airMix,
        risePixels = 0,
    }

    return state
end

function Presentation.Draw(ctx, movement, point, radius, height, draw, options)
    local state = Presentation.State(movement, point, radius, height, options)
    if not state or state.alpha <= 0 then return false end
    nvgSave(ctx)
    nvgGlobalAlpha(ctx, state.alpha)
    draw(state)
    nvgRestore(ctx)
    return true
end

return Presentation
