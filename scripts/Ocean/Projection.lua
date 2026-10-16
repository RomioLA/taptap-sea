-- Fixed oblique water-plane projection. World distances remain meters.
-- +Y travels toward the horizon. The camera is a world reference at the ship anchor.
local Config = require("Ocean.Config")
local Projection = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function parameters(view)
    if type(view) ~= "table" or type(view.camera) ~= "table" then return end
    local width, height = view.viewportWidth, view.viewportHeight
    if not finite(width) or not finite(height) or width <= 0 or height <= 0 then return end
    local camera = Config.camera
    local distance = camera.viewHeight * (camera.anchorY - camera.horizonY) / camera.depthCompression
    return width, height, height / camera.viewHeight, distance,
        height * camera.horizonY, height * (camera.anchorY - camera.horizonY)
end

local function curvatureRatio()
    local visual = Config.visual
    local curvature = type(visual) == "table" and visual.curvature or nil
    local ratio = type(curvature) == "table" and curvature.heightRatio or nil
    -- Keep the projection usable while loading older project configs. The current
    -- project config declares this same presentation value explicitly.
    if not finite(ratio) then ratio = 0.018 end
    return math.max(0, ratio)
end

-- The small safety cap keeps the q-to-screen-y curve strictly increasing, so
-- each visible ground pixel still has one analytic inverse.
local function curvature(width, height, anchorHeight, screenX)
    if not finite(screenX) then return 0, 0 end
    local halfWidth = width * 0.5
    if halfWidth <= 0 then return 0, 0 end
    local rawU = (screenX - halfWidth) / halfWidth
    local u = math.max(-1, math.min(1, rawU))
    local maxRatio = math.max(0, anchorHeight / height * 0.499)
    local ratio = math.min(curvatureRatio(), maxRatio)
    local magnitude = height * ratio
    local value = magnitude * u * u
    local slope = 0
    if rawU > -1 and rawU < 1 then
        slope = magnitude * 2 * u / halfWidth
    end
    return value, slope
end

function Projection.Horizon(view, screenX)
    local width, height, _, _, baseline, anchorHeight = parameters(view)
    if not width then return end
    if not finite(screenX) then return baseline end
    local rise = curvature(width, height, anchorHeight, screenX)
    return baseline + rise
end

function Projection.Project(view, position, altitude)
    if type(position) ~= "table" or not finite(position.x) or not finite(position.y) then return end
    local width, height, base, distance, horizon, anchorHeight = parameters(view)
    if not width or not finite(view.camera.x) or not finite(view.camera.y) then return end
    local depth = position.y - view.camera.y
    local denominator = distance + depth
    if denominator <= Config.world.epsilon or depth > Config.camera.farDepth + Config.world.epsilon then return end
    local q = distance / denominator
    local scale = base * q
    local x = width * Config.camera.anchorX + (position.x - view.camera.x) * scale
    local bend = 0
    if q < 1 then
        local amount = curvature(width, height, anchorHeight, x)
        local remaining = math.max(0, 1 - q)
        bend = amount * remaining * remaining
    end
    local y = horizon + anchorHeight * q + bend
        - (finite(altitude) and altitude or 0) * scale
    if not finite(x) or not finite(y) or not finite(scale) then return end
    return x, y, scale
end

---@return OceanPoint?
function Projection.Unproject(view, x, y)
    if not finite(x) or not finite(y) then return end
    local width, height, base, distance, horizon, anchorHeight = parameters(view)
    if not width or not finite(view.camera.x) or not finite(view.camera.y)
        or x < 0 or x > width or y <= Projection.Horizon(view, x) or y > height then return end

    local anchorY = horizon + anchorHeight
    ---@type number?
    local q
    if y <= anchorY then
        local bend = curvature(width, height, anchorHeight, x)
        local linear = anchorHeight - 2 * bend
        local offset = y - horizon - bend
        if bend <= 1e-12 * math.max(1, anchorHeight) then
            q = offset / linear
        else
            local discriminant = linear * linear + 4 * bend * offset
            if discriminant < 0 or not finite(discriminant) then return end
            local root = math.sqrt(discriminant)
            -- Rationalized positive root avoids cancellation near the horizon.
            q = 2 * offset / (linear + root)
        end
    else
        -- The near-water branch has q >= 1 and no curvature.
        q = (y - horizon) / anchorHeight
    end
    if not finite(q) or q <= Config.world.epsilon then return end

    local depth = distance * (1 / q - 1)
    if not finite(depth) or depth > Config.camera.farDepth + Config.world.epsilon then return end
    local worldX = view.camera.x + (x - width * Config.camera.anchorX) / (base * q)
    local worldY = view.camera.y + depth
    if not finite(worldX) or not finite(worldY) then return end
    return { x = worldX, y = worldY }
end

-- Differential for small existing vector silhouettes. This includes lateral
-- perspective shear and both derivatives of the curved far-water projection.
function Projection.Vector(view, position, dx, dy)
    if not finite(dx) or not finite(dy) then return end
    local x, _, scale = Projection.Project(view, position)
    if not x then return end
    local width, height, _, distance, _, anchorHeight = parameters(view)
    local depth = position.y - view.camera.y
    local q = distance / (distance + depth)
    local dQ = -q * q / distance * dy
    local dScreenX = scale * dx
        - (x - width * Config.camera.anchorX) * q / distance * dy
    local dScreenY = anchorHeight * dQ

    if q < 1 then
        local bend, bendSlope = curvature(width, height, anchorHeight, x)
        local remaining = 1 - q
        local bendFactor = remaining * remaining
        dScreenY = dScreenY
            + bendSlope * bendFactor * dScreenX
            - 2 * bend * remaining * dQ
    end
    if not finite(dScreenX) or not finite(dScreenY) then return end
    return dScreenX, dScreenY
end

-- A finite trapezoid, extended only for visible art margins. Its near edge has
-- q >= 1, where the projection is unchanged; the far edge stays at farDepth.
-- Curvature changes projected far y values, not this world-plane visibility cap.
function Projection.ViewPolygon(view, paddingMeters)
    local width, height, base, distance, horizon, anchorHeight = parameters(view)
    if not width then return {} end
    local padding = finite(paddingMeters) and math.max(0, paddingMeters) or 0
    local nearQ = (height + padding * base - horizon) / anchorHeight
    local nearDepth = distance * (1 / nearQ - 1)
    local farDepth = Config.camera.farDepth
    local farQ = distance / (distance + farDepth)
    local function point(screenX, depth, q)
        return { x = view.camera.x + (screenX - width * Config.camera.anchorX) / (base * q),
            y = view.camera.y + depth }
    end
    return {
        point(-padding * base, nearDepth, nearQ),
        point(width + padding * base, nearDepth, nearQ),
        point(width + padding * base, farDepth, farQ),
        point(-padding * base, farDepth, farQ),
    }
end

function Projection.ViewBounds(view, paddingMeters)
    local polygon = Projection.ViewPolygon(view, paddingMeters)
    local bounds = { minX = math.huge, maxX = -math.huge, minY = math.huge, maxY = -math.huge }
    for _, point in ipairs(polygon) do
        bounds.minX, bounds.maxX = math.min(bounds.minX, point.x), math.max(bounds.maxX, point.x)
        bounds.minY, bounds.maxY = math.min(bounds.minY, point.y), math.max(bounds.maxY, point.y)
    end
    return bounds
end

return Projection
