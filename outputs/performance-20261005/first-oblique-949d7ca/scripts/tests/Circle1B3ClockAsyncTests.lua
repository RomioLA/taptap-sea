-- Boundary and callback fault injection. No engine window or real cloud calls.
local Loop = require("Gameplay.Loop")
local Persistence = require("Gameplay.Persistence")
local Flow = require("tests.Circle1BFishingFlowTests")
local Tests = {}

local function fixture(options)
    local store = { saves = {}, callbacks = {}, loads = {} }
    function store:Save(snapshot, done)
        self.saves[#self.saves + 1] = snapshot
        self.callbacks[#self.callbacks + 1] = done
    end
    function store:Load(done) self.loads[#self.loads + 1] = done end
    options = options or {}
    options.store = store
    return Loop.New(options), store
end

local function settle(loop)
    assert(loop:EndToday())
    assert(loop:ConfirmSettlement())
end

function Tests.Run()
    local results = {}
    local function check(name, action)
        local ok, err = xpcall(action, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end
    check("late return formula keeps fractional seconds for every confirmed maximum", function()
        for _, maximum in ipairs({100, 160, 200}) do
            for _, seconds in ipairs({0, 30, 30.001, 59.999}) do
                local loop = fixture()
                loop.player.maxStamina = maximum
                assert(loop:Depart())
                loop.clock:Seek("night", seconds)
                local expected = math.max(0, maximum - math.max(0, seconds - 30))
                assert(math.abs(loop:GetNextDayStamina(false) - expected) < 1e-9)
            end
            local loop = fixture()
            loop.player.maxStamina = maximum
            assert(loop:GetNextDayStamina(true) == math.floor(maximum * 0.5))
        end
    end)
    check("day-night warning uses the existing transition only", function()
        local loop = fixture()
        assert(loop:Depart()); loop:Update(119.9)
        assert(not loop.lastMessage:find("黄昏", 1, true))
        loop:Update(0.1)
        assert(loop.clock.phase == "night" and loop.lastMessage:find("黄昏", 1, true))
        assert(loop.lastMessage:find("30", 1, true))
    end)
    check("night boundary cancels locked cast and physically returns without refreshing fish", function()
        local env = Flow.Fixture()
        function env.runtime:GetPortPosition() return {x=0,y=0} end
        function env.runtime:ResetShipAtPort()
            self.ship.position = {x=0,y=0}; self:ClearMovementTarget(); return true
        end
        assert(env.loop:Depart())
        env.runtime.ship.position = {x=25,y=0}
        env.runtime:spawnFish("sardine", {x=25,y=0})
        env.loop.clock:Seek("night", 59)
        local token = env.bridge:BeginFishing({x=25,y=0}); assert(token)
        env.bridge:Update(0.5)
        assert(env.runtime.lockCalls == 1)
        env.bridge:Update(0.5)
        assert(env.loop.forcedReturnPending and env.loop.inPort)
        assert(env.runtime:GetShipPosition().x == 0 and env.runtime.refreshCalls == 0)
        assert(env.loop.player.stamina == 100 and env.runtime.unlockCalls == 1)
        assert(env.loop:GetFishingState().state == "cancelled")
    end)
    check("missing forced-return interface never grants port access", function()
        local env = Flow.Fixture()
        env.runtime.ResetShipAtPort = false
        assert(env.loop:Depart()); env.loop.clock:Seek("night",60); env.loop:RefreshClockStatus()
        assert(env.loop.forcedReturnPending and not env.loop.inPort)
        assert(not env.loop:ConfirmForcedReturn() and env.loop.player.day == 1)
    end)
    check("large frame preserves fishing completed before night end", function()
        local env = Flow.Fixture()
        assert(env.loop:Depart())
        env.runtime:spawnFish("sardine", env.runtime:GetShipPosition())
        env.loop.clock:Seek("night",55)
        assert(env.bridge:BeginFishing(env.runtime:GetShipPosition()))
        env.bridge:Update(5)
        assert(env.loop.forcedReturnPending)
        assert(env.loop.player.inventory:GetItems()[3] == "sardine")
        assert(env.loop:GetFishingState().state ~= "cancelled")
    end)
    check("fishing completion exactly at night end cancels without charging", function()
        local env = Flow.Fixture()
        assert(env.loop:Depart())
        local fish = env.runtime:spawnFish("sardine", env.runtime:GetShipPosition())
        env.loop.clock:Seek("night",56)
        local stamina = env.loop.player.stamina
        assert(env.bridge:BeginFishing(env.runtime:GetShipPosition()))
        env.bridge:Update(4)
        assert(env.loop.forcedReturnPending and env.loop:GetFishingState().state == "cancelled")
        assert(env.loop.player.stamina == stamina and #env.loop.player.inventory:GetItems() == 2)
        assert(env.runtime.world:GetEntity(fish.id) and env.runtime.unlockCalls == 1)
    end)
    check("saving rejects duplicate confirmation and explicit skip ignores late callbacks", function()
        local days = {}; local loop, store = fixture({onNewDay=function(day) days[#days+1]=day end})
        settle(loop); assert(loop.player.day == 2 and loop.busy)
        assert(not loop:ConfirmSettlement() and loop:ContinueWithoutSaving())
        store.callbacks[1](true); store.callbacks[1](true); store.callbacks[1](false,"late")
        assert(loop.player.day == 2 and #days == 1 and loop.saveStatus == "skipped")
    end)
    check("timeout then retry ignores late old success", function()
        local days = {}; local loop, store = fixture({onNewDay=function(day) days[#days+1]=day end})
        settle(loop); store.callbacks[1](false,"timeout")
        assert(loop:ConfirmSettlement()); store.callbacks[1](true)
        assert(loop.busy and loop.settlementPending and #days == 0)
        store.callbacks[2](true); assert(#days == 1 and #store.saves == 2 and loop.player.day == 2)
    end)
    check("explicit abandon keeps old snapshot and next day still saves", function()
        local loop, store = fixture(); settle(loop); store.callbacks[1](false,"offline")
        assert(loop:ContinueWithoutSaving()); assert(not loop:ContinueWithoutSaving())
        assert(loop.player.day == 2 and loop.saveStatus == "skipped")
        settle(loop); assert(#store.saves == 2); store.callbacks[2](true)
        assert(loop.player.day == 3 and loop.saveStatus == "saved")
    end)
    check("many failed days do not duplicate dates stock or stamina", function()
        local count = 0; local loop, store = fixture({onNewDay=function() count=count+1 end})
        for day=1,5 do
            settle(loop); store.callbacks[day](false,"offline")
            assert(loop.player.day == day+1 and loop.player.stamina == 100)
            assert(loop:GetShopStock("apple") == 2)
            assert(loop:ContinueWithoutSaving()); store.callbacks[day](true)
            assert(loop.player.day == day+1 and count == day)
        end
    end)
    check("synchronous store rejection completes error rather than staying saving", function()
        local loop = Loop.New({store={Save=function() return false,"offline" end}})
        settle(loop); assert(not loop.busy and loop.saveStatus == "error" and loop.settlementPending)
    end)
    check("close invalidates queued save and load callbacks", function()
        local loop, store = fixture(); settle(loop); assert(loop:Close()); store.callbacks[1](true)
        assert(loop.closed and loop.settlementPending and loop.saveStatus == "saving")
        local other, reads = fixture(); assert(other:LoadSaved()); local oldPlayer = other.player
        assert(other:Close()); reads.loads[1](true,Persistence.Snapshot(Loop.New({}).player))
        assert(other.player == oldPlayer and other.closed)
    end)
    check("load states distinguish missing corrupt failure and retry", function()
        local loop, store = fixture(); loop:BeginEntry(); assert(loop:LoadSaved())
        store.loads[1](true,nil); assert(loop.loadStatus == "empty" and loop.entryPending)
        assert(loop:LoadSaved()); store.loads[2](false,"offline"); assert(loop.loadStatus == "error")
        assert(loop:LoadSaved()); store.loads[3](true,{schemaVersion=1}); assert(loop.loadStatus == "error")
        local saved = Persistence.Snapshot(Loop.New({}).player)
        assert(loop:LoadSaved()); store.loads[4](true,saved)
        assert(loop.loadStatus == "loaded" and not loop.entryPending and loop.inPort)
        store.loads[2](true,saved); assert(loop.loadStatus == "loaded")
    end)
    check("legitimate restored progress retains containers and rejects old reads", function()
        local source = Loop.New({}); assert(source:RecognizeLocation("driftwood_barrel"))
        assert(source:Buy("apple")); local saved = Persistence.Snapshot(source.player)
        local loop, store = fixture(); assert(loop:LoadSaved()); store.loads[1](true,saved)
        assert(loop.player:IsRecognized("driftwood_barrel")); assert(#loop.player.inventory:GetItems()==3)
        assert(loop:NewRun()); store.loads[1](true,saved)
        assert(not loop.player:IsRecognized("driftwood_barrel"))
    end)
    check("new run immediately writes a reset snapshot before releasing the entry pause", function()
        local old = Loop.New({}); old.player.day=5
        require("Gameplay.Circle1B2Progress").OnDayStarted(old.player)
        local saved = Persistence.Snapshot(old.player)
        local store = { data=saved, saves={}, callbacks={} }
        function store:Load(done) done(self.data~=nil,self.data) end
        function store:Save(snapshot,done)
            self.saves[#self.saves+1]=snapshot
            self.callbacks[#self.callbacks+1]=done
        end
        local loop=Loop.New({store=store}); assert(loop:NewRun())
        assert(loop.player.day==1 and loop.entryPending and loop.initialSaveStatus=="saving")
        assert(#store.saves==1 and store.saves[1].day==1)
        store.callbacks[1](false,"offline")
        assert(loop.entryPending and loop.initialSaveStatus=="error")
        assert(loop:RetryInitialSave()); assert(#store.saves==2)
        store.data=store.saves[2]
        store.callbacks[2](true)
        assert(not loop.entryPending and loop.initialSaveStatus=="saved")
        assert(loop:LoadSaved()); assert(loop.player.day==1)
    end)
    check("world preparation failure keeps port blocked and retries without saving again", function()
        local attempts = 0
        local loop, store=fixture({onNewDay=function() attempts=attempts+1; return attempts>1 end})
        settle(loop); store.callbacks[1](true)
        assert(loop.dayPreparationError and loop.settlementPending and not loop:Depart())
        assert(loop:ConfirmSettlement()); assert(#store.saves==1 and loop.player.day==2)
        assert(not loop.settlementPending and attempts==2)
    end)
    check("closing one pause owner retains all the others", function()
        local loop=fixture(); assert(loop:Depart()); loop:ToggleManualPause()
        assert(loop:SetInventoryOpen(true)); assert(loop:SetElderOpen(true))
        assert(loop:SetElderOpen(false)); assert(loop.clock.pauseReasons.inventory and loop.clock.pauseReasons.manual)
        assert(loop:SetInventoryOpen(false)); assert(loop.clock.pauseReasons.manual and loop.clock:IsPaused())
    end)
    return {results=results, kind="protocol", guiVerified=false, realCloudVerified=false}
end
return Tests
