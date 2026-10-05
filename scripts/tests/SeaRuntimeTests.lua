local Config = require("Ocean.Config")
local Data = require("Ocean.FishData")
local M = require("Ocean.Math")
local World = require("Ocean.World")
local Runtime = require("Ocean.SeaRuntime")
local Strategy = require("Ocean.SpawnStrategy")
local Tests = {}

function Tests.Run()
    local results = {}
    local metrics = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results+1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end
    local function near(actual, expected, tolerance)
        assert(math.abs(actual-expected) <= (tolerance or 0.00001), tostring(actual).." != "..tostring(expected))
    end
    local function fresh()
        return Runtime.New({ initializeRegions = false })
    end
    local function step(runtime, seconds, x, y)
        for _ = 1, math.floor(seconds/0.05+0.5) do runtime:Update(0.05, x, y) end
    end

    check("supplement02 authoritative values and 16:9 full-height projection", function()
        local r=fresh();r.movement:SetViewport(1920,1080)
        near(r.movement.viewHeight,45);near(r.movement.viewWidth,80)
        assert(Config.fishing.maxCastDistance==30 and Config.fishing.netRadius==8
            and Config.fishing.durationSec==4 and Config.fishing.maxCatchCount==1)
        assert(Config.interaction.operateDistance==5 and Config.interaction.portDistance==10
            and Config.interaction.maxThrowDistance==12 and Config.interaction.outlineDistance==80
            and Config.interaction.recognitionDistance==20 and Config.interaction.revealRadius==20)
        assert(Config.debug.revealRadius==nil and Config.camera.viewWidth==nil)
        assert(Data.sardine.avoidMargin==4 and Data.tuna.avoidMargin==6)
        assert(Data.sardine.minShipSpawnDistance==15 and Data.tuna.minShipSpawnDistance==30)
    end)
    check("cast confirms at30 meters, rejects beyond and uses radius8 single target", function()
        local r=fresh();local center={x=30,y=0}
        assert(r:canCastNet(center));assert(not r:canCastNet({x=30.001,y=0}))
        assert(not r:canCastNet({x=35,y=25})) -- blocking island
        local edge=r:spawnFish("sardine",{x=38,y=0})
        r:spawnFish("tuna",{x=38.001,y=0})
        assert(r:selectFishingTarget(center)==edge)
        r.world:remove(edge.id,"caught")
        assert(r:selectFishingTarget(center)==nil)
        local target,reason=r:selectFishingTarget({x=30.001,y=0})
        assert(target==nil and reason~=nil)
        assert(not pcall(function() r:selectFishingTarget(center,16) end))
    end)
    check("avoid prediction uses species4 and6 meter clearance before boundary", function()
        for _,species in ipairs({"sardine","tuna"}) do
            local r=fresh();local data=Data[species]
            r.ship.position={x=Config.world.halfSize-40,y=0}
            local limit=Config.world.halfSize-data.radius-data.avoidMargin
            local fish=r:spawnFish(species,{x=limit-0.01,y=0},0)
            assert(r.world:getAvoidance(fish,data.avoidMargin)==nil)
            fish.position.x=limit
            assert(r.world:getAvoidance(fish,data.avoidMargin)~=nil)
            r:Update(0.05);assert(fish.state=="Avoid")
        end
    end)
    check("drop confirms at12 meters and rejection neither spawns nor changes payload", function()
        local r=fresh();local payload={itemId="future-generic",worldEffect="NONE"}
        local before=r.world:getCounts().total
        local drop=r:spawnDroppedItem(payload,{x=12,y=0});assert(drop)
        local rejected,reason=r:spawnDroppedItem(payload,{x=12.001,y=0})
        assert(rejected==nil and reason=="throw_out_of_range")
        assert(r.world:getCounts().total==before+1 and payload.worldEffect=="NONE")
    end)
    check("ordinary region spawn respects current boat exclusion plus day departure200", function()
        local world=World.New();local departure={x=0,y=0};local boat={x=200,y=0}
        local sardine,tuna=0,0
        for seed=1,30 do
            local placements=Strategy.GenerateRegion(world,seed,9,7,departure,Data,boat)
            for _,p in ipairs(placements) do
                assert(M.distance(p.position,boat)>=Data[p.species].minShipSpawnDistance)
                if p.species=="tuna" then
                    assert(M.distance(p.position,departure)>=200);tuna=tuna+1
                else sardine=sardine+1 end
            end
        end
        assert(sardine>0 and tuna>0)
        local r=Runtime.New();local known={}
        for _,e in ipairs(r.world.entities) do known[e.id]=true end
        r.ship.position={x=400,y=400};r:ensureNearbyRegions()
        for _,e in ipairs(r.world.entities) do
            if e.ordinaryFish and not known[e.id] then
                assert(M.distance(e.position,r.ship.position)>=Data[e.species].minShipSpawnDistance)
            end
        end
    end)
    check("birth exclusion is not an AI barrier after generation", function()
        for _,spec in ipairs({{"sardine",18,"ATTRACT_SMALL_FISH"},{"tuna",31,"ATTRACT_BIG_FISH"}}) do
            local r=fresh();local fish=r:spawnFish(spec[1],{x=spec[2],y=0},math.pi)
            r:spawnDroppedItem({itemId="generic",worldEffect=spec[3]},r.ship.position)
            step(r,1)
            assert(M.distance(fish.position,r.ship.position)<Data[spec[1]].minShipSpawnDistance)
        end
    end)
    check("scope reveal uses20 and changes visibility only", function()
        local r=fresh();local inside=r:spawnFish("sardine",{x=0,y=20})
        local outside=r:spawnFish("tuna",{x=0,y=20.001})
        local position=M.copy(inside.position);local state=inside.state
        local count=r.world:getCounts().total
        r:revealWithScope({x=0,y=0},0.1)
        assert(r.world:isVisible(inside) and not r.world:isVisible(outside))
        assert(inside.state==state and M.distance(position,inside.position)==0)
        assert(r.world:getCounts().total==count and r:selectFishingTarget(inside.position)==inside)
        r.world:updateLifecycle(0.1,r.ship);assert(not r.world:isVisible(inside))
    end)
    check("four-second fishing contract never implicitly pauses world time", function()
        local r=fresh();local drop=r:spawnDroppedItem({itemId="generic"},r.ship.position)
        local time=r.time;step(r,Config.fishing.durationSec)
        near(r.time-time,4);near(drop.age,4);assert(not r.paused)
        -- CompleteFishing(0/1) action callbacks remain an explicit integration contract.
    end)

    check("meter units, derived map and implementation values", function()
        near(Config.world.mapSize, Config.ship.maxSpeed*180)
        assert(Config.units.length == "meter" and Config.units.metersPerWorldUnit == 1)
        assert(Config.ship.tuningStatus == "V1_IMPLEMENTATION_VALUE")
        assert(Config.camera.viewHeight == 45 and Config.camera.viewWidth == nil)
        assert(Data.sardine.targetActiveCount == 20 and Data.tuna.targetActiveCount == 4)
        assert(Data.sardine.densityStatus == "BALANCE_TARGET" and Data.tuna.densityStatus == "BALANCE_TARGET")
        assert(Data.sardine.dailyCount == nil and Data.tuna.dailyCount == nil)
        assert(Data.tuna.preyRadius > Data.sardine.dangerRadius)
        assert(Data.tuna.chaseSpeed > Data.sardine.fleeSpeed)
        assert(Data.tuna.turnDegPerSec < Data.sardine.turnDegPerSec)
    end)
    check("configured ship levels move at the configured meters per second", function()
        for level, speed in ipairs(Config.ship.speedByLevel) do
            local r = Runtime.New({initializeRegions=false,shipLevel=level})
            near(r.movement.speed,speed);assert(r.ship.level==level)
            step(r,1,1,0);near(r.ship.position.x,speed)
        end
        local r=fresh();near(r:SetShipLevel(2),Config.ship.speedByLevel[2]);r:Reset()
        assert(r.ship.level==2);near(r.movement.speed,Config.ship.speedByLevel[2])
        near(r:SetShipLevel(3),Config.ship.speedByLevel[3]);near(r:SetShipLevel(1),Config.ship.speedByLevel[1])
    end)
    check("invalid ship level leaves capability unchanged", function()
        local r=fresh()
        for _,level in ipairs({0,4,1.5,-1}) do
            assert(not pcall(function() r:SetShipLevel(level) end))
            near(r.movement.speed,Config.ship.speedByLevel[1]);assert(r.ship.level==1)
        end
    end)
    check("camera framing changes without rescaling meter movement", function()
        local original=Config.camera.viewHeight
        local ok,err=pcall(function()
            Config.camera.viewHeight=48
            local r=fresh();r.movement:SetViewport(1000,600)
            local a=r.movement:ScreenToWorld(0,600*Config.camera.anchorY)
            local b=r.movement:ScreenToWorld(1000,600*Config.camera.anchorY);near(b.x-a.x,80)
            step(r,1,1,0);near(r.ship.position.x,Config.ship.speedByLevel[1])
        end)
        Config.camera.viewHeight=original
        assert(ok,err)
    end)
    check("fishing selects one nearest live hidden or frozen fish without removal", function()
        local r=fresh()
        local far=r:spawnFish("tuna",{x=205,y=0})
        local nearest=r:spawnFish("sardine",{x=201,y=0})
        local center={x=200,y=0}
        r.ship.position=M.copy(center)
        r.world:spawnDroppedItem({itemId="generic"},center)
        local target=r:selectFishingTarget(center)
        assert(target==nearest and nearest.frozen and not r.world:isVisible(nearest))
        assert(r.world:get(nearest.id)==nearest and r.world:get(far.id)==far)
        r.world:remove(nearest.id,"caught")
        assert(r:selectFishingTarget(center)==far)
    end)
    check("fishing respects validity filter and nearest distance to net center", function()
        local r=fresh();r:spawnFish("sardine",{x=1,y=0})
        local tuna=r:spawnFish("tuna",{x=4,y=0})
        local sardine=r:spawnFish("sardine",{x=5,y=0})
        assert(r:selectFishingTarget({x=4,y=0})==tuna)
        assert(r:selectFishingTarget({x=4,y=0},nil,{species="sardine"})==sardine)
        assert(r:selectFishingTarget({x=4,y=0},nil,function(e) return e.id==tuna.id end)==tuna)
    end)
    check("empty net allows zero result including zero-radius queries", function()
        local r=fresh();local p={x=0,y=0}
        r:spawnDroppedItem({itemId="generic"},p)
        assert(r:selectFishingTarget(p)==nil)
        local fish=r:spawnFish("sardine",{x=1,y=0})
        assert(#r:queryEntitiesInRadius(p,0,{entityType="fish"})==0)
        assert(r:selectFishingTarget(fish.position)==fish)
    end)
    check("independent fishing selections have no daily three or six catch limit", function()
        local r=fresh();local p={x=0,y=0}
        for _=1,8 do
            local fish=r:spawnFish("sardine",{x=1,y=0})
            assert(r:selectFishingTarget(p)==fish)
            assert(r.world:remove(fish.id,"caught"))
            assert(r:selectFishingTarget(p)==nil)
        end
    end)
    check("ship straight speed and max clamp", function()
        local r = fresh(); step(r, 1, 1, 0); near(r.ship.position.x, Config.ship.speedByLevel[1])
        near(r.movement:SetSpeed(20), Config.ship.maxSpeed); near(r.movement:SetSpeed(-1), 0)
    end)
    check("diagonal travel no speed boost", function()
        local r = fresh(); r.ship.rotation = math.pi/4
        step(r, 1, 1, 1); near(M.distance(r.ship.position, Config.ship.start), Config.ship.speedByLevel[1])
    end)
    check("keyboard cancels click target; opposite key axes stop", function()
        local r = fresh(); r.movement:SetTarget({x=40,y=0})
        r:Update(0.05, -1, 0); assert(r.movement.target == nil)
        local p = M.copy(r.ship.position); step(r, 1, 0, 0); near(M.distance(p,r.ship.position),0)
    end)
    check("ship turn speed bound", function()
        local r = fresh(); r:Update(0.05, 0, 1)
        near(r.ship.rotation, math.rad(180)*0.05)
    end)
    check("click arrival and no movement within arrival radius", function()
        local r = fresh(); r.movement:SetTarget({x=1,y=0}); step(r,1)
        near(r.ship.position.x,0); assert(r.movement.target==nil)
        r.movement:SetTarget({x=18,y=0}); step(r,4)
        assert(M.distance(r.ship.position,{x=18,y=0})<=1.5 and r.movement.target==nil)
    end)
    check("configured meter framing, anchor, inverse coordinates across aspects", function()
        local r = fresh()
        for _, size in ipairs({{1000,600},{400,800},{1920,1080}}) do
            r.movement:SetViewport(size[1],size[2])
            local x,y=r.movement:WorldToScreen(r.ship.position)
            near(x,size[1]*Config.camera.anchorX); near(y,size[2]*Config.camera.anchorY)
            assert(r.movement:ScreenToWorld(0,0)==nil, "sky must not unproject to water")
            local left=r.movement:ScreenToWorld(0,y)
            local right=r.movement:ScreenToWorld(size[1],y)
            near(right.x-left.x,Config.camera.viewHeight*size[1]/size[2])
            local bottom=r.movement:ScreenToWorld(0,size[2])
            assert(bottom.y < left.y, "near water must be below the anchor in world depth")
            local p={x=math.min(4,r.movement.viewWidth*0.15),y=-4}; local sx,sy=r.movement:WorldToScreen(p)
            local q=r.movement:ScreenToWorld(sx,sy); near(q.x,p.x); near(q.y,p.y)
        end
    end)
    check("camera continuously smooth follows and settles", function()
        local r=fresh(); r.movement:SetViewport(1000,600)
        local p=M.copy(r.movement.camera); step(r,1,1,0)
        assert(r.movement.camera.x>p.x and r.movement.camera.x<r.ship.position.x)
        near(r.movement.camera.y,p.y)
        local previousX=r.movement.camera.x
        r.ship.position={x=25,y=0}; r:Update(0.05)
        near(r.movement.camera.x,previousX+(25-previousX)*(1-math.exp(-0.05/Config.camera.followSec)))
    end)
    check("all world edges block and outward intent produces feedback", function()
        for _, axis in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
            local r=fresh(); local bound=Config.world.halfSize-r.ship.radius
            r.ship.position={x=axis[1]*bound,y=axis[2]*bound}
            r.ship.rotation=math.atan(axis[2],axis[1]); r:Update(0.05,axis[1],axis[2])
            assert(r.movement.pushRemaining>0)
            step(r,0.3); assert(math.abs(r.ship.position.x)<=bound and math.abs(r.ship.position.y)<=bound)
            assert(M.distance(r.ship.position,{x=axis[1]*bound,y=axis[2]*bound})>0)
        end
    end)
    check("held outward input still visibly pushes inward", function()
        local r=fresh();local bound=Config.world.halfSize-r.ship.radius
        r.ship.position={x=bound,y=0};r.ship.rotation=0;r:Update(0.05,1,0)
        step(r,0.25,1,0)
        near(bound-r.ship.position.x,Config.world.pushSpeed*0.25,0.0001)
        assert(r.movement.pushRemaining>0)
    end)
    check("swept island collision no tunnelling", function()
        local r=fresh(); r.ship.position={x=0,y=25}
        local hit=r.world:moveEntity(r.ship,100,0); assert(hit)
        assert(r.ship.position.x<35-12)
        assert(r.world:isPositionFree(r.ship.position,r.ship.radius))
    end)
    check("small floats overlap without blocking", function()
        local r=fresh(); local overlaps=0
        r.world.onOverlap=function(e) if e.entityType=="float" then overlaps=overlaps+1 end end
        step(r,3,1,0); near(r.ship.position.x,Config.ship.speedByLevel[1]*3); assert(overlaps==1)
    end)
    check("unique IDs and removed query exclusion", function()
        local r=fresh(); local a=r:spawnFish("sardine",{x=0,y=0})
        local b=r:spawnFish("sardine",{x=1,y=0}); assert(a.id~=b.id)
        assert(r.world:remove(a.id,"caught")); assert(not r.world:remove(a.id))
        assert(#r:queryEntitiesInRadius({x=0,y=0},10,{species="sardine"})==1)
    end)
    check("underwater hidden yet queryable; reveal changes visibility only", function()
        local r=fresh(); local e=r:spawnFish("sardine",{x=0,y=0})
        assert(not r.world:isVisible(e)); assert(#r:queryEntitiesInRadius({x=0,y=0},2,{species="sardine"})==1)
        local state=e.state; local p=M.copy(e.position)
        r:setDebugFlag("showUnderwater",true); assert(r.world:isVisible(e))
        assert(e.state==state); near(M.distance(p,e.position),0)
        r:setDebugFlag("showUnderwater",false); r.world:revealUnderwater(e.position,3,0.1)
        assert(r.world:isVisible(e)); step(r,0.15); assert(not r.world:isVisible(e))
    end)
    check("visibility switch does not change AI trajectory", function()
        local a,b=fresh(),fresh()
        a:spawnFish("sardine",{x=0,y=0}); b:spawnFish("sardine",{x=0,y=0})
        b:setDebugFlag("showUnderwater",true); step(a,2); step(b,2)
        near(M.distance(a.world.entities[5].position,b.world.entities[5].position),0)
    end)
    check("sardine wander speed and timed direction choice", function()
        local r=fresh(); local e=r:spawnFish("sardine",{x=0,y=0})
        r:Update(0.05); assert(e.state=="Wander"); near(M.distance(e.position,{x=0,y=0}),4*0.05)
        ---@type FishBehavior
        local behavior=r.behaviors[e.id]
        assert(behavior.wanderRemaining>=Data.sardine.wanderMinSec-0.05 and behavior.wanderRemaining<=Data.sardine.wanderMaxSec)
    end)
    check("effect-based sardine attraction and priority over wander", function()
        local r=fresh(); local e=r:spawnFish("sardine",{x=0,y=0})
        r:spawnDroppedItem({itemId="unknown-test-id",category="any",worldEffect="ATTRACT_SMALL_FISH"},{x=8,y=0})
        r:Update(0.05); assert(e.state=="Attracted"); near(e.position.x,5*0.05)
    end)
    check("NONE effect ignored; temporary TTL and payload copy", function()
        local r=fresh(); local e=r:spawnFish("sardine",{x=0,y=0})
        local payload={itemId="anything",category="test",worldEffect="NONE",lifetimeSec=0.1}
        local item=r:spawnDroppedItem(payload,{x=3,y=0}); payload.worldEffect="ATTRACT_SMALL_FISH"
        r:Update(0.05); assert(e.state=="Wander" and item.worldEffect=="NONE")
        step(r,0.1); assert(not r.world:get(item.id))
        local default=r:spawnDroppedItem({itemId="default"},{x=3,y=0}); assert(default.lifetimeSec==20)
    end)
    check("predator sees prey before sardine senses danger", function()
        local r=fresh(); local s=r:spawnFish("sardine",{x=0,y=0})
        local t=r:spawnFish("tuna",{x=20,y=0},math.pi); r:Update(0.05)
        assert(s.state=="Wander" and t.state=="Chase")
    end)
    check("danger outranks attraction; flee jitter remains away", function()
        local r=fresh(); local s=r:spawnFish("sardine",{x=0,y=0})
        local t=r:spawnFish("tuna",{x=8,y=0}); t.active,t.frozen=false,true
        r:spawnDroppedItem({itemId="test",worldEffect="ATTRACT_SMALL_FISH"},{x=4,y=0})
        ---@type FishBehavior
        local behavior=r.behaviors[s.id]
        for _=1,18 do
            local p=M.copy(s.position); local ax,ay=M.normal(p.x-t.position.x,p.y-t.position.y)
            behavior:Update(0.05); assert(s.state=="Flee")
            assert((s.position.x-p.x)*ax+(s.position.y-p.y)*ay>0)
            assert(math.abs(behavior.fleeJitterRadians)<=math.rad(25))
        end
    end)
    check("avoid outranks danger and attraction", function()
        local r=fresh(); local bound=Config.world.halfSize
        local s=r:spawnFish("sardine",{x=bound-2,y=0})
        r.ship.position={x=bound-20,y=0};r.world:updateActivity(r.ship.position)
        local t=r:spawnFish("tuna",{x=bound-9,y=0}); t.frozen=true;t.active=false
        r.world:spawnDroppedItem({itemId="test",worldEffect="ATTRACT_SMALL_FISH"},{x=bound-10,y=0})
        r.behaviors[s.id]:Update(0.05); assert(s.state=="Avoid")
    end)
    check("tuna true predation removes entity and query membership", function()
        local r=fresh(); local s=r:spawnFish("sardine",{x=1,y=0})
        local t=r:spawnFish("tuna",{x=0,y=0}); r.behaviors[t.id]:Update(0.05)
        assert(s.removed and not r.world:get(s.id))
        assert(#r:queryEntitiesInRadius({x=0,y=0},5,{species="sardine"})==0)
    end)
    check("tuna chase tracks moved prey; loss grace >2 sec", function()
        local r=fresh(); local s=r:spawnFish("sardine",{x=20,y=0})
        local t=r:spawnFish("tuna",{x=0,y=0}); local b=r.behaviors[t.id] --[[@as FishBehavior]]
        b:Update(0.05); assert(t.state=="Chase")
        s.position={x=10,y=15}; b:Update(0.05); assert(b.lastPreyPosition.y==15)
        r.world:remove(s.id); b:Update(1.9); assert(t.state=="Chase")
        b:Update(0.2); assert(t.state=="Wander")
    end)
    check("tuna displacement respects configured turn rate", function()
        local r=fresh();r:spawnFish("sardine",{x=0,y=20})
        local t=r:spawnFish("tuna",{x=0,y=0},0)
        r.behaviors[t.id]:Update(0.05)
        near(t.rotation, math.rad(Data.tuna.turnDegPerSec)*0.05)
        near(math.atan(t.position.y,t.position.x),t.rotation)
        near(M.distance(t.position,{x=0,y=0}),Data.tuna.chaseSpeed*0.05)
    end)
    check("moving predator and prey complete chase flee and real capture", function()
        local elapsedTotal, elapsedMin, elapsedMax=0,math.huge,0
        for seed=1,16 do
            local r=Runtime.New({initializeRegions=false,daySeed=seed,departure={x=400,y=400}})
            local s=r:spawnFish("sardine",{x=410,y=400},0)
            local t=r:spawnFish("tuna",{x=390,y=400},0)
            local chased,fled=false,false
            local elapsed=0
            for i=1,400 do
                r:Update(0.05)
                chased=chased or t.state=="Chase"
                fled=fled or s.state=="Flee"
                if s.removed then elapsed=i*0.05;break end
            end
            assert(chased and fled and s.removed,"moving chase failed for seed "..seed)
            assert(s.removeReason=="eaten" and not r.world:get(s.id))
            assert(#r:queryEntitiesInRadius(s.position,1,{species="sardine"})==0)
            assert(r.behaviors[s.id]==nil and r.world:getCounts().sardine==0)
            elapsedTotal=elapsedTotal+elapsed
            elapsedMin=math.min(elapsedMin,elapsed);elapsedMax=math.max(elapsedMax,elapsed)
        end
        metrics.movingCaptureMeanSec=elapsedTotal/16
        metrics.movingCaptureMinSec=elapsedMin;metrics.movingCaptureMaxSec=elapsedMax
    end)
    check("confirmed big fish attraction uses centralized implementation values", function()
        assert(Data.tuna.attractRadius==36 and Data.tuna.attractedSpeed==6.0)
        assert(Data.tuna.tuningStatus=="V1_IMPLEMENTATION_VALUE"
            and Data.tuna.attractionStatus=="V1_IMPLEMENTATION_VALUE")
        local r=fresh(); local t=r:spawnFish("tuna",{x=0,y=0})
        r:spawnDroppedItem({itemId="generic",worldEffect="ATTRACT_BIG_FISH"},{x=8,y=0})
        r:Update(0.05); assert(t.state=="Attracted")
        near(t.position.x,Data.tuna.attractedSpeed*0.05)
    end)
    check("supplement02 prey chase outranks big attraction", function()
        local r=fresh();local t=r:spawnFish("tuna",{x=0,y=0},0)
        r:spawnFish("sardine",{x=20,y=0})
        r:spawnDroppedItem({itemId="generic",worldEffect="ATTRACT_BIG_FISH"},{x=8,y=0})
        r:Update(0.05)
        assert(t.state=="Chase");near(t.position.x,Data.tuna.chaseSpeed*0.05)
    end)
    check("big attraction includes radius36 boundary and excludes outside", function()
        for _, distance in ipairs({Data.tuna.attractRadius,Data.tuna.attractRadius+0.1}) do
            local r=fresh();local t=r:spawnFish("tuna",{x=0,y=0},0)
            r.world:spawnDroppedItem({itemId="range",worldEffect="ATTRACT_BIG_FISH"},{x=distance,y=0})
            r:Update(0.05)
            assert(t.state==(distance<=Data.tuna.attractRadius and "Attracted" or "Wander"))
        end
    end)
    check("tuna attraction filters effects and respects turn rate", function()
        for _, effect in ipairs({"NONE","ATTRACT_SMALL_FISH"}) do
            local r=fresh();local t=r:spawnFish("tuna",{x=0,y=0})
            r:spawnDroppedItem({itemId="any-item",worldEffect=effect},{x=8,y=0})
            r:Update(0.05);assert(t.state=="Wander")
        end
        local r=fresh();local t=r:spawnFish("tuna",{x=0,y=0},0)
        r.world:spawnDroppedItem({itemId="turn",worldEffect="ATTRACT_BIG_FISH"},{x=0,y=Data.tuna.attractRadius})
        r:Update(0.05);assert(t.state=="Attracted")
        near(t.rotation,math.rad(Data.tuna.turnDegPerSec)*0.05)
        near(math.atan(t.position.y,t.position.x),t.rotation)
        near(M.distance(t.position,{x=0,y=0}),Data.tuna.attractedSpeed*0.05)
    end)
    check("big attraction expiry restores available prey chase", function()
        local r=fresh();local t=r:spawnFish("tuna",{x=0,y=0},0)
        local prey=r:spawnFish("sardine",{x=31,y=0})
        local bait=r:spawnDroppedItem({itemId="expiry",worldEffect="ATTRACT_BIG_FISH",lifetimeSec=0.1},{x=8,y=0})
        r:Update(0.05);assert(t.state=="Attracted")
        prey.position={x=20,y=0}
        r:Update(0.05);assert(not r.world:get(bait.id) and t.state=="Chase")
    end)
    check("tuna avoid outranks official big attraction and prey chase", function()
        local r=fresh();local bound=Config.world.halfSize
        r.ship.position={x=bound-20,y=0}
        local t=r:spawnFish("tuna",{x=bound-2,y=0})
        r:spawnFish("sardine",{x=bound-20,y=0})
        r:spawnDroppedItem({itemId="avoid",worldEffect="ATTRACT_BIG_FISH"},{x=bound-10,y=0})
        r:Update(0.05);assert(t.state=="Avoid")
    end)
    check("activity hysteresis and frozen state retention", function()
        local r=fresh(); local s=r:spawnFish("sardine",{x=121,y=0})
        assert(s.frozen); r.ship.position={x=1,y=0}; r.world:updateActivity(r.ship.position)
        assert(s.active and not s.frozen)
        r.ship.position={x=-19,y=0}; r.world:updateActivity(r.ship.position); assert(s.active)
        r.ship.position={x=-30,y=0}; r.world:updateActivity(r.ship.position); assert(s.frozen)
        local p=M.copy(s.position); local state=s.state; step(r,1)
        near(M.distance(p,s.position),0); assert(s.state==state)
        r.ship.position={x=10,y=0}; r.world:updateActivity(r.ship.position)
        assert(not s.frozen and r.world:get(s.id)==s)
    end)
    check("region seeds reproducible independent of exploration order", function()
        local w=World.New(); local dep={x=0,y=0}
        local a=Strategy.GenerateRegion(w,123,10,10,dep,Data)
        Strategy.GenerateRegion(w,123,9,10,dep,Data)
        local b=Strategy.GenerateRegion(w,123,10,10,dep,Data)
        assert(#a==#b)
        for i=1,#a do assert(a[i].species==b[i].species);near(M.distance(a[i].position,b[i].position),0) end
        local c=Strategy.GenerateRegion(w,124,10,10,dep,Data)
        assert(#c~=#a or M.distance(a[1].position,c[1].position)>0)
    end)
    check("tuna first spawn exclusion on all initialized regions", function()
        local r=Runtime.New()
        assert(#r:queryEntitiesInRadius(r.ship.position,120,{species="tuna"})==0)
        r.ship.position={x=400,y=0}; r:ensureNearbyRegions()
        local count=0
        for _,e in ipairs(r.world.entities) do
            if e.species=="tuna" then assert(M.distance(e.position,r.departure)>=200);count=count+1 end
        end
        assert(count>0)
    end)
    check("same-day regions do not refill after catch/clear/return", function()
        local r=Runtime.New(); local s=r:queryEntitiesInRadius({x=0,y=0},120,{species="sardine"})[1]
        assert(s); r.world:remove(s.id,"caught"); local count=r.world:getCounts().sardine
        step(r,2); assert(r.world:getCounts().sardine==count)
        r.ship.position={x=400,y=0}; r:ensureNearbyRegions()
        r.ship.position={x=0,y=0}; r:ensureNearbyRegions(); assert(not r.world:get(s.id))
        r:clearOrdinaryFish(); step(r,1); assert(r.world:getCounts().sardine==0 and r.world:getCounts().tuna==0)
    end)
    check("daily refresh clears temps/fish preserves fixed objects/ship", function()
        local r=Runtime.New(); local fixed=r.world.entities[1]; local ship=r.ship
        local old=r:queryEntitiesInRadius({x=0,y=0},120,{species="sardine"})[1]
        local item=r:spawnDroppedItem({itemId="temporary"},{x=0,y=0})
        r:refreshOrdinaryFish(42,{x=0,y=0})
        assert(r.world:get(fixed.id)==fixed and r.world:get(ship.id)==ship)
        assert(not r.world:get(old.id) and not r.world:get(item.id))
        assert(r.world:getCounts().sardine>0 and r.daySeed==42)
    end)
    check("local density measured across 100 day seeds away from departure", function()
        local totalS,totalT,totalActiveS,totalActiveT=0,0,0,0
        local startS,startT,viewS,viewT=0,0,0,0
        for seed=1,100 do
            local r=Runtime.New({daySeed=seed})
            startS=startS+#r:queryEntitiesInRadius(r.ship.position,120,{species="sardine"})
            startT=startT+#r:queryEntitiesInRadius(r.ship.position,120,{species="tuna"})
            r.ship.position={x=400,y=400};r:ensureNearbyRegions();r.world:updateActivity(r.ship.position)
            r.movement:SetViewport(1920,1080)
            r.movement:_AnchorCameraToShip()
            local nearby=r:queryEntitiesInRadius(r.ship.position,120,{entityType="fish"})
            for _,e in ipairs(nearby) do
                local x,y=r.movement:WorldToScreen(e.position)
                if x and y and x>=0 and x<=1920 and y>=r.movement:GetHorizonY() and y<=1080 then
                    if e.species=="sardine" then viewS=viewS+1 else viewT=viewT+1 end
                end
            end
            for _,e in ipairs(nearby) do if e.species=="sardine" then totalS=totalS+1 else totalT=totalT+1 end end
            for _,e in ipairs(r.world.entities) do
                if e.ordinaryFish and e.active then
                    if e.species=="sardine" then totalActiveS=totalActiveS+1 else totalActiveT=totalActiveT+1 end
                end
            end
        end
        metrics.startSardineIn120=startS/100;metrics.startTunaIn120=startT/100
        metrics.debugViewportSardine=viewS/100;metrics.debugViewportTuna=viewT/100
        metrics.hiddenViewportFish=0
        metrics.sardineIn120=totalS/100;metrics.tunaIn120=totalT/100
        metrics.sardineRunning=totalActiveS/100;metrics.tunaRunning=totalActiveT/100
        assert(metrics.sardineIn120>17 and metrics.sardineIn120<23)
        assert(metrics.tunaIn120>3 and metrics.tunaIn120<5)
    end)
    check("overlap callback removal leaves no stale entries after repeated collection", function()
        local r=fresh()
        local collected=0
        r.world.onOverlap=function(entity)
            if entity.entityType=="droppedItem" then
                collected=collected+1
                assert(r.world:remove(entity.id,"collected"))
            end
        end
        for _=1,100 do
            local item=r:spawnDroppedItem({itemId="overlap-removal",worldEffect="NONE"},r.ship.position)
            r:Update(0.05)
            assert(not r.world:get(item.id) and item.removed)
            assert(r.world.overlaps[item.id]==nil,"removed object retained overlap marker")
            assert(r.world:getCounts().temp==0)
        end
        assert(collected==100 and next(r.world.overlaps)==nil)
    end)
    return { results=results, metrics=metrics }
end
return Tests
