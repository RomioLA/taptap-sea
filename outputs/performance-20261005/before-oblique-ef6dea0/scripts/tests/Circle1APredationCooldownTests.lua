local Runtime = require("Ocean.SeaRuntime")
local Config = require("Ocean.Config")
local Math = require("Ocean.Math")

local Tests = {}

local function fresh()
    return Runtime.New({ initializeRegions = false, departure = { x = 200, y = 0 } })
end

local function near(actual, expected, tolerance)
    assert(math.abs(actual - expected) <= (tolerance or 0.00001),
        tostring(actual) .. " != " .. tostring(expected))
end

local function advance(runtime, seconds)
    local fullSteps = math.floor(seconds / 0.05)
    for _ = 1, fullSteps do runtime:Update(0.05) end
    local remainder = seconds - fullSteps * 0.05
    if remainder > 0.0000001 then runtime:Update(remainder) end
end

local function predationScenario()
    local runtime = fresh()
    local tuna = runtime:spawnFish("tuna", { x = 200, y = 0 }, 0)
    local prey = runtime:spawnFish("sardine", { x = 200, y = 1 }, 0)
    local behavior = runtime.behaviors[tuna.id] --[[@as FishBehavior]]
    return runtime, tuna, prey, behavior
end

local function holdPreyStill(entity)
    -- Keep a real World fish entity queryable while preventing its own AI from moving it.
    entity.ordinaryFish = false
    entity.active, entity.frozen = false, true
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("successful scheduled predation starts one five-second world-time cooldown", function()
        assert(Config.predation.cooldownSeconds == 5,
            "the user-confirmed Circle 1 test value remains five seconds")
        local runtime, tuna, prey, behavior = predationScenario()
        assert(behavior.predationCooldownUntil == 0)

        runtime:Update(0.05)
        assert(prey.removed and prey.removeReason == "eaten")
        assert(runtime:GetFishingTarget(prey.id) == nil, "successful predation removes the prey from the World")
        near(behavior.predationCooldownUntil, runtime.world.time + Config.predation.cooldownSeconds)
        local firstDeadline = behavior.predationCooldownUntil

        runtime:Update(0.05)
        assert(runtime:GetFishingTarget(tuna.id) == tuna)
        near(behavior.predationCooldownUntil, firstDeadline)
    end)

    check("cooldown blocks retargeting and eating but permits attraction, avoidance, and expiry", function()
        local runtime, tuna, prey, behavior = predationScenario()
        runtime:Update(0.05)
        assert(prey.removed)
        local deadline = behavior.predationCooldownUntil

        local secondPrey = runtime:spawnFish("sardine", { x = 201, y = 0 }, 0)
        behavior:Update(0.05)
        assert(runtime:GetFishingTarget(secondPrey.id) == secondPrey and not secondPrey.removed)
        assert(behavior.state ~= "Chase" and behavior.preyId == nil,
            "the cooldown suppresses ordinary and cached prey acquisition")

        tuna.position = { x = Config.world.halfSize - tuna.radius - 1, y = 0 }
        behavior:Update(0.05)
        assert(behavior.state == "Avoid", "world-edge avoidance remains available during cooldown")
        assert(not secondPrey.removed)

        runtime.ship.position = { x = 300, y = 0 }
        tuna.position = { x = 300, y = 0 }
        tuna.rotation = 0
        local bait = runtime:spawnDroppedItem({ itemId = "circle1-cooldown-bait", worldEffect = "ATTRACT_BIG_FISH" },
            { x = 310, y = 0 })
        local positionBeforeAttraction = Math.copy(tuna.position)
        behavior:Update(0.05)
        assert(behavior.state == "Attracted", "matching bait still attracts a cooling predator")
        assert(tuna.position.x > positionBeforeAttraction.x)
        assert(not secondPrey.removed)
        assert(runtime.world:remove(bait.id, "test"))

        local expiryPrey = runtime:spawnFish("sardine", { x = tuna.position.x + 5, y = tuna.position.y }, 0)
        holdPreyStill(expiryPrey)
        advance(runtime, Config.predation.cooldownSeconds - 0.05)
        assert(runtime.world.time < deadline, "AI world time remains just before the cooldown deadline")
        assert(runtime:GetFishingTarget(expiryPrey.id) == expiryPrey,
            "a nearby eligible prey is not eaten during the cooldown")

        expiryPrey.position = { x = tuna.position.x + 1, y = tuna.position.y }
        advance(runtime, 0.1)
        assert(runtime.world.time >= deadline)
        assert(expiryPrey.removed and expiryPrey.removeReason == "eaten",
            "predation resumes once world time passes the deadline")
        assert(behavior.predationCooldownUntil > deadline,
            "the next successful meal starts a new cooldown")
    end)

    check("pause stops cooldown time while capture lock and freeze stop only fish AI", function()
        local runtime, tuna, prey, behavior = predationScenario()
        runtime:Update(0.05)
        assert(prey.removed)
        local deadline = behavior.predationCooldownUntil
        local followupPrey = runtime:spawnFish("sardine", { x = 201, y = 0 }, 0)
        holdPreyStill(followupPrey)

        local owner = {}
        assert(runtime:LockFishingTarget(tuna.id, owner))
        local lockedPosition = Math.copy(tuna.position)
        local lockedState = tuna.state
        local timeBeforeLockStep = runtime.world.time
        advance(runtime, 0.5)
        assert(runtime.world.time > timeBeforeLockStep,
            "a capture-locked predator does not pause the sea world clock")
        near(Math.distance(tuna.position, lockedPosition), 0)
        assert(tuna.state == lockedState and behavior.predationCooldownUntil == deadline)
        assert(not followupPrey.removed)
        assert(runtime:UnlockFishingTarget(tuna.id, owner))

        runtime.ship.position = { x = 0, y = 0 }
        lockedPosition = Math.copy(tuna.position)
        local timeBeforeFreeze = runtime.world.time
        advance(runtime, 0.5)
        assert(tuna.frozen and not tuna.active, "the test moves the predator outside its activity range")
        assert(runtime.world.time > timeBeforeFreeze,
            "a frozen predator does not pause the sea world clock")
        near(Math.distance(tuna.position, lockedPosition), 0)
        assert(not followupPrey.removed)

        runtime:TogglePause()
        local pausedTime = runtime.world.time
        advance(runtime, 1)
        near(runtime.world.time, pausedTime)
        assert(behavior.predationCooldownUntil == deadline)
        runtime:TogglePause()

        runtime.ship.position = { x = 200, y = 0 }
        runtime:Update(0.05)
        assert(not tuna.frozen and tuna.active, "bringing the ship back reactivates the same predator")
        assert(not followupPrey.removed, "reactivation during the remaining cooldown does not eat prey")
        local remaining = deadline - runtime.world.time
        assert(remaining > 0.05, "paused time did not consume the remaining cooldown")
        advance(runtime, remaining - 0.02)
        assert(runtime.world.time < deadline and not followupPrey.removed)

        followupPrey.position = { x = tuna.position.x + 1, y = tuna.position.y }
        advance(runtime, 0.05)
        assert(runtime.world.time >= deadline)
        assert(followupPrey.removed and followupPrey.removeReason == "eaten",
            "the remaining cooldown elapses only after unpaused world time resumes")
    end)

    check("failed prey removal leaves prey alive and does not start cooldown", function()
        local runtime, tuna, prey, behavior = predationScenario()
        local originalRemove = runtime.world.remove
        local attempts = 0
        runtime.world.remove = function(world, id, reason, ownerToken)
            if reason == "eaten" then
                attempts = attempts + 1
                return false
            end
            return originalRemove(world, id, reason, ownerToken)
        end

        behavior:Update(0.05)
        runtime.world.remove = originalRemove
        assert(attempts == 1, "the contact path attempted one authoritative World removal")
        assert(runtime:GetFishingTarget(prey.id) == prey and not prey.removed,
            "failed removal does not manually mark prey removed")
        assert(behavior.predationCooldownUntil == 0,
            "failed removal does not trigger the success cooldown")
        assert(behavior.state == "Chase")
    end)

    return { results = results }
end

return Tests
