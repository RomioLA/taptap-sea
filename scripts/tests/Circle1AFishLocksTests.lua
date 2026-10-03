local Runtime = require("Ocean.SeaRuntime")
local Math = require("Ocean.Math")
local EntityStateSystem = require("Systems.EntityStateSystem")

local Tests = {}

local function fresh()
    return Runtime.New({ initializeRegions = false, departure = { x = 200, y = 0 } })
end

local function near(actual, expected, tolerance)
    assert(math.abs(actual - expected) <= (tolerance or 0.00001),
        tostring(actual) .. " != " .. tostring(expected))
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("nearest target, empty net, hidden fish, and locked target exclusion", function()
        local runtime = fresh()
        local farther = runtime:spawnFish("tuna", { x = 207, y = 0 })
        local nearest = runtime:spawnFish("sardine", { x = 202, y = 0 })
        nearest.active, nearest.frozen = false, true
        local center = { x = 200, y = 0 }

        assert(runtime:selectFishingTarget(center) == nearest,
            "nearest hidden/frozen fish remains eligible before locking")
        local owner = {}
        assert(runtime:LockFishingTarget(nearest.id, owner))
        assert(runtime:selectFishingTarget(center) == farther,
            "selection skips the locked fish and returns the next nearest target")

        local secondOwner = {}
        assert(runtime:LockFishingTarget(farther.id, secondOwner))
        assert(runtime:selectFishingTarget(center) == nil, "all locked fish produce an empty net")
        assert(runtime:UnlockFishingTarget(nearest.id, owner))
        assert(runtime:selectFishingTarget(center) == nearest)
        assert(runtime.world:get(nearest.id) == nearest and runtime.world:get(farther.id) == farther)

        local tieRuntime = fresh()
        local firstAtTie = tieRuntime:spawnFish("sardine", { x = 199, y = 0 })
        tieRuntime:spawnFish("tuna", { x = 201, y = 0 })
        local tieCenter = { x = 200, y = 0 }
        assert(tieRuntime:selectFishingTarget(tieCenter) == firstAtTie)
        assert(tieRuntime:selectFishingTarget(tieCenter) == firstAtTie,
            "equal-distance selection remains stable in world order")
    end)

    check("lock owner contract uses table identity and idempotent cleanup", function()
        local runtime = fresh()
        local fish = runtime:spawnFish("sardine", { x = 201, y = 0 })
        local owner = {}
        local equalMetatable = { __eq = function() return true end }
        local distinctButEqualOwner = setmetatable({}, equalMetatable)
        owner = setmetatable({}, equalMetatable)
        assert(owner == distinctButEqualOwner and not rawequal(owner, distinctButEqualOwner),
            "fixture must distinguish __eq from object identity")

        local ok, reason = runtime:LockFishingTarget("missing-target", owner)
        assert(not ok and reason == "fishing_target_expired")
        ok, reason = runtime:LockFishingTarget(runtime.ship.id, owner)
        assert(not ok and reason == "fishing_target_expired", "non-fish entities cannot be locked")
        ok, reason = runtime:LockFishingTarget(fish.id, "not-a-table-token")
        assert(not ok and reason == "invalid_capture_owner")
        ok, reason = runtime:UnlockFishingTarget(fish.id, nil)
        assert(not ok and reason == "invalid_capture_owner")
        assert(runtime:UnlockFishingTarget("missing-target", owner), "unlocking an expired ID is idempotent")
        assert(runtime:UnlockFishingTarget(fish.id, owner), "unlocking an already-unlocked fish is idempotent")

        assert(runtime:LockFishingTarget(fish.id, owner))
        assert(runtime:LockFishingTarget(fish.id, owner), "same owner may repeat its lock")
        ok, reason = runtime:LockFishingTarget(fish.id, distinctButEqualOwner)
        assert(not ok and reason == "fishing_target_locked", "equal metamethods do not confer ownership")
        ok, reason = runtime:UnlockFishingTarget(fish.id, distinctButEqualOwner)
        assert(not ok and reason == "capture_owner_mismatch")
        ok, reason = runtime:RemoveFishingTarget(fish.id, distinctButEqualOwner)
        assert(not ok and reason == "capture_owner_mismatch")
        ok, reason = runtime:RemoveFishingTarget(fish.id)
        assert(not ok and reason == "capture_owner_mismatch", "a locked fish needs its owner token to be removed")
        assert(not runtime.world:remove(fish.id, "eaten"), "World independently blocks predation of a locked fish")
        assert(runtime:GetFishingTarget(fish.id) == fish and fish.captureLocked == true)
        assert(runtime:UnlockFishingTarget(fish.id, owner))
        assert(runtime:UnlockFishingTarget(fish.id, distinctButEqualOwner),
            "valid-token cleanup stays idempotent after the fish is unlocked")
        assert(runtime:RemoveFishingTarget(fish.id), "legacy one-argument removal remains valid after unlock")
        assert(fish.removeReason == "caught" and not fish.captureLocked and fish.captureOwnerToken == nil)
        assert(runtime:UnlockFishingTarget(fish.id, owner), "unlocking after successful removal is idempotent")
    end)

    check("captured sardine pauses AI and rise, clears birds, and resumes as the same entity", function()
        local runtime = fresh()
        local predator = runtime:spawnFish("tuna", { x = 200, y = 8 }, math.pi * 1.5)
        local fish = runtime:spawnFish("sardine", { x = 200, y = 0 }, 0)
        runtime:Update(0.05)

        local behavior = runtime.behaviors[fish.id] --[[@as FishBehavior]]
        local predatorBehavior = runtime.behaviors[predator.id] --[[@as FishBehavior]]
        assert(fish.state == "Flee" and fish.riseRemaining > 0,
            "fixture must enter the accepted surface-rise behavior")
        assert(predatorBehavior.preyId == fish.id, "fixture must give the predator a prior target")
        assert(#runtime.surfaceSignals:GetBirds() > 0, "fixture must have a live functional bird group")

        local center = Math.copy(fish.position)
        assert(runtime:selectFishingTarget(center) == fish)
        local owner = {}
        assert(runtime:LockFishingTarget(fish.id, owner))
        assert(fish.captureLocked == true)
        assert(#runtime.surfaceSignals:GetBirds() == 0, "locking immediately revokes the bird group")
        assert(runtime:selectFishingTarget(center) ~= fish, "locked target cannot be selected again")

        local fishPosition = Math.copy(fish.position)
        local fishState = fish.state
        local riseRemaining = fish.riseRemaining
        local worldTime = runtime.world.time
        behavior:Update(0.25)
        near(Math.distance(fish.position, fishPosition), 0)
        near(fish.riseRemaining, riseRemaining)
        assert(fish.state == fishState)
        runtime.world:moveEntity(fish, 10, 0)
        near(Math.distance(fish.position, fishPosition), 0)

        -- The predator already held this prey ID before the capture lock.
        predatorBehavior:Update(0.05)
        assert(runtime:GetFishingTarget(fish.id) == fish and not fish.removed,
            "a locked fish cannot be eaten through a cached prey ID")
        assert(predatorBehavior.preyId ~= fish.id, "locked prey is discarded from the chase target")

        EntityStateSystem:Update(runtime.world, 0.25)
        near(Math.distance(fish.position, fishPosition), 0)
        near(fish.riseRemaining, riseRemaining)
        runtime:Update(0.25)
        assert(runtime.world.time > worldTime, "a single locked fish does not pause world time")
        near(Math.distance(fish.position, fishPosition), 0)
        near(fish.riseRemaining, riseRemaining)
        assert(#runtime.surfaceSignals:GetBirds() == 0)

        assert(runtime:UnlockFishingTarget(fish.id, owner))
        assert(runtime:GetFishingTarget(fish.id) == fish, "unlock restores the original entity")
        local positionBeforeResume = Math.copy(fish.position)
        behavior:Update(0.05)
        assert(Math.distance(fish.position, positionBeforeResume) > 0,
            "direct Fish.Update resumes ordinary movement after unlock")
        assert(fish.riseRemaining < riseRemaining, "surface rise resumes from its retained progress")
    end)

    check("failed removal snapshot, owner replacement, day refresh, and reset generation", function()
        local runtime = fresh()
        local fish = runtime:spawnFish("sardine", { x = 201, y = 0 })
        local behavior = runtime.behaviors[fish.id]
        local owner = {}
        assert(runtime:LockFishingTarget(fish.id, owner))
        local snapshot = runtime:SnapshotFishingTarget(fish)

        local originalRemove = runtime.world.remove
        runtime.world.remove = function() return false end
        local removed = runtime:RemoveFishingTarget(fish.id, owner)
        runtime.world.remove = originalRemove
        assert(not removed and runtime:GetFishingTarget(fish.id) == fish)
        assert(runtime:RestoreFishingTarget(fish, snapshot), "failed removal snapshot remains restorable")
        assert(fish.captureLocked and runtime.behaviors[fish.id] == behavior)

        assert(runtime:RemoveFishingTarget(fish.id, owner))
        assert(runtime:GetFishingTarget(fish.id) == nil)
        assert(runtime:RestoreFishingTarget(fish, snapshot), "rollback re-inserts a removed fish")
        assert(runtime:GetFishingTarget(fish.id) == fish and fish.captureLocked == true)
        assert(runtime.behaviors[fish.id] == behavior)

        local replacementOwner = {}
        assert(runtime:UnlockFishingTarget(fish.id, owner))
        assert(runtime:LockFishingTarget(fish.id, replacementOwner))
        assert(not runtime:RestoreFishingTarget(fish, snapshot),
            "snapshot owned by a prior token cannot overwrite the current owner")
        assert(fish.captureOwnerToken == replacementOwner)

        local beforeRefresh = runtime:GetFishingGeneration()
        runtime:refreshOrdinaryFish(45, { x = 200, y = 0 })
        assert(runtime:GetFishingGeneration() > beforeRefresh)
        assert(not fish.captureLocked and fish.captureOwnerToken == nil,
            "day refresh clears the old lock from the retired entity")

        local refreshed = runtime:spawnFish("sardine", { x = 201, y = 0 })
        local staleRemoved, staleReason = runtime:RemoveFishingTarget(refreshed.id, replacementOwner)
        assert(not staleRemoved and staleReason == "capture_owner_mismatch",
            "old owner cannot remove a new unlocked fish after day refresh")
        assert(runtime:GetFishingTarget(refreshed.id) == refreshed)

        local resetRuntime = fresh()
        local oldFish = resetRuntime:spawnFish("tuna", { x = 201, y = 0 })
        local oldId = oldFish.id
        local oldOwner = {}
        assert(resetRuntime:LockFishingTarget(oldId, oldOwner))
        local oldSnapshot = resetRuntime:SnapshotFishingTarget(oldFish)
        local oldGeneration = resetRuntime:GetFishingGeneration()
        resetRuntime:Reset()
        assert(resetRuntime:GetFishingGeneration() > oldGeneration)
        local newFish = resetRuntime:spawnFish("tuna", { x = 201, y = 0 })
        assert(newFish.id == oldId, "fixture must exercise an ID reused by the reset world")
        local newOwner = {}
        assert(resetRuntime:LockFishingTarget(newFish.id, newOwner))
        staleRemoved, staleReason = resetRuntime:RemoveFishingTarget(newFish.id, oldOwner)
        assert(not staleRemoved and staleReason == "capture_owner_mismatch")
        local unlocked, unlockReason = resetRuntime:UnlockFishingTarget(newFish.id, oldOwner)
        assert(not unlocked and unlockReason == "capture_owner_mismatch")
        assert(not resetRuntime:RestoreFishingTarget(oldFish, oldSnapshot),
            "snapshot cannot restore across reset world or generation")
        assert(resetRuntime:GetFishingTarget(newFish.id) == newFish and newFish.captureOwnerToken == newOwner)
        assert(not oldFish.captureLocked and oldFish.captureOwnerToken == nil,
            "Runtime reset clears locks on entities in its retired world")
    end)

    return { results = results }
end

return Tests
