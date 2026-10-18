local Runtime = require("Ocean.SeaRuntime")
local BaseWorld = require("Game.World")
local StateMachine = require("FSM.StateMachine")
local EntityStateSystem = require("Systems.EntityStateSystem")
local Bridge = require("Integration.Bridge")

local Tests = {}
local hasCaptureLockApi = type(Runtime.LockFishingTarget) == "function"
    and type(Runtime.UnlockFishingTarget) == "function"
local function near(a, b) assert(math.abs(a - b) < 0.000001) end
local function runtime()
    return Runtime.New({ departure = { x = -20, y = -20 }, initializeRegions = false })
end

function Tests.Run()
    local results = {}
    local skippedCount = 0
    local function test(name, fn, needsCaptureLockApi)
        if needsCaptureLockApi and not hasCaptureLockApi then
            skippedCount = skippedCount + 1
            results[#results + 1] = {
                name = name,
                skipped = true,
                status = "skipped",
                error = "UNVERIFIED_DEPENDENCY: Ocean.SeaRuntime requires LockFishingTarget and UnlockFishingTarget",
            }
            return
        end
        local ok, error = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(error) or nil }
    end
    test("shared registry and factory retain entity identity", function()
        local r = runtime()
        local fish = r:spawnFish("sardine", { x = -30, y = -20 })
        assert(r.world:GetEntity(fish.id) == fish and r.world:get(fish.id) == fish)
        assert(r.world.entityFactory.nextId - 1 == r.world.nextId)
        assert(fish.fsm == r.behaviors[fish.id].fsm)
        assert(r.world.systems[1] == EntityStateSystem and r.world.systems[2] == r.surfaceSignals)
        assert(#r.world.systems == 2)
        assert(not r.world:AddSystem(EntityStateSystem) and not r.world:AddSystem(r.surfaceSignals)
            and #r.world.systems == 2)
    end)
    test("one automatic fish update per sea substep", function()
        local r = runtime()
        local fish = r:spawnFish("sardine", { x = -30, y = -20 })
        local behavior = r.behaviors[fish.id]
        local updates, seconds = 0, 0
        local original = behavior.Update
        behavior.Update = function(self, dt)
            updates, seconds = updates + 1, seconds + dt
            return original(self, dt)
        end
        r:Update(0.1)
        assert(updates == 2)
        near(seconds, 0.1)
        near(r.time, 0.1)
        near(r.world.time, 0.1)
    end)
    test("frozen and removed entities never receive FSM updates", function()
        local r = runtime()
        local fish = r:spawnFish("sardine", { x = -400, y = -400 })
        local calls = 0
        r.behaviors[fish.id].Update = function() calls = calls + 1 end
        r:Update(0.05)
        assert(calls == 0 and fish.frozen)
        assert(r.world:RemoveEntity(fish.id))
        r:Update(0.05)
        assert(calls == 0 and not fish.alive and r.behaviors[fish.id] == nil)
    end)
    test("paused Game leaves sea and temporary lifetime unchanged", function()
        local r = runtime()
        local b = Bridge.New(r)
        local dropped = r:spawnDroppedItem({ itemId = "bait" }, { x = -20, y = -20 })
        assert(b.game:GetWorld() == r.world and b.game:GetPlayerState() == b.loop.player)
        b:Update(0.05)
        near(r.time, 0)
        near(dropped.age, 0)
        assert(b.loop:Depart())
        b:Update(0.05)
        near(r.time, 0.05)
        near(dropped.age, 0.05)
        b.loop:SetInventoryOpen(true)
        b:Update(0.05)
        near(r.time, 0.05)
        near(dropped.age, 0.05)
    end)
    test("Game uses reset runtime world rather than cached registry", function()
        local r = runtime()
        local b = Bridge.New(r)
        local oldWorld = b.game:GetWorld()
        r:Reset()
        assert(b.game:GetWorld() == r.world and r.world ~= oldWorld)
        assert(#r.world.systems == 3 and r.world.systems[2] == r.surfaceSignals)
    end)
    test("shared FSM calls enter exit and update once", function()
        local log = {}
        local fsm = StateMachine.New({
            a = { enter = function() log[#log + 1] = "enter-a" end,
                exit = function() log[#log + 1] = "exit-a" end },
            b = { enter = function(_, previous) assert(previous == "a"); log[#log + 1] = "enter-b" end,
                update = function(_, dt) near(dt, 0.05); log[#log + 1] = "update-b" end },
        }, "a", {})
        assert(fsm:Change("b") and not fsm:Change("b"))
        fsm:Update(0.05)
        assert(table.concat(log, ",") == "enter-a,exit-a,enter-b,update-b")
    end)
    test("base skeleton retains numeric IDs and remove/clear interfaces", function()
        local world = BaseWorld.New()
        local position = { x = 1, y = 2 }
        local first = world:CreateEntity("fish", { position = position })
        local second = world:CreateEntity("ship")
        position.x = 100
        ---@type {x:number, y:number}
        local copiedPosition = first.position
        assert(first.id == 1 and second.id == 2 and copiedPosition.x == 1)
        assert(world:RemoveEntity(first.id) and #world:GetEntities() == 1)
        world:Clear()
        assert(#world:GetEntities() == 0 and not second.alive and world:GetEntity(second.id) == nil)
    end)
    test("Integration owns references while Gameplay owns transient action records", function()
        local r = runtime()
        local b = Bridge.New(r)
        assert(b.loop:Depart())
        local fish = r:spawnFish("sardine", { x = -19, y = -20 })
        fish.frozen = true
        local token = assert(b:BeginFishing({ x = -20, y = -20 }))
        assert(rawget(b, "_pendingFishing") == nil and rawget(b, "_fishingTokens") == nil)
        assert(rawget(b, "dropTarget") == nil and rawget(b, "_completeLoopFishing") == nil)
        local actions = assert(b.loop.actions)
        local record = actions._fishingTokens[token]
        assert(record == actions._pendingFishing and record.state == "casting" and record.targetId == nil)
        assert(rawget(record, "target") == nil, "action records retain IDs, not mutable sea entities")
        assert(b:Update(0.5))
        assert(record.state == "landed" and record.targetId == fish.id,
            "the real Runtime target is selected and locked at net landing")
        local point = { x = -20, y = -20 }
        assert(b:SetDropTarget(point))
        point.x = 999
        local selected = actions:GetDropTarget()
        assert(selected.x == -20)
        selected.x = 999
        assert(actions:GetDropTarget().x == -20)
        assert(b:NewRun())
        assert(actions._pendingFishing == nil and next(actions._fishingTokens) == nil)
        assert(actions:GetDropTarget() == nil and not b:CompleteFishing(token))
    end, true)
    test("registered frame System keeps raw clock dt separate from sea substeps", function()
        local r = runtime()
        local b = Bridge.New(r)
        assert(b.loop:Depart())
        local fish = r:spawnFish("sardine", { x = -30, y = -20 })
        local clockCalls, fishCalls = 0, 0
        local updateLoop = b.loop.Update
        b.loop.Update = function(self, dt, advanceWorld)
            clockCalls = clockCalls + 1
            updateLoop(self, dt, advanceWorld)
        end
        r.behaviors[fish.id].Update = function() fishCalls = fishCalls + 1 end
        assert(r.world.systemCadences[b.game.gameplaySystem] == "frame")
        b:Update(1)
        assert(clockCalls == 1 and fishCalls == 5)
        near(b.loop.clock.elapsed, 1)
        near(r.time, 0.25)
        assert(b.loop:SetInventoryOpen(true))
        b:Update(1)
        assert(clockCalls == 2 and fishCalls == 5)
        near(b.loop.clock.elapsed, 1)
        near(r.time, 0.25)
        b.loop.clock:Seek("night", b.loop.clock.nightSec)
        b:Update(0)
        assert(clockCalls == 3 and b.loop.forcedReturnPending and r.paused)
        near(r.time, 0.25)
    end)
    test("runtime replacement rejects old tokens even when fish IDs are reused", function()
        local r = runtime()
        local b = Bridge.New(r)
        assert(b.loop:Depart())
        local original = r:spawnFish("sardine", { x = -19, y = -20 })
        original.frozen = true
        local token = assert(b:BeginFishing({ x = -20, y = -20 }))
        local record = b.loop.actions._fishingTokens[token]
        assert(record.state == "casting" and record.targetId == nil)
        assert(b:Update(0.5) and record.state == "landed" and record.targetId == original.id)
        r:Reset()
        local replacement = r:spawnFish("sardine", { x = -19, y = -20 })
        assert(original.id == replacement.id and original ~= replacement)
        assert(not b:CompleteFishing(token) and not replacement.removed)
        b:Update(0.1)
        assert(#r.world.systems == 3 and r.world.systems[2] == r.surfaceSignals)
        near(b.loop.clock.elapsed, 0.6)
        b:Update(0.1)
        assert(#r.world.systems == 3 and r.world.systems[2] == r.surfaceSignals)
        near(b.loop.clock.elapsed, 0.7)
    end, true)
    test("Ocean rollback restores removed fish identity and active FSM", function()
        local r = runtime()
        local b = Bridge.New(r)
        assert(b.loop:Depart())
        local fish = r:spawnFish("sardine", { x = -19, y = -20 })
        local token = assert(b:BeginFishing({ x = -20, y = -20 }))
        local record = b.loop.actions._fishingTokens[token]
        assert(record.state == "casting" and record.targetId == nil)
        assert(b:Update(0.5) and record.state == "landed" and record.targetId == fish.id)
        local stamina = b.loop.player.stamina
        local itemCount = #b.loop.player.inventory:GetItems()
        local originalRemove = r.world.remove
        r.world.remove = function(self, id, reason)
            assert(originalRemove(self, id, reason))
            self:compact()
            error("injected failure after compact")
        end
        assert(b:Update(3.5))
        assert(not b:CompleteFishing(token))
        r.world.remove = originalRemove
        assert(r.world:get(fish.id) == fish and fish.alive and not fish.removed)
        assert(r.behaviors[fish.id] and fish.fsm == r.behaviors[fish.id].fsm)
        assert(b.loop.player.stamina == stamina and #b.loop.player.inventory:GetItems() == itemCount)
        local calls = 0
        r.behaviors[fish.id].Update = function() calls = calls + 1 end
        b:Update(0.1)
        assert(calls == 2)
        token = assert(b:BeginFishing({ x = -20, y = -20 }))
        record = b.loop.actions._fishingTokens[token]
        assert(b:Update(0.5) and record.state == "landed" and record.targetId == fish.id)
        assert(b:Update(3.5))
        local ok, result = b:CompleteFishing(token)
        assert(ok and result == "caught")
        assert(not fish.alive and fish.removed)
    end, true)
    test("Bridge works through public Runtime APIs without sea internals", function()
        local r = runtime()
        local b = Bridge.New(r, { dropReceiver = function() return false end })
        -- Game has its own Runtime reference; the Bridge boundary only exposes public methods.
        b.runtime = setmetatable({}, { __index = function(_, name)
            assert(name ~= "ship" and name ~= "world" and name ~= "movement",
                "Integration accessed sea internals: " .. name)
            local method = r[name]
            assert(type(method) == "function", "only Runtime methods are exposed")
            return function(_, ...) return method(r, ...) end
        end })
        local position = r:GetShipPosition()
        position.x = 999
        assert(r:GetShipPosition().x == -20)
        assert(b.loop:Depart())
        assert(b:SetDropTarget({ x = -8, y = -20 }))
        local entities = #r.world:GetEntities()
        local items = #b.loop.player.inventory:GetItems()
        assert(not b.loop:DropItem(1))
        assert(#r.world:GetEntities() == entities and #r.world.entities == entities)
        assert(#b.loop.player.inventory:GetItems() == items)
        assert(not r:RejectDroppedItem(r.ship.id), "drop cleanup cannot remove the ship")
        assert(b:RecognizeLocation("reef-interface", { x = -20, y = -20 }))
        r.movement:SetTarget({ x = -15, y = -20 })
        assert(b:NewRun())
        assert(r.movement.target == nil and b.loop.inPort)
    end)
    return { results = results, skipped_count = skippedCount }
end

return Tests
