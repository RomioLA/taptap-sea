-- Replaceable regional fish population strategy.
-- A region is initialized once per day by the runtime; returning to it must
-- reuse that day's entities rather than refill it on every activity update.
local Config = require("Ocean.Config")
local Math = require("Ocean.Math")
local Content = require("data.content")

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

-- Soft preferred-distance band from the day's departure point (S1 distribution
-- goal: small fish near the start, big fish farther out). Band hits are preferred,
-- never required: when no in-band candidate exists the caller falls back to any
-- valid position, so distant regions keep their populations (no dead zones).
local function inBand(position, departure, band)
    if not band then return false end
    if not validDeparture(departure) then return false end
    local distanceSquared = Math.distanceSquared(position, departure)
    return distanceSquared >= band.min * band.min and distanceSquared <= band.max * band.max
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

-- V2.8 固定生态特例（系统规则·V2.8固定生态特例）：
-- leviathan_bones_01 所在 120×120m 中海分区每日首次激活时总数仍为 6，
-- 但配比覆写为 4 小鱼 + 2 大鱼；大鱼优先在距巨骨 15～45m 环带内采样。
-- 只改这一个固定分区的初始化组成，不新增鱼 AI 状态、不增加每日总鱼数。
local function leviathanOverride(regionX, regionY)
    local v28 = Config.v28
    local leviathan = type(v28) == "table" and v28.leviathan or nil
    if type(leviathan) ~= "table" then return nil end
    local config = Config.world
    local size = leviathan.regionSize or config.regionSize
    local left = -config.halfSize + regionX * config.regionSize
    local bottom = -config.halfSize + regionY * config.regionSize
    local centerX, centerY = left + size * 0.5, bottom + size * 0.5
    -- 分区中心距巨骨不超过半分区对角线时视为包含该节点。
    local content = nil
    for _, definition in ipairs(Content.fixed) do
        if definition.contentId == leviathan.contentId then content = definition end
    end
    if not content then return nil end
    local dx, dy = content.position.x - centerX, content.position.y - centerY
    if dx * dx + dy * dy > (size * 0.7072) ^ 2 then return nil end
    return {
        content = content,
        sardineCount = leviathan.sardineCount,
        tunaCount = leviathan.tunaCount,
        ringMin = leviathan.bigFishRingMin,
        ringMax = leviathan.bigFishRingMax,
    }
end

local function ringPositionInRegion(region, ring, maxAttempts, rng, accept)
    local config = Config.world
    local center = ring.content.position
    for _ = 1, maxAttempts do
        local angle = rng() * TWO_PI
        local distance = ring.ringMin + rng() * (ring.ringMax - ring.ringMin)
        local position = { x = center.x + math.cos(angle) * distance,
            y = center.y + math.sin(angle) * distance }
        local insideRegion = position.x >= region.left and position.x <= region.right
            and position.y >= region.bottom and position.y <= region.top
        if insideRegion and accept(position) then return position end
    end
    return nil
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
    local ring = leviathanOverride(regionX, regionY)
    local regionBounds = { left = left, bottom = bottom, right = right, top = top }

    for _, key in ipairs(speciesKeys(fishData)) do
        local data = fishData[key]
        local speciesId = data.id or key
        local rng = Math.rng(mixSeed(daySeed, regionX, regionY, speciesId))
        local count = targetCount(data, regionArea, activeArea, rng)
        local overrideCount = nil
        if ring then
            if speciesId == "sardine" then overrideCount = ring.sardineCount
            elseif speciesId == "tuna" then overrideCount = ring.tunaCount end
        end
        if overrideCount ~= nil then count = overrideCount end
        local radius = data.radius or 0
        local minSpawnDistance = data.minSpawnDistance
        local minShipDistance = data.minShipSpawnDistance or 0
        local band = data.spawnBandFromDayStart
        if band then
            assert(type(band.min) == "number" and type(band.max) == "number" and band.min <= band.max,
                "spawnBandFromDayStart must be a {min,max} table")
        end
        assert(type(minShipDistance) == "number" and minShipDistance >= 0, "invalid minShipSpawnDistance")
        if minSpawnDistance == false then minSpawnDistance = nil end
        if minSpawnDistance ~= nil then
            assert(type(minSpawnDistance) == "number" and minSpawnDistance >= 0,
                "minSpawnDistance must be a nonnegative number")
            if minSpawnDistance > 0 and not validDeparture(departure) then
                error("GenerateRegion requires departure coordinates for " .. speciesId)
            end
        end

        -- S1-f（2026-10-16 卡顿排查）：spawn band 是 departure 距离带；当整个 region
        -- 与 band 无空间交集（远处区域整体在带外）时 phase1 不可能命中，原本仍会
        -- 为每条鱼跑满 maxAttempts 次 isPositionFree（远处移动 121ms 卡顿帧根因）。
        -- 快速路径：band 不可达时第一个 valid 位置即采纳（与原 fallback 语义一致），
        -- inRegion/minSpawnDistance/minShipDistance 约束判定完全不变。
        -- 注意：band 是物种级变量，本计算必须在物种循环内、band 就绪之后。
        local bandReachable = true
        if band and validDeparture(departure) then
            local nearX = math.max(left, math.min(departure.x, right))
            local nearY = math.max(bottom, math.min(departure.y, top))
            local nearestSquared = (nearX - departure.x) ^ 2 + (nearY - departure.y) ^ 2
            local farX = math.abs(departure.x - left) > math.abs(departure.x - right) and left or right
            local farY = math.abs(departure.y - bottom) > math.abs(departure.y - top) and bottom or top
            local farthestSquared = (farX - departure.x) ^ 2 + (farY - departure.y) ^ 2
            bandReachable = not (farthestSquared < band.min * band.min
                or nearestSquared > band.max * band.max)
        elseif band then
            bandReachable = false -- departure 非法时 inBand 恒 false
        end

        for _ = 1, count do
            -- Phase 1 prefers an in-band candidate; phase 2 keeps the first valid
            -- out-of-band candidate as fallback. Deterministic for a fixed seed.
            local chosenPosition = nil
            local fallbackPosition = nil
            -- V2.8：巨骨分区的两条大鱼优先在距巨骨 15～45m 环带内采样，
            -- 但仍必须满足全部既有硬约束；环带内无合法点时回退常规合法位置。
            if ring and speciesId == "tuna" then
                chosenPosition = ringPositionInRegion(regionBounds, ring, maxAttempts, rng,
                    function(position)
                        return inRegion(world, position, radius, departure, minSpawnDistance,
                            shipPosition, minShipDistance)
                    end)
            end
            for _attempt = 1, maxAttempts do
                if chosenPosition then break end
                local position = {
                    x = left + rng() * width,
                    y = bottom + rng() * height,
                }
                if inRegion(world, position, radius, departure, minSpawnDistance, shipPosition, minShipDistance) then
                    if bandReachable and inBand(position, departure, band) then
                        chosenPosition = position
                        break
                    elseif not fallbackPosition then
                        fallbackPosition = position
                        if not bandReachable then
                            -- band 不可达：第一个 valid 位置即最终结果（与原 fallback 语义一致）
                            chosenPosition = position
                            break
                        end
                    end
                end
            end

            if not chosenPosition then chosenPosition = fallbackPosition end
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
