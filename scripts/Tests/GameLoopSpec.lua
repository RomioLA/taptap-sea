-- 纯 Lua 验收：真实业务模块 + 可控云存档/世界交接 mock，不需要 GUI。
local Config = require("config.gameplay")
local Items = require("data.items")
local Player = require("Gameplay.PlayerState")
local Inventory = require("Gameplay.Inventory")
local Clock = require("Gameplay.GameClock")
local Loop = require("Gameplay.Loop")
local Persistence = require("Gameplay.Persistence")
local passed = 0

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function test(name, run)
    run()
    passed = passed + 1
    print("PASS " .. name)
end

local function newLoop(options)
    local store = { saves = {}, callbacks = {} }
    function store:Save(snapshot, done)
        self.saves[#self.saves + 1] = snapshot
        self.callbacks[#self.callbacks + 1] = done
    end
    function store:Load(done) done(true, self.loaded) end
    options = options or {}
    options.store = store
    return Loop.New(options), store
end

test("configuration values and four authoritative item definitions", function()
    eq(Config.initial.stamina, 100); eq(Config.initial.maxStamina, 100); eq(Config.initial.money, 100)
    eq(Config.stamina.fishingCost, 40); eq(Config.stamina.salvageCost, 40); eq(Config.stamina.sailingCost, 0)
    eq(Config.clock.daySec, 120); eq(Config.clock.nightSec, 60); eq(Config.clock.graceSec, 30)
    eq(Config.clock.forcedStaminaRatio, 0.5)
    for index, capacity in ipairs({5,10,15,20}) do eq(Config.inventory.capacities[index], capacity) end
    eq(Items.GetDefinition("apple").buyPrice, 30); eq(Items.GetDefinition("bait").buyPrice, 20)
    eq(Items.GetDefinition("sardine").sellPrice, 70); eq(Items.GetDefinition("tuna").sellPrice, 120)
    eq(Items.GetDefinition("small_fish"), nil); eq(Items.GetDefinition("big_fish"), nil)
end)

test("stamina guards, complete action cost and zero stamina return", function()
    local loop = newLoop()
    eq(loop.player.stamina, 100)
    assert(loop:Depart()); assert(loop:CompleteAction("fishing")); eq(loop.player.stamina, 60)
    assert(loop:CompleteAction("salvage")); eq(loop.player.stamina, 20)
    eq(loop:CanStartAction("fishing"),false)
    eq(loop:CompleteAction("fishing"), false); eq(loop.player.stamina, 20)
    assert(loop.player:ConsumeStamina(20)); eq(loop.player.stamina, 0)
    assert(loop:ReturnToPort()); eq(loop.player.stamina, 0)
    eq(loop.player:ConsumeStamina(-1), false); eq(loop.player:ConsumeStamina(0/0), false)
    eq(loop.player:RestoreStamina(-1), false)
end)

test("special events pause time and prevent starting full actions", function()
    local loop = newLoop(); assert(loop:Depart())
    loop.clock:Pause("special_event"); loop:Update(20); eq(loop.clock.elapsed,0)
    eq(loop:CanStartAction("fishing"),false); eq(loop:CompleteAction("salvage"),false)
    eq(loop.player.stamina,100); loop.clock:Resume("special_event")
    assert(loop:CanStartAction("fishing")); eq(loop.player.stamina,100)
    assert(loop:CompleteAction("fishing")); eq(loop.player.stamina,60)
end)

test("food use, cap and no elder stamina reward", function()
    local loop = newLoop()
    loop.player.stamina = 60
    assert(loop:UseItem(1)); eq(loop.player.stamina, 80)
    assert(loop.player.inventory:Add("apple")); loop.player.stamina = 90
    assert(loop:UseItem(2)); eq(loop.player.stamina, 100)
    assert(loop.player.inventory:Add("sardine")); loop.player.stamina = 0
    assert(loop:UseItem(2)); eq(loop.player.stamina, 10)
    assert(loop.player.inventory:Add("tuna")); assert(loop:UseItem(2)); eq(loop.player.stamina, 30)
    assert(loop.player.inventory:Add("apple")); assert(loop:SetElderOpen(true))
    assert(loop:GiveToElder(2)); eq(loop.player.stamina, 30); eq(loop.player.elder.lastGivenItemId, "apple")
end)

test("inventory one item per slot, capacity upgrades and defensive copies", function()
    local inventory = Inventory.New(1, {})
    eq(inventory:GetCapacity(), 5)
    for _ = 1, 5 do assert(inventory:Add("sardine")) end
    eq(#inventory:GetItems(), 5); eq(inventory:Add("tuna"), false)
    local snapshot = inventory:GetItems(); snapshot[1] = "tuna"
    eq(inventory:GetItems()[1], "sardine")
    eq(inventory:Remove(0), false); eq(inventory:Remove(1.5), false)
    assert(inventory:Upgrade()); eq(inventory:GetCapacity(), 10)
    assert(inventory:Upgrade()); eq(inventory:GetCapacity(), 15)
    assert(inventory:Upgrade()); eq(inventory:GetCapacity(), 20)
    eq(inventory:Upgrade(), false); eq(inventory:Add("unknown"), false)
end)

test("multi reason pauses and day night boundaries", function()
    local clock = Clock.New()
    clock:Update(120); eq(clock.phase, "night"); eq(clock.elapsed, 0)
    clock:Pause("inventory"); clock:Pause("elder"); clock:Update(25); eq(clock.elapsed, 0)
    clock:Resume("inventory"); clock:Update(10); eq(clock.elapsed, 0)
    clock:Resume("elder"); clock:Update(40); eq(clock.elapsed, 40)
    eq(clock:Update(20), true); eq(clock.exhausted, true); eq(clock:GetState().remaining, 0)
    eq(clock:Update(10), false)
end)

test("port pauses preserve elapsed and repeat departure", function()
    local loop = newLoop()
    loop:Update(50); eq(loop.clock.elapsed, 0)
    assert(loop:Depart()); loop:Update(70); assert(loop:ReturnToPort())
    loop:Update(999); eq(loop.clock.elapsed, 70)
    assert(loop:Depart()); loop:Update(10); eq(loop.clock.elapsed, 80)
    assert(loop:SetInventoryOpen(true)); assert(loop:SetElderOpen(true)); loop:Update(10)
    assert(loop:SetInventoryOpen(false)); loop:Update(10); eq(loop.clock.elapsed, 80)
    assert(loop:SetElderOpen(false)); loop:Update(10); eq(loop.clock.elapsed, 90)
end)

test("normal return penalties at 0 30 30.9 40 55 59.9", function()
    for _, pair in ipairs({{0,100},{30,100},{30.9,99.1},{40,90},{55,75},{59.9,70.1}}) do
        local loop, store = newLoop()
        assert(loop:Depart()); loop.clock:Seek("night", pair[1]); assert(loop:ReturnToPort())
        assert(loop:EndToday()); eq(#store.saves, 0)
        assert(loop:ConfirmSettlement()); eq(loop.player.stamina, pair[2]); eq(loop.player.day, 2)
        eq(#store.saves, 1); store.callbacks[1](true); eq(loop.saveStatus, "saved")
        eq(loop.clock.phase, "day"); assert(loop:Depart())
    end
end)

test("night 60 forced modal, proportional stamina and one settlement", function()
    local loop, store = newLoop()
    loop.player.maxStamina = 120
    assert(loop:Depart()); loop:Update(180)
    eq(loop.forcedReturnPending, true); eq(loop.lastMessage, "夜深了，你必须返港。")
    eq(loop:Depart(), false); eq(#store.saves, 0)
    assert(loop:ConfirmForcedReturn()); eq(loop.player.stamina, 60); eq(loop.player.day, 2)
    eq(#store.saves, 1); eq(loop:ConfirmForcedReturn(), false)
    store.callbacks[1](true); eq(loop.settlementPending, false)
end)

test("save failure retry freezes state and does not advance day twice", function()
    local loop, store = newLoop()
    assert(loop:EndToday()); assert(loop:ConfirmSettlement()); eq(loop:Buy("apple"), false)
    eq(loop:NewRun(), false); store.callbacks[1](false, "offline")
    eq(loop.saveStatus, "error"); eq(loop.player.day, 2); eq(loop:Depart(), false)
    assert(loop:ConfirmSettlement()); eq(loop.player.day, 2); eq(#store.saves, 2)
    eq(store.saves[1], store.saves[2]); store.callbacks[2](true)
    store.callbacks[2](true); eq(loop.player.day, 2)
end)

test("explicitly skipping a failed save releases one settlement without pretending to save", function()
    local days = {}
    local loop, store = newLoop({ onNewDay = function(day) days[#days + 1] = day end })
    eq(loop:ContinueWithoutSaving(), false)
    assert(loop:EndToday()); assert(loop:ConfirmSettlement())
    store.callbacks[1](false, "offline")
    local stamina, money, stock = loop.player.stamina, loop.player.money, loop:GetShopStock("apple")
    assert(loop:ContinueWithoutSaving())
    eq(loop.player.day, 2); eq(loop.player.stamina, stamina); eq(loop.player.money, money)
    eq(loop:GetShopStock("apple"), stock); eq(loop.saveStatus, "skipped")
    eq(loop.settlementPending, false); eq(loop.settlementApplied, false)
    eq(#store.saves, 1); eq(#days, 1); eq(days[1], 2)
    eq(loop:ContinueWithoutSaving(), false)
    store.callbacks[1](true)
    eq(loop.saveStatus, "skipped"); eq(#days, 1)
    assert(loop:Depart()); assert(loop:ReturnToPort()); assert(loop:EndToday())
    assert(loop:ConfirmSettlement()); store.callbacks[2](true)
    eq(loop.player.day, 3); eq(loop.saveStatus, "saved"); eq(#days, 2)
end)

test("a save retry in flight can be explicitly skipped and ignores its late callback", function()
    local loop, store = newLoop()
    assert(loop:EndToday()); assert(loop:ConfirmSettlement())
    store.callbacks[1](false, "offline")
    assert(loop:ConfirmSettlement())
    assert(loop:ContinueWithoutSaving())
    eq(loop.settlementPending, false)
    eq(loop.saveStatus, "skipped")
    store.callbacks[2](true)
    eq(loop.saveStatus, "skipped"); eq(loop.player.day, 2)
end)

test("transactions read item prices, reject invalid/full/sea without side effects", function()
    local loop, store = newLoop()
    assert(loop:Buy("apple")); eq(loop.player.money, 70)
    assert(loop:Buy("bait")); eq(loop.player.money, 50)
    assert(loop.player.inventory:Add("sardine")); eq(loop:Buy("apple"), false); eq(loop.player.money, 50)
    assert(loop:Sell(5)); eq(loop.player.money, 120)
    assert(loop.player.inventory:Add("tuna")); assert(loop:Sell(5)); eq(loop.player.money, 240)
    eq(loop:Sell(1), false); eq(loop:Buy("tuna"), false)
    assert(loop:Depart()); eq(loop:Buy("bait"), false); eq(loop:Sell(1), false)
    eq(#store.saves, 0)
end)

test("drop acceptance payloads and rejected/error receiver retains item", function()
    for _, id in ipairs({"apple","bait","sardine","tuna"}) do
        local request = {}
        local loop = newLoop({dropReceiver=function(payload) request = payload; return true end})
        while #loop.player.inventory:GetItems() > 0 do loop.player.inventory:Remove(1) end
        assert(loop.player.inventory:Add(id)); assert(loop:Depart())
        local ok, payload = loop:DropItem(1); assert(ok); eq(payload, request)
        local definition = Items.GetDefinition(id)
        eq(payload.itemId, id); eq(payload.category, definition.category)
        eq(payload.worldEffect, definition.worldEffect); eq(payload.lifetimeSec, 20)
        eq(#loop.player.inventory:GetItems(), 0); eq((payload --[[@as table]]).position, nil)
    end
    for _, receiver in ipairs({function() return false end,function() error("rejected") end}) do
        local loop = newLoop({dropReceiver=receiver}); assert(loop:Depart())
        eq(loop:DropItem(1), false); eq(#loop.player.inventory:GetItems(), 2)
    end
    local loop = newLoop(); assert(loop:Depart()); eq(loop:DropItem(1), false)
    eq(#loop.player.inventory:GetItems(), 2)
end)

test("new run resets gameplay and immediately saves its starting snapshot", function()
    local resetCount = 0
    local loop, store = newLoop({resetDynamicWorld=function() resetCount = resetCount+1 end})
    loop.player.money = 999; loop.player.maxStamina = 120; loop.player.stamina = 1
    loop.player:MarkRecognized("island"); loop.player.treasures.found = true
    loop.player.story.chapter = 3; loop.player.elder.lastGivenItemId = "bait"
    loop.player.inventory:Upgrade(); assert(loop:NewRun())
    eq(loop.player.money,100); eq(loop.player.maxStamina,100); eq(loop.player.stamina,100)
    eq(loop.player.inventory:GetCapacity(),5); eq(#loop.player.inventory:GetItems(),2)
    eq(loop.player:IsRecognized("island"),false); eq(loop.player.treasures.found,nil)
    eq(loop.player.treasures.scopeLens,false); eq(loop.player.story.chapter,nil)
    eq(loop.player.story.circle1B2.barrelStage,0); eq(loop.player.story.circle1B2.paperShown,false)
    eq(loop.player.elder.lastGivenItemId,nil); eq(loop.player.elder.circle1B2.applesGiven,0)
    eq(loop.player.elder.circle1B2.decision,"pending"); eq(resetCount,1)
    eq(#store.saves,1); eq(store.saves[1].day,1); eq(store.saves[1].money,100)
end)

test("snapshot round trip and invalid saves leave state intact", function()
    local player = Player.New(); player:MarkRecognized("port1"); player.inventory:Upgrade()
    player.treasures.found = true; player.story.chapter = 2; player.elder.lastGivenItemId = "apple"
    local snapshot = Persistence.Snapshot(player); local restored = assert(Persistence.Restore(snapshot))
    eq(restored:IsRecognized("port1"),true); eq(restored.inventory:GetCapacity(),10)
    eq(restored.story.chapter,2); eq(restored.elder.lastGivenItemId,"apple")
    snapshot.inventory[1] = "tuna"; eq(restored.inventory:GetItems()[1],"apple")
    snapshot.schemaVersion = 99; eq(Persistence.Restore(snapshot),nil)
    snapshot = Persistence.Snapshot(player); snapshot.inventory[1] = "unknown"; eq(Persistence.Restore(snapshot),nil)
    snapshot = Persistence.Snapshot(player); snapshot.stamina = math.huge; eq(Persistence.Restore(snapshot),nil)
end)

test("cloud callback mapping, timeout and duplicate completion", function()
    local cloud = {written={}}
    function cloud:Set(key,value,events) self.written={key=key,value=value}; events.ok(); events.error(1,"late") end
    function cloud:Get(key,events) events.ok({[key]=self.written.value}) end
    local backend = Persistence.Cloud(cloud); local completions = 0
    local snapshot = Persistence.Snapshot(Player.New())
    backend:Save(snapshot,function(ok) assert(ok); completions=completions+1 end)
    eq(completions,1); eq(cloud.written.key,Config.persistence.key)
    backend:Load(function(ok,data) assert(ok); eq(data.day,1) end)
    function cloud:Set(_,_,events) events.timeout() end
    backend:Save(snapshot,function(ok,err) eq(ok,false); eq(err,"cloud_timeout") end)
end)

test("load success failure pending lock and late callbacks", function()
    local loop, store = newLoop()
    local callback
    function store:Load(done) callback = done end
    assert(loop:LoadSaved()); eq(loop:Depart(),false); eq(loop:Buy("apple"),false)
    local savedPlayer = Player.New(); savedPlayer.money = 333; savedPlayer.day = 8
    savedPlayer:MarkRecognized("saved_island")
    callback(true,Persistence.Snapshot(savedPlayer)); eq(loop.player.money,333); eq(loop.player.day,8)
    eq(loop.player:IsRecognized("saved_island"),true); eq(loop.loading,false)
    assert(loop:LoadSaved()); callback(false,"offline"); eq(loop.player.money,333)
    assert(loop:LoadSaved()); callback(true,{schemaVersion=99}); eq(loop.player.money,333)
    eq(loop.loading,false); assert(loop:Depart()); eq(loop:LoadSaved(),false)
    eq(#store.saves,0)
end)

test("drop callback reentry and elder rejection have no extra side effects", function()
    local loop
    loop = newLoop({dropReceiver=function()
        eq(loop:DropItem(1),false); eq(loop:NewRun(),false); eq(loop:ReturnToPort(),false)
        return true
    end})
    assert(loop:Depart()); assert(loop:DropItem(1)); eq(#loop.player.inventory:GetItems(),1)
    loop = newLoop({elderReceiver=function() return false end})
    assert(loop:SetElderOpen(true)); eq(loop:GiveToElder(1),false)
    eq(#loop.player.inventory:GetItems(),2); eq(loop.player.stamina,100)
end)

test("new day hooks fire once after successful save, never on failed retry", function()
    local days = {}
    local loop,store = newLoop({onNewDay=function(day) days[#days+1]=day end})
    assert(loop:EndToday()); assert(loop:ConfirmSettlement()); eq(#days,0)
    store.callbacks[1](false,"offline"); eq(#days,0)
    assert(loop:ConfirmSettlement()); store.callbacks[2](true); eq(#days,1); eq(days[1],2)
    store.callbacks[2](true); eq(#days,1)
end)

test("clock debug bounds scales sorted reasons and invalid inputs", function()
    local clock=Clock.New()
    clock:SetTimeScale(5); clock:Update(10); eq(clock.elapsed,50)
    clock:SetTimeScale(20); clock:Update(3.5); eq(clock.phase,"night"); eq(clock.elapsed,0)
    clock:Pause("z"); clock:Pause("a"); eq(table.concat(clock:GetPauseReasons(),","),"a,z")
    local reasons=clock:GetPauseReasons(); reasons[1]="other"; eq(clock:GetPauseReasons()[1],"a")
    clock:Seek("night",55); eq(clock:IsPaused(),true)
    eq(pcall(clock.Seek,clock,"night",61),false); eq(clock.elapsed,55)
    eq(pcall(clock.Update,clock,0/0),false); eq(pcall(clock.SetTimeScale,clock,2),false)
    clock:Reset(); eq(clock.timeScale,1); eq(clock:IsPaused(),false)
end)

test("only confirmed daily settlement writes, no manual sea save API", function()
    local loop, store = newLoop()
    assert(loop:Buy("apple")); assert(loop:SetElderOpen(true)); assert(loop:GiveToElder(1))
    assert(loop:SetElderOpen(false)); assert(loop:Depart()); loop.player:MarkRecognized("island")
    loop.player:ConsumeStamina(40); loop:Update(10)
    eq(#store.saves,0); eq((loop --[[@as table]]).Save,nil); eq(loop:EndToday(),false)
end)

print("GAME_LOOP_SPEC_PASS " .. passed)
return passed
