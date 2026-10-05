-- Legacy illustration config plus centralized Sea Runtime values.
-- World lengths are meters. Camera full height is stable; width derives from aspect.
local FishRows = require("GeneratedData.Fish")
local activityRange = FishRows[1].ai
-- The existing world has one shared activity range, not per-species thresholds.
for _, row in ipairs(FishRows) do
    assert(row.ai.fullRange == activityRange.fullRange and row.ai.freezeRange == activityRange.freezeRange,
        "fish AI ranges must match the shared world activity range")
end
---@type number[]
local shipSpeeds = { 6.0, 8.0, 10.0 }
local Config = {
    units = { length = "meter", metersPerWorldUnit = 1, speed = "meter_per_second" },
    title = "海风小岛",
    layers = {
        birds = 0.21,
        waves = 0.32,
        fish = 0.44,
        boat = 0.61,
        island = 0.83,
    },
    boat = {
        initialX = 0.5,
        minX = 0.18,
        maxX = 0.82,
        speed = 0.24,
        buttonStep = 0.12,
    },
    birds = {
        { x = 0.39, phase = 0, scale = 1 },
        { x = 0.62, phase = 1.8, scale = 0.82 },
    },
    fish = {
        { x = 0.38, phase = 0, direction = 1, color = { 255, 165, 112, 255 } },
        { x = 0.65, phase = 2.4, direction = -1, color = { 176, 238, 218, 255 } },
    },
    -- Legacy fields remain compatible with the unmodified HUD/Draw.
    ship = { tuningStatus = "V1_IMPLEMENTATION_VALUE", defaultLevel = 1,
    speedByLevel = shipSpeeds, speed = 0, maxSpeed = 0, turnDegPerSec = 180, arrivalRadius = 1.5,
    radius = 1.8, start = { x = 0, y = 0 } },
    world = { tuningStatus = "V1_IMPLEMENTATION_VALUE", travelSec = 180, visualPadding = 100, pushSpeed = 3, pushSec = 0.3,
    temporaryLifetimeSec = 20, activateRadius = activityRange.fullRange, freezeRadius = activityRange.freezeRange,
    maxStepSec = 0.05, maxFrameSec = 0.25, spawnAttempts = 1000, seed = 271828, spawnInset = 8,
    mapSize = 0, halfSize = 0, overlapRadius = 3, epsilon = 0.000001, regionSize = 120,
    fixedObjects = {
        { entityType = "island", position = { x = 35, y = 25 }, radius = 12, blocking = true },
        { entityType = "island", position = { x = -80, y = 90 }, radius = 20, blocking = true },
        { entityType = "float", position = { x = 10, y = 0 }, radius = 2, blocking = false },
    },    -- 新手教程点位：出港点(0,0)右侧近海的固定木桶，出港即可见、抵达即教学。
    -- 非阻挡漂浮物，靠近 ≤ operateDistance(5m) 可检查（World:Init 注册）。
    fixedBarrel = { position = { x = 14, y = 6 }, radius = 2,
        tuningStatus = "TUTORIAL_PROVISIONAL_GEOMETRY" },
},
    camera = { tuningStatus = "SEA_VIEW_VISUAL_TEST_VALUE",
    minX = 0.35, maxX = 0.65, minY = 0.45, maxY = 0.75,
    -- min/max retained for legacy callers; continuous follow no longer uses a dead zone.
    anchorX = 0.5, anchorY = 0.72, followSec = 0.15, viewHeight = 45,
    horizonY = 0.24, depthCompression = 0.65, farDepth = 110 },
    fishing = { tuningStatus = "V1_IMPLEMENTATION_VALUE", maxCastDistance = 30,
        netRadius = 8, durationSec = 4, maxCatchCount = 1 },
    -- Circle 1 confirmed playtest value; not a new planning/data-schema field.
    predation = { cooldownSeconds = 5, tuningStatus = "USER_APPROVED_TEST_VALUE" },
    interaction = { tuningStatus = "V1_IMPLEMENTATION_VALUE", operateDistance = 5,
        portDistance = 10, maxThrowDistance = 12, outlineDistance = 80,
        recognitionDistance = 20, revealRadius = 20 },
    debug = { enabled = true, showUnderwater = false, showStates = false, showPerception = false,
    showActivity = false, showBounds = false, spawnOffset = 12, baitOffset = 8,
    refreshSec = 0.25 },
    visual = { waveSpacing = 12, waveLength = 3, waveSpeed = 0.6,
    -- Presentation-only temporary values; no world interaction/AI distances change.
    surface = { spacingMeters = 12, lengthMeters = 3, driftSpeed = 0.6,
        amplitudeMeters = 0.18, periodSec = 5, maxMarks = 1800,
        nearSpacingMeters = 12, farSpacingMeters = 6,
        detailTransitionStartMeters = 35, detailTransitionEndMeters = 110 },
    wake = { lifetimeSec = 3, spacingMeters = 0.6, minSpeed = 0.15, maxSamples = 96,
        initialWidth = 0.65, spreadPerSec = 0.45, sternOffset = 2.5, opacity = 125 },
    projection = { circleSegments = 48, sectorSegments = 32, birdAltitude = 1.2 },
    boatMotion = { enabled = true, heaveMeters = 0.35, maxRollDegrees = 7,
        turnRateForMaxRoll = math.pi, turnSmoothSec = 0.22 },
    curvature = { heightRatio = 0.045 },
    horizonOcclusion = { tangentSpan = 0.1 },
    aerialPerspective = { enabled = true, startDepthMeters = 18,
        endDepthMeters = 125, maxOpacityLoss = 0.48 },
    atmosphere = { cloudShadowCount = 10, cloudShadowOpacity = 40,
        cloudShadowDriftMps = 0.55, cloudShadowRadiusMeters = 24,
        fogCount = 10, fogOpacity = 46, fogDriftMps = 0.30,
        fogRadiusMeters = 22, fogNearOpacityScale = 0.12 },
    shoreFoam = { enabled = true, bubbleCount = 36, ringRatio = 1.0,
        bubbleRadiusMeters = 0.30, pulsePeriodSec = 3.2 },
    -- Remote STEP-5 visual, confirmed by the planning workbook's night-visual rule.
    nightOverlay = { 10, 22, 48, 190 },
    background = { 15, 91, 125, 255 }, wave = { 109, 207, 216, 145 },
    island = { 135, 171, 110, 255 }, shore = { 209, 193, 137, 255 },
    ship = { 251, 222, 139, 255 }, float = { 184, 130, 90, 255 },
    effect = { 255, 192, 97, 255 }, bound = { 145, 231, 255, 180 },
    target = { 243, 247, 208, 160 }, shipLength = 5, shipWidth = 2.4 },
    tuningStatus = "V1_PROVISIONAL_TUNING",
    -- User-approved playtest values; this table does not amend planning documents.
    surfaceSignals = {
        enabled = true, riseSeconds = 2, riseTuningStatus = "USER_APPROVED_TEST_VALUE",
        birdOffset = 9, birdRadius = 3, birdsPerGroup = 2, birdPollSeconds = 0.25,
        birdDiveSeconds = 1.5, birdAngularSpeed = 1.8, birdAnimationStatus = "VISUAL_TEST_VALUE",
        splashInterval = 1, chaseSplashInterval = 0.5, splashLifetime = 0.6, trailLength = 2,
    },
    seaTitle = "渔夫漂流记 · Sea Runtime V1",
}
-- Compatibility speed alias; all level speeds and the map derive from this one table.
Config.ship.speed = Config.ship.speedByLevel[Config.ship.defaultLevel]
Config.ship.maxSpeed = math.max(table.unpack(Config.ship.speedByLevel))
Config.world.mapSize = Config.ship.maxSpeed * Config.world.travelSec
Config.world.halfSize = Config.world.mapSize / 2
return Config
