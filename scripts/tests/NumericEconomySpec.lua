local Config = require("config.gameplay")
local Items = require("data.items")
local Loop = require("Gameplay.Loop")
local Persistence = require("Gameplay.Persistence")
local passed = 0
local function eq(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function test(name, fn) fn(); passed = passed + 1; print("PASS numeric " .. name) end
local function newLoop()
    local store = { writes = 0 }
    function store:Save(data, done) self.writes = self.writes + 1; self.data = data; done(true) end
    function store:Load(done) done(true, self.data) end
    return Loop.New({store = store}), store
end

test("stamina100-to160-cost400", function()
    local l = newLoop(); l.player.money = 1000
    assert(l:UpgradeStamina()); eq(l.player.money, 600)
    eq(l.player.maxStamina, 160); eq(l.player.stamina, 160)
end)
test("stamina160-to200-cost600", function()
    local l = newLoop(); l.player.money = 1000
    assert(l:UpgradeStamina()); assert(l:UpgradeStamina())
    eq(l.player.money, 0); eq(l.player.stamina, 200); eq(l.player.maxStamina, 200)
end)
test("upgrade-preserves-missing-stamina", function()
    local l = newLoop(); l.player.money = 1000; l.player.stamina = 20
    assert(l:UpgradeStamina()); eq(l.player.stamina, 80)
    assert(l:UpgradeStamina()); eq(l.player.stamina, 120)
end)
for _, case in ipairs({{1,5,10,300}, {2,10,15,600}, {3,15,20,900}}) do
    test("inventory-transition-" .. case[1], function()
        local l = newLoop(); l.player.money = 2000
        for _ = 1, case[1] - 1 do assert(l.player.inventory:Upgrade()) end
        eq(l.player.inventory:GetCapacity(), case[2])
        assert(l:UpgradeInventory()); eq(l.player.inventory:GetCapacity(), case[3])
        eq(l.player.money, 2000-case[4]); eq(#l.player.inventory:GetItems(), 2)
    end)
end
for _, case in ipairs({{1,9,12,350}, {2,12,16,750}}) do
    test("boat-speed-transition-" .. case[1], function()
        local l = newLoop(); l.player.money = 1100; l.player.boatSpeedLevel = case[1]
        eq(Config.upgrades.boatSpeed.metersPerSec[l.player.boatSpeedLevel], case[2])
        assert(l:UpgradeBoatSpeed()); eq(l.player.money, 1100-case[4])
        eq(Config.upgrades.boatSpeed.metersPerSec[l.player.boatSpeedLevel], case[3])
    end)
end
for _, case in ipairs({{"apple",30,0,20}, {"bait",20,0,0}, {"sardine",false,70,10}, {"tuna",false,120,20}}) do
    test("item-values-" .. case[1], function()
        local d = assert(Items.GetDefinition(case[1]))
        eq(d.buyPrice or false, case[2]); eq(d.sellPrice, case[3]); eq(d.heal, case[4]); eq(d.lifetimeSec, 20)
    end)
end
test("standalone-empty-net-is-free-and-world-bound-direct-completion-is-rejected", function()
    local l = newLoop(); assert(l:Depart())
    local count = #l.player.inventory:GetItems()
    assert(l:CompleteFishing(0)); eq(l.player.stamina,100)
    eq(#l.player.inventory:GetItems(),count)
    eq(l:CompleteFishing(2),false); eq(l.player.stamina,100)
    assert(l:CompleteFishing(1)); eq(l.player.stamina,60)
    assert(l:CompleteFishing(0)); eq(l.player.stamina,60)

    local worldBound = newLoop(); worldBound:EnableWorldActions(); assert(worldBound:Depart())
    eq(worldBound:CompleteFishing(0),false)
    eq(worldBound:CompleteFishing(1),false)
    eq(worldBound.player.stamina,100)
end)
test("free-interactions-no-save-no-player-mutation", function()
    local l, store = newLoop()
    for _, kind in ipairs({"observation","discovery","dialogue","information","elder_dialogue"}) do
        assert(l:InspectEvent(kind)); eq(l.player.stamina,100); eq(l.player.money,100)
    end
    eq(l:InspectEvent("operation"),false); eq(store.writes,0)
end)
test("event-operation-cost40-on-explicit-completion", function()
    local l = newLoop(); assert(l:Depart()); l.clock:Pause("special_event")
    assert(l:InspectEvent("discovery")); assert(l:CanStartEventOperation()); eq(l.player.stamina,100)
    assert(l:CompleteEventOperation()); eq(l.player.stamina,60)
    assert(l:CompleteEventOperation()); eq(l.player.stamina,20)
    eq(l:CanStartEventOperation(),false); eq(l:CompleteEventOperation(),false)
    eq(l.player.stamina,20); eq(l.clock.pauseReasons.special_event,true)
end)
test("no-daily-fishing-limit-and-food-action-math", function()
    for _, case in ipairs({{100,0,2},{100,1,3},{160,0,4},{200,0,5},{200,2,6}}) do
        local l = newLoop(); l.player.maxStamina = case[1]; l.player.stamina = case[1]
        for _ = 1,case[2] do assert(l.player.inventory:Add("apple")) end
        assert(l:Depart())
        local actions = 0
        while l:CanStartAction("fishing") do assert(l:CompleteFishing(1)); actions = actions + 1 end
        for _ = 1,case[2] do
            -- 食物在消耗后恢复，不突破上限；初始苹果用于其中一次。
            assert(l:UseItem(1))
            if l:CanStartAction("fishing") then assert(l:CompleteFishing(1)); actions = actions + 1 end
            -- 下一次苹果位于初始鱼饵之后。
            if case[2] > 1 and l.player.inventory:GetItems()[1] == "bait" then
                assert(l.player.inventory:Remove(1))
            end
        end
        eq(actions,case[3])
    end
    eq((Config --[[@as table]]).dailyFishingLimit,nil)
end)
test("single-config-prices-and-total-cost3900", function()
    local l = newLoop(); l.player.money = 3900
    for _ = 1,2 do assert(l:UpgradeStamina()) end
    for _ = 1,3 do assert(l:UpgradeInventory()) end
    for _ = 1,2 do assert(l:UpgradeBoatSpeed()) end
    eq(l.player.money,0)
    for _, method in ipairs({"UpgradeStamina","UpgradeInventory","UpgradeBoatSpeed"}) do
        local upgrade = l[method] --[[@as fun(loop: GameplayLoop): boolean]]
        eq(upgrade(l),false); eq(l.player.money,0)
    end
    -- 改同一配置的价格，交易必须即时读取；恢复配置避免污染后续测试。
    l = newLoop(); local original = Config.upgrades.stamina.prices[1]
    Config.upgrades.stamina.prices[1] = 1
    local ok = l:UpgradeStamina(); Config.upgrades.stamina.prices[1] = original
    assert(ok); eq(l.player.money,99)
end)
test("forced-night60-proportional160-and200", function()
    for _, maximum in ipairs({160,200}) do
        local l = newLoop(); l.player.maxStamina = maximum; l.player.stamina = maximum
        assert(l:Depart()); l:Update(Config.clock.daySec+Config.clock.nightSec)
        assert(l.forcedReturnPending); assert(l:ConfirmForcedReturn())
        eq(l.player.stamina,maximum/2)
    end
end)
test("upgrade-rejections-atomic-sea-busy-and-insufficient", function()
    for _, method in ipairs({"UpgradeStamina","UpgradeInventory","UpgradeBoatSpeed"}) do
        local l = newLoop()
        local upgrade = l[method] --[[@as fun(loop: GameplayLoop): boolean]]
        eq(upgrade(l),false); eq(l.player.money,100); eq(l.player.maxStamina,100)
        eq(l.player.inventory:GetLevel(),1); eq(l.player.boatSpeedLevel,1)
        l.player.money = 4000; assert(l:Depart()); eq(upgrade(l),false); eq(l.player.money,4000)
        assert(l:ReturnToPort()); l.loading = true; eq(upgrade(l),false); eq(l.player.money,4000)
    end
end)
test("persistence-levels-legacy-validation-and-new-run-reset", function()
    local l, store = newLoop(); l.player.money = 3900
    assert(l:UpgradeStamina()); assert(l:UpgradeInventory()); assert(l:UpgradeBoatSpeed())
    eq(store.writes,0); assert(l:EndToday()); assert(l:ConfirmSettlement()); eq(store.writes,1)
    local restored = assert(Persistence.Restore(store.data))
    eq(restored.maxStamina,160); eq(restored.boatSpeedLevel,2); eq(restored.inventory:GetCapacity(),10)
    assert(l:NewRun()); eq(l.player.boatSpeedLevel,1); eq(l.player.maxStamina,100)
    eq(l.player.inventory:GetCapacity(),5); eq(l.player.money,100); eq(store.writes,2)
    assert(l:LoadSaved()); eq(l.player.boatSpeedLevel,1); eq(l:GetStaminaLevel(),1)
    store.data.boatSpeedLevel = nil; eq(assert(Persistence.Restore(store.data)).boatSpeedLevel,1)
    for _, level in ipairs({0,99,"2",true,1.5,math.huge,0/0}) do
        store.data.boatSpeedLevel = level
        local safe, player = pcall(Persistence.Restore,store.data); eq(safe,true); eq(player,nil)
    end
end)
test("balance-model-references-not-runtime-quotas", function()
    eq(7*(Config.clock.daySec+Config.clock.nightSec)/60,21)
    eq(21*Items.GetDefinition("sardine").sellPrice+9*Items.GetDefinition("tuna").sellPrice,2550)
    local cost = 2*Items.GetDefinition("apple").buyPrice
    eq(cost,60); eq(Items.GetDefinition("sardine").sellPrice-cost,10)
    eq(Items.GetDefinition("tuna").sellPrice-cost,60)
end)
print("NUMERIC_ECONOMY_SPEC_PASS " .. passed)
