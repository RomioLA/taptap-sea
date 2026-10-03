local OceanConfig = require("Ocean.Config")
local Loop = require("Gameplay.Loop")

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

local function copyPoint(point)
    return { x = point.x, y = point.y }
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

local function portRuntime(distance, options)
    options = options or {}
    local runtime = {
        port = { x = 0, y = 0 },
        ship = { x = distance or 0, y = 0 },
        resetCalls = 0,
        clearCalls = 0,
        resetResult = options.resetResult,
        moveOnReset = options.moveOnReset,
    }
    if not options.missingPort then
        function runtime:GetPortPosition() return copyPoint(self.port) end
    end
    function runtime:GetShipPosition() return copyPoint(self.ship) end
    function runtime:ClearMovementTarget() self.clearCalls = self.clearCalls + 1 end
    if not options.missingReset then
        function runtime:ResetShipAtPort()
            self.resetCalls = self.resetCalls + 1
            if self.resetResult == false then return false, "test_reset_rejected" end
            if self.moveOnReset ~= false then self.ship = copyPoint(self.port) end
            return true
        end
    end
    return runtime
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("standalone gameplay keeps port rules usable without a sea runtime", function()
        local loop = newLoop()
        assert(loop:CanAccessPort())
        assert(loop:Depart())
        assert(loop:ReturnToPort())
        eq(loop.inPort, true)
    end)

    test("bound gameplay fails closed when the port position protocol is missing", function()
        local runtime = portRuntime(0, { missingPort = true })
        local loop = newLoop(runtime)
        local allowed, reason = loop:CanAccessPort()
        eq(allowed, false)
        eq(reason, "port_interface_unavailable")
        assert(loop:Depart())
        local returned, returnReason = loop:ReturnToPort()
        eq(returned, false)
        eq(returnReason, "port_interface_unavailable")
        eq(runtime.resetCalls, 0)
        eq(loop.inPort, false)
    end)

    test("ordinary return accepts exactly ten meters and never teleports", function()
        eq(OceanConfig.interaction.portDistance, 10)
        local runtime = portRuntime(OceanConfig.interaction.portDistance)
        local loop = newLoop(runtime)
        assert(loop:Depart())
        assert(loop:ReturnToPort())
        eq(loop.inPort, true)
        eq(runtime.ship.x, 10)
        eq(runtime.resetCalls, 0)
    end)

    test("ordinary return rejects just beyond ten meters without moving the ship", function()
        local distance = OceanConfig.interaction.portDistance + 0.001
        local runtime = portRuntime(distance)
        local loop = newLoop(runtime)
        assert(loop:Depart())
        local returned, reason = loop:ReturnToPort()
        eq(returned, false)
        eq(reason, "port_out_of_range")
        eq(loop.inPort, false)
        eq(runtime.ship.x, distance)
        eq(runtime.resetCalls, 0)
    end)

    test("shop and upgrade actions reject a ship outside the port radius atomically", function()
        local runtime = portRuntime(OceanConfig.interaction.portDistance + 0.001)
        local loop = newLoop(runtime)
        local inventory = loop.player.inventory
        assert(inventory:RestoreItems({ "sardine" }))
        loop.player.money = 5000
        local before = {
            money = loop.player.money,
            stock = loop:GetShopStock("bait"),
            items = inventory:GetItems(),
            revision = loop:GetCargoRevision(),
            inventoryLevel = inventory:GetLevel(),
            stamina = loop.player.stamina,
            maxStamina = loop.player.maxStamina,
            boatSpeedLevel = loop.player.boatSpeedLevel,
        }
        local actions = {
            function() return loop:Buy("bait") end,
            function() return loop:Sell(1, "sardine", before.revision) end,
            function() return loop:UpgradeInventory() end,
            function() return loop:UpgradeStamina() end,
            function() return loop:UpgradeBoatSpeed() end,
        }
        for _, action in ipairs(actions) do
            local accepted, reason = action()
            eq(accepted, false)
            eq(reason, "port_out_of_range")
        end
        eq(loop.player.money, before.money)
        eq(loop:GetShopStock("bait"), before.stock)
        eq(loop:GetCargoRevision(), before.revision)
        eq(inventory:GetLevel(), before.inventoryLevel)
        eq(loop.player.stamina, before.stamina)
        eq(loop.player.maxStamina, before.maxStamina)
        eq(loop.player.boatSpeedLevel, before.boatSpeedLevel)
        eq(inventory:GetItems()[1], "sardine")
        eq(#inventory:GetItems(), 1)
    end)

    test("port preparation requires reset support and verifies the resulting position", function()
        local missing = newLoop(portRuntime(30, { missingReset = true }))
        local prepared, reason = missing:PreparePort("forced_return")
        eq(prepared, false)
        eq(reason, "port_reset_unavailable")

        local rejectedRuntime = portRuntime(30, { resetResult = false })
        local rejected = newLoop(rejectedRuntime)
        local reset, resetReason = rejected:PreparePort("forced_return")
        eq(reset, false)
        eq(resetReason, "test_reset_rejected")
        eq(rejectedRuntime.ship.x, 30)

        local incorrectRuntime = portRuntime(30, { moveOnReset = false })
        local incorrect = newLoop(incorrectRuntime)
        local verified, verifyReason = incorrect:PreparePort("new_day")
        eq(verified, false)
        eq(verifyReason, "port_out_of_range")
        eq(incorrectRuntime.resetCalls, 1)

        local validRuntime = portRuntime(30)
        local valid = newLoop(validRuntime)
        assert(valid:PreparePort("forced_return"))
        eq(validRuntime.resetCalls, 1)
        eq(validRuntime.ship.x, validRuntime.port.x)
        eq(validRuntime.ship.y, validRuntime.port.y)
        eq(validRuntime.clearCalls, 1)
    end)

    local passed = 0
    for _, result in ipairs(results) do
        if result.passed then passed = passed + 1 end
    end
    return { results = results, passed = passed, total = #results }
end

return Tests
