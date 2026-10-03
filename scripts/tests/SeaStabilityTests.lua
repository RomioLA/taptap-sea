-- Sustained simulation checks; these do not measure native rendering FPS or hardware input.
local Runtime = require("Ocean.SeaRuntime")
local Config = require("Ocean.Config")
local M = require("Ocean.Math")
local Tests = {}

local function finite(value)
    return value == value and math.abs(value) < math.huge
end

local function audit(runtime)
    local ids, fishCount = {}, 0
    for _, entity in ipairs(runtime.world.entities) do
        assert(not entity.removed and not ids[entity.id], "removed or duplicate live entity")
        ids[entity.id] = true
        assert(runtime.world:get(entity.id) == entity, "entity lookup mismatch")
        assert(finite(entity.position.x) and finite(entity.position.y) and finite(entity.rotation), "nonfinite transform")
        if entity.kind ~= "fixed" then
            assert(runtime.world:isPositionFree(entity.position, entity.radius), "entity outside free sea: "..entity.id)
        end
        if entity.ordinaryFish then
            fishCount = fishCount+1
            assert(entity.active ~= entity.frozen, "inconsistent activity flags")
            assert(runtime.behaviors[entity.id], "live fish missing behavior")
        end
    end
    for id in pairs(runtime.world.byId) do assert(ids[id], "orphan entity lookup") end
    local behaviorCount = 0
    for id in pairs(runtime.behaviors) do
        behaviorCount = behaviorCount+1
        assert(ids[id] and runtime.world:get(id).ordinaryFish, "orphan fish behavior")
    end
    local counts = runtime.world:getCounts()
    assert(counts.total == #runtime.world.entities and behaviorCount == fishCount)
    assert(counts.active+counts.frozen == fishCount and counts.sardine+counts.tuna == fishCount)
    assert(finite(runtime.movement.camera.x) and finite(runtime.movement.camera.y), "nonfinite camera")
end

function Tests.Run()
    local results, metrics = {}, {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results+1] = {name=name, passed=ok, error=ok and "" or tostring(err)}
    end
    check("four seeded 180-second voyages across regions and mixed frame deltas", function()
        local samples, sardines, tuna, active, maxEntities, maxFrozen = 0, 0, 0, 0, 0, 0
        local activeSardines, activeTuna, viewportSardines, viewportTuna = 0, 0, 0, 0
        local eaten, frozenChecks, completed = 0, 0, 0
        for _, seed in ipairs({11, 97, 2026, 271828}) do
            local r = Runtime.New({daySeed=seed, departure={x=400,y=400}})
            r.movement:SetViewport(1920,1080)
            local fixed = {}
            for _, entity in ipairs(r.world.entities) do
                if entity.kind == "fixed" then fixed[entity.id] = entity end
            end
            local waypoints = {{x=600,y=400},{x=600,y=600},{x=400,y=600},{x=400,y=400}}
            local waypoint, frame, nextSample, nextDrop = 1, 0, 1, 0
            local drops = {}
            ---@type number[]
            local deltas = {1/60,1/30,0.1}
            r.movement:SetTarget(waypoints[waypoint])
            while r.time < 180-Config.world.epsilon do
                frame = frame+1
                local frameDelta = assert(deltas[(frame-1)%#deltas+1])
                local dt = math.min(frameDelta,180-r.time)
                local frozen = {}
                for _, entity in ipairs(r.world.entities) do
                    if entity.ordinaryFish and entity.frozen then
                        frozen[entity.id] = {entity=entity, position=M.copy(entity.position), state=entity.state}
                    end
                end
                if r.time >= nextDrop and nextDrop < 150 then
                    drops[#drops+1] = r:spawnDroppedItem({itemId="stability-small",worldEffect="ATTRACT_SMALL_FISH"},r.ship.position)
                    drops[#drops+1] = r:spawnDroppedItem({itemId="stability-big",worldEffect="ATTRACT_BIG_FISH"},r.ship.position)
                    r.world:revealUnderwater(r.ship.position,30,5)
                    nextDrop = nextDrop+60
                end
                local previousEntities = r.world.entities
                r:Update(dt)
                for id, snapshot in pairs(frozen) do
                    local entity = r.world:get(id)
                    if entity and entity.frozen then
                        assert(M.distanceSquared(snapshot.position,entity.position) == 0 and snapshot.state == entity.state,
                            "frozen fish advanced AI")
                        frozenChecks = frozenChecks+1
                    end
                end
                if r.movement.target == nil and waypoint <= #waypoints then
                    waypoint = waypoint+1
                    r.movement:SetTarget(waypoints[waypoint])
                end
                if r.time >= nextSample then
                    audit(r)
                    local counts = r.world:getCounts()
                    maxEntities, maxFrozen = math.max(maxEntities,counts.total), math.max(maxFrozen,counts.frozen)
                    active = active+counts.active
                    for _, entity in ipairs(r.world.entities) do
                        if entity.ordinaryFish then
                            if entity.active then
                                if entity.species == "sardine" then activeSardines = activeSardines+1 else activeTuna = activeTuna+1 end
                            end
                            local sx, sy = r.movement:WorldToScreen(entity.position)
                            if sx >= 0 and sx <= 1920 and sy >= 0 and sy <= 1080 then
                                if entity.species == "sardine" then viewportSardines = viewportSardines+1 else viewportTuna = viewportTuna+1 end
                            end
                        end
                    end
                    for _, entity in ipairs(r:queryEntitiesInRadius(r.ship.position,Config.world.activateRadius,{ordinaryFish=true})) do
                        if entity.species == "sardine" then sardines = sardines+1 else tuna = tuna+1 end
                    end
                    samples = samples+1
                    nextSample = nextSample+1
                end
                for _, entity in ipairs(previousEntities) do
                    if entity.ordinaryFish and entity.removed then
                        assert(r.world:get(entity.id) == nil and r.behaviors[entity.id] == nil)
                        if entity.removeReason == "eaten" then eaten = eaten+1 end
                    end
                end
            end
            audit(r)
            assert(waypoint == #waypoints+1, "voyage failed to complete its loop")
            assert(M.distance(r.ship.position,waypoints[#waypoints]) <= Config.ship.arrivalRadius)
            for id, entity in pairs(fixed) do assert(r.world:get(id) == entity, "fixed world changed") end
            for _, drop in ipairs(drops) do assert(drop.removed and drop.removeReason == "expired", "temporary object leaked") end
            assert(#r.world.reveals == 0, "temporary visibility leaked")
            local regionCount = 0
            for _ in pairs(r.initializedRegions) do regionCount = regionCount+1 end
            assert(regionCount > 4, "voyage did not explore multiple regions")
            completed = completed+1
        end
        metrics.voyageCount, metrics.simulatedSecondsPerVoyage = completed, 180
        metrics.radius120SardineMean, metrics.radius120TunaMean = sardines/samples,tuna/samples
        metrics.fullAIAliveMean = active/samples
        metrics.fullAISardineMean, metrics.fullAITunaMean = activeSardines/samples,activeTuna/samples
        metrics.debugViewportSardineMean, metrics.debugViewportTunaMean = viewportSardines/samples,viewportTuna/samples
        metrics.maxLiveEntities, metrics.maxFrozenFish = maxEntities,maxFrozen
        metrics.frozenFrameAssertions, metrics.populationSamples = frozenChecks,samples
        metrics.eatenDuringVoyages = eaten
    end)
    check("cleared explored regions do not refill during 180 seconds of same-day return", function()
        local r = Runtime.New({daySeed=97,departure={x=400,y=400}})
        -- Pre-initialize the return route and a steering margin without running AI.
        for _, position in ipairs({{x=380,y=380},{x=450,y=380},{x=450,y=450},{x=380,y=450}}) do
            r.ship.position = position
            r:ensureNearbyRegions()
        end
        r.ship.position = {x=400,y=400}
        local initialized = r.initializedRegions
        r:clearOrdinaryFish()
        local regionCount = 0
        for _ in pairs(initialized) do regionCount = regionCount+1 end
        local route = {{x=430,y=400},{x=430,y=430},{x=400,y=430},{x=400,y=400}}
        local waypoint, returns = 1, 0
        r.movement:SetTarget(route[waypoint])
        for _ = 1,3600 do
            r:Update(0.05)
            if not r.movement.target then
                if waypoint == #route then returns = returns+1 end
                waypoint = waypoint%#route+1
                r.movement:SetTarget(route[waypoint])
            end
            assert(r.world:getCounts().sardine == 0 and r.world:getCounts().tuna == 0, "same-day refill")
        end
        local finalRegions = 0
        for _ in pairs(r.initializedRegions) do finalRegions = finalRegions+1 end
        assert(finalRegions == regionCount and r.initializedRegions == initialized)
        assert(returns >= 5, "insufficient return visits")
        metrics.sameDayReturnVisits = returns
        assert(r.world:getCounts().sardine == 0 and r.world:getCounts().tuna == 0, "same-day refill")
        audit(r)
    end)
    check("twenty daily rebuilds retain fixed objects and discard prior-day dynamic state", function()
        local r = Runtime.New({daySeed=11,departure={x=400,y=400}})
        local fixed, ship = {}, r.ship
        for _, entity in ipairs(r.world.entities) do if entity.kind == "fixed" then fixed[entity.id] = entity end end
        local highestId = r.world.nextId
        for day = 1,20 do
            local priorFish = {}
            for _, entity in ipairs(r.world.entities) do if entity.ordinaryFish then priorFish[#priorFish+1] = entity end end
            local drop = r:spawnDroppedItem({itemId="stability-none",worldEffect="NONE"},r.ship.position)
            r.world:revealUnderwater(r.ship.position,30,20)
            r:refreshOrdinaryFish(day,r.ship.position)
            for _, entity in ipairs(priorFish) do assert(entity.removed and not r.world:get(entity.id) and not r.behaviors[entity.id]) end
            assert(drop.removed and drop.removeReason == "newDay" and #r.world.reveals == 0)
            assert(r.ship == ship and r.world:get(ship.id) == ship and r.world.nextId > highestId)
            highestId = r.world.nextId
            for id, entity in pairs(fixed) do assert(r.world:get(id) == entity) end
            for _ = 1,200 do r:Update(0.05) end
            audit(r)
        end
        metrics.dailyRebuilds = 20
    end)
    return {results=results,metrics=metrics}
end
return Tests
