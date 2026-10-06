-- T1（2026-10-06）：第 7 天结算即结局，不进入第 8 天；两支结局与 NewRun 重置。
-- 纯 Lua/Lupa 离线回归；非真机验证。结局文案为占位，判定与状态机为本套件验收对象。
local Flow = require("tests.Circle1BFishingFlowTests")
local Config = require("config.gameplay")
local Progress = require("Gameplay.Circle1B2Progress")

local Tests = {}

local function assertEqual(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

-- 结算到指定天：从第 fromDay 天结束结算（港口内）。
local function settleDay(fixture, fromDay)
    fixture.loop.player.day = fromDay
    assert(fixture.loop:EndToday())
    assert(fixture.loop:ConfirmSettlement())
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = xpcall(fn, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("config declares maxDay = 7", function()
        assertEqual(Config.clock.maxDay, 7, "clock.maxDay")
    end)

    check("day 1-6 settlement still advances the day without ending", function()
        local f = Flow.Fixture({ loadSaved = false })
        settleDay(f, 1)
        assertEqual(f.loop.player.day, 2, "day after settlement")
        assertEqual(f.loop.endingPending, false, "endingPending")
        assertEqual(f.loop.endingKind, nil, "endingKind")
    end)

    check("day 7 settlement enters normal ending and keeps day = 7", function()
        local f = Flow.Fixture({ loadSaved = false })
        settleDay(f, 7)
        assertEqual(f.loop.player.day, 7, "day stays 7")
        assertEqual(f.loop.endingPending, true, "endingPending")
        assertEqual(f.loop.endingKind, "normal", "endingKind default")
        assertEqual(f.loop.settlementPending, false, "settlement finished")
        assert(f.loop.settlementSnapshot ~= nil, "ending run saved a final snapshot")
    end)

    check("3-apple saved elder produces the changed ending", function()
        local f = Flow.Fixture({ loadSaved = false })
        Progress.Initialize(f.loop.player)
        local elder = f.loop.player.elder.circle1B2
        elder.applesGiven, elder.decision = 3, "saved"
        settleDay(f, 7)
        assertEqual(f.loop.endingPending, true, "endingPending")
        assertEqual(f.loop.endingKind, "changed", "endingKind changed")
    end)

    check("day 7 forced-return settlement also ends the run", function()
        local f = Flow.Fixture({ loadSaved = false })
        f.loop.player.day = 7
        -- 夜尽强返路径：ConfirmForcedReturn 需要 forcedReturnPending 状态。
        f.loop.forcedReturnPending = true
        f.loop.forcedAtPort = false
        assert(f.loop:ConfirmForcedReturn())
        assertEqual(f.loop.player.day, 7, "day stays 7")
        assertEqual(f.loop.endingPending, true, "endingPending")
        assertEqual(f.loop.endingKind, "normal", "endingKind")
    end)

    check("NewRun resets the ending state for a fresh run", function()
        local f = Flow.Fixture({ loadSaved = false })
        settleDay(f, 7)
        assertEqual(f.loop.endingPending, true, "endingPending before reset")
        assert(f.loop:NewRun())
        assertEqual(f.loop.player.day, 1, "day reset")
        assertEqual(f.loop.endingPending, false, "endingPending cleared")
        assertEqual(f.loop.endingKind, nil, "endingKind cleared")
    end)

    return { results = results, metrics = {} }
end

return Tests
