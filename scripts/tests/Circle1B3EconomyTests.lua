local GameplayConfig = require("config.gameplay")
local Items = require("data.items")
local Loop = require("Gameplay.Loop")
local OceanConfig = require("Ocean.Config")
local OceanRuntime = require("Ocean.SeaRuntime")

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

local function sameItems(actual, expected)
    eq(#actual, #expected, "inventory length")
    for index, itemId in ipairs(expected) do eq(actual[index], itemId, "inventory index " .. index) end
end

local function store()
    local value = { writes = 0 }
    function value:Save(data, done)
        self.writes = self.writes + 1
        self.data = data
        if done then done(true) end
    end
    function value:Load(done)
        if done then done(self.data ~= nil, self.data) end
    end
    return value
end

local function newLoop(runtime)
    local loop = Loop.New({ store = store() })
    if runtime then loop:BindRuntime(runtime) end
    return loop
end

local function newRuntimeAtPort()
    local runtime = OceanRuntime.New({ initializeRegions = false })
    local port = runtime:GetShipPosition()
    function runtime:GetPortPosition() return { x = port.x, y = port.y } end
    return runtime
end

local function capturePortState(loop, runtime, stockItem)
    return {
        items = loop.player.inventory:GetItems(),
        inventoryLevel = loop.player.inventory:GetLevel(),
        money = loop.player.money,
        stamina = loop.player.stamina,
        maxStamina = loop.player.maxStamina,
        boatSpeedLevel = loop.player.boatSpeedLevel,
        stock = loop:GetShopStock(stockItem),
        movementLevel = runtime and runtime.movement.level or nil,
        movementSpeed = runtime and runtime.movement.speed or nil,
    }
end

local function assertPortState(loop, runtime, stockItem, before)
    sameItems(loop.player.inventory:GetItems(), before.items)
    eq(loop.player.inventory:GetLevel(), before.inventoryLevel)
    eq(loop.player.money, before.money)
    eq(loop.player.stamina, before.stamina)
    eq(loop.player.maxStamina, before.maxStamina)
    eq(loop.player.boatSpeedLevel, before.boatSpeedLevel)
    eq(loop:GetShopStock(stockItem), before.stock)
    if runtime then
        eq(runtime.movement.level, before.movementLevel)
        eq(runtime.movement.speed, before.movementSpeed)
    end
end

local function injectMoneyFailureAfterMutation(loop, mode)
    local changeMoney = loop.player.ChangeMoney
    loop.player.ChangeMoney = function(player, amount)
        local accepted, reason = changeMoney(player, amount)
        if not accepted then return false, reason end
        if mode == "throw" then error("injected post-mutation payment failure") end
        return false, "injected_money_failure"
    end
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("cargo revision changes with inventory mutations and is exposed by Loop", function()
        local loop = newLoop()
        local inventory = loop.player.inventory
        eq(loop:GetCargoRevision(), inventory:GetRevision())
        local revision = loop:GetCargoRevision()
        assert(inventory:RestoreItems({ "sardine" }))
        eq(loop:GetCargoRevision(), revision + 1)
        revision = loop:GetCargoRevision()
        assert(inventory:Add("tuna"))
        eq(loop:GetCargoRevision(), revision + 1)
        revision = loop:GetCargoRevision()
        assert(inventory:Remove(1))
        eq(loop:GetCargoRevision(), revision + 1)
        revision = loop:GetCargoRevision()
        assert(inventory:Upgrade())
        eq(loop:GetCargoRevision(), revision + 1)
    end)

    test("selling a rendered cargo row credits once and rejects its duplicate click", function()
        local loop = newLoop()
        local inventory = loop.player.inventory
        assert(inventory:RestoreItems({ "sardine", "tuna" }))
        local revision = loop:GetCargoRevision()
        local money = loop.player.money
        local sardinePrice = assert(Items.GetDefinition("sardine")).sellPrice

        assert(loop:Sell(1, "sardine", revision))
        eq(loop.player.money, money + sardinePrice)
        eq(loop:GetCargoRevision(), revision + 1)
        sameItems(inventory:GetItems(), { "tuna" })

        local duplicate, reason = loop:Sell(1, "sardine", revision)
        eq(duplicate, false)
        eq(reason, "cargo_changed")
        eq(loop.player.money, money + sardinePrice)
        sameItems(inventory:GetItems(), { "tuna" })
    end)

    test("a moved inventory index or changed row identity cannot sell a stale item", function()
        local loop = newLoop()
        local inventory = loop.player.inventory
        assert(inventory:RestoreItems({ "sardine", "tuna" }))
        local revision = loop:GetCargoRevision()
        local money = loop.player.money

        local wrongIdentity, identityReason = loop:Sell(1, "tuna", revision)
        eq(wrongIdentity, false)
        eq(identityReason, "cargo_changed")
        eq(loop.player.money, money)

        assert(inventory:Remove(1))
        local movedRow, rowReason = loop:Sell(1, "sardine", revision)
        eq(movedRow, false)
        eq(rowReason, "cargo_changed")
        eq(loop.player.money, money)
        sameItems(inventory:GetItems(), { "tuna" })
    end)

    test("a successful purchase changes cargo, money, and stock together", function()
        local loop = newLoop()
        local definition = assert(Items.GetDefinition("bait"))
        local stock = loop:GetShopStock("bait")
        assert(stock > 0)
        loop.player.money = definition.buyPrice + 10
        local beforeItems = loop.player.inventory:GetItems()
        local revision = loop:GetCargoRevision()

        assert(loop:Buy("bait"))
        eq(loop.player.money, 10)
        eq(loop:GetShopStock("bait"), stock - 1)
        eq(loop:GetCargoRevision(), revision + 1)
        local afterItems = loop.player.inventory:GetItems()
        eq(#afterItems, #beforeItems + 1)
        eq(afterItems[#afterItems], "bait")
    end)

    test("a rejected full-inventory purchase does not charge or consume stock", function()
        local loop = newLoop()
        local inventory = loop.player.inventory
        assert(inventory:RestoreItems({ "apple", "bait", "apple", "bait", "apple" }))
        local definition = assert(Items.GetDefinition("bait"))
        local stock = loop:GetShopStock("bait")
        loop.player.money = definition.buyPrice + 10
        local money = loop.player.money

        local purchased, reason = loop:Buy("bait")
        eq(purchased, false)
        eq(reason, "inventory_full")
        eq(loop.player.money, money)
        eq(loop:GetShopStock("bait"), stock)
        sameItems(inventory:GetItems(), { "apple", "bait", "apple", "bait", "apple" })
    end)

    test("inventory can hold more than two apples", function()
        local loop = newLoop()
        local inventory = loop.player.inventory
        assert(inventory:RestoreItems({}))
        for _ = 1, 3 do assert(inventory:Add("apple")) end
        sameItems(inventory:GetItems(), { "apple", "apple", "apple" })
    end)

    local mutationCases = {
        {
            name = "purchase",
            run = function(loop) return loop:Buy("bait") end,
            prepare = function(loop) assert(loop.player.inventory:RestoreItems({})) end,
        },
        {
            name = "sale",
            run = function(loop) return loop:Sell(1, "sardine", loop:GetCargoRevision()) end,
            prepare = function(loop) assert(loop.player.inventory:RestoreItems({ "sardine" })) end,
        },
        {
            name = "inventory upgrade",
            run = function(loop) return loop:UpgradeInventory() end,
            prepare = function() end,
        },
        {
            name = "stamina upgrade",
            run = function(loop) return loop:UpgradeStamina() end,
            prepare = function(loop) loop.player.stamina = 30 end,
        },
        {
            name = "boat-speed upgrade",
            usesRuntime = true,
            run = function(loop) return loop:UpgradeBoatSpeed() end,
            prepare = function() end,
        },
    }

    for _, failureMode in ipairs({ "false", "throw" }) do
        local mode = failureMode
        for _, mutationCase in ipairs(mutationCases) do
            local currentCase = mutationCase
            test(currentCase.name .. " rolls back after ChangeMoney mutates then " .. mode, function()
                local runtime = currentCase.usesRuntime and newRuntimeAtPort() or nil
                local loop = newLoop(runtime)
                loop.player.money = 10000
                currentCase.prepare(loop)
                local before = capturePortState(loop, runtime, "bait")
                injectMoneyFailureAfterMutation(loop, mode)

                local accepted, reason = currentCase.run(loop)
                eq(accepted, false)
                eq(reason, mode == "throw" and "transaction_failed" or "injected_money_failure")
                eq(loop.inventoryRollback, nil)
                assert(loop:Ready(), "a completed rollback must unblock port actions")
                assertPortState(loop, runtime, "bait", before)
            end)
        end
    end

    test("failed speed rollback stays blocked and retries until the real movement speed is restored", function()
        local runtime = newRuntimeAtPort()
        local setShipLevel = runtime.SetShipLevel
        local calls = 0
        function runtime:SetShipLevel(level)
            calls = calls + 1
            if calls == 2 then return false, "injected_rollback_failure" end
            return setShipLevel(self, level)
        end
        local loop = newLoop(runtime)
        loop.player.money = 10000
        local before = capturePortState(loop, runtime, "bait")
        injectMoneyFailureAfterMutation(loop, "false")

        local upgraded, reason = loop:UpgradeBoatSpeed()
        eq(upgraded, false)
        eq(reason, "inventory_rollback_pending")
        eq(calls, 2)
        eq(loop.player.money, before.money)
        eq(loop.player.boatSpeedLevel, before.boatSpeedLevel)
        eq(runtime.movement.level, 2)
        eq(runtime.movement.speed, OceanConfig.ship.speedByLevel[2])
        assert(loop.inventoryRollback, "failed external speed restoration must retain its snapshot")
        assert(not loop:Ready(), "pending economic rollback must block future actions")

        loop:Update(0)
        eq(calls, 3)
        eq(loop.inventoryRollback, nil)
        assert(loop:Ready(), "successful retry must restore readiness")
        assertPortState(loop, runtime, "bait", before)
        eq(runtime.movement.level, 1)
        eq(runtime.movement.speed, OceanConfig.ship.speedByLevel[1])
    end)

    test("boat-speed upgrade changes the real Ocean movement speed", function()
        local runtime = newRuntimeAtPort()
        runtime.paused = false
        local loop = newLoop(runtime)
        local prices = GameplayConfig.upgrades.boatSpeed.prices
        loop.player.money = prices[1] + prices[2]

        local function measureOneSecond(expectedSpeed)
            local before = runtime:GetShipPosition()
            -- Keep this measurement aligned with the target so it measures travel speed,
            -- independent of the turn-rate test covered by Ocean movement tests.
            runtime.ship.rotation = 0
            runtime.movement:SetTarget({ x = before.x + 100, y = before.y })
            for _ = 1, math.ceil(1 / OceanConfig.world.maxFrameSec) do
                runtime:Update(OceanConfig.world.maxFrameSec)
            end
            local after = runtime:GetShipPosition()
            local dx, dy = after.x - before.x, after.y - before.y
            local traveled = math.sqrt(dx * dx + dy * dy)
            assert(math.abs(traveled - expectedSpeed) < 0.000001,
                "one second of real movement should cover " .. expectedSpeed .. " meters; got " .. traveled)
        end

        local function returnToPortByMovement()
            local port = runtime:GetPortPosition()
            runtime.movement:SetTarget(port)
            for _ = 1, math.ceil(20 / OceanConfig.world.maxFrameSec) do
                runtime:Update(OceanConfig.world.maxFrameSec)
                local position = runtime:GetShipPosition()
                local dx, dy = position.x - port.x, position.y - port.y
                if math.sqrt(dx * dx + dy * dy) <= OceanConfig.interaction.portDistance * 0.5 then
                    return true
                end
            end
            return false
        end

        eq(runtime.movement.speed, OceanConfig.ship.speedByLevel[1])
        measureOneSecond(GameplayConfig.upgrades.boatSpeed.metersPerSec[1])

        assert(loop:UpgradeBoatSpeed())
        eq(loop.player.boatSpeedLevel, 2)
        eq(runtime.movement.level, 2)
        eq(runtime.movement.speed, OceanConfig.ship.speedByLevel[2])
        eq(loop.player.money, prices[2])
        eq(GameplayConfig.upgrades.boatSpeed.metersPerSec[2], OceanConfig.ship.speedByLevel[2])
        measureOneSecond(GameplayConfig.upgrades.boatSpeed.metersPerSec[2])

        assert(returnToPortByMovement(), "real movement should bring the ship back into port range")
        assert(loop:CanAccessPort(), "the next configured speed purchase requires the real port radius")
        assert(loop:UpgradeBoatSpeed())
        eq(loop.player.boatSpeedLevel, 3)
        eq(runtime.movement.level, 3)
        eq(runtime.movement.speed, OceanConfig.ship.speedByLevel[3])
        eq(loop.player.money, 0)
        eq(GameplayConfig.upgrades.boatSpeed.metersPerSec[3], OceanConfig.ship.speedByLevel[3])
        measureOneSecond(GameplayConfig.upgrades.boatSpeed.metersPerSec[3])
    end)

    test("zero stamina still allows same-day sailing and an ordinary return without restoring cargo", function()
        local runtime = newRuntimeAtPort()
        local port = runtime:GetShipPosition()
        local loop = newLoop(runtime)
        local inventory = loop.player.inventory
        assert(inventory:RestoreItems({ "apple", "bait", "sardine" }))
        loop.player.stamina = 0
        local itemsBefore = inventory:GetItems()
        local dayBefore = loop.player.day
        local home = runtime:GetShipPosition()

        assert(loop:Depart())
        eq(loop.player.stamina, 0)
        runtime.movement:SetTarget({ x = port.x + OceanConfig.interaction.portDistance * 3, y = port.y })
        local sailedBeyondPort = false
        for _ = 1, 40 do
            loop:Update(0.25, function(dt) runtime:Update(dt) end)
            local position = runtime:GetShipPosition()
            local dx, dy = position.x - port.x, position.y - port.y
            if math.sqrt(dx * dx + dy * dy) > OceanConfig.interaction.portDistance + 1 then
                sailedBeyondPort = true
                break
            end
        end
        assert(sailedBeyondPort, "real OceanRuntime movement should take the ship outside port range")
        local rejected, rejectReason = loop:ReturnToPort()
        eq(rejected, false)
        eq(rejectReason, "port_out_of_range")
        eq(loop.inPort, false)

        runtime.movement:SetTarget(home)
        local reachedPortRadius = false
        for _ = 1, 80 do
            loop:Update(0.25, function(dt) runtime:Update(dt) end)
            local position = runtime:GetShipPosition()
            local dx, dy = position.x - port.x, position.y - port.y
            if math.sqrt(dx * dx + dy * dy) <= OceanConfig.interaction.portDistance * 0.5 then
                reachedPortRadius = true
                break
            end
        end
        assert(reachedPortRadius, "the ship should return by real movement into the port radius")
        local beforeReturn = runtime:GetShipPosition()
        assert(loop:ReturnToPort())
        local afterReturn = runtime:GetShipPosition()
        eq(afterReturn.x, beforeReturn.x)
        eq(afterReturn.y, beforeReturn.y)
        assert(math.sqrt((afterReturn.x - port.x)^2 + (afterReturn.y - port.y)^2) > 0.1,
            "ordinary return should not reset or teleport the ship onto the port")
        eq(runtime.movement.target, nil)
        eq(loop.inPort, true)
        eq(loop.player.day, dayBefore)
        eq(loop.player.stamina, 0)
        sameItems(inventory:GetItems(), itemsBefore)
    end)

    local passed = 0
    for _, result in ipairs(results) do
        if result.passed then passed = passed + 1 end
    end
    return { results = results, passed = passed, total = #results }
end

return Tests
