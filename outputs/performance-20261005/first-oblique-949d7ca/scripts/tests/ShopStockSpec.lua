local Config = require("config.gameplay")
local Loop = require("Gameplay.Loop")
local Persistence = require("Gameplay.Persistence")
local passed = 0
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function test(name,fn) fn(); passed=passed+1; print("PASS stock "..name) end
local function newLoop(options)
    local store = { writes=0 }
    function store:Save(data,done) self.writes=self.writes+1; self.data=data; done(true) end
    function store:Load(done) done(true,self.data) end
    options=options or {}; options.store=store
    return Loop.New(options),store
end
for _, itemId in ipairs({"apple","bait"}) do
    test(itemId.."-initial-stock2",function()
        local l=newLoop(); eq(Config.shop.dailyStock[itemId],2); eq(l:GetShopStock(itemId),2)
    end)
    test(itemId.."-third-buy-rejected-without-charge",function()
        local l=newLoop(); l.player.money=1000
        assert(l:Buy(itemId)); assert(l:Buy(itemId)); eq(l:GetShopStock(itemId),0)
        local money,count=l.player.money,#l.player.inventory:GetItems()
        local ok,reason=l:Buy(itemId); eq(ok,false); eq(reason,"shop_sold_out")
        eq(l.player.money,money); eq(#l.player.inventory:GetItems(),count); eq(l:GetShopStock(itemId),0)
    end)
    test(itemId.."-new-day-restocks2",function()
        local l=newLoop(); l.player.money=1000
        assert(l:Buy(itemId)); assert(l:Buy(itemId)); eq(l:GetShopStock(itemId),0)
        assert(l:EndToday()); assert(l:ConfirmSettlement()); eq(l.player.day,2); eq(l:GetShopStock(itemId),2)
    end)
end
test("full-inventory-no-money-or-stock-loss",function()
    for _, itemId in ipairs({"apple","bait"}) do
        local l=newLoop()
        while l.player.inventory:HasSpace() do assert(l.player.inventory:Add("sardine")) end
        local ok,reason=l:Buy(itemId); eq(ok,false); eq(reason,"inventory_full")
        eq(l.player.money,100); eq(l:GetShopStock(itemId),2)
    end
end)
test("insufficient-money-sea-and-busy-no-stock-loss",function()
    local l=newLoop(); l.player.money=0
    eq(l:Buy("apple"),false); eq(l:GetShopStock("apple"),2)
    l.player.money=100; assert(l:Depart()); eq(l:Buy("bait"),false); eq(l:GetShopStock("bait"),2)
    assert(l:ReturnToPort()); l.loading=true; eq(l:Buy("apple"),false); eq(l:GetShopStock("apple"),2)
end)
test("stock-does-not-reset-on-repeat-port-or-dialog",function()
    local l=newLoop(); assert(l:Buy("apple")); eq(l:GetShopStock("apple"),1)
    assert(l:Depart()); assert(l:ReturnToPort()); assert(l:SetInventoryOpen(true)); assert(l:SetInventoryOpen(false))
    assert(l:SetElderOpen(true)); assert(l:SetElderOpen(false)); eq(l:GetShopStock("apple"),1)
end)
test("stock-independent-of-holding-and-apple-use",function()
    local l=newLoop(); l.player.money=1000
    assert(l:UpgradeInventory()); l.player.money=1000
    assert(l:Buy("apple")); assert(l:Buy("apple")); eq(l:GetShopStock("apple"),0)
    assert(l.player.inventory:Add("apple")) -- 其他来源可以继续获得。
    l.player.stamina=0
    assert(l:UseItem(1)); assert(l:UseItem(2)); assert(l:UseItem(2)); assert(l:UseItem(2))
    eq(l.player.stamina,80); eq(l:GetShopStock("apple"),0) -- 可吃超过两苹果。
end)
test("drop-world-rejection-keeps-inventory",function()
    local l=newLoop({dropReceiver=function() return false end}); assert(l:Depart())
    local count=#l.player.inventory:GetItems(); eq(l:DropItem(1),false)
    eq(#l.player.inventory:GetItems(),count); eq(l.player.inventory:GetItems()[1],"apple")
end)
test("fishing4sec-clock-runs-empty-catch-free",function()
    local l=newLoop(); assert(l:Depart()); assert(l:CanStartAction("fishing"))
    eq(l.clock:IsPaused(),false); l:Update(4); eq(l.clock.elapsed,4); eq(l.player.stamina,100)
    assert(l:CompleteFishing(0)); eq(l.player.stamina,100); eq(l.clock:IsPaused(),false)
    l:Update(4); eq(l.clock.elapsed,8); eq(l.player.stamina,100)
end)
test("new-run-and-successful-day-snapshot-load-restock",function()
    local l,store=newLoop(); assert(l:Buy("apple")); assert(l:EndToday()); assert(l:ConfirmSettlement())
    assert(l:Buy("apple")); eq(l:GetShopStock("apple"),1)
    assert(l:LoadSaved()); eq(l:GetShopStock("apple"),2)
    assert(l:Buy("bait")); assert(l:NewRun()); eq(l:GetShopStock("bait"),2); eq(l:GetShopStock("apple"),2)
    eq(store.writes,2); eq(store.data.shopStock,nil); eq(store.data.schemaVersion,Config.persistence.schemaVersion)
end)
test("invalid-load-keeps-current-stock",function()
    local l,store=newLoop(); assert(l:Buy("apple"))
    store.data=Persistence.Snapshot(l.player); store.data.inventoryCapacity=nil
    local calls=0; assert(l:LoadSaved(function(ok) eq(ok,false); calls=calls+1 end))
    eq(calls,1); eq(l:GetShopStock("apple"),1)
end)
test("save-retry-does-not-repeat-day-or-restock",function()
    local l,store=newLoop(); l.player.money=1000
    function store:Save(data,done) self.data=data; self.done=done end
    assert(l:Buy("apple")); assert(l:Buy("apple")); assert(l:EndToday()); assert(l:ConfirmSettlement())
    eq(l.player.day,2); eq(l:GetShopStock("apple"),2); store.done(false,"offline")
    eq(l:Buy("apple"),false); assert(l:ConfirmSettlement()); store.done(true)
    assert(l:Buy("apple")); eq(l:GetShopStock("apple"),1)
    store.done(true); eq(l:GetShopStock("apple"),1); eq(l.player.day,2)
end)
print("SHOP_STOCK_SPEC_PASS "..passed)
