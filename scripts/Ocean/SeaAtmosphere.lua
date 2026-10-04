-- Small, deterministic surface atmosphere for the projected sea.
-- All placement is in world meters; time is supplied by the caller and never stored.
local Config = require("Ocean.Config")
local Projection = require("Ocean.Projection")

local SeaAtmosphere = {}

local MAX_PUFFS = 12
local FOG_PUFFS_PER_SLICE = 3
local MAX_FOG_PUFFS = MAX_PUFFS * FOG_PUFFS_PER_SLICE
local MAX_PUFF_RADIUS_PIXELS = 220
local FOG_SLICE_VERTICAL_SCALE = 0.28
local WORLD_ROW_METERS = 55
local HORIZON_MARGIN_PIXELS = 3
local HORIZON_SAMPLES = 7
local PRIME = 2147483647
local COLUMN_SPACING_METERS = { 64, 96, 128, 160 }
local FOG_SLICE_OFFSETS = { -0.82, 0, 0.82 }
local CLOUD_SHADOW_COLOR = { 31, 71, 83 }
local FOG_COLOR = { 190, 221, 220 }

local DEFAULTS = {
    cloudShadowCount = 10,
    cloudShadowOpacity = 40,
    cloudShadowDriftMps = 0.55,
    cloudShadowRadiusMeters = 24,
    fogCount = 10,
    fogOpacity = 46,
    fogDriftMps = 0.30,
    fogRadiusMeters = 22,
    fogNearOpacityScale = 0.12,
}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function settings()
    local visual = Config.visual
    local atmosphere = type(visual) == "table" and visual.atmosphere or nil
    return type(atmosphere) == "table" and atmosphere or DEFAULTS
end

local function settingNumber(values, name, minimum, maximum)
    local value = values[name]
    if not finite(value) then value = DEFAULTS[name] end
    return clamp(value, minimum, maximum)
end

local function settingCount(values, name)
    local value = values[name]
    if not finite(value) then value = DEFAULTS[name] end
    return math.floor(clamp(value, 0, MAX_PUFFS))
end

-- Integer hash noise is tied to world-cell coordinates and seed. It does not
-- depend on Lua's RNG state and never changes merely because another frame ran.
local function hash01(seed, cellX, cellY, salt)
    local value = (seed % PRIME + PRIME) % PRIME
    value = (value + (cellX % PRIME) * 73856093
        + (cellY % PRIME) * 19349663 + salt * 83492791) % PRIME
    value = (value * 48271 + 1) % PRIME
    return value / PRIME
end

local function normalizedSeed(seed)
    if not finite(seed) then seed = Config.world and Config.world.seed or 1 end
    if not finite(seed) then seed = 1 end
    return math.floor(seed) % PRIME
end

local function viewIsReady(movement)
    return type(movement) == "table"
        and type(movement.camera) == "table"
        and finite(movement.camera.x) and finite(movement.camera.y)
        and finite(movement.viewportWidth) and movement.viewportWidth > 0
        and finite(movement.viewportHeight) and movement.viewportHeight > 0
end

local function screenHorizon(movement, x)
    local horizon = Projection.Horizon(movement, x)
    if finite(horizon) then return horizon end
    return movement.viewportHeight * Config.camera.horizonY
end

-- Use one conservative top edge for each soft puff. This clips the part above
-- the curved horizon instead of dropping a whole fog/shadow patch when it
-- crosses the horizon. The caller's sea scissor remains active through the
-- intersect operation.
local function horizonClip(movement, x, y, radiusX, radiusY)
    local left = math.max(0, x - radiusX)
    local right = math.min(movement.viewportWidth, x + radiusX)
    if right < 0 or left > movement.viewportWidth then return false end

    local highestHorizon = -math.huge
    for sample = 0, HORIZON_SAMPLES do
        local sampleX = left + (right - left) * sample / HORIZON_SAMPLES
        highestHorizon = math.max(highestHorizon, screenHorizon(movement, sampleX))
    end
    local clipTop = highestHorizon + HORIZON_MARGIN_PIXELS
    if y + radiusY <= clipTop then return false end
    local visibleRatio = clamp((y + radiusY - clipTop) / (2 * radiusY), 0, 1)
    local edgeFade = visibleRatio * visibleRatio * (3 - 2 * visibleRatio)
    return left, right - left, clipTop, edgeFade
end

local function candidate(movement, drift, seed, candidateIndex, salt)
    local row = (candidateIndex - 1) % 4
    local column = math.floor((candidateIndex - 1) / 4) - 1
    local rowCell = math.floor(movement.camera.y / WORLD_ROW_METERS) + row
    -- Every value that describes a puff is keyed by its absolute world cell.
    -- The relative `row` only selects which nearby cell is visited this frame.
    local rowJitter = (hash01(seed, rowCell, rowCell, salt + 1) - 0.5) * WORLD_ROW_METERS * 0.22
    local worldY = rowCell * WORLD_ROW_METERS + WORLD_ROW_METERS * 0.5 + rowJitter
    local depth = worldY - movement.camera.y
    if depth <= 1 or depth > Config.camera.farDepth - 1 then return end

    local spacingIndex = rowCell % #COLUMN_SPACING_METERS + 1
    local spacing = COLUMN_SPACING_METERS[spacingIndex]
    local columnCell = math.floor((movement.camera.x - drift) / spacing + 0.5) + column
    local horizontalJitter = (hash01(seed, columnCell, rowCell, salt + 2) - 0.5) * spacing * 0.18
    local worldX = columnCell * spacing + horizontalJitter + drift
    local sizeJitter = 0.82 + hash01(seed, columnCell, rowCell, salt + 3) * 0.36
    local selected = hash01(seed, columnCell, rowCell, salt + 4)
    return worldX, worldY, sizeJitter, selected
end

local function drawPuff(ctx, movement, position, sizeJitter, worldRadius, screenFactor,
    opacity, color, ship, nearOpacityScale, layerOpacity, ellipseYScale)
    local x, y, scale = Projection.Project(movement, position)
    if not finite(x) or not finite(y) or not finite(scale) then return false end

    local radiusX = clamp(worldRadius * scale * screenFactor * sizeJitter, 8, MAX_PUFF_RADIUS_PIXELS)
    local radiusY = radiusX * (ellipseYScale or 1)
    if x + radiusX < 0 or x - radiusX > movement.viewportWidth
        or y + radiusY < 0 or y - radiusY > movement.viewportHeight then
        return false
    end
    local clipX, clipWidth, clipTop, edgeFade = horizonClip(movement, x, y, radiusX, radiusY)
    if not clipX or clipWidth <= 0 or clipTop >= movement.viewportHeight then return false end

    local alpha = opacity * sizeJitter * layerOpacity * edgeFade
    if ship and type(ship.position) == "table"
        and finite(ship.position.x) and finite(ship.position.y) and nearOpacityScale ~= nil then
        local dx = position.x - ship.position.x
        local dy = position.y - ship.position.y
        local clearance = math.max(0, math.sqrt(dx * dx + dy * dy) - worldRadius)
        local distanceRatio = clamp(clearance / 44, 0, 1)
        distanceRatio = distanceRatio * distanceRatio * (3 - 2 * distanceRatio)
        alpha = alpha * (nearOpacityScale + (1 - nearOpacityScale) * distanceRatio)
    end
    alpha = math.floor(clamp(alpha, 0, 255) + 0.5)
    if alpha <= 0 then return false end

    nvgSave(ctx)
    nvgIntersectScissor(ctx, clipX, clipTop, clipWidth, movement.viewportHeight - clipTop)
    if ellipseYScale then
        -- Keep the scissor in screen coordinates, then squash the radial disk
        -- into a broad horizontal soft slice. NanoVG transforms the path and paint.
        nvgTranslate(ctx, x, y)
        nvgScale(ctx, 1, ellipseYScale)
        nvgBeginPath(ctx)
        nvgCircle(ctx, 0, 0, radiusX)
        nvgFillPaint(ctx, nvgRadialGradient(ctx, 0, 0, radiusX * 0.12, radiusX,
            nvgRGBA(color[1], color[2], color[3], alpha),
            nvgRGBA(color[1], color[2], color[3], 0)))
        nvgFill(ctx)
        nvgRestore(ctx)
        return true
    end
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, radiusX)
    nvgFillPaint(ctx, nvgRadialGradient(ctx, x, y, radiusX * 0.12, radiusX,
        nvgRGBA(color[1], color[2], color[3], alpha),
        nvgRGBA(color[1], color[2], color[3], 0)))
    nvgFill(ctx)
    nvgRestore(ctx)
    return true
end

local function drawField(ctx, movement, time, seed, countName, opacityName, driftName,
    radiusName, salt, screenFactor, color, nearOpacityScale, fogSlice)
    if not ctx or not viewIsReady(movement) then return 0 end
    local values = settings()
    local count = settingCount(values, countName)
    if count == 0 then return 0 end

    time = finite(time) and time or 0
    local opacity = settingNumber(values, opacityName, 0, 64)
    local driftSpeed = settingNumber(values, driftName, -2, 2)
    local worldRadius = settingNumber(values, radiusName, 0.5, 60)
    local normalized = normalizedSeed(seed)
    local drift = time * driftSpeed
    local ship = movement.ship
    local drawn = 0
    local density = count / 12

    nvgSave(ctx)
    for candidateIndex = 1, MAX_PUFFS do
        -- Count controls stable world-cell density. Do not re-rank a smaller
        -- per-frame subset: that would make existing puffs jump at cell edges.
        local worldX, worldY, sizeJitter, selected = candidate(
            movement, drift, normalized, candidateIndex, salt)
        if worldX and selected < density then
            if fogSlice then
                -- Three overlapping, world-offset radial puffs form one broad
                -- horizontal mist slice. The 12-anchor cap keeps this at 36.
                for puffIndex = 1, FOG_PUFFS_PER_SLICE do
                    local position = {
                        x = worldX + FOG_SLICE_OFFSETS[puffIndex] * worldRadius * sizeJitter,
                        y = worldY,
                    }
                    if drawn < MAX_FOG_PUFFS
                        and drawPuff(ctx, movement, position, sizeJitter, worldRadius,
                            screenFactor, opacity, color, ship, nearOpacityScale, 0.62,
                            FOG_SLICE_VERTICAL_SCALE) then
                        drawn = drawn + 1
                    end
                end
            else
                local position = { x = worldX, y = worldY }
                if drawPuff(ctx, movement, position, sizeJitter, worldRadius,
                    screenFactor, opacity, color, ship, nearOpacityScale, 1) then
                    drawn = drawn + 1
                end
            end
        end
    end
    nvgRestore(ctx)
    return drawn
end

--- Draw deterministic, slowly drifting shadow patches over the water.
--- Call after the base sea surface and before projected world objects.
---@param ctx NVGContextWrapper
---@param movement OceanMovement
---@param time number Read-only runtime.time value; a paused clock freezes the field.
---@param seed number? Optional deterministic world seed.
---@return number drawnPuffs
function SeaAtmosphere.CloudShadows(ctx, movement, time, seed)
    local values = settings()
    if values.cloudShadowsEnabled == false then return 0 end
    return drawField(ctx, movement, time, seed,
        "cloudShadowCount", "cloudShadowOpacity", "cloudShadowDriftMps",
        "cloudShadowRadiusMeters", 101, 0.95, CLOUD_SHADOW_COLOR, nil, false)
end

--- Draw sparse sea mist after projected objects. Near the ship the opacity falls
--- smoothly so the boat and nearby interaction targets stay clear.
---@param ctx NVGContextWrapper
---@param movement OceanMovement
---@param time number Read-only runtime.time value; a paused clock freezes the field.
---@param seed number? Optional deterministic world seed.
---@return number drawnPuffs
function SeaAtmosphere.Fog(ctx, movement, time, seed)
    local values = settings()
    if values.fogEnabled == false then return 0 end
    local nearScale = settingNumber(values, "fogNearOpacityScale", 0, 1)
    return drawField(ctx, movement, time, seed,
        "fogCount", "fogOpacity", "fogDriftMps", "fogRadiusMeters",
        211, 0.95, FOG_COLOR, nearScale, true)
end

return SeaAtmosphere
