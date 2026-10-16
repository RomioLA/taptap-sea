-- 实际模块的异常快照回归；同步/异步 store 均不访问真实云。
local Config = require("config.gameplay")
local Player = require("Gameplay.PlayerState")
local Persistence = require("Gameplay.Persistence")
local Loop = require("Gameplay.Loop")
local Progress = require("Gameplay.Circle1B2Progress")
local passed = 0

local function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function same(actual, expected)
    eq(type(actual), type(expected))
    if type(expected) ~= "table" then eq(actual, expected); return end
    for key, value in pairs(expected) do same(actual[key], value) end
    for key in pairs(actual) do assert(expected[key] ~= nil) end
end

local function snapshot()
    local player = assert(Player.New())
    player.day, player.money, player.stamina = 7, 321, 37
    player.recognizedLocations = { harbor = true }
    player.treasures = { found = true }
    player.story = { chapter = 2 }
    player.elder = { lastGivenItemId = "apple" }
    assert(Progress.Initialize(player)); assert(Progress.OnDayStarted(player))
    return Persistence.Snapshot(player)
end

local cases = {
    { "normal", function(_) end },
    { "level-out-of-range", function(d) d.inventoryLevel = 99 end },
    { "original-level99-capacitynil", function(d) d.inventoryLevel = 99; d.inventoryCapacity = nil end },
    { "capacity-missing", function(d) d.inventoryCapacity = nil end },
    { "capacity-string", function(d) d.inventoryCapacity = "5" end },
    { "capacity-table", function(d) d.inventoryCapacity = {} end },
    { "capacity-boolean", function(d) d.inventoryCapacity = false end },
    { "level-capacity-mismatch", function(d) d.inventoryCapacity = Config.inventory.capacities[2] end },
}
for _, field in ipairs({ "inventoryLevel", "inventoryCapacity" }) do
    for _, invalid in ipairs({
        { "missing", function(d) d[field] = nil end },
        { "string", function(d) d[field] = "1" end },
        { "boolean", function(d) d[field] = true end },
        { "table", function(d) d[field] = {} end },
        { "zero", function(d) d[field] = 0 end },
        { "negative", function(d) d[field] = -1 end },
        { "fraction", function(d) d[field] = 1.5 end },
        { "nan", function(d) d[field] = 0/0 end },
        { "infinity", function(d) d[field] = math.huge end },
    }) do
        cases[#cases + 1] = { field .. "-" .. invalid[1], invalid[2] }
    end
end

for _, case in ipairs(cases) do
    local valid = case[1] == "normal"
    local data = snapshot()
    case[2](data)
    local safe, restored, err = pcall(Persistence.Restore, data)
    eq(safe, true)
    if valid then same(Persistence.Snapshot(assert(restored)), data)
    else eq(restored, nil); eq(type(err), "string") end
    passed = passed + 1

    for _, asynchronous in ipairs({ false, true }) do
        local deliver
        local store = { Load = function(_, callback)
            deliver = callback
            if not asynchronous then callback(true, data) end
        end }
        local loop = Loop.New({ store = store })
        local original = loop.player
        original.money, original.day, original.stamina = 123, 3, 42
        original.recognizedLocations = { original = true }
        original.story = { original = "story" }
        original.treasures = { original = true }
        original.elder = { original = "elder" }
        local before = Persistence.Snapshot(original)
        loop.clock:Pause("special_event")
        local successes, failures = 0, 0
        local function done(ok, reason)
            if ok then successes = successes + 1
            else failures = failures + 1; eq(type(reason), "string") end
        end
        local noThrow, started = pcall(loop.LoadSaved, loop, done)
        eq(noThrow, true); eq(started, true)
        if asynchronous then
            eq(loop.loading, true); eq(successes + failures, 0)
            eq(pcall(deliver, true, data), true)
        end
        -- 后端重复/交错通知不能触发第二次完成，也不能应用另一快照。
        eq(pcall(deliver, true, snapshot()), true)
        eq(pcall(deliver, false, "late error"), true)
        eq(successes, valid and 1 or 0); eq(failures, valid and 0 or 1)
        eq(loop.loading, false); eq(loop.clock.pauseReasons.loading, nil)
        eq(loop.clock.pauseReasons.port, true)
        if valid then
            assert(loop.player ~= original)
            same(Persistence.Snapshot(loop.player), data)
        else
            eq(loop.player, original); same(Persistence.Snapshot(loop.player), before)
            eq(loop.clock.pauseReasons.special_event, true)
            assert(loop.lastMessage:find("读档失败", 1, true))
        end
        passed = passed + 1
    end
end

-- 防御 Restore 实现或构造过程意外抛错，同步和异步都必须通知失败。
local realRestore = Persistence.Restore
for _, asynchronous in ipairs({ false, true }) do
    local deliver
    local loop = Loop.New({ store = { Load = function(_, callback)
        deliver = callback
        if not asynchronous then callback(true, snapshot()) end
    end } })
    local original, calls = loop.player, 0
    Persistence.Restore = function() error("injected restore exception") end
    local safe, started = pcall(loop.LoadSaved, loop, function(ok, reason)
        eq(ok, false); eq(type(reason), "string"); calls = calls + 1
    end)
    if asynchronous then eq(pcall(deliver, true, snapshot()), true) end
    Persistence.Restore = realRestore
    eq(safe, true); eq(started, true); eq(calls, 1)
    eq(loop.player, original); eq(loop.loading, false)
    deliver(false, "duplicate"); eq(calls, 1)
    passed = passed + 1
end

-- 全部配置等级的正常快照均可恢复，避免仅支持初始等级。
for level, capacity in ipairs(Config.inventory.capacities) do
    local data = snapshot()
    data.inventoryLevel, data.inventoryCapacity = level, capacity
    same(Persistence.Snapshot(assert(Persistence.Restore(data))), data)
    passed = passed + 1
end
print("PERSISTENCE_REGRESSION_PASS " .. passed)
