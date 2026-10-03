local Config = require("Ocean.Config")
local FishRows = require("GeneratedData.Fish")
-- Code-owned visuals, species relationships and density/wander tuning remain here.
---@type table<string, table>
local FishData = {
    sardine = { id = "sardine", tuningStatus = "V1_IMPLEMENTATION_VALUE",
        densityStatus = "BALANCE_TARGET", targetActiveCount = 20, radius = 0.6,
        wanderMinSec = 2, wanderMaxSec = 4, dangerSpecies = "tuna",
        color = Config.fish[2].color, renderLength = 1.8 },
    tuna = { id = "tuna", tuningStatus = "V1_IMPLEMENTATION_VALUE",
        densityStatus = "BALANCE_TARGET", targetActiveCount = 4, radius = 1.1,
        wanderMinSec = 2, wanderMaxSec = 4, preySpecies = "sardine",
        attractionStatus = "V1_IMPLEMENTATION_VALUE", -- Latest user values supersede provisional D1/D2.
        color = Config.fish[1].color, renderLength = 3.8 },
}
for _, row in ipairs(FishRows) do
    local fish = assert(FishData[row.id], "unsupported fish species in data table")
    -- Preserve the existing species->item ID convention without changing either table.
    assert(row.itemDropped == nil or row.itemDropped == row.id, "fish drop ID must match its existing item ID")
    fish.wanderSpeed = row.speeds.wander
    fish.attractedSpeed = row.speeds.attracted
    fish.fleeSpeed = row.speeds.flee
    fish.chaseSpeed = row.speeds.chase
    fish.turnDegPerSec = row.turnRate
    fish.attractEffect = row.attractedBy
    fish.attractRadius = row.sense.attract
    fish.dangerRadius = row.sense.danger
    fish.preyRadius = row.sense.prey
    fish.avoidMargin = row.avoid.predict
    fish.fleeJitterSec = row.avoid.steerInterval
    fish.fleeJitterDeg = row.avoid.steerDeviation
    if row.predation then
        fish.eatRadius = row.predation.contact
        fish.lostPreySec = row.predation.loseTargetAfter
    end
    fish.minShipSpawnDistance = row.spawn.minDistFromBoat
    fish.minSpawnDistance = row.spawn.minDistFromDayStart
end
return FishData
