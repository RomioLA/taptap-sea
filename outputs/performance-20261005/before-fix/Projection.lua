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

-- A short tangent interval joins the established near-water projection to a
-- curved surface. The continued surface sinks behind the tangent; it is never
-- clamped to the horizon. r is dimensionless and distances remain world meters.
local function surface(r)
    local span = Config.visual.horizonOcclusion.tangentSpan or 0.1
    if r >= span then return r, 1 end
    if r >= 0 then
        return r * r * (2 * span - r) / (span * span),
            r * (4 * span - 3 * r) / (span * span)
    end
    return r * r / span, 2 * r / span
end

local function inverseSurface(value)
    local span = Config.visual.horizonOcclusion.tangentSpan or 0.1
    if value >= span then return value end
    local low, high = 0, span
    for _ = 1, 48 do
        local middle = (low + high) * 0.5
        if surface(middle) < value then low = middle else high = middle end
    end
    return (low + high) * 0.5
end

function Projection.Project(view, position, altitude)
    if type(position) ~= "table" or not finite(position.x) or not finite(position.y) then return end
    local width, height, base, distance, horizon, anchorHeight = parameters(view)
    if not width or not finite(view.camera.x) or not finite(view.camera.y) then return end
    local depth = position.y - view.camera.y
    local denominator = distance + depth
    if denominator <= Config.world.epsilon then return end
    local q = distance / denominator
    local farQ = distance / (distance + Config.camera.farDepth)
    local horizonQ = surface((q - farQ) / (1 - farQ))
    local scale = base * q
    local x = width * Config.camera.anchorX + (position.x - view.camera.x) * scale
    local bend = 0
    if horizonQ < 1 then
        local amount = curvature(width, height, anchorHeight, x)
        local remaining = 1 - horizonQ
        bend = amount * remaining * remaining
    end
    local y = horizon + anchorHeight * horizonQ + bend
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
    local horizonQ
    if y <= anchorY then
        local bend = curvature(width, height, anchorHeight, x)
        local linear = anchorHeight - 2 * bend
        local offset = y - horizon - bend
        if bend <= 1e-12 * math.max(1, anchorHeight) then
            horizonQ = offset / linear
        else
            local discriminant = linear * linear + 4 * bend * offset
            if discriminant < 0 or not finite(discriminant) then return end
            local root = math.sqrt(discriminant)
            -- Rationalized positive root avoids cancellation near the horizon.
            horizonQ = 2 * offset / (linear + root)
        end
    else
        -- The near-water branch has q >= 1 and no curvature.
        horizonQ = (y - horizon) / anchorHeight
    end
    if not finite(horizonQ) or horizonQ < 0 then return end

    local farQ = distance / (distance + Config.camera.farDepth)
    local q = farQ + (1 - farQ) * inverseSurface(horizonQ)
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
function Projection.Vector(view, position, dx, dy, altitude)
    if not finite(dx) or not finite(dy) then return end
    local x, _, scale = Projection.Project(view, position)
    if not x then return end
    local width, height, _, distance, _, anchorHeight = parameters(view)
    local depth = position.y - view.camera.y
    local q = distance / (distance + depth)
    local farQ = distance / (distance + Config.camera.farDepth)
    local horizonQ, derivative = surface((q - farQ) / (1 - farQ))
    local dQ = derivative * (-q * q / distance * dy) / (1 - farQ)
    local dScreenX = scale * dx
        - (x - width * Config.camera.anchorX) * q / distance * dy
    local dScreenY = anchorHeight * dQ
        + (finite(altitude) and altitude or 0) * scale * q / distance * dy

    if horizonQ < 1 then
        local bend, bendSlope = curvature(width, height, anchorHeight, x)
        local remaining = 1 - horizonQ
        local bendFactor = remaining * remaining
        dScreenY = dScreenY
            + bendSlope * bendFactor * dScreenX
            - 2 * bend * remaining * dQ
    end
    if not finite(dScreenX) or not finite(dScreenY) then return end
    return dScreenX, dScreenY
end

-- Signed geometric visibility, independent of entity type, alpha and World
-- state. On the far side only heights above the intervening water are visible.
function Projection.OccludedAltitude(view, position)
    local x, groundY, scale = Projection.Project(view, position)
    if not x then return math.huge end
    if position.y <= view.camera.y + Config.camera.farDepth then return 0 end
    return math.max(0, (groundY - Projection.Horizon(view, x)) / scale)
end

function Projection.Visibility(view, position, altitude)
    local height = finite(altitude) and altitude or position.altitude or 0
    local depth = position.y - view.camera.y
    if depth <= Config.camera.farDepth then return height + Config.camera.farDepth - depth end
    return height - Projection.OccludedAltitude(view, position)
end

-- Conservative depth bound from actual height. Viewport factors cancel here.
-- Cache rounded-up height bounds to avoid a binary search for each art segment.
local depthCache, cacheKey, cacheCount = {}, "", 0
function Projection.VisibleDepth(view, altitude)
    if not finite(altitude) or altitude <= 0 then return Config.camera.farDepth end
    local width, height, _, distance = parameters(view)
    if not width then return Config.camera.farDepth end
    local camera = Config.camera
    local span = Config.visual.horizonOcclusion.tangentSpan or 0.1
    local key = table.concat({camera.farDepth,distance,camera.viewHeight,
        camera.anchorY-camera.horizonY,curvatureRatio(),span}, ":")
    if key ~= cacheKey then depthCache, cacheKey, cacheCount = {}, key, 0 end
    local bound = math.ceil(altitude * 20) / 20
    if depthCache[bound] then return depthCache[bound] end
    local farQ = distance / (distance + camera.farDepth)
    local anchor = camera.viewHeight * (camera.anchorY-camera.horizonY)
    local bend = camera.viewHeight * math.min(curvatureRatio(),
        (camera.anchorY-camera.horizonY)*0.499)
    local function hidden(depth)
        local q = distance / (distance + depth)
        local f = surface((q-farQ)/(1-farQ))
        local curvatureOffset = f < 1 and bend*(f*f-2*f) or -bend
        return math.max(0,(anchor*f+curvatureOffset)/q)
    end
    local low, high = camera.farDepth, camera.farDepth * 2
    while hidden(high) < bound do high = high * 2 end
    for _ = 1, 40 do
        local middle = (low + high) * 0.5
        if hidden(middle) < bound then low = middle else high = middle end
    end
    if cacheCount >= 128 then depthCache, cacheCount = {}, 0 end
    depthCache[bound], cacheCount = high, cacheCount + 1
    return high
end

-- A finite trapezoid, extended only for visible art margins. Its near edge has
-- q >= 1, where the projection is unchanged; the far edge stays at farDepth.
-- Curvature changes projected far y values, not this world-plane visibility cap.
function Projection.ViewPolygon(view, paddingMeters, horizonExtensionMeters)
    local width, height, base, distance, horizon, anchorHeight = parameters(view)
    if not width then return {} end
    local padding = finite(paddingMeters) and math.max(0, paddingMeters) or 0
    local nearQ = (height + padding * base - horizon) / anchorHeight
    local referenceFarQ = distance / (distance + Config.camera.farDepth)
    local actualNearQ = referenceFarQ + (1 - referenceFarQ) * inverseSurface(nearQ)
    local nearDepth = distance * (1 / actualNearQ - 1)
    local extension = finite(horizonExtensionMeters) and math.max(0, horizonExtensionMeters) or 0
    local farDepth = Config.camera.farDepth + extension
    local farQ = distance / (distance + farDepth)
    local function point(screenX, depth, q)
        return { x = view.camera.x + (screenX - width * Config.camera.anchorX) / (base * q),
            y = view.camera.y + depth }
    end
    return {
        point(-padding * base, nearDepth, actualNearQ),
        point(width + padding * base, nearDepth, actualNearQ),
        point(width + padding * base, farDepth, farQ),
        point(-padding * base, farDepth, farQ),
    }
end

function Projection.ViewBounds(view, paddingMeters, horizonExtensionMeters)
    local polygon = Projection.ViewPolygon(view, paddingMeters, horizonExtensionMeters)
    local bounds = { minX = math.huge, maxX = -math.huge, minY = math.huge, maxY = -math.huge }
    for _, point in ipairs(polygon) do
        bounds.minX, bounds.maxX = math.min(bounds.minX, point.x), math.max(bounds.maxX, point.x)
        bounds.minY, bounds.maxY = math.min(bounds.minY, point.y), math.max(bounds.maxY, point.y)
    end
    return bounds
end

return Projection
