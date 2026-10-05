local Config = require("Ocean.Config")
local Math = require("Ocean.Math")
local Runtime = require("Ocean.SeaRuntime")

local Tests = {}

local function fresh(options)
    local runtimeOptions = {}
    for key, value in pairs(options or {}) do runtimeOptions[key] = value end
    if runtimeOptions.initializeRegions == nil then runtimeOptions.initializeRegions = false end
    if runtimeOptions.daySeed == nil then runtimeOptions.daySeed = 31415 end
    return Runtime.New(runtimeOptions)
end

local function copyPoint(point)
    return { x = point.x, y = point.y }
end

local function assertNear(actual, expected, epsilon)
    assert(math.abs(actual - expected) <= (epsilon or 0.00001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

local function assertStableBarrel(runtime, entity, expected)
    local snapshot = runtime:GetFixedBarrel()
    assert(snapshot ~= nil, "fixed barrel snapshot should remain available")
    assert(runtime.world.fixedBarrel == entity, "fixed barrel entity reference changed")
    assert(runtime.world:get(expected.id) == entity, "fixed barrel ID no longer resolves to its exact entity")
    assert(snapshot.id == expected.id, "fixed barrel ID changed")
    assert(snapshot.contentId == "driftwood_barrel", "fixed barrel content ID changed")
    assert(snapshot.generation == expected.generation, "fixed barrel generation changed")
    assertNear(snapshot.position.x, expected.position.x)
    assertNear(snapshot.position.y, expected.position.y)
end

local function pointToSegmentDistance(point, startPoint, endPoint)
    local dx, dy = endPoint.x - startPoint.x, endPoint.y - startPoint.y
    local lengthSquared = dx * dx + dy * dy
    if lengthSquared <= Config.world.epsilon then return Math.distance(point, startPoint) end
    local projection = ((point.x - startPoint.x) * dx + (point.y - startPoint.y) * dy) / lengthSquared
    local t = Math.clamp(projection, 0, 1)
    local closest = { x = startPoint.x + dx * t, y = startPoint.y + dy * t }
    return Math.distance(point, closest)
end

local function trackShipRoute(runtime, barrelId, barrelPosition, barrelRadius)
    ---@type string?
    local closestBlockerId = nil
    local route = {
        traveledDistance = 0.0,
        shipSteps = 0,
        collisionSteps = 0,
        minimumClearance = math.huge,
        closestBlockerId = closestBlockerId,
        blockingObjects = 0,
        seenBlockerIds = {},
    }
    local originalMoveEntity = runtime.world.moveEntity
    runtime.world.moveEntity = function(world, entity, dx, dy)
        if entity ~= runtime.ship then return originalMoveEntity(world, entity, dx, dy) end

        local startPoint = copyPoint(entity.position)
        local collided, normalX, normalY = originalMoveEntity(world, entity, dx, dy)
        local endPoint = copyPoint(entity.position)
        route.shipSteps = route.shipSteps + 1
        route.traveledDistance = route.traveledDistance + Math.distance(startPoint, endPoint)
        if collided then
            -- 木桶是教学碰撞体（真机反馈 #6，blocking=true）：贴桶停靠与原地
            -- 调头扫到桶体属预期玩法；只有其它阻挡物的碰撞才算航线违规。
            local barrelContact = pointToSegmentDistance(barrelPosition, startPoint, endPoint)
                <= entity.radius + barrelRadius + 0.05
            if not barrelContact then route.collisionSteps = route.collisionSteps + 1 end
        end

        for _, blocker in ipairs(world.entities) do
            if blocker ~= entity and not blocker.removed and blocker.blocking then
                if not route.seenBlockerIds[blocker.id] then
                    route.seenBlockerIds[blocker.id] = true
                    route.blockingObjects = route.blockingObjects + 1
                end
                if blocker.id == barrelId then
                    -- 木桶接触不计入最小净空（见上）。
                else
                    local centerDistance = pointToSegmentDistance(blocker.position, startPoint, endPoint)
                    local clearance = centerDistance - entity.radius - blocker.radius
                    if clearance < route.minimumClearance then
                        route.minimumClearance = clearance
                        route.closestBlockerId = blocker.id
                    end
                end
            end
        end
        return collided, normalX, normalY
    end
    return route, originalMoveEntity
end

local function sailTo(runtime, point, fixedStep)
    runtime.movement:SetTarget(point)
    local steps = 0
    while runtime.movement.target ~= nil do
        assert(steps < 2000, "ship did not reach waypoint")
        runtime:Update(fixedStep)
        steps = steps + 1
    end
    return steps
end

local function voyage(seed)
    local runtime = Runtime.New({ initializeRegions = true, daySeed = seed })
    runtime:SetShipLevel(1)
    local barrel = runtime:GetFixedBarrel()
    assert(barrel ~= nil, "voyage needs the fixed barrel")
    local barrelEntity = runtime.world.fixedBarrel
    local barrelPosition = copyPoint(barrel.position)
    local expectedBarrel = { id = barrel.id, generation = barrel.generation, position = barrelPosition }
    local initialCounts = runtime.world:getCounts()
    local initialFishCount = initialCounts.sardine + initialCounts.tuna
    assert(initialFishCount > 0, "voyage must use the seeded first-day fish population")

    local start = copyPoint(runtime.ship.position)
    assertNear(start.x, Config.ship.start.x)
    assertNear(start.y, Config.ship.start.y)
    assertNear(runtime.movement.speed, Config.ship.speedByLevel[1])
    local firstWaypoint = { x = 35, y = 5 }
    local theoreticalWaypointLength = Math.distance(start, firstWaypoint)
        + Math.distance(firstWaypoint, barrelPosition)
    local route, originalMoveEntity = trackShipRoute(runtime, barrel.id, barrelPosition, barrelEntity.radius)
    local fixedStep = 0.05
    local elapsedSteps = 0
    local visits = {}
    -- 木桶现为碰撞实体（真机反馈 #6）：不能把桶心设为目标（船会被 hull 挡在
    -- 半径和外），改为驶到桶旁。停靠点取 3.5m：船体最贴近 3.8m（半径和），
    -- 到达判定半径 1.5m 内必然清目标，最终停点必落在操作距离 5m 内。
    local barrelStandoff = 3.5
    local function barrelApproach(fromPoint)
        local dx, dy = barrelPosition.x - fromPoint.x, barrelPosition.y - fromPoint.y
        local length = Math.distance(fromPoint, barrelPosition)
        return { x = barrelPosition.x - dx / length * barrelStandoff,
            y = barrelPosition.y - dy / length * barrelStandoff }
    end
    local targets = {
        firstWaypoint,
        barrelApproach(firstWaypoint),
        { x = 85, y = 5 },
        barrelApproach({ x = 85, y = 5 }),
        { x = 85, y = 5 },
        barrelApproach({ x = 85, y = 5 }),
    }
    for targetIndex, target in ipairs(targets) do
        elapsedSteps = elapsedSteps + sailTo(runtime, target, fixedStep)
        if targetIndex == 2 or targetIndex == 4 or targetIndex == 6 then
            local beforeRuntimeTime, beforeWorldTime = runtime.time, runtime.world.time
            local beforeEntityCount = #runtime.world.entities
            local firstVisitSnapshot = runtime:GetFixedBarrel()
            local secondVisitSnapshot = runtime:GetFixedBarrel()
            local thirdVisitSnapshot = runtime:GetFixedBarrel()
            assert(firstVisitSnapshot and secondVisitSnapshot and thirdVisitSnapshot,
                "all three physical visits should resolve the barrel")
            assert(firstVisitSnapshot.id == barrel.id and secondVisitSnapshot.id == barrel.id
                and thirdVisitSnapshot.id == barrel.id, "all visits should resolve the same barrel ID")
            assert(firstVisitSnapshot.generation == barrel.generation
                and secondVisitSnapshot.generation == barrel.generation
                and thirdVisitSnapshot.generation == barrel.generation,
                "all visits should retain the same barrel generation")
            assert(runtime.world.fixedBarrel == barrelEntity,
                "all visits should retain the exact barrel entity reference")
            assertStableBarrel(runtime, barrelEntity, expectedBarrel)
            local endpointDistance = Math.distance(runtime.ship.position, barrelPosition)
            local canInteract, reason = runtime:CanInteractWithBarrel(barrel.id, barrel.generation)
            assert(canInteract, "ship visit is outside barrel operation range: " .. tostring(reason))
            assert(runtime.time == beforeRuntimeTime and runtime.world.time == beforeWorldTime,
                "barrel reads and range checks must not advance time or action progress")
            assert(#runtime.world.entities == beforeEntityCount,
                "barrel reads and range checks must not maintain or change the world")
            visits[#visits + 1] = {
                endpoint = copyPoint(runtime.ship.position),
                endpointDistance = endpointDistance,
                traveledDistance = route.traveledDistance,
                elapsedSec = elapsedSteps * fixedStep,
            }
        end
    end
    runtime.world.moveEntity = originalMoveEntity

    local endpointDistance = Math.distance(runtime.ship.position, barrelPosition)
    local canInteract, reason = runtime:CanInteractWithBarrel(barrel.id, barrel.generation)
    assert(route.shipSteps > 0, "voyage should move the ship through the world")
    assert(#visits == 3, "voyage should make three distinct physical visits")
    assert(route.blockingObjects > 0, "voyage should measure actual world blockers")
    -- 自动转向会触碰现有阻挡物并轻弹；当前约定要求不穿透，而非无接触。
    assert(route.minimumClearance >= -Config.world.epsilon,
        "actual swept route penetrated a blocker: " .. tostring(route.minimumClearance))
    assert(canInteract, "ship did not finish within barrel operation distance: " .. tostring(reason))
    assert(endpointDistance <= Config.interaction.operateDistance,
        "voyage endpoint exceeded barrel operation range")
    assert(runtime.world.fixedBarrel == barrelEntity, "voyage replaced the fixed barrel")
    assertStableBarrel(runtime, barrelEntity, expectedBarrel)

    return {
        seed = seed,
        initialFishCount = initialFishCount,
        fixedStepSec = fixedStep,
        elapsedSec = elapsedSteps * fixedStep,
        traveledDistance = route.traveledDistance,
        theoreticalWaypointLength = theoreticalWaypointLength,
        shipSteps = route.shipSteps,
        collisionSteps = route.collisionSteps,
        minimumClearance = route.minimumClearance,
        closestBlockerId = route.closestBlockerId,
        blockingObjectsMeasured = route.blockingObjects,
        visits = visits,
        endpoint = copyPoint(runtime.ship.position),
        endpointDistance = endpointDistance,
        operationDistance = Config.interaction.operateDistance,
    }
end

function Tests.Run()
    local results = {}
    local metrics = { voyages = {} }
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("fixed barrel getter identifies one exact float and returns read-only snapshots", function()
        local runtime = fresh()
        local entity = runtime.world.fixedBarrel
        local first = runtime:GetFixedBarrel()
        local second = runtime:GetFixedBarrel()
        local third = runtime:GetFixedBarrel()
        assert(first and second and third, "three consecutive getter accesses should succeed")
        assert(first ~= second and second ~= third, "each access should return a fresh snapshot")
        assert(first.position ~= second.position and second.position ~= third.position,
            "each access should return a fresh nested position snapshot")
        assert(first.id == entity.id and second.id == entity.id and third.id == entity.id,
            "all accesses must identify the same registered entity")
        assert(first.generation == runtime.world.fixedBarrelGeneration
            and second.generation == first.generation and third.generation == first.generation)
        assert(first.contentId == "driftwood_barrel" and entity.contentId == first.contentId)
        -- 真机反馈（2026-10-04 七项修复 #6）：木桶与岛屿一样拥有碰撞实体（blocking）。
        -- B 侧 v2.2 曾改回非碰撞，按用户显式反馈恢复碰撞语义。
        assert(entity.kind == "fixed" and entity.entityType == "float" and entity.blocking == true,
            "barrel is a fixed blocking float (tutorial collision)")
        assertNear(entity.radius, Config.world.fixedBarrel.radius)
        assertNear(first.position.x, Config.world.fixedBarrel.position.x)
        assertNear(first.position.y, Config.world.fixedBarrel.position.y)
        assert(runtime.world:get(first.id) == entity, "getter identity must match the world registry")

        local otherFloatCount = 0
        local otherFixedCount = 0
        for _, worldEntity in ipairs(runtime.world.entities) do
            if worldEntity.entityType == "float" and worldEntity ~= entity then
                otherFloatCount = otherFloatCount + 1
                assert(first.id ~= worldEntity.id,
                    "the getter must not substitute an existing generic float")
            end
            if worldEntity.kind == "fixed" and worldEntity ~= entity then
                otherFixedCount = otherFixedCount + 1
            end
        end
        assert(otherFloatCount > 0, "fixture should include the pre-existing generic float")
        assert(otherFixedCount == #Config.world.fixedObjects,
            "the barrel should be added beside the three original fixed objects")

        local writeSucceeded = pcall(function() first.id = "changed" end)
        assert(not writeSucceeded, "top-level snapshot writes must fail")
        writeSucceeded = pcall(function() first.position.x = -9999 end)
        assert(not writeSucceeded, "nested position snapshot writes must fail")
        writeSucceeded = pcall(function() first.position = { x = -9999, y = -9999 } end)
        assert(not writeSucceeded, "replacing the nested position snapshot must fail")

        local repeated = runtime:GetFixedBarrel()
        assert(repeated.id == first.id and repeated.generation == first.generation)
        assertNear(repeated.position.x, first.position.x)
        assertNear(repeated.position.y, first.position.y)
        assert(entity.position.x == Config.world.fixedBarrel.position.x
            and entity.position.y == Config.world.fixedBarrel.position.y,
            "snapshot mutation attempts must leave world coordinates unchanged")
    end)

    check("fish clearing and repeated day refreshes preserve the fixed barrel", function()
        local runtime = fresh({ daySeed = Config.world.seed })
        local entity = runtime.world.fixedBarrel
        local initial = runtime:GetFixedBarrel()
        local expected = { id = initial.id, generation = initial.generation,
            position = copyPoint(initial.position) }
        local fish = runtime:spawnFish("sardine", { x = 0, y = 20 }, 0)
        assert(runtime.world:get(fish.id) == fish)

        runtime:clearOrdinaryFish()
        assert(runtime.world:get(fish.id) == nil, "fixture fish should be cleared")
        assertStableBarrel(runtime, entity, expected)

        for _, seed in ipairs({ 271828, 314159, 161803 }) do
            runtime:refreshOrdinaryFish(seed, runtime.ship.position)
            assert(runtime.daySeed == seed, "refresh should use the requested day seed")
            assertStableBarrel(runtime, entity, expected)
            runtime:Update(0.05)
            assertStableBarrel(runtime, entity, expected)
        end
    end)

    check("reset and new runtimes reject stale barrel credentials after ID reuse", function()
        local runtime = fresh()
        local oldSnapshot = runtime:GetFixedBarrel()
        local oldEntity = runtime.world.fixedBarrel
        assert(oldSnapshot ~= nil)

        runtime:Reset()
        local afterReset = runtime:GetFixedBarrel()
        assert(afterReset ~= nil and runtime.world.fixedBarrel ~= oldEntity)
        assert(afterReset.id == oldSnapshot.id, "reset fixture should exercise a reused barrel ID")
        assert(afterReset.generation ~= oldSnapshot.generation,
            "new World generation must differ after reset")
        local allowed, reason = runtime:CanInteractWithBarrel(oldSnapshot.id, oldSnapshot.generation)
        assert(not allowed and reason == "barrel_generation_mismatch",
            "reset must invalidate the old ID/generation pair")

        local separateRuntime = fresh()
        local separateSnapshot = separateRuntime:GetFixedBarrel()
        assert(separateSnapshot ~= nil and separateSnapshot.id == oldSnapshot.id,
            "new Runtime fixture should also reuse the barrel ID")
        assert(separateSnapshot.generation ~= oldSnapshot.generation,
            "separate Runtime world generation must differ")
        allowed, reason = separateRuntime:CanInteractWithBarrel(oldSnapshot.id, oldSnapshot.generation)
        assert(not allowed and reason == "barrel_generation_mismatch",
            "new Runtime must invalidate credentials from the previous Runtime")
    end)

    check("barrel interaction rejects wrong identity and generation", function()
        local runtime = fresh()
        local barrel = runtime:GetFixedBarrel()
        assert(barrel ~= nil)
        runtime.ship.position = copyPoint(barrel.position)

        local allowed, reason = runtime:CanInteractWithBarrel(barrel.id .. "-wrong", barrel.generation)
        assert(not allowed and reason == "barrel_identity_mismatch", tostring(reason))
        allowed, reason = runtime:CanInteractWithBarrel(barrel.id, barrel.generation + 1)
        assert(not allowed and reason == "barrel_generation_mismatch", tostring(reason))
    end)

    check("removed, dead, nonfinite, or registry-replaced barrels are unavailable", function()
        local removedRuntime = fresh()
        local removedSnapshot = removedRuntime:GetFixedBarrel()
        assert(removedSnapshot ~= nil)
        assert(removedRuntime.world:remove(removedSnapshot.id, "test_removed"))
        assert(removedRuntime:GetFixedBarrel() == nil)
        local allowed, reason = removedRuntime:CanInteractWithBarrel(removedSnapshot.id, removedSnapshot.generation)
        assert(not allowed and reason == "barrel_unavailable", tostring(reason))

        local deadRuntime = fresh()
        local deadSnapshot = deadRuntime:GetFixedBarrel()
        assert(deadSnapshot ~= nil)
        deadRuntime.world.fixedBarrel.alive = false
        assert(deadRuntime:GetFixedBarrel() == nil, "dead but indexed barrel should be hidden")
        allowed, reason = deadRuntime:CanInteractWithBarrel(deadSnapshot.id, deadSnapshot.generation)
        assert(not allowed and reason == "barrel_unavailable", tostring(reason))

        local invalidRuntime = fresh()
        local invalidSnapshot = invalidRuntime:GetFixedBarrel()
        assert(invalidSnapshot ~= nil)
        local invalidEntity = invalidRuntime.world.fixedBarrel
        for _, invalidPosition in ipairs({
            { x = 0 / 0, y = 25 },
            { x = math.huge, y = 25 },
            { x = 60, y = -math.huge },
        }) do
            invalidEntity.position = invalidPosition
            assert(invalidRuntime:GetFixedBarrel() == nil,
                "barrel getter must reject NaN and infinite coordinates")
            allowed, reason = invalidRuntime:CanInteractWithBarrel(invalidSnapshot.id, invalidSnapshot.generation)
            assert(not allowed and reason == "barrel_unavailable", tostring(reason))
        end

        local replacementRuntime = fresh()
        local replacementSnapshot = replacementRuntime:GetFixedBarrel()
        assert(replacementSnapshot ~= nil)
        replacementRuntime.world.byId[replacementSnapshot.id] = {
            id = replacementSnapshot.id,
            contentId = "driftwood_barrel",
            alive = true,
            removed = false,
            position = copyPoint(replacementSnapshot.position),
        }
        assert(replacementRuntime:GetFixedBarrel() == nil,
            "same-ID byId replacement must not replace the exact registered barrel object")
        allowed, reason = replacementRuntime:CanInteractWithBarrel(
            replacementSnapshot.id, replacementSnapshot.generation)
        assert(not allowed and reason == "barrel_unavailable", tostring(reason))
    end)

    check("barrel interaction rejects invalid ship coordinates", function()
        local runtime = fresh()
        local barrel = runtime:GetFixedBarrel()
        assert(barrel ~= nil)
        for _, invalidPosition in ipairs({
            { x = 0 / 0, y = 25 },
            { x = 60, y = math.huge },
            { x = -math.huge, y = 25 },
        }) do
            runtime.ship.position = invalidPosition
            local allowed, reason = runtime:CanInteractWithBarrel(barrel.id, barrel.generation)
            assert(not allowed and reason == "invalid_ship_position", tostring(reason))
        end
    end)

    check("barrel operation distance includes exactly five meters", function()
        local runtime = fresh()
        local barrel = runtime:GetFixedBarrel()
        assert(barrel ~= nil)
        assertNear(Config.interaction.operateDistance, 5)
        assert(#Config.world.fixedObjects == 3, "the original fixed-object set should remain unchanged")

        for index, originalObject in ipairs(Config.world.fixedObjects) do
            ---@type SeaEntity
            local entity = runtime.world.entities[index]
            assert(entity.entityType == originalObject.entityType,
                "original fixed object type changed at index " .. tostring(index))
            assertNear(entity.position.x, originalObject.position.x)
            assertNear(entity.position.y, originalObject.position.y)
            assertNear(entity.radius, originalObject.radius)
            assert(entity.blocking == originalObject.blocking,
                "original fixed object blocking flag changed at index " .. tostring(index))
        end

        runtime.ship.position = { x = barrel.position.x - 3, y = barrel.position.y - 4 }
        local allowed, reason = runtime:CanInteractWithBarrel(barrel.id, barrel.generation)
        assert(allowed, "the exact 3-4-5 distance should be interactable: " .. tostring(reason))

        runtime.ship.position = { x = barrel.position.x - 3.000001, y = barrel.position.y - 4 }
        allowed, reason = runtime:CanInteractWithBarrel(barrel.id, barrel.generation)
        assert(not allowed and reason == "barrel_out_of_range", tostring(reason))
    end)

    check("blocking barrel stops the ship but keeps water actions and fish avoidance unchanged", function()
        local runtime = fresh()
        local barrel = runtime:GetFixedBarrel()
        assert(barrel ~= nil)
        -- 真机反馈 #6：木桶拥有碰撞实体——迎面直行必须被桶体挡下（swept-circle）。
        runtime.ship.position = { x = barrel.position.x - 6, y = barrel.position.y }
        local collided = runtime.world:moveEntity(runtime.ship, 12, 0)
        assert(collided, "barrel collision entity must block the ship")
        assert(runtime.ship.position.x < barrel.position.x - Config.world.fixedBarrel.radius,
            "ship must not penetrate the barrel hull")
        assert(not runtime:canCastNet(barrel.position),
            "barrel hull itself is not legal casting water (blocking entity)")
        -- 桶旁 4m：超出桶体半径 2 + 金枪鱼半径 1.1 的自由水域判定。
        local beside = { x = barrel.position.x + Config.world.fixedBarrel.radius + 2, y = barrel.position.y }
        assert(runtime:canCastNet(beside), "water beside the barrel remains legal")
        local fish = runtime:spawnFish("tuna", beside)
        -- 碰撞语义（真机反馈 #6）的自然结果：鱼类避障把 blocking 木桶视为障碍物。
        assert(runtime.world:getAvoidance(fish, 6) ~= nil, "blocking barrel must trigger fish avoidance")
        assert(runtime.world.fixedBarrel.id == barrel.id, "collision must not consume or replace the barrel")
    end)

    check("default first-day voyages reach operation range without penetrating blockers", function()
        for _, seed in ipairs({ Config.world.seed, 314159 }) do
            metrics.voyages[#metrics.voyages + 1] = voyage(seed)
        end
        local first = metrics.voyages[1]
        -- 桶位 (14,6)：dist(start,(35,5))=√1250 ≈ 35.3553，dist((35,5),(14,6))=√442 ≈ 21.0238。
        assertNear(first.theoreticalWaypointLength, 56.3791, 0.001)
        -- 起点/木桶几何已改；按当前路径和停车半径核对，不锁死旧坐标的里程。
        assert(first.visits[1].traveledDistance >= first.theoreticalWaypointLength
            - Config.interaction.operateDistance - 2 * Config.ship.arrivalRadius,
            "first physical visit must traverse the waypoint route rather than teleport")
        assert(first.visits[1].elapsedSec < require("config.gameplay").clock.daySec,
            "the tutorial barrel should be reachable during the first daylight phase")
    end)

    return { results = results, metrics = metrics }
end

return Tests
