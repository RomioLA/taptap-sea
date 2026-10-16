-- Replaceable regional fish population strategy.
-- A region is initialized once per day by the runtime; returning to it must
-- reuse that day's entities rather than refill it on every activity update.
local Config = require("Ocean.Config")
local Math = require("Ocean.Math")

local SpawnStrategy = {}

local MODULUS = 2147483647
local RNG_MULTIPLIER = 48271
local TWO_PI = math.pi * 2

local function normalizedSeed(value)
    local result = math.floor(value) % MODULUS
    if result <= 0 then result = result + MODULUS - 1 end
    return result
end

local function mixSeed(daySeed, regionX, regionY, speciesId)
    local state = normalizedSeed(daySeed)
    local function mix(component)
        state = (state * RNG_MULTIPLIER + (math.floor(component) % MODULUS) + 1) % MODULUS
        if state <= 0 then state = 1 end
    end

    mix(regionX)
    mix(regionY)

    local speciesHash = 0
    for index = 1, #speciesId do
        speciesHash = (speciesHash * 31 + string.byte(speciesId, index)) % MODULUS
    end
    mix(speciesHash)
    return state
end

local function targetCount(speciesData, regionArea, activeArea, rng)
    -- BALANCE_TARGET is an expected initial density, never a live-count quota or refill trigger.
    local targetActiveCount = speciesData.targetActiveCount
    assert(type(targetActiveCount) == "number" and targetActiveCount >= 0,
        "fish species requires a nonnegative targetActiveCount")

    local expected = targetActiveCount * regionArea / activeArea
    local count = math.floor(expected)
    local fraction = expected - count
    if fraction > 0 and rng() < fraction then count = count + 1 end
    return count
end

local function validDeparture(departure)
    return type(departure) == "table"
        and type(departure.x) == "number"
        and type(departure.y) == "number"
end

local function inRegion(world, position, radius, departure, minSpawnDistance, shipPosition, minShipDistance)
    if not world:isPositionFree(position, radius) then return false end
    if minShipDistance > 0 and Math.distanceSquared(position, shipPosition) < minShipDistance^2 then return false end
    if minSpawnDistance and minSpawnDistance > 0 then
        if not validDeparture(departure) then return false end
        return Math.distanceSquared(position, departure) >= minSpawnDistance * minSpawnDistance
    end
    return true
end

local function speciesKeys(fishData)
    local keys = {}
    for key, data in pairs(fishData) do
        if type(data) == "table" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
end

function SpawnStrategy.GenerateRegion(world, daySeed, regionX, regionY, departure, fishData, shipPosition)
    assert(type(world) == "table" and type(world.isPositionFree) == "function",
        "GenerateRegion requires a world with isPositionFree(position, radius)")
    assert(type(daySeed) == "number", "GenerateRegion requires a numeric daySeed")
    assert(type(regionX) == "number" and regionX == math.floor(regionX), "regionX must be an integer")
    assert(type(regionY) == "number" and regionY == math.floor(regionY), "regionY must be an integer")
    assert(type(fishData) == "table", "GenerateRegion requires fishData")
    shipPosition = shipPosition or departure
    assert(validDeparture(shipPosition), "GenerateRegion requires current ship coordinates")

    local config = Config.world
    local mapSize = config.mapSize
    local halfSize = config.halfSize
    local regionSize = config.regionSize
    local activeRadius = config.activateRadius
    assert(type(mapSize) == "number" and mapSize > 0, "world.mapSize must be positive")
    assert(type(halfSize) == "number" and halfSize > 0, "world.halfSize must be positive")
    assert(type(regionSize) == "number" and regionSize > 0, "world.regionSize must be positive")
    assert(type(activeRadius) == "number" and activeRadius > 0, "world.activateRadius must be positive")

    local regionsPerAxis = math.ceil(mapSize / regionSize)
    assert(regionX >= 0 and regionX < regionsPerAxis and regionY >= 0 and regionY < regionsPerAxis,
        "region indices are outside the canonical map grid")

    local left = -halfSize + regionX * regionSize
    local bottom = -halfSize + regionY * regionSize
    local right = math.min(left + regionSize, halfSize)
    local top = math.min(bottom + regionSize, halfSize)
    local width, height = right - left, top - bottom
    assert(width > 0 and height > 0, "region has no playable area")

    local regionArea = width * height
    local activeArea = math.pi * activeRadius * activeRadius
    local output = {}
    local maxAttempts = math.floor(config.spawnAttempts or 0)
    assert(maxAttempts > 0, "world.spawnAttempts must be positive")

    for _, key in ipairs(speciesKeys(fishData)) do
        local data = fishData[key]
        local speciesId = data.id or key
        local rng = Math.rng(mixSeed(daySeed, regionX, regionY, speciesId))
        local count = targetCount(data, regionArea, activeArea, rng)
        local radius = data.radius or 0
        local minSpawnDistance = data.minSpawnDistance
        local minShipDistance = data.minShipSpawnDistance or 0
        assert(type(minShipDistance) == "number" and minShipDistance >= 0, "invalid minShipSpawnDistance")
        if minSpawnDistance == false then minSpawnDistance = nil end
        if minSpawnDistance ~= nil then
            assert(type(minSpawnDistance) == "number" and minSpawnDistance >= 0,
                "minSpawnDistance must be a nonnegative number")
            if minSpawnDistance > 0 and not validDeparture(departure) then
                error("GenerateRegion requires departure coordinates for " .. speciesId)
            end
        end

        for _ = 1, count do
            local chosenPosition = nil
            for _attempt = 1, maxAttempts do
                local position = {
                    x = left + rng() * width,
                    y = bottom + rng() * height,
                }
                if inRegion(world, position, radius, departure, minSpawnDistance, shipPosition, minShipDistance) then
                    chosenPosition = position
                    break
                end
            end

            if not chosenPosition then
                if speciesId == "tuna" or minShipDistance > 0 then
                    -- Some regions cannot satisfy the 200-meter departure
                    -- exclusion or obstacle clearance; leave those empty.
                    break
                end
                error(string.format(
                    "Unable to place %s in region (%d, %d) after %d attempts",
                    speciesId, regionX, regionY, maxAttempts
                ))
            end

            output[#output + 1] = {
                species = speciesId,
                position = chosenPosition,
                rotation = rng() * TWO_PI - math.pi,
            }
        end
    end

    return output
end

return SpawnStrategy
