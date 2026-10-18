-- Opt-in sustained probe driven by real engine Update/NanoVGRender callbacks.
-- Targets are scripted; this does not assert real mouse/keyboard/touch or visual quality.
local Config = require("Ocean.Config")
local M = require("Ocean.Math")
local Probe = {}

local function audit(runtime)
    local ids, behaviors = {}, 0
    for _, entity in ipairs(runtime.world.entities) do
        assert(not entity.removed and not ids[entity.id], "native voyage duplicate/removed entity")
        ids[entity.id] = true
        assert(runtime.world:get(entity.id) == entity, "native voyage ID lookup mismatch")
        assert(entity.position.x == entity.position.x and math.abs(entity.position.x) < math.huge
            and entity.position.y == entity.position.y and math.abs(entity.position.y) < math.huge,
            "native voyage nonfinite position")
        if entity.kind ~= "fixed" then
            assert(runtime.world:isPositionFree(entity.position,entity.radius), "native voyage invalid position")
        end
        if entity.ordinaryFish then assert(runtime.behaviors[entity.id], "native voyage missing fish behavior") end
    end
    for id in pairs(runtime.world.byId) do assert(ids[id], "native voyage orphan lookup") end
    for id in pairs(runtime.behaviors) do
        behaviors = behaviors+1
        assert(ids[id] and runtime.world:get(id).ordinaryFish, "native voyage orphan behavior")
    end
    local counts = runtime.world:getCounts()
    assert(counts.total == #runtime.world.entities and counts.active+counts.frozen == behaviors)
end

function Probe.Attach(sea)
    local regression = require("tests.SeaRuntimeTests").Run()
    for _, result in ipairs(regression.results) do assert(result.passed,result.name..": "..result.error) end
    print("[SeaV1][NativeVoyage] logic PASS "..#regression.results.."/"..#regression.results)
    local runtime = sea.runtime
    local update, render = sea.Update, sea.Render
    -- The preceding smoke stage checks the real input subscriptions. This stage
    -- supplies scripted targets/zero axes and measures engine-driven simulation.
    local route = {{x=600,y=400},{x=600,y=600},{x=400,y=600},{x=400,y=400}}
    local waypoint, nextSample, nextDrop, nextReport = 1, 1, 0, 30
    local updates, renders, samples, rawElapsed = 0, 0, 0, 0
    local sardines, tuna, active, peak = 0, 0, 0, 0
    local drops, fixed = {}, {}
    local flags = {"showUnderwater","showStates","showPerception","showActivity"}
    local debugShown, completed = false, false
    for _, entity in ipairs(runtime.world.entities) do if entity.kind == "fixed" then fixed[entity.id] = entity end end
    runtime.movement:SetTarget(route[waypoint])
    print("[SeaV1][NativeVoyage] START seed="..runtime.daySeed.." targetSec=180 scriptedTargets=true")
    sea.Render = function(self)
        render(self)
        renders = renders+1
    end
    sea.Update = function(self, dt)
        if completed then return update(self,dt) end
        updates = updates+1
        rawElapsed = rawElapsed+dt
        if runtime.time >= nextDrop and nextDrop < 150 then
            drops[#drops+1] = runtime:spawnDroppedItem({itemId="native-voyage",worldEffect="ATTRACT_SMALL_FISH"},runtime.ship.position)
            drops[#drops+1] = runtime:spawnDroppedItem({itemId="native-voyage-big",worldEffect="ATTRACT_BIG_FISH"},runtime.ship.position)
            runtime.world:revealUnderwater(runtime.ship.position,30,5)
            nextDrop = nextDrop+60
        end
        local shouldShow = runtime.time >= 45 and runtime.time < 135
        if shouldShow ~= debugShown then
            debugShown = shouldShow
            for _, flag in ipairs(flags) do runtime:setDebugFlag(flag,debugShown) end
            print("[SeaV1][NativeVoyage] debug flags="..tostring(debugShown).." time="..runtime.time)
        end
        self:SyncViewport()
        runtime.movement:SetTarget(route[waypoint])
        runtime:Update(dt,0,0)
        self.tools.refresh(dt)
        if not runtime.movement.target and waypoint <= #route then
            assert(M.distance(runtime.ship.position,route[waypoint]) <= Config.ship.arrivalRadius,
                "native voyage target canceled before waypoint arrival")
            waypoint = waypoint+1
            runtime.movement:SetTarget(route[waypoint])
            print("[SeaV1][NativeVoyage] reached waypoint="..(waypoint-1).." time="..runtime.time)
        end
        if runtime.time >= nextSample then
            audit(runtime)
            local counts = runtime.world:getCounts()
            peak, active = math.max(peak,counts.total), active+counts.active
            for _, entity in ipairs(runtime:queryEntitiesInRadius(runtime.ship.position,Config.world.activateRadius,{ordinaryFish=true})) do
                if entity.species == "sardine" then sardines = sardines+1 else tuna = tuna+1 end
            end
            samples = samples+1
            nextSample = nextSample+1
        end
        if runtime.time >= nextReport then
            print(string.format("[SeaV1][NativeVoyage] progress time=%.3f updates=%d renders=%d samples=%d entities=%d",
                runtime.time,updates,renders,samples,#runtime.world.entities))
            nextReport = nextReport+30
        end
        if runtime.time >= 180 then
            audit(runtime)
            assert(waypoint == #route+1 and M.distance(runtime.ship.position,route[#route]) <= Config.ship.arrivalRadius,
                "native voyage did not complete route")
            assert(renders > 0 and samples >= 179, "native voyage callback evidence incomplete")
            for id, entity in pairs(fixed) do assert(runtime.world:get(id) == entity, "native voyage fixed object changed") end
            for _, drop in ipairs(drops) do assert(drop.removed and drop.removeReason == "expired", "native voyage temporary object leaked") end
            assert(#runtime.world.reveals == 0, "native voyage reveal leaked")
            print(string.format("[SeaV1][NativeVoyage] PASS simulatedSec=%.3f rawUpdateSec=%.3f updates=%d renders=%d samples=%d radius120SardineMean=%.4f radius120TunaMean=%.4f fullAIAliveMean=%.4f sampledPeakEntities=%d",
                runtime.time,rawElapsed,updates,renders,samples,sardines/samples,tuna/samples,active/samples,peak))
            completed = true
            self.Update, self.Render = update, render
        end
    end
end
return Probe
