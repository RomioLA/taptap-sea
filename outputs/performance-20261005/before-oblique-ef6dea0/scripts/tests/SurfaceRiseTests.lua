local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local Tests = {}

local function fresh()
    return Runtime.New({ initializeRegions = false, departure = { x = 400, y = 400 } })
end

local function spawnFleePair(distance)
    local runtime = fresh()
    local sardine = runtime:spawnFish("sardine", { x = 410, y = 400 }, 0)
    local tuna = runtime:spawnFish("tuna", { x = 410 + distance, y = 400 }, math.pi)
    return runtime, sardine, tuna, runtime.behaviors[sardine.id]
end

local function keepDangerNear(sardine, tuna, distance)
    tuna.position = { x = sardine.position.x + distance, y = sardine.position.y }
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("Flee rise uses the configured two seconds and leaves fish movement active", function()
        local duration = assert(Config.surfaceSignals and Config.surfaceSignals.riseSeconds,
            "Config.surfaceSignals.riseSeconds is required")
        assert(duration == 2, "surface rise remains a two-second test value")
        local _, sardine, tuna, behavior = spawnFleePair(6)

        behavior:Update(0)
        assert(sardine.state == "Flee")
        assert(sardine.surfaceDepth == 0 and sardine.riseRemaining == duration)

        local start = { x = sardine.position.x, y = sardine.position.y }
        for _ = 1, 4 do
            keepDangerNear(sardine, tuna, 6)
            behavior:Update(0.5)
        end
        assert(sardine.state == "Flee")
        assert(sardine.riseRemaining == 0 and sardine.surfaceDepth == 1)
        assert(sardine.position.x ~= start.x or sardine.position.y ~= start.y,
            "the visual rise must not stop Flee movement")

        keepDangerNear(sardine, tuna, 6)
        behavior:Update(0.5)
        assert(sardine.riseRemaining == 0 and sardine.surfaceDepth == 1,
            "completed rise stays at the surface until Flee exits")
    end)

    check("leaving Flee clears rise fields and re-entry starts a fresh rise", function()
        local duration = Config.surfaceSignals.riseSeconds
        local _, sardine, tuna, behavior = spawnFleePair(6)

        behavior:Update(0)
        keepDangerNear(sardine, tuna, 6)
        behavior:Update(0.5)
        assert(sardine.surfaceDepth > 0 and sardine.riseRemaining < duration)

        keepDangerNear(sardine, tuna, 30)
        behavior:Update(0.1)
        assert(sardine.state ~= "Flee")
        assert(sardine.surfaceDepth == 0 and sardine.riseRemaining == 0)

        keepDangerNear(sardine, tuna, 6)
        behavior:Update(0)
        assert(sardine.state == "Flee")
        assert(sardine.surfaceDepth == 0 and sardine.riseRemaining == duration)
    end)

    check("inactive, frozen, removed, paused, and missing config do not advance rise", function()
        local _, sardine, tuna, behavior = spawnFleePair(6)
        behavior:Update(0)
        keepDangerNear(sardine, tuna, 6)
        behavior:Update(0.25)
        local remaining = sardine.riseRemaining

        sardine.active = false
        behavior:Update(0.5)
        assert(sardine.riseRemaining == remaining)
        sardine.active = true

        sardine.frozen = true
        behavior:Update(0.5)
        assert(sardine.riseRemaining == remaining)
        sardine.frozen = false

        sardine.removed = true
        behavior:Update(0.5)
        assert(sardine.riseRemaining == remaining)
        sardine.removed = false

        local runtime = fresh()
        local pausedFish = runtime:spawnFish("sardine", { x = 410, y = 400 }, 0)
        local pausedTuna = runtime:spawnFish("tuna", { x = 416, y = 400 }, math.pi)
        ---@type FishBehavior
        local pausedBehavior = runtime.behaviors[pausedFish.id]
        pausedBehavior:Update(0)
        pausedBehavior:Update(0.25)
        local pausedRemaining = pausedFish.riseRemaining
        runtime:TogglePause()
        runtime:Update(1)
        assert(pausedFish.riseRemaining == pausedRemaining)

        local originalSignals = Config.surfaceSignals
        local ok, err = pcall(function()
            Config.surfaceSignals = { enabled = false, riseSeconds = 2 }
            local _, disabledFish, disabledTuna, disabledBehavior = spawnFleePair(6)
            disabledBehavior:Update(0)
            keepDangerNear(disabledFish, disabledTuna, 6)
            disabledBehavior:Update(0.5)
            assert(disabledFish.state == "Flee")
            assert(disabledFish.surfaceDepth == 0 and disabledFish.riseRemaining == 0)

            Config.surfaceSignals = nil
            local _, noConfigFish, noConfigTuna, noConfigBehavior = spawnFleePair(6)
            noConfigBehavior:Update(0)
            assert(noConfigFish.state == "Flee")
            assert(noConfigFish.surfaceDepth == 0 and noConfigFish.riseRemaining == 0)
            keepDangerNear(noConfigFish, noConfigTuna, 6)
            noConfigBehavior:Update(0.5)
            assert(noConfigFish.surfaceDepth == 0 and noConfigFish.riseRemaining == 0)
        end)
        Config.surfaceSignals = originalSignals
        if not ok then error(err) end
    end)

    check("a rising Flee fish remains a valid tuna prey", function()
        local runtime, sardine, tuna, behavior = spawnFleePair(2)
        behavior:Update(0)
        keepDangerNear(sardine, tuna, 6)
        behavior:Update(0.5)
        assert(sardine.state == "Flee" and sardine.surfaceDepth > 0)

        tuna.position = { x = sardine.position.x + 1, y = sardine.position.y }
        runtime.behaviors[tuna.id]:Update(0.05)
        assert(sardine.removed and runtime.world:get(sardine.id) == nil,
            "surface rise must not make a fish immune to tuna predation")
    end)

    return { results = results }
end

return Tests
