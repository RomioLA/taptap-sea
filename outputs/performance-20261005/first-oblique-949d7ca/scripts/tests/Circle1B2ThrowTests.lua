-- Circle 1B2 throw-selection and world handoff protocol tests.
local Flow = require("tests.Circle1BFishingFlowTests")
local OceanConfig = require("Ocean.Config")
local Items = require("data.items")

local Tests = {}

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function items(actual, expected, label)
    Flow.AssertItems(actual, expected, label)
end

local function atSea(settings)
    local fixture = Flow.Fixture(settings)
    assert(fixture.loop:Depart())
    return fixture
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("selected inventory item is thrown at the inclusive twelve-meter boundary", function()
        local f = atSea({ items = { "apple", "bait" } })
        assert(f.loop:BeginThrowItem(2))
        local selected = assert(f.loop:GetThrowSelection())
        eq(selected.index, 2)
        eq(selected.itemId, "bait")

        local consumed = f.bridge:OnSeaPointer({
            x = OceanConfig.interaction.maxThrowDistance,
            y = 0,
        })
        eq(consumed, true, "throw pointer is consumed by the throw flow")
        eq(f.loop:GetThrowSelection(), nil)
        items(f.loop.player.inventory:GetItems(), { "apple" }, "only selected item is removed")

        local dropped = assert(f.runtime.droppedItems[1])
        eq(dropped.itemId, "bait")
        eq(dropped.worldEffect, "ATTRACT_SMALL_FISH")
        eq(dropped.lifetimeSec, 20)
        eq(dropped.age, 0)
        eq(dropped.position.x, OceanConfig.interaction.maxThrowDistance)
        eq(dropped.position.y, 0)
    end)

    test("out-of-range throw attempts consume the pointer without moving or losing the selection", function()
        local f = atSea({ items = { "apple", "bait" }, movementTarget = { x = 3, y = 4 } })
        assert(f.loop:BeginThrowItem(2))
        local selected = assert(f.loop:GetThrowSelection())
        local before = f.loop.player.inventory:GetItems()

        local consumed = f.bridge:OnSeaPointer({
            x = OceanConfig.interaction.maxThrowDistance + 0.01,
            y = 0,
        })
        eq(consumed, true, "failed throw still owns this pointer input")
        eq(f.runtime.movementTarget, nil, "throw pointer must not become a navigation target")
        eq(f.loop:GetThrowSelection().itemId, selected.itemId)
        eq(f.loop:GetThrowSelection().index, selected.index)
        items(f.loop.player.inventory:GetItems(), before, "out-of-range attempt keeps cargo")
        eq(#f.runtime.droppedItems, 0)
    end)

    test("receiver rejection rolls back cargo while consuming the throw pointer", function()
        local f = atSea({
            items = { "apple", "bait" },
            dropReceiver = function() return false end,
        })
        assert(f.loop:BeginThrowItem(2))
        local before = f.loop.player.inventory:GetItems()

        local consumed = f.bridge:OnSeaPointer({ x = 4, y = 0 })
        eq(consumed, true, "rejected drop still consumes the throw pointer")
        items(f.loop.player.inventory:GetItems(), before, "rejected handoff restores cargo")
        eq(f.loop:GetThrowSelection().itemId, "bait")
        eq(#f.runtime.droppedItems, 1)
        assert(f.runtime.droppedItems[1].removed, "rejected world entity must be removed")
        eq(f.runtime.droppedItems[1].removeReason, "rejected")
    end)

    test("ordinary sea pointers pass through without creating a drop target", function()
        local f = atSea()
        eq(f.loop.actions:GetDropTarget(), nil)
        local consumed = f.bridge:OnSeaPointer({ x = 3, y = 4 })
        eq(consumed, false, "ordinary navigation pointer is not consumed by the bridge")
        eq(f.loop.actions:GetDropTarget(), nil, "navigation click must not create a drop target")
    end)

    test("all four item payloads preserve their configured world effect and twenty-second lifetime", function()
        local wanted = { "apple", "bait", "sardine", "tuna" }
        local f = atSea({ items = wanted })

        for _, itemId in ipairs(wanted) do
            assert(f.loop:BeginThrowItem(1))
            local consumed = f.bridge:OnSeaPointer({ x = #f.runtime.droppedItems + 1, y = 0 })
            eq(consumed, true, itemId .. " throw pointer consumed")
            local dropped = assert(f.runtime.droppedItems[#f.runtime.droppedItems], itemId .. " was handed to A")
            local definition = assert(Items.GetDefinition(itemId))
            eq(dropped.itemId, itemId)
            eq(dropped.worldEffect, definition.worldEffect, itemId .. " world effect")
            eq(dropped.lifetimeSec, definition.lifetimeSec, itemId .. " lifetime")
            eq(dropped.lifetimeSec, 20, itemId .. " configured lifetime is twenty seconds")
            eq(dropped.age, 0, itemId .. " starts at age zero")
        end

        items(f.loop.player.inventory:GetItems(), {}, "all requested cargo was thrown once")
    end)

    return { results = results }
end

return Tests
