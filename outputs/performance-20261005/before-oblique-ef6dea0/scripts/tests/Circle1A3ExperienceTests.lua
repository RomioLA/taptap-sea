-- Circle 1 A3 experience evidence from the ordinary seeded sea population.
-- This is a pure-Lua runtime scenario: no native player, engine UI, or seeded
-- fish/signal fixture is used for the route, fishing query, or scope check.
local Runtime = require("Ocean.SeaRuntime")
local Config = require("Ocean.Config")
local Math = require("Ocean.Math")

local Tests = {}
local EXPERIENCE_SEED = Config.world.seed
local STEP = 0.05

---@class Circle1A3RouteSignalSample
---@field birdSourceIds string[]
---@field splashSourceIds string[]
---@field nearbyNaturalTuna number
---@field activeNaturalSardineIds string[]

---@class Circle1A3NaturalLongRouteObservation
---@field birds table<string, boolean>
---@field splashes table<string, boolean>
---@field sampleFrames number
---@field birdSampleFrames number
---@field splashSampleFrames number
---@field maxNearbyNaturalTuna number
---@field seaDrawWaterCenterSampleCount number
---@field fullyInWaterSplashSampleCount number
---@field seaDrawWaterCenterSamples table[]
---@field fullyInWaterSplashSamples table[]
---@field birdSourceIds string[]
---@field splashSourceIds string[]

---@class Circle1A3NaturalExperienceReport
---@field birdSourceId string
---@field birdSourceCount number
---@field queryTargetId string
---@field queryTargetSpecies string
---@field queryInputKind string
---@field queryDistanceMeters number
---@field candidateVisibleAfterFollow boolean
---@field visibleNaturalFishIdsAfterFollow string[]
---@field scopeEnabled boolean
---@field scopeShipIsCurrentShip boolean
---@field shipFollowDistanceMeters number
---@field followStepsToCandidateVisibility number
---@field shipAfterFollow { x: number, y: number }
---@field naturalSplashSourceIdsAfterFollow string[]

local function advance(runtime, seconds)
    local steps = math.floor(seconds / STEP + 0.0000001)
    for _ = 1, steps do runtime:Update(STEP) end
    local remainder = seconds - steps * STEP
    if remainder > 0.000001 then runtime:Update(remainder) end
end

local function sailTo(runtime, target)
    runtime.movement:SetTarget(target)
    local steps = 0
    while runtime.movement.target ~= nil do
        assert(steps < 6000, "ship did not reach the normal-seed experience waypoint")
        runtime:Update(STEP)
        steps = steps + 1
    end
    return steps
end

---@param set table<string, boolean>
---@return string[]
local function sortedIds(set)
    ---@type string[]
    local result = {}
    for id in pairs(set) do result[#result + 1] = tostring(id) end
    table.sort(result)
    return result
end

---@param runtime table
---@param species string
---@return string[]
local function activeFishIds(runtime, species)
    ---@type string[]
    local result = {}
    for _, entity in ipairs(runtime.world.entities) do
        if entity.ordinaryFish and not entity.removed and entity.species == species
            and entity.active and not entity.frozen then
            result[#result + 1] = entity.id
        end
    end
    table.sort(result)
    return result
end

---@param runtime table
---@return string[]
local function visibleNaturalFish(runtime)
    ---@type string[]
    local result = {}
    for _, entity in ipairs(runtime.world.entities) do
        if entity.ordinaryFish and not entity.removed and runtime.world:isVisible(entity) then
            result[#result + 1] = entity.id
        end
    end
    table.sort(result)
    return result
end

local function signalSourceIds(signals, getter)
    local sources = {}
    for _, signal in ipairs(getter(signals)) do
        if signal.sourceId ~= nil then sources[signal.sourceId] = true end
    end
    return sources
end

---@param runtime table
---@return Circle1A3RouteSignalSample
local function sampleNormalSignals(runtime)
    local birdSources = signalSourceIds(runtime.surfaceSignals, runtime.surfaceSignals.GetBirds)
    local splashSources = signalSourceIds(runtime.surfaceSignals, runtime.surfaceSignals.GetSplashes)
    local nearbyTuna = 0
    for _, entity in ipairs(runtime.world.entities) do
        if entity.ordinaryFish and not entity.removed and entity.species == "tuna"
            and entity.active and not entity.frozen
            and Math.distance(entity.position, runtime.ship.position) <= Config.world.activateRadius then
            nearbyTuna = nearbyTuna + 1
        end
    end
    return {
        birdSourceIds = sortedIds(birdSources),
        splashSourceIds = sortedIds(splashSources),
        nearbyNaturalTuna = nearbyTuna,
        activeNaturalSardineIds = activeFishIds(runtime, "sardine"),
    }
end

local function onScreenSplashSamples(runtime, step)
    local centerInWater, fullyInWater = {}, {}
    local width, height = 1920, 1080
    local horizonY = height * (Config.layers.waves or 0.32)
    local pixelsPerUnit = height / runtime.movement.viewHeight
    local seaDrawMargin = 4 * pixelsPerUnit + 3
    for _, splash in ipairs(runtime.surfaceSignals:GetSplashes()) do
        local screenX, screenY = runtime.movement:WorldToScreen(splash.position)
        -- Match SeaDraw.onScreen for the splash's actual effect margin, then
        -- account for its water-only scissor region (horizonY..height).
        local seaDrawEligible = screenX + seaDrawMargin >= 0
            and screenX - seaDrawMargin <= width
            and screenY + seaDrawMargin >= horizonY
            and screenY - seaDrawMargin <= height
        if seaDrawEligible and screenY >= horizonY then
            local sample = {
                step = step,
                simulatedSeconds = runtime.world.time,
                sourceId = splash.sourceId,
                worldPosition = Math.copy(splash.position),
                screenPosition = { x = screenX, y = screenY },
                shipPosition = Math.copy(runtime.ship.position),
                seaDrawSplashMarginPixels = seaDrawMargin,
                waterHorizonY = horizonY,
            }
            centerInWater[#centerInWater + 1] = sample
            if screenX >= seaDrawMargin and screenX <= width - seaDrawMargin
                and screenY >= horizonY + seaDrawMargin
                and screenY <= height - seaDrawMargin then
                fullyInWater[#fullyInWater + 1] = sample
            end
        end
    end
    return centerInWater, fullyInWater
end

---@return SeaEntity?
local function findBirdSourceForFishing(runtime)
    local birdSources = signalSourceIds(runtime.surfaceSignals, runtime.surfaceSignals.GetBirds)
    local best, bestDistance = nil, math.huge
    for _, entity in ipairs(runtime.world.entities) do
        if entity.ordinaryFish and not entity.removed and entity.alive
            and entity.species == "sardine" and birdSources[entity.id]
            and Math.distanceSquared(entity.position, runtime.ship.position)
                <= Config.fishing.maxCastDistance * Config.fishing.maxCastDistance then
            local distance = Math.distanceSquared(entity.position, runtime.ship.position)
            if distance < bestDistance then best, bestDistance = entity, distance end
        end
    end
    return best
end

---@param runtime table
---@return Circle1A3NaturalExperienceReport
local function performNormalFishingAndScope(runtime)
    -- Bird source and fishing candidate are the same fish from the normal,
    -- configured first-day population. The fishing API receives the fish's
    -- live position and must independently select a legal target.
    ---@type SeaEntity?
    local candidate = findBirdSourceForFishing(runtime)
    assert(candidate,
        "normal route produced no nearby live sardine with real-source bird cues")
    local queryCenter = Math.copy(candidate.position)
    ---@type SeaEntity?
    local queryTarget
    local queryReason
    queryTarget, queryReason = runtime:selectFishingTarget(queryCenter)
    assert(queryTarget and queryTarget.entityType == "fish",
        "normal route fishing query returned no live fish: " .. tostring(queryReason))
    assert(queryTarget == candidate,
        "query at the natural sardine position should select that exact fish")
    assert(queryTarget.species ~= nil, "selected natural fish has no species")
    local queryTargetSpecies = tostring(queryTarget.species)
    local queryDistance = Math.distance(queryCenter, runtime.ship.position)
    assert(queryDistance <= Config.fishing.maxCastDistance,
        "selected natural fish must remain within the configured cast range")

    -- Turn and travel through the real Movement/Runtime path so the lens uses
    -- the ship's current transform instead of a cached reveal or test camera.
    runtime:SetScopeEnabled(true)
    local beforeMove = Math.copy(runtime.ship.position)
    local followSteps = 0
    local candidateVisible = false
    for step = 1, 160 do
        local currentCandidate = runtime.world:get(candidate.id)
        if currentCandidate == candidate and not candidate.removed then
            local dx = candidate.position.x - runtime.ship.position.x
            local dy = candidate.position.y - runtime.ship.position.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance > Config.world.epsilon then
                runtime.movement:SetTarget({
                    x = runtime.ship.position.x + dx / distance * 100,
                    y = runtime.ship.position.y + dy / distance * 100,
                })
            end
        end
        runtime:Update(STEP)
        followSteps = step
        if runtime.world:get(candidate.id) == candidate and runtime.world:isVisible(candidate) then
            candidateVisible = true
            break
        end
    end
    local shipMoved = Math.distance(beforeMove, runtime.ship.position)
    assert(shipMoved > 0.1, "lens follow requires real ship movement")
    assert(runtime:IsScopeEnabled() and runtime.world.scopeShip == runtime.ship,
        "the enabled lens must follow the live ship object")

    local visibleIds = visibleNaturalFish(runtime)
    assert(#visibleIds > 0, "moving scope cone did not reveal any normal-population fish")
    assert(#runtime.world.reveals == 0 and not runtime.world.showUnderwater,
        "natural lens proof cannot use a timed reveal or global underwater debug view")
    assert(candidateVisible,
        "the live moving scope cone did not reveal its natural bird/fishing candidate")
    local postMoveSample = sampleNormalSignals(runtime)
    return {
        birdSourceId = candidate.id,
        birdSourceCount = #postMoveSample.birdSourceIds,
        queryTargetId = queryTarget.id,
        queryTargetSpecies = queryTargetSpecies,
        queryInputKind = "natural sardine current world position",
        queryDistanceMeters = queryDistance,
        candidateVisibleAfterFollow = candidateVisible,
        visibleNaturalFishIdsAfterFollow = visibleIds,
        scopeEnabled = runtime:IsScopeEnabled(),
        scopeShipIsCurrentShip = runtime.world.scopeShip == runtime.ship,
        shipFollowDistanceMeters = shipMoved,
        followStepsToCandidateVisibility = followSteps,
        shipAfterFollow = Math.copy(runtime.ship.position),
        naturalSplashSourceIdsAfterFollow = postMoveSample.splashSourceIds,
    }
end

local function runNormalVoyage(seed)
    local runtime = Runtime.New({ daySeed = seed })
    runtime.movement:SetViewport(1920, 1080)
    local startCounts = runtime.world:getCounts()
    assert(startCounts.sardine > 0 and startCounts.tuna >= 0,
        "normal configured first-day fish initialization did not run")
    ---@type OceanFixedBarrelSnapshot?
    local barrel = runtime:GetFixedBarrel()
    assert(barrel, "the fixed route barrel is missing")
    local barrelEntity = runtime.world.fixedBarrel
    local steps = 0
    local waypoints = {
        { x = 35, y = 5 },
        { x = 60, y = 25 },
        { x = 85, y = 25 },
        { x = 35, y = 5 },
        { x = 0, y = 0 },
    }
    ---@type Circle1A3RouteSignalSample?
    local barrelRouteSample = nil
    ---@type Circle1A3NaturalExperienceReport?
    local experience = nil
    for index, target in ipairs(waypoints) do
        steps = steps + sailTo(runtime, target)
        advance(runtime, index == 3 and 1 or 0.35)
        if index == 2 or index == 3 or index == 4 or index == 5 then
            ---@type OceanFixedBarrelSnapshot?
            local currentBarrel = runtime:GetFixedBarrel()
            assert(currentBarrel, "the fixed route barrel disappeared")
            assert(runtime.world.fixedBarrel == barrelEntity
                and currentBarrel.id == barrel.id
                and currentBarrel.generation == barrel.generation,
                "same-day barrel identity changed along the normal route")
        end
        if index == 3 then
            barrelRouteSample = sampleNormalSignals(runtime)
            experience = performNormalFishingAndScope(runtime)
        end
    end

    assert(barrelRouteSample ~= nil, "barrel route signal sample was not collected")
    assert(experience ~= nil, "natural route experience was not collected")
    ---@type Circle1A3RouteSignalSample
    local completedBarrelRouteSample = barrelRouteSample
    ---@type Circle1A3NaturalExperienceReport
    local completedExperience = experience

    -- Continue from the authored departure on the ordinary first-day sea. This
    -- matches the default-speed 120 second route used by the signal evidence
    -- and observes naturally generated tuna cues without injecting fish.
    ---@type Circle1A3NaturalLongRouteObservation
    local routeObservation = { birds = {}, splashes = {}, sampleFrames = 0,
        birdSampleFrames = 0, splashSampleFrames = 0, maxNearbyNaturalTuna = 0,
        seaDrawWaterCenterSampleCount = 0, fullyInWaterSplashSampleCount = 0,
        seaDrawWaterCenterSamples = {}, fullyInWaterSplashSamples = {},
        birdSourceIds = {}, splashSourceIds = {} }
    for step = 1, 2400 do
        runtime:Update(STEP, 0, 1)
        if step % 5 == 0 then
            local sample = sampleNormalSignals(runtime)
            routeObservation.sampleFrames = routeObservation.sampleFrames + 1
            if #sample.birdSourceIds > 0 then
                routeObservation.birdSampleFrames = routeObservation.birdSampleFrames + 1
            end
            if #sample.splashSourceIds > 0 then
                routeObservation.splashSampleFrames = routeObservation.splashSampleFrames + 1
            end
            routeObservation.maxNearbyNaturalTuna = math.max(
                routeObservation.maxNearbyNaturalTuna, sample.nearbyNaturalTuna)
            for _, id in ipairs(sample.birdSourceIds) do routeObservation.birds[id] = true end
            for _, id in ipairs(sample.splashSourceIds) do routeObservation.splashes[id] = true end
            local waterCenterSamples, fullyInWaterSamples = onScreenSplashSamples(runtime, step)
            routeObservation.seaDrawWaterCenterSampleCount = routeObservation.seaDrawWaterCenterSampleCount
                + #waterCenterSamples
            routeObservation.fullyInWaterSplashSampleCount = routeObservation.fullyInWaterSplashSampleCount
                + #fullyInWaterSamples
            for _, row in ipairs(waterCenterSamples) do
                if #routeObservation.seaDrawWaterCenterSamples < 12 then
                    routeObservation.seaDrawWaterCenterSamples[#routeObservation.seaDrawWaterCenterSamples + 1] = row
                end
            end
            for _, row in ipairs(fullyInWaterSamples) do
                if #routeObservation.fullyInWaterSplashSamples < 12 then
                    routeObservation.fullyInWaterSplashSamples[#routeObservation.fullyInWaterSplashSamples + 1] = row
                end
            end
        end
    end
    routeObservation.birdSourceIds = sortedIds(routeObservation.birds)
    routeObservation.splashSourceIds = sortedIds(routeObservation.splashes)
    assert(#routeObservation.splashSourceIds > 0,
        "the natural 120-second route produced no real Tuna water splash sources")
    assert(routeObservation.seaDrawWaterCenterSampleCount > 0,
        "natural Tuna splashes were recorded, but none passed the SeaDraw water-scissor center test")

    local finalCounts = runtime.world:getCounts()
    local regionKeys = sortedIds(runtime.initializedRegions)
    local finalSample = sampleNormalSignals(runtime)
    local digestRows = {
        "seed=" .. tostring(seed),
        string.format("startFish=%d/%d", startCounts.sardine, startCounts.tuna),
        -- Generation is a process-global credential and differs across
        -- independent Runtime.New instances; report it but exclude it from the digest.
        "barrel=" .. tostring(barrel.id),
        "regions=" .. table.concat(regionKeys, ","),
        "barrelBirdSources=" .. table.concat(completedBarrelRouteSample.birdSourceIds, ","),
        "barrelSplashSources=" .. table.concat(completedBarrelRouteSample.splashSourceIds, ","),
        "barrelNearbyTuna=" .. tostring(completedBarrelRouteSample.nearbyNaturalTuna),
        "fishQuery=" .. tostring(completedExperience.birdSourceId) .. ":" .. tostring(completedExperience.queryTargetId),
        "scopeVisible=" .. table.concat(completedExperience.visibleNaturalFishIdsAfterFollow, ","),
        "routeBirdSources=" .. table.concat(routeObservation.birdSourceIds, ","),
        "routeSplashSources=" .. table.concat(routeObservation.splashSourceIds, ","),
        "waterCenterSplashSamples=" .. tostring(routeObservation.seaDrawWaterCenterSampleCount),
        "fullyInWaterSplashSamples=" .. tostring(routeObservation.fullyInWaterSplashSampleCount),
        string.format("ship=%.5f,%.5f", runtime.ship.position.x, runtime.ship.position.y),
        string.format("worldTime=%.5f", runtime.world.time),
        "finalBirdSources=" .. table.concat(finalSample.birdSourceIds, ","),
        "finalSplashSources=" .. table.concat(finalSample.splashSourceIds, ","),
        string.format("finalFish=%d/%d", finalCounts.sardine, finalCounts.tuna),
    }
    return {
        digest = table.concat(digestRows, "\n"),
        route = {
            waypoints = waypoints,
            updateSteps = steps + 2400,
            simulatedSeconds = runtime.world.time,
            normalStartFish = { sardine = startCounts.sardine, tuna = startCounts.tuna },
            finalFish = { sardine = finalCounts.sardine, tuna = finalCounts.tuna },
            initializedRegionCount = #regionKeys,
            fixedBarrelId = barrel.id,
            fixedBarrelGeneration = barrel.generation,
            barrelRouteSignals = completedBarrelRouteSample,
            naturalLongRouteSignals = routeObservation,
            experience = completedExperience,
            finalBirdSourceIds = finalSample.birdSourceIds,
            finalSplashSourceIds = finalSample.splashSourceIds,
            normalRuntimeFishLimitRaised = false,
            syntheticFishOrSignalFixtureUsed = false,
        },
    }
end

function Tests.Run()
    local results = {}
    local metrics = {
        experienceSeed = EXPERIENCE_SEED,
        normalVoyages = {},
        repeatedDigestMatch = false,
        nativeHumanPlayMeasured = false,
        syntheticNormalRouteFishOrSignalsUsed = false,
    }

    local okFirst, first = pcall(runNormalVoyage, EXPERIENCE_SEED)
    if not okFirst then
        results[#results + 1] = { name = "normal seeded barrel and open-sea route supports repeatable bird, fishing, and moving-lens feedback",
            passed = false, error = tostring(first) }
        metrics.normalVoyages[1] = { seed = EXPERIENCE_SEED, passed = false, error = tostring(first) }
        return { results = results, metrics = metrics }
    end
    local okSecond, second = pcall(runNormalVoyage, EXPERIENCE_SEED)
    if not okSecond then
        results[#results + 1] = { name = "normal seeded barrel and open-sea route supports repeatable bird, fishing, and moving-lens feedback",
            passed = false, error = tostring(second) }
        metrics.normalVoyages = {
            { seed = EXPERIENCE_SEED, passed = true, digest = first.digest, report = first.route },
            { seed = EXPERIENCE_SEED, passed = false, error = tostring(second) },
        }
        return { results = results, metrics = metrics }
    end

    metrics.repeatedDigestMatch = first.digest == second.digest
    metrics.normalVoyages = {
        { seed = EXPERIENCE_SEED, passed = true, digest = first.digest, report = first.route },
        { seed = EXPERIENCE_SEED, passed = true, digest = second.digest, report = second.route },
    }
    results[#results + 1] = {
        name = "normal seeded barrel and open-sea route supports repeatable bird, fishing, and moving-lens feedback",
        passed = metrics.repeatedDigestMatch,
        error = metrics.repeatedDigestMatch and "" or "same seed produced a different normal-voyage digest",
    }
    return { results = results, metrics = metrics }
end

return Tests
