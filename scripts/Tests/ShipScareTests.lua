-- V2.2 movement threats and regional fish availability, using real sea modules.
local Runtime = require("Ocean.SeaRuntime")
local Config = require("Ocean.Config")
local Data = require("Ocean.FishData")
local M = require("Ocean.Math")
local Tests = {}

local function fresh()
    return Runtime.New({ initializeRegions = false, departure = { x = -300, y = -300 } })
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, reason = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(reason) or nil }
    end
    check("actual movement frightens small fish; stopping immediately restores bait attraction", function()
        local r = fresh()
        local fish = r:spawnFish("sardine", { x = -292, y = -298 })
        assert(r:spawnDroppedItem({ itemId = "bait", worldEffect = "ATTRACT_SMALL_FISH" }, fish.position))
        r:Update(0.05, 0, 0)
        assert(not r.ship.isMoving and fish.state == "Attracted")
        r:Update(0.05, 1, 0)
        assert(r.ship.isMoving and fish.state == "Flee", "movement threat must outrank bait")
        r:Update(0.05, 0, 0)
        assert(not r.ship.isMoving and fish.state == "Attracted", "no stop recovery delay")
    end)
    check("movement threat uses existing inclusive danger radius without frightening tuna", function()
        local r = fresh()
        local fish = r:spawnFish("sardine", { x = -300 + Data.sardine.dangerRadius, y = -300 })
        local behavior = r.behaviors[fish.id]
        r.ship.isMoving = true
        assert(behavior:_findDanger() == r.ship)
        fish.position.x = fish.position.x + 0.001
        assert(behavior:_findDanger() == nil)
        local tuna = r:spawnFish("tuna", { x = -295, y = -300 })
        assert(r.behaviors[tuna.id]:_findDanger() == nil)
        r.ship.isMoving = false
        fish.position = { x = -294, y = -300 }
        assert(behavior:_findDanger() == tuna, "stopping does not remove nearby tuna danger")
    end)
    check("input without displacement is not a threat; reset clears movement state", function()
        local r = fresh()
        r.movement:SetSpeed(0)
        r:Update(0.05, 1, 0)
        assert(not r.ship.isMoving)
        r.movement:SetSpeed(Config.ship.speed)
        r:Update(0.05, 1, 0)
        assert(r.ship.isMoving)
        r.movement:ResetAtPosition({ x = -300, y = -300 })
        assert(not r.ship.isMoving)
        r.movement:SetTarget({ x = -300, y = -300 })
        r:Update(0.05)
        assert(not r.ship.isMoving and r.movement.target == nil)
    end)
    check("pause freezes fish and translation; capture lock remains stronger than threats", function()
        local r = fresh()
        local fish = r:spawnFish("sardine", { x = -292, y = -298 })
        local owner = {}
        assert(r:LockFishingTarget(fish.id, owner))
        local position, state = M.copy(fish.position), fish.state
        r:Update(0.05, 1, 0)
        assert(r.ship.isMoving and M.distanceSquared(position, fish.position) == 0 and fish.state == state)
        r.paused = true
        local time, shipPosition = r.time, M.copy(r.ship.position)
        r:Update(1, 1, 0)
        assert(r.time == time and M.distanceSquared(shipPosition, r.ship.position) == 0)
        r.paused = false
        assert(r:UnlockFishingTarget(fish.id, owner))
        r:Update(0.05, 0, 0)
        assert(not r.ship.isMoving and fish.state ~= "Flee")
    end)
    check("new regions generate fish, revisits preserve depletion, next day regenerates", function()
        local r = Runtime.New()
        local firstCount = r.world:getCounts().total
        local regions = 0
        for _ in pairs(r.initializedRegions) do regions = regions + 1 end
        r.movement:ResetAtPosition({ x = 400, y = 400 })
        r:ensureNearbyRegions()
        local newRegions = 0
        for _ in pairs(r.initializedRegions) do newRegions = newRegions + 1 end
        assert(newRegions > regions and r.world:getCounts().total > firstCount)
        r:clearOrdinaryFish()
        local depleted = r.world:getCounts().total
        r.movement:ResetAtPosition(Config.ship.start)
        r:ensureNearbyRegions()
        r.movement:ResetAtPosition({ x = 400, y = 400 })
        r:ensureNearbyRegions()
        assert(r.world:getCounts().total == depleted, "revisiting must not refill caught fish")
        r:refreshOrdinaryFish(r.daySeed + 1, Config.ship.start)
        assert(r.world:getCounts().total > depleted, "new day repopulates nearby regions")
    end)
    return { results = results }
end
return Tests
