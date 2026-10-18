-- Day/night regression for the 60/30-second world clock.
local GameplayConfig = require("config.gameplay")
local Clock = require("Gameplay.GameClock")
local Loop = require("Gameplay.Loop")

local Tests = {}

local function near(actual, expected, label)
    assert(type(actual) == "number" and math.abs(actual - expected) <= 1e-9,
        (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fixture()
    local store = { saves = {}, callbacks = {}, loaded = nil }
    function store:Save(snapshot, done)
        self.saves[#self.saves + 1] = snapshot
        self.callbacks[#self.callbacks + 1] = done
    end
    function store:Load(done)
        done(true, self.loaded)
        return true
    end
    return Loop.New({ store = store }), store
end

function Tests.Run()
    local results = {}
    local function check(name, action)
        local ok, err = xpcall(action, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("day and night boundaries are 60 and 30 seconds", function()
        assert(GameplayConfig.clock.daySec == 60)
        assert(GameplayConfig.clock.nightSec == 30)
        assert(GameplayConfig.clock.graceSec == 15)
        assert(GameplayConfig.clock.penaltyPerSec == 2)
        assert(7 * (GameplayConfig.clock.daySec + GameplayConfig.clock.nightSec) == 630)

        local clock = Clock.New()
        clock:Seek("day", 59.999)
        assert(clock.phase == "day" and not clock.exhausted)
        near(clock.elapsed, 59.999, "day 59.999")
        clock:Update(0.001)
        assert(clock.phase == "night" and not clock.exhausted)
        near(clock.elapsed, 0, "day 60.000 enters night")

        clock:Reset()
        clock:Update(60)
        assert(clock.phase == "night" and not clock.exhausted)
        near(clock.elapsed, 0, "day update at 60.000")
        clock:Seek("night", 29.999)
        assert(not clock.exhausted)
        near(clock:GetState().remaining, 0.001, "night 29.999 remaining")
        assert(clock:Update(0.001))
        assert(clock.phase == "night" and clock.exhausted)
        near(clock.elapsed, 30, "night 30.000")
    end)

    check("night penalty maps old 30/45/60-second states to 15/22.5/30", function()
        local cases = {
            { 0, 200 }, { 14.999, 200 }, { 15, 200 },
            { 15.001, 199.998 }, { 22.5, 185 }, { 29.999, 170.002 },
        }
        for _, case in ipairs(cases) do
            local loop = fixture()
            assert(loop:Depart())
            loop.player.maxStamina = 200
            loop.clock:Seek("night", case[1])
            near(loop:GetNextDayStamina(false), case[2], "night " .. tostring(case[1]))
        end

        local loop = fixture()
        assert(loop:Depart())
        loop.player.maxStamina = 200
        loop.clock:Seek("night", 30)
        assert(loop.clock.exhausted)
        assert(loop:GetNextDayStamina(true) == 100)
    end)

    check("pause freezes day and night elapsed time", function()
        local clock = Clock.New()
        clock:Seek("day", 59.999)
        clock:Pause("test")
        clock:Update(5)
        near(clock.elapsed, 59.999, "paused day")
        clock:Resume("test")
        clock:Update(0.001)
        assert(clock.phase == "night")
        near(clock.elapsed, 0, "day resumes into night")

        clock:Seek("night", 14.999)
        clock:Pause("test")
        clock:Update(5)
        near(clock.elapsed, 14.999, "paused night")
        clock:Resume("test")
        clock:Update(0.001)
        near(clock.elapsed, 15, "night safe boundary")
        clock:Update(0.001)
        near(clock.elapsed, 15.001, "night penalty boundary")
    end)

    return { results = results, guiVerified = false }
end

return Tests
