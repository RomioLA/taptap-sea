-- Legacy illustration config plus centralized Sea Runtime values.
-- World lengths are meters. Camera full height is stable; width derives from aspect.
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
    temporaryLifetimeSec = 20, activateRadius = 120, freezeRadius = 150,
    maxStepSec = 0.05, maxFrameSec = 0.25, spawnAttempts = 1000, seed = 271828, spawnInset = 8,
    mapSize = 0, halfSize = 0, overlapRadius = 3, epsilon = 0.000001, regionSize = 120,
    fixedObjects = {
        { entityType = "island", position = { x = 35, y = 25 }, radius = 12, blocking = true },
        { entityType = "island", position = { x = -80, y = 90 }, radius = 20, blocking = true },
        { entityType = "float", position = { x = 10, y = 0 }, radius = 2, blocking = false },
    },
},
    camera = { tuningStatus = "V1_IMPLEMENTATION_VALUE",
    minX = 0.35, maxX = 0.65, minY = 0.45, maxY = 0.75,
    anchorX = 0.5, anchorY = 0.6, followSec = 0.15, viewHeight = 45 },
    fishing = { tuningStatus = "V1_IMPLEMENTATION_VALUE", maxCastDistance = 30,
        netRadius = 8, durationSec = 4, maxCatchCount = 1 },
    interaction = { tuningStatus = "V1_IMPLEMENTATION_VALUE", operateDistance = 5,
        portDistance = 10, maxThrowDistance = 12, outlineDistance = 80,
        recognitionDistance = 20, revealRadius = 20 },
    debug = { enabled = true, showUnderwater = false, showStates = false, showPerception = false,
    showActivity = false, showBounds = false, spawnOffset = 12, baitOffset = 8,
    refreshSec = 0.25 },
    visual = { waveSpacing = 12, waveLength = 3, waveSpeed = 0.6,
    background = { 15, 91, 125, 255 }, wave = { 89, 184, 202, 80 },
    island = { 135, 171, 110, 255 }, shore = { 209, 193, 137, 255 },
    ship = { 251, 222, 139, 255 }, float = { 184, 130, 90, 255 },
    effect = { 255, 192, 97, 255 }, bound = { 145, 231, 255, 180 },
    target = { 243, 247, 208, 160 }, shipLength = 5, shipWidth = 2.4 },
    tuningStatus = "V1_PROVISIONAL_TUNING",
    seaTitle = "渔夫漂流记 · Sea Runtime V1",
}
-- Compatibility speed alias; all level speeds and the map derive from this one table.
Config.ship.speed = Config.ship.speedByLevel[Config.ship.defaultLevel]
Config.ship.maxSpeed = math.max(table.unpack(Config.ship.speedByLevel))
Config.world.mapSize = Config.ship.maxSpeed * Config.world.travelSec
Config.world.halfSize = Config.world.mapSize / 2
return Config
