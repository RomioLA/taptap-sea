local Config = require("Ocean.Config")
return {
    sardine = { id = "sardine", tuningStatus = "V1_IMPLEMENTATION_VALUE",
        densityStatus = "BALANCE_TARGET", targetActiveCount = 20, radius = 0.6,
        wanderSpeed = 4, attractedSpeed = 5, fleeSpeed = 7, turnDegPerSec = 220,
        wanderMinSec = 2, wanderMaxSec = 4, fleeJitterSec = 0.4, fleeJitterDeg = 25,
        attractEffect = "ATTRACT_SMALL_FISH", attractRadius = 18,
        dangerSpecies = "tuna", dangerRadius = 12, avoidMargin = 4, minShipSpawnDistance = 15,
        color = Config.fish[2].color, renderLength = 1.8 },
    tuna = { id = "tuna", tuningStatus = "V1_IMPLEMENTATION_VALUE",
        densityStatus = "BALANCE_TARGET", targetActiveCount = 4, radius = 1.1,
        wanderSpeed = 5, chaseSpeed = 8, turnDegPerSec = 90,
        wanderMinSec = 2, wanderMaxSec = 4, preySpecies = "sardine", preyRadius = 30,
        eatRadius = 1.5, lostPreySec = 2, minSpawnDistance = 200, avoidMargin = 6, minShipSpawnDistance = 30,
        attractEffect = "ATTRACT_BIG_FISH", attractRadius = 36, attractedSpeed = 6.0,
        attractionStatus = "V1_IMPLEMENTATION_VALUE", -- Latest user values supersede provisional D1/D2.
        color = Config.fish[1].color, renderLength = 3.8 },
}
