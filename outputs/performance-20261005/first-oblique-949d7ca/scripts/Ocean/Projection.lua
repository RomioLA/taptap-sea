-- Fixed oblique water-plane projection. World distances remain meters.
-- +Y travels toward the horizon. The camera is a world reference at the ship anchor.
local Config = require("Ocean.Config")
local Projection = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function parameters(view)
    local width, height = view.viewportWidth, view.viewportHeight
    if not finite(width) or not finite(height) or width <= 0 or height <= 0 then return end
    local camera = Config.camera
    local distance = camera.viewHeight * (camera.anchorY - camera.horizonY) / camera.depthCompression
    return width, height, height / camera.viewHeight, distance,
        height * camera.horizonY, height * (camera.anchorY - camera.horizonY)
end

function Projection.Horizon(view)
    return view.viewportHeight * Config.camera.horizonY
end

function Projection.Project(view, position, altitude)
    if type(position) ~= "table" or not finite(position.x) or not finite(position.y) then return end
    local width, _, base, distance, horizon, anchorHeight = parameters(view)
    if not width then return end
    local depth = position.y - view.camera.y
    local denominator = distance + depth
    if denominator <= Config.world.epsilon or depth > Config.camera.farDepth + Config.world.epsilon then return end
    local q = distance / denominator
    local scale = base * q
    local x = width * Config.camera.anchorX + (position.x - view.camera.x) * scale
    local y = horizon + anchorHeight * q - (finite(altitude) and altitude or 0) * scale
    if not finite(x) or not finite(y) or not finite(scale) then return end
    return x, y, scale
end

---@return OceanPoint?
function Projection.Unproject(view, x, y)
    if not finite(x) or not finite(y) then return end
    local width, height, base, distance, horizon, anchorHeight = parameters(view)
    if not width or x < 0 or x > width or y <= horizon or y > height then return end
    local q = (y - horizon) / anchorHeight
    local depth = distance * (1 / q - 1)
    if not finite(depth) or depth > Config.camera.farDepth + Config.world.epsilon then return end
    return { x = view.camera.x + (x - width * Config.camera.anchorX) / (base * q),
        y = view.camera.y + depth }
end

-- Differential for small existing vector silhouettes. This includes the lateral
-- perspective shear; rotation alone would give fish/birds a different heading.
function Projection.Vector(view, position, dx, dy)
    local x, _, scale = Projection.Project(view, position)
    if not x or not finite(dx) or not finite(dy) then return end
    local width, _, _, distance, _, anchorHeight = parameters(view)
    local q = distance / (distance + position.y - view.camera.y)
    return scale * dx - (x - width * Config.camera.anchorX) * q / distance * dy,
        -anchorHeight * q * q / distance * dy
end

-- A finite trapezoid, extended only for visible art margins. It is deliberately
-- separate from world activity/visibility and never initializes fish regions.
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
