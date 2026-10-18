local AutoNavigation = require("Ocean.AutoNavigation")
local Runtime = require("Ocean.SeaRuntime")
local Geometry = AutoNavigation.Geometry
local Tests = {}

local function quietDiagnostic() end

local function point(x, y)
    return { x = x, y = y }
end

local function copyPoint(value)
    return value and { x = value.x, y = value.y } or nil
end

local function distance(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function eq(actual, expected, label)
    assert(actual == expected,
        (label or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

local function near(actual, expected, epsilon, label)
    assert(type(actual) == "number" and math.abs(actual - expected) <= (epsilon or 0.00001),
        (label or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

local function makeAdapter(options)
    options = options or {}
    local state = {
        position = copyPoint(options.position or point(30, 0)),
        blockers = options.blockers or {},
        target = nil,
        valid = options.valid ~= false,
        events = {},
    }
    local adapter = {
        shipRadius = options.shipRadius or 1.8,
        halfSize = options.halfSize or 1440,
    }

    function adapter.getPosition()
        return copyPoint(state.position)
    end

    function adapter.getBlockers()
        if options.rawBlockers then return state.blockers end
        local snapshot = {}
        for index, blocker in ipairs(state.blockers) do
            local item = {}
            for key, value in pairs(blocker) do
                item[key] = key == "position" and copyPoint(value) or value
            end
            snapshot[index] = item
        end
        return snapshot
    end

    function adapter.getTarget()
        return state.target
    end

    function adapter.setTarget(value)
        state.target = copyPoint(value)
        return state.target
    end

    function adapter.isValid()
        return state.valid
    end

    adapter.diagnostic = options.diagnostic or function(event, fields)
        state.events[#state.events + 1] = { event = event, fields = fields }
    end

    function state.setPosition(value)
        state.position = copyPoint(value)
    end

    function state.setBlockers(values)
        state.blockers = values
    end

    function state.setManualTarget(value)
        return adapter.setTarget(value)
    end

    return adapter, state
end

local function advance(nav, seconds, step)
    step = step or 0.25
    local remaining = seconds
    while remaining > 0 do
        local delta = math.min(step, remaining)
        nav:Update(delta)
        remaining = remaining - delta
    end
end

local function runRealVoyage(departure, level, reverseHeading, expectedObstacle)
    local runtime = Runtime.New({
        initializeRegions = false,
        daySeed = 314159,
        autoReturnDiagnostic = quietDiagnostic,
        departure = copyPoint(departure),
        shipLevel = level,
    })
    local expectedLevel, expectedSpeed = runtime.movement.level, runtime.movement.speed
    local collisionHits = 0
    local moveEntity = runtime.world.moveEntity
    runtime.world.moveEntity = function(world, entity, dx, dy)
        local hit, normalX, normalY = moveEntity(world, entity, dx, dy)
        if entity == runtime.ship and hit then collisionHits = collisionHits + 1 end
        return hit, normalX, normalY
    end
    local port = runtime:GetPortPosition()
    local desired = math.atan(port.y - departure.y, port.x - departure.x)
    runtime.ship.rotation = desired + (reverseHeading and math.pi or 0)

    local started, reason = runtime:StartAutoReturn()
    assert(started, "StartAutoReturn rejected: " .. tostring(reason))
    if expectedObstacle then
        local expectedId
        if expectedObstacle.kind == "barrel" then
            local barrel = runtime.world.fixedBarrel
            assert(barrel and barrel.blocking == true, "fixed barrel is not a real blocker")
            expectedId = tostring(barrel.id)
        else
            for _, entity in ipairs(runtime.world.entities) do
                if entity and entity.blocking == true
                    and entity.position.x == expectedObstacle.x
                    and entity.position.y == expectedObstacle.y then
                    expectedId = tostring(entity.id)
                end
            end
        end
        assert(expectedId, "expected world blocker is missing")
        eq(runtime:GetAutoReturnState().obstacleId, expectedId, "first actual blocker id")
    end

    local mixedDt = { 1 / 60, 1 / 30, 0.1, 0.25, 1.5 }
    local contacts = 0
    local state
    for tick = 1, 7500 do
        runtime:Update(mixedDt[((tick - 1) % #mixedDt) + 1], 0, 0)
        state = runtime:GetAutoReturnState()
        if (runtime.movement.pushRemaining or 0) > 0 then
            contacts = contacts + 1
        end
        assert(state.planCount <= AutoNavigation.Defaults.maxPlans,
            "plan budget exceeded")
        assert(state.retryCount <= AutoNavigation.Defaults.maxStuckRetries,
            "stuck retry budget exceeded")
        assert(state.phase ~= "failed",
            "navigation failed: " .. tostring(state.failureReason))
        if state.phase == "arrival_ready" then break end
    end

    state = runtime:GetAutoReturnState()
    eq(state.phase, "arrival_ready", "real runtime voyage phase")
    eq(contacts, 0, "collision push steps")
    local arrival = runtime:ConsumeAutoReturnArrival()
    assert(arrival, "arrival handshake missing")
    near(arrival.portPosition.x, port.x, 0.00001, "arrival port x")
    near(arrival.portPosition.y, port.y, 0.00001, "arrival port y")
    assert(arrival.distance <= AutoNavigation.Defaults.portRadius,
        "arrival outside port radius")
    eq(arrival.requestId, state.requestId, "arrival request id")
    eq(runtime:GetAutoReturnState().phase, "arrival_consumed", "consumed phase")
    eq(collisionHits, 0, "actual world collision hits")
    eq(runtime.movement.level, expectedLevel, "ship level unchanged")
    near(runtime.movement.speed, expectedSpeed, 0.000001, "ship speed unchanged")
end

local function installWorldCollisionSpy(runtime)
    local stats = { hits = 0, barrelHits = 0, otherHits = 0 }
    local barrel = runtime.world.fixedBarrel
    assert(barrel and barrel.blocking == true, "fixture requires the real blocking barrel")
    local moveEntity = runtime.world.moveEntity
    runtime.world.moveEntity = function(world, entity, dx, dy)
        local hit, normalX, normalY = moveEntity(world, entity, dx, dy)
        if entity == runtime.ship and hit then
            stats.hits = stats.hits + 1
            local nearestContact, nearestError, nearestDistance
            for _, candidate in ipairs(world.entities) do
                if not candidate.removed and candidate.blocking and candidate.id ~= entity.id then
                    local contactDistance = distance(entity.position, candidate.position)
                    local contactError = math.abs(contactDistance - (entity.radius + candidate.radius))
                    if nearestError == nil or contactError < nearestError then
                        nearestContact, nearestError, nearestDistance = candidate, contactError, contactDistance
                    end
                end
            end
            if rawequal(nearestContact, barrel) and nearestError <= 0.0001 then
                stats.barrelHits = stats.barrelHits + 1
                stats.barrelContactEntity = nearestContact
                stats.barrelContactDistance = nearestDistance
                stats.barrelContactRadius = entity.radius + barrel.radius
                stats.barrelContactError = nearestError
            else
                stats.otherHits = stats.otherHits + 1
            end
        end
        return hit, normalX, normalY
    end
    return stats
end

local function assertFixedBarrelContact(stats, runtime, label)
    local barrel = runtime.world.fixedBarrel
    assert(barrel and barrel.blocking == true, (label or "fixture") .. ": fixed barrel must block movement")
    assert(stats.hits > 0 and stats.barrelHits > 0,
        (label or "fixture") .. ": no collision was attributed to the fixed barrel")
    eq(rawequal(stats.barrelContactEntity, barrel), true, (label or "fixture") .. " collision identity")
    near(stats.barrelContactDistance, runtime.ship.radius + barrel.radius, 0.0001,
        (label or "fixture") .. " barrel contact distance")
    near(stats.barrelContactError, 0, 0.0001, (label or "fixture") .. " nearest contact error")
end

local function installStopSpy(runtime)
    local stop = runtime.movement.Stop
    assert(type(stop) == "function", "Movement.Stop is missing")
    local calls = 0
    runtime.movement.Stop = function(movement)
        calls = calls + 1
        return stop(movement)
    end
    return function() return calls end
end

local function moveIntoBarrelPush(runtime, stats, useRuntimeUpdate)
    for _ = 1, 240 do
        if useRuntimeUpdate then
            runtime:Update(0.05, 0, 0)
        else
            runtime.movement:Update(0.05, 0, 0)
        end
        if stats.barrelHits > 0 and runtime.movement.pushRemaining > 0 then
            return
        end
    end
    error("fixture did not produce a real barrel collision and pending push")
end

local function makeCollisionRuntime()
    return Runtime.New({
        initializeRegions = false,
        daySeed = 314159,
        autoReturnDiagnostic = quietDiagnostic,
        departure = point(30, 0),
        shipLevel = 3,
    })
end
function Tests.Run()
    local results = {}
    local function check(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = {
            name = name,
            passed = ok,
            error = ok and "" or tostring(err),
        }
    end

    check("defaults and segment entry cover endpoint contact and a zero-length interior segment", function()
        local defaults = AutoNavigation.Defaults
        near(defaults.safetyMargin, 8)
        near(defaults.waypointRadius, 1.5)
        near(defaults.portRadius, 10)
        near(defaults.progressMeters, 1)
        near(defaults.stuckWindowSec, 4)
        eq(defaults.maxStuckRetries, 2)
        eq(defaults.maxPlans, 16)
        near(defaults.checkIntervalSec, 0.5)
        near(defaults.maxLegSec, 600)
        near(defaults.maxDurationSec, 900)
        eq(defaults.maxBlockers, 128)

        near(Geometry.SegmentEntry(point(0, 0), point(1, 0), point(2, 0), 1.5),
            0.5, 0.000002, "endpoint example")
        near(Geometry.SegmentEntry(point(2, 0), point(2, 0), point(2, 0), 1),
            0, 0.000001, "zero-length segment in circle")
        eq(Geometry.SegmentEntry(point(0, 0), point(1, 0), point(5, 0), 1), nil,
            "non-intersecting segment")
    end)

    check("geometry emits only the two tangent-line intersection candidates and validates both", function()
        local start, goal = point(0, 0), point(30, 0)
        local blocker = {
            id = "center",
            position = point(15, 0),
            radius = 1,
            blocking = true,
        }
        local candidates = Geometry.GenerateCandidates(start, goal, blocker, 1.8, 8)
        local count = 0
        for side, candidate in pairs(candidates) do
            assert(side == "left" or side == "right", "unexpected candidate side")
            assert(type(candidate) == "table", "candidate point missing")
            local valid, reason = Geometry.CandidateValid(
                start, goal, candidate, blocker, { blocker }, 1.8, 8, 1440)
            assert(valid, "candidate rejected: " .. tostring(reason))
            count = count + 1
        end
        eq(count, 2, "candidate count")

        local plan, reason = Geometry.Plan(start, goal, { blocker }, 1.8, 1440)
        assert(plan, "detour plan missing: " .. tostring(reason))
        eq(plan.kind, "detour")
        eq(plan.obstacleId, "center")
        assert(plan.side == "left" or plan.side == "right")
    end)

    check("planner has direct, one-side-only, shortest-side, stable-tie, and order-independent routes", function()
        local start, goal = point(0, 0), point(30, 0)
        local main = { id = "main", position = point(15, 0), radius = 1, blocking = true }
        local direct = Geometry.Plan(start, goal, {}, 1.8, 1440)
        assert(direct)
        eq(direct.kind, "direct")

        local candidates = Geometry.GenerateCandidates(start, goal, main, 1.8, 8)
        assert(candidates.left and candidates.right)
        local leftBlocked = {
            main,
            { id = "left-only", position = candidates.left, radius = 1, blocking = true },
        }
        local rightOnly = Geometry.Plan(start, goal, leftBlocked, 1.8, 1440)
        assert(rightOnly)
        eq(rightOnly.kind, "detour")
        eq(rightOnly.side, "right")

        local rightBlocked = {
            main,
            { id = "right-only", position = candidates.right, radius = 1, blocking = true },
        }
        local leftOnly = Geometry.Plan(start, goal, rightBlocked, 1.8, 1440)
        assert(leftOnly)
        eq(leftOnly.kind, "detour")
        eq(leftOnly.side, "left")

        local bothBlocked = {
            main,
            { id = "left-only", position = candidates.left, radius = 1, blocking = true },
            { id = "right-only", position = candidates.right, radius = 1, blocking = true },
        }
        local noRoute, noRouteReason = Geometry.Plan(start, goal, bothBlocked, 1.8, 1440)
        eq(noRoute, nil)
        eq(noRouteReason, "no_viable_detour")

        local offset = { id = "offset", position = point(15, 2), radius = 1, blocking = true }
        local shorter = Geometry.Plan(start, goal, { offset }, 1.8, 1440)
        assert(shorter)
        eq(shorter.kind, "detour")
        eq(shorter.side, "right")

        local tiedA = Geometry.Plan(start, goal, { main }, 1.8, 1440)
        local tiedB = Geometry.Plan(start, goal, {
            { id = "off-path", position = point(0, 40), radius = 1, blocking = true },
            main,
        }, 1.8, 1440)
        assert(tiedA and tiedB)
        eq(tiedA.side, "left")
        eq(tiedB.side, "left")
        near(tiedA.target.x, tiedB.target.x, 0.000001)
        near(tiedA.target.y, tiedB.target.y, 0.000001)
    end)

    check("planner and candidate validation reject world bounds and actual-circle collision", function()
        local blocker = { id = "main", position = point(15, 0), radius = 1, blocking = true }
        local valid, reason = Geometry.CandidateValid(
            point(0, 0), point(8, 0), point(14, 0), blocker, { blocker }, 1.8, 8, 15)
        eq(valid, false)
        eq(reason, "world_bounds")

        valid, reason = Geometry.CandidateValid(
            point(0, 0), point(30, 0), point(15, 0), blocker, { blocker }, 1.8, 8, 1440)
        eq(valid, false)
        eq(reason, "no_viable_detour")

        local plan, planReason = Geometry.Plan(
            point(-12, -12), point(12, 12),
            { { id = "wide", position = point(0, 0), radius = 4, blocking = true } },
            1.8, 15)
        eq(plan, nil)
        eq(planReason, "world_bounds")
    end)

    check("nearest blocker returns exact entry and resolves equal entries by id regardless of order", function()
        local nearBlocker = {
            id = "near",
            position = point(-70, 0),
            radius = 5,
            blocking = true,
        }
        local sideBlocker = {
            id = "side",
            position = point(-35, 8),
            radius = 5,
            blocking = true,
        }
        local nearest, entry = Geometry.NearestBlocker(
            point(-100, 0), point(0, 0), { sideBlocker, nearBlocker }, 1.8, 0)
        eq(nearest.id, "near")
        near(entry, 0.232, 0.000002, "nearest blocker entry")
        local reversed, reversedEntry = Geometry.NearestBlocker(
            point(-100, 0), point(0, 0), { nearBlocker, sideBlocker }, 1.8, 0)
        eq(reversed.id, "near")
        near(reversedEntry, entry, 0.000001)

        local alpha = { id = "alpha", position = point(0, 0), radius = 1, blocking = true }
        local zeta = { id = "zeta", position = point(0, 0), radius = 1, blocking = true }
        local tied, tiedEntry = Geometry.NearestBlocker(
            point(-10, 0), point(10, 0), { zeta, alpha }, 1, 0)
        eq(tied.id, "alpha")
        near(tiedEntry, 0.4, 0.000002)
        tied = Geometry.NearestBlocker(point(-10, 0), point(10, 0), { alpha, zeta }, 1, 0)
        eq(tied.id, "alpha")
    end)
    check("geometry rejects a ship already inside an actual circle and a target inside one", function()
        local blocker = {
            id = "solid",
            position = point(0, 0),
            radius = 2,
            blocking = true,
        }
        local plan, reason = Geometry.Plan(point(0, 0), point(30, 0), { blocker }, 1.8, 1440)
        eq(plan, nil)
        eq(reason, "invalid_runtime")

        plan, reason = Geometry.Plan(point(-30, 0), point(0, 0), { blocker }, 1.8, 1440)
        eq(plan, nil)
        eq(reason, "invalid_target")

        plan, reason = Geometry.Plan(point(0, 0), point(1440, 0), {}, 1.8, 1440)
        eq(plan, nil)
        eq(reason, "invalid_target")
    end)

    check("geometry chooses the next blocker on the segment and ignores inactive circles", function()
        local blockers = {
            { id = "later", position = point(-35, 8), radius = 5, blocking = true },
            { id = "first", position = point(-70, 0), radius = 5, blocking = true },
            { id = "nonblocking", position = point(-85, 0), radius = 5, blocking = false },
            { id = "removed", position = point(-90, 0), radius = 5, blocking = true, removed = true },
        }
        local plan, reason = Geometry.Plan(point(-100, 0), point(0, 0), blockers, 1.8, 1440)
        assert(plan, "multi-circle plan missing: " .. tostring(reason))
        eq(plan.kind, "detour")
        eq(plan.obstacleId, "first")
    end)

    check("port radius boundary is inclusive at nine meters and accepts twelve and sixteen", function()
        for _, d in ipairs({ 9, 12, 16 }) do
            local adapter, state = makeAdapter({ position = point(d, 0) })
            local nav = AutoNavigation.New(adapter)
            local started, reason = nav:Start(point(0, 0))
            if d == 9 then
                eq(started, false)
                eq(reason, "already_near_port")
                eq(nav:GetFailure(), "already_near_port")
                eq(state.target, nil)
            else
                assert(started, "distance " .. d .. " rejected: " .. tostring(reason))
                eq(nav:GetState().phase, "active")
                assert(state.target, "accepted start did not set movement target")
            end
        end
    end)

    check("start copies the port and state snapshots, and duplicate active starts are refused", function()
        local adapter, state = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter)
        local port = point(0, 0)
        local started, reason = nav:Start(port)
        assert(started, tostring(reason))
        port.x = 500
        port.y = 500

        local first = nav:GetState()
        eq(first.phase, "active")
        eq(first.planCount, 1)
        eq(first.requestId, 1)
        near(first.portPosition.x, 0)
        near(first.portPosition.y, 0)
        first.active = false
        first.target.x = 999
        first.portPosition.y = 999
        local nextState = nav:GetState()
        eq(nextState.active, true)
        near(nextState.target.x, 0)
        near(nextState.portPosition.y, 0)
        assert(not rawequal(first.target, nextState.target), "state target was not copied")

        local oldTarget = state.target
        local plans, requestId = nextState.planCount, nextState.requestId
        local duplicate, duplicateReason = nav:Start(point(0, 0))
        eq(duplicate, false)
        eq(duplicateReason, "already_active")
        eq(rawequal(state.target, oldTarget), true)
        eq(nav:GetState().planCount, plans)
        eq(nav:GetState().requestId, requestId)
    end)

    check("cancel clears its own target idempotently", function()
        local adapter, state = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        assert(state.target)
        eq(nav:Cancel("test_cancel"), true)
        eq(state.target, nil)
        eq(nav:GetState().phase, "cancelled")
        eq(nav:GetState().cancelReason, "test_cancel")
        eq(nav:Cancel("repeat"), true)
        eq(state.target, nil)
    end)

    check("cancel preserves a manual target with a different movement identity", function()
        local adapter, state = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        local ownedTarget = state.target
        local manualTarget = state.setManualTarget(point(12, 7))
        assert(not rawequal(ownedTarget, manualTarget), "test adapter reused target identity")
        eq(nav:Cancel("manual_override"), true)
        eq(rawequal(state.target, manualTarget), true)
        eq(nav:GetState().phase, "cancelled")
    end)

    check("update detects an external same-coordinate replacement without clearing it", function()
        local adapter, state = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        local manualTarget = state.setManualTarget(point(0, 0))
        nav:Update(0.05)
        eq(nav:GetState().phase, "cancelled")
        eq(nav:GetState().cancelReason, "movement_overridden")
        eq(rawequal(state.target, manualTarget), true)
    end)

    check("controller update observes position without moving it and clamps one update to a quarter second", function()
        local adapter, state = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        nav:Update(1000)
        near(state.position.x, 30)
        near(state.position.y, 0)
        near(nav:GetState().elapsed, 0.25)
        near(nav:GetState().noProgressSec, 0.25)
    end)

    check("a newly blocking current leg is rechecked at the half-second interval", function()
        local adapter, state = makeAdapter({ position = point(50, 0) })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        state.setBlockers({
            { id = "late", position = point(25, 0), radius = 1, blocking = true },
        })

        nav:Update(0.25)
        eq(nav:GetState().planCount, 1)
        nav:Update(0.25)
        eq(nav:GetState().planCount, 2)
        eq(nav:GetState().obstacleId, "late")
        eq(nav:GetState().phase, "active")
    end)

    check("stuck retries are counted twice and the third stalled interval fails explicitly", function()
        local adapter = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        advance(nav, 3.75)
        eq(nav:GetState().retryCount, 0)
        eq(nav:GetState().phase, "active")
        advance(nav, 0.25)
        eq(nav:GetState().retryCount, 1)
        eq(nav:GetState().planCount, 2)
        advance(nav, 4)
        eq(nav:GetState().retryCount, 2)
        eq(nav:GetState().planCount, 3)
        advance(nav, 4)
        eq(nav:GetState().phase, "failed")
        eq(nav:GetFailure(), "stuck")
    end)

    check("plan-count budget fails closed with retry_limit", function()
        local adapter = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter, { maxPlans = 2 })
        assert(nav:Start(point(0, 0)))
        advance(nav, 8)
        eq(nav:GetState().phase, "failed")
        eq(nav:GetFailure(), "retry_limit")
        eq(nav:GetState().planCount, 2)
    end)

    check("single-leg time budget fails closed with retry_limit", function()
        local adapter = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter, { maxLegSec = 0.5, maxDurationSec = 10 })
        assert(nav:Start(point(0, 0)))
        advance(nav, 0.5)
        eq(nav:GetState().phase, "failed")
        eq(nav:GetFailure(), "retry_limit")
    end)

    check("overall time budget fails closed with retry_limit", function()
        local adapter = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter, { maxLegSec = 10, maxDurationSec = 0.5 })
        assert(nav:Start(point(0, 0)))
        advance(nav, 0.5)
        eq(nav:GetState().phase, "failed")
        eq(nav:GetFailure(), "retry_limit")
    end)

    check("blocker snapshot limit is enforced before a target is installed", function()
        local blockers = {}
        for index = 1, 129 do
            blockers[index] = {
                id = tostring(index),
                position = point(200 + index, 100),
                radius = 1,
                blocking = true,
            }
        end
        local adapter, state = makeAdapter({ position = point(30, 0), blockers = blockers })
        local nav = AutoNavigation.New(adapter)
        local started, reason = nav:Start(point(0, 0))
        eq(started, false)
        eq(reason, "blocker_limit")
        eq(state.target, nil)
        eq(nav:GetFailure(), "blocker_limit")
    end)

    check("configuration cannot raise the frozen retry, plan, blocker, or time ceilings", function()
        local overrides = {
            { maxPlans = 17 },
            { maxStuckRetries = 3 },
            { maxBlockers = 129 },
            { maxLegSec = 600.0001 },
            { maxDurationSec = 900.0001 },
        }
        for _, config in ipairs(overrides) do
            local adapter, state = makeAdapter({ position = point(30, 0) })
            local nav = AutoNavigation.New(adapter, config)
            local started, reason = nav:Start(point(0, 0))
            eq(started, false)
            eq(reason, "invalid_runtime")
            eq(nav:GetFailure(), "invalid_runtime")
            eq(state.target, nil)

            local plan, planReason = Geometry.Plan(
                point(30, 0), point(0, 0), {}, 1.8, 1440, config)
            eq(plan, nil)
            eq(planReason, "invalid_runtime")
        end
    end)
    check("diagnostic callback errors do not break navigation", function()
        local adapter = makeAdapter({
            position = point(30, 0),
            diagnostic = function() error("diagnostics unavailable") end,
        })
        local nav = AutoNavigation.New(adapter)
        local started, reason = nav:Start(point(0, 0))
        assert(started, tostring(reason))
        eq(nav:GetState().phase, "active")
    end)

    check("state snapshots copy waypoint coordinates", function()
        local adapter = makeAdapter({
            position = point(30, 0),
            blockers = { { id = "main", position = point(15, 0), radius = 1, blocking = true } },
        })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        local first = nav:GetState()
        assert(first.waypoint)
        local originalX, originalY = first.waypoint.x, first.waypoint.y
        first.waypoint.x, first.waypoint.y = 999, 999
        near(nav:GetState().waypoint.x, originalX)
        near(nav:GetState().waypoint.y, originalY)
    end)

    check("a new request after failure gets a fresh request id and clears failure state", function()
        local adapter, state = makeAdapter({ position = point(30, 0), valid = false })
        local nav = AutoNavigation.New(adapter)
        local started, reason = nav:Start(point(0, 0))
        eq(started, false)
        eq(reason, "invalid_runtime")
        eq(nav:GetFailure(), "invalid_runtime")
        state.valid = true
        assert(nav:Start(point(0, 0)))
        eq(nav:GetState().requestId, 2)
        eq(nav:GetState().planCount, 1)
        eq(nav:GetState().failureReason, nil)
        eq(nav:GetState().phase, "active")
    end)

    check("a cancelled detour never resumes its old waypoint on a new request", function()
        local adapter, state = makeAdapter({
            position = point(30, 0),
            blockers = { { id = "old", position = point(15, 0), radius = 1, blocking = true } },
        })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        assert(nav:GetState().waypoint)
        nav:Cancel("user_cancel")
        eq(nav:GetState().waypoint, nil)
        state.setBlockers({})
        assert(nav:Start(point(0, 0)))
        eq(nav:GetState().requestId, 2)
        eq(nav:GetState().planCount, 1)
        eq(nav:GetState().waypoint, nil)
        near(nav:GetState().target.x, 0)
        near(nav:GetState().target.y, 0)
    end)

    check("arrival at exactly ten meters is ready and consumed only once", function()
        local adapter, state = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        state.setPosition(point(10, 0))
        nav:Update(0.05)
        eq(nav:GetState().phase, "arrival_ready")
        near(nav:GetState().distance, 10)
        local arrival = nav:ConsumeArrival()
        assert(arrival)
        near(arrival.distance, 10)
        eq(nav:ConsumeArrival(), nil)
    end)
    check("arrival is a one-shot handshake and rejection requires prior consumption", function()
        local adapter, state = makeAdapter({ position = point(30, 0) })
        local nav = AutoNavigation.New(adapter)
        assert(nav:Start(point(0, 0)))
        state.setPosition(point(9, 0))
        nav:Update(0.05)
        eq(nav:GetState().phase, "arrival_ready")
        eq(state.target, nil)

        local rejectedEarly, earlyReason = nav:RejectArrival("gameplay_rejected")
        eq(rejectedEarly, false)
        eq(earlyReason, "arrival_not_consumed")
        eq(nav:GetState().phase, "arrival_ready")

        local arrival = nav:ConsumeArrival()
        assert(arrival)
        near(arrival.portPosition.x, 0)
        near(arrival.portPosition.y, 0)
        near(arrival.distance, 9)
        eq(arrival.requestId, 1)
        eq(nav:ConsumeArrival(), nil)
        eq(nav:GetState().phase, "arrival_consumed")

        eq(nav:RejectArrival("gameplay_rejected"), true)
        eq(nav:GetState().phase, "failed")
        eq(nav:GetFailure(), "gameplay_rejected")
    end)

    check("failed initial planning clears the explicitly taken-over manual target", function()
        local runtime = Runtime.New({
            initializeRegions = false,
            daySeed = 314159,
            autoReturnDiagnostic = quietDiagnostic,
            departure = point(40, 12),
        })
        runtime.movement:SetTarget(point(90, 90))
        local oldManualTarget = runtime.movement.target
        assert(oldManualTarget)
        local started, reason = runtime:StartAutoReturn()
        eq(started, false)
        eq(reason, "no_viable_detour")
        eq(runtime.movement.target, nil)
        assert(not rawequal(oldManualTarget, runtime.movement.target))
    end)

    check("reset retires the old runtime navigation adapter", function()
        local runtime = Runtime.New({
            initializeRegions = false,
            daySeed = 314159,
            autoReturnDiagnostic = quietDiagnostic,
            departure = point(30, 0),
        })
        assert(runtime:StartAutoReturn())
        local oldNavigation, oldMovement = runtime.autoNavigation, runtime.movement
        runtime:Reset()
        eq(oldMovement.target, nil)
        eq(runtime:GetAutoReturnState().phase, "idle")
        local restarted, reason = oldNavigation:Start(point(0, 0))
        eq(restarted, false)
        eq(reason, "invalid_runtime")
        eq(oldNavigation:GetFailure(), "invalid_runtime")
    end)
    check("runtime treats nine meters as near and starts at twelve or sixteen meters", function()
        for _, d in ipairs({ 9, 12, 16 }) do
            local runtime = Runtime.New({
                initializeRegions = false,
                daySeed = 314159,
                autoReturnDiagnostic = quietDiagnostic,
                departure = point(d, 0),
            })
            local started, reason = runtime:StartAutoReturn()
            if d == 9 then
                eq(started, false)
                eq(reason, "already_near_port")
                eq(runtime:GetAutoReturnFailure(), "already_near_port")
                eq(runtime.movement.target, nil)
            else
                assert(started, "runtime distance " .. d .. " rejected: " .. tostring(reason))
                eq(runtime:GetAutoReturnState().phase, "active")
                assert(runtime.movement.target)
                runtime:CancelAutoReturn("test_cleanup")
            end
        end
    end)

    check("runtime cancels keyboard intent before even a zero-delta movement update", function()
        local runtime = Runtime.New({
            initializeRegions = false,
            daySeed = 314159,
            autoReturnDiagnostic = quietDiagnostic,
            departure = point(30, 0),
        })
        assert(runtime:StartAutoReturn())
        assert(runtime.movement.target)
        runtime:Update(0, 1, 0)
        eq(runtime:GetAutoReturnState().phase, "cancelled")
        eq(runtime:GetAutoReturnState().cancelReason, "manual_input")
        eq(runtime.movement.target, nil)
    end)

    check("runtime pause and explicit target clearing cancel auto navigation", function()
        local paused = Runtime.New({
            initializeRegions = false,
            daySeed = 314159,
            autoReturnDiagnostic = quietDiagnostic,
            departure = point(30, 0),
        })
        assert(paused:StartAutoReturn())
        paused.paused = true
        paused:Update(0.05, 0, 0)
        eq(paused:GetAutoReturnState().phase, "cancelled")
        eq(paused.movement.target, nil)

        local cleared = Runtime.New({
            initializeRegions = false,
            daySeed = 314159,
            autoReturnDiagnostic = quietDiagnostic,
            departure = point(30, 0),
        })
        assert(cleared:StartAutoReturn())
        cleared:ClearMovementTarget()
        eq(cleared:GetAutoReturnState().phase, "cancelled")
        eq(cleared.movement.target, nil)
    end)

    check("successful port reset cancels auto navigation", function()
        local runtime = Runtime.New({
            initializeRegions = false,
            daySeed = 314159,
            autoReturnDiagnostic = quietDiagnostic,
            departure = point(16, 0),
        })
        assert(runtime:StartAutoReturn())
        local reset, reason = runtime:ResetShipAtPort()
        assert(reset, "ResetShipAtPort failed: " .. tostring(reason))
        eq(runtime:GetAutoReturnState().phase, "cancelled")
        eq(runtime.movement.target, nil)
        near(runtime.ship.position.x, 0)
        near(runtime.ship.position.y, 0)
    end)

    check("real blockers at forty twelve reject safely without moving the ship", function()
        local diagnostics = {}
        local runtime = Runtime.New({
            initializeRegions = false,
            daySeed = 314159,
            autoReturnDiagnostic = function(event, fields)
                diagnostics[#diagnostics + 1] = { event = event, fields = fields }
            end,
            departure = point(40, 12),
        })
        local island
        for _, entity in ipairs(runtime.world.entities) do
            if entity and entity.blocking == true
                and entity.position.x == 35 and entity.position.y == 25 then
                island = entity
                break
            end
        end
        assert(island, "fixed-seed fixture must include the real blocking island")
        eq(island.id, "sea-1")
        eq(island.entityType, "island")
        eq(island.kind, "fixed")
        near(island.radius, 12)
        near(distance(runtime.ship.position, island.position), math.sqrt(194), 0.001,
            "ship center is 13.93m from island center")

        local before = copyPoint(runtime.ship.position)
        local started, reason = runtime:StartAutoReturn()
        eq(started, false)
        eq(reason, "no_viable_detour")
        local state = runtime:GetAutoReturnState()
        eq(state.phase, "failed")
        eq(state.failureReason, "no_viable_detour")
        eq(state.obstacleId, nil, "no waypoint obstacle was selected")
        eq(state.planCount, 1)
        eq(#diagnostics, 3)
        eq(diagnostics[2].event, "AUTO_RETURN_PLAN_FAILED")
        eq(diagnostics[2].fields.reason, "no_viable_detour")
        eq(diagnostics[2].fields.obstacleId, nil)
        eq(diagnostics[2].fields.planCount, 1)
        eq(diagnostics[3].event, "AUTO_RETURN_FAILED")
        eq(diagnostics[3].fields.reason, "no_viable_detour")
        eq(runtime.movement.target, nil)
        near(runtime.ship.position.x, before.x)
        near(runtime.ship.position.y, before.y)
    end)

    check("real two-circle route replans from the first obstacle to the second", function()
        local waypointObstacles = {}
        local runtime = Runtime.New({
            initializeRegions = false,
            daySeed = 314159,
            departure = point(-100, 0),
            autoReturnDiagnostic = function(event, fields)
                if event == "AUTO_RETURN_WAYPOINT" then
                    waypointObstacles[#waypointObstacles + 1] = fields.obstacleId
                end
            end,
        })
        local first = runtime.world:spawn({
            entityType = "island",
            kind = "fixed",
            layer = "surface",
            position = point(-70, 0),
            radius = 5,
            blocking = true,
        })
        local second = runtime.world:spawn({
            entityType = "island",
            kind = "fixed",
            layer = "surface",
            position = point(-35, 8),
            radius = 5,
            blocking = true,
        })
        local collisionHits = 0
        local moveEntity = runtime.world.moveEntity
        runtime.world.moveEntity = function(world, entity, dx, dy)
            local hit, normalX, normalY = moveEntity(world, entity, dx, dy)
            if entity == runtime.ship and hit then collisionHits = collisionHits + 1 end
            return hit, normalX, normalY
        end        local started, reason = runtime:StartAutoReturn()
        assert(started, tostring(reason))

        local dtValues = { 1 / 60, 1 / 30, 0.1, 0.25 }
        for tick = 1, 5000 do
            runtime:Update(dtValues[((tick - 1) % #dtValues) + 1], 0, 0)
            local state = runtime:GetAutoReturnState()
            assert(state.phase ~= "failed",
                "two-circle route failed: " .. tostring(state.failureReason))
            if state.phase == "arrival_ready" then break end
        end
        local state = runtime:GetAutoReturnState()
        eq(state.phase, "arrival_ready")
        eq(state.planCount, 3)
        eq(#waypointObstacles, 2)
        eq(waypointObstacles[1], tostring(first.id))
        eq(waypointObstacles[2], tostring(second.id))
        eq(runtime:ConsumeAutoReturnArrival() ~= nil, true)
        eq(collisionHits, 0, "two-circle world collision hits")
    end)

    check("auto cancel stops a real fixed-barrel push without moving the ship", function()
        local runtime = makeCollisionRuntime()
        runtime.ship.rotation = math.pi / 2
        local collisions = installWorldCollisionSpy(runtime)
        local stopCalls = installStopSpy(runtime)
        local started, reason = runtime:StartAutoReturn()
        assert(started, "auto return start failed: " .. tostring(reason))
        assert(runtime.movement.target)
        moveIntoBarrelPush(runtime, collisions, false)
        assertFixedBarrelContact(collisions, runtime, "auto cancel")

        local position, x, y = runtime.ship.position, runtime.ship.position.x, runtime.ship.position.y
        eq(runtime:CancelAutoReturn("collision_cancel"), true)
        eq(runtime:GetAutoReturnState().phase, "cancelled")
        eq(stopCalls(), 1)
        eq(runtime.movement.target, nil)
        eq(runtime.movement.pushRemaining, 0)
        eq(runtime.movement.pushNormal.x, 0)
        eq(runtime.movement.pushNormal.y, 0)
        eq(runtime.ship.isMoving, false)
        eq(rawequal(runtime.ship.position, position), true)
        eq(runtime.ship.position.x, x)
        eq(runtime.ship.position.y, y)

        eq(runtime:CancelAutoReturn("repeat_cancel"), true)
        eq(stopCalls(), 1)
        runtime:Update(0.25, 0, 0)
        eq(rawequal(runtime.ship.position, position), true)
        eq(runtime.ship.position.x, x)
        eq(runtime.ship.position.y, y)
    end)

    check("failed planning stops a real pending barrel push before the next runtime update", function()
        local runtime = makeCollisionRuntime()
        local collisions = installWorldCollisionSpy(runtime)
        local stopCalls = installStopSpy(runtime)
        runtime.movement:SetTarget(copyPoint(runtime.world.fixedBarrel.position))
        moveIntoBarrelPush(runtime, collisions, true)
        assertFixedBarrelContact(collisions, runtime, "failed planning")
        assert(runtime.movement.pushRemaining > 0)

        local position, x, y = runtime.ship.position, runtime.ship.position.x, runtime.ship.position.y
        local started, reason = runtime:StartAutoReturn()
        eq(started, false)
        eq(reason, "no_viable_detour")
        eq(runtime:GetAutoReturnFailure(), "no_viable_detour")
        eq(stopCalls(), 1)
        eq(runtime.movement.target, nil)
        eq(runtime.movement.pushRemaining, 0)
        eq(runtime.movement.pushNormal.x, 0)
        eq(runtime.movement.pushNormal.y, 0)

        runtime:Update(0.25, 0, 0)
        eq(rawequal(runtime.ship.position, position), true)
        eq(runtime.ship.position.x, x)
        eq(runtime.ship.position.y, y)
    end)

    check("cancel preserves a replacement manual target and its real collision feedback", function()
        local runtime = makeCollisionRuntime()
        local collisions = installWorldCollisionSpy(runtime)
        local stopCalls = installStopSpy(runtime)
        assert(runtime:StartAutoReturn())
        local autoTarget = runtime.movement.target
        runtime.movement:SetTarget(copyPoint(runtime.world.fixedBarrel.position))
        local manualTarget = runtime.movement.target
        assert(autoTarget and manualTarget and not rawequal(autoTarget, manualTarget))
        moveIntoBarrelPush(runtime, collisions, false)
        assertFixedBarrelContact(collisions, runtime, "manual replacement")
        local pushRemaining = runtime.movement.pushRemaining
        local pushX, pushY = runtime.movement.pushNormal.x, runtime.movement.pushNormal.y

        eq(runtime:CancelAutoReturn("manual_target_kept"), true)
        eq(runtime:GetAutoReturnState().phase, "cancelled")
        eq(stopCalls(), 0)
        eq(rawequal(runtime.movement.target, manualTarget), true)
        eq(runtime.movement.pushRemaining, pushRemaining)
        eq(runtime.movement.pushNormal.x, pushX)
        eq(runtime.movement.pushNormal.y, pushY)
    end)

    check("Movement.Stop clears only steering feedback and is idempotent", function()
        local runtime = makeCollisionRuntime()
        local collisions = installWorldCollisionSpy(runtime)
        runtime.movement:SetTarget(copyPoint(runtime.world.fixedBarrel.position))
        moveIntoBarrelPush(runtime, collisions, false)
        assertFixedBarrelContact(collisions, runtime, "Movement.Stop")

        local movement, ship, world = runtime.movement, runtime.ship, runtime.world
        local position, positionX, positionY = ship.position, ship.position.x, ship.position.y
        local rotation = ship.rotation
        local direction, directionX, directionY = ship.direction, ship.direction.x, ship.direction.y
        local speed, level, turnRate = movement.speed, movement.level, ship.visualTurnRate
        local camera, cameraX, cameraY = movement.camera, movement.camera.x, movement.camera.y
        local wake, entities, barrel = movement.wake, world.entities, world.fixedBarrel
        local worldMoveEntity, shipRadius = world.moveEntity, ship.radius
        local barrelPosition = copyPoint(barrel.position)
        local barrelRadius, barrelBlocking = barrel.radius, barrel.blocking
        local pushNormal = movement.pushNormal
        assert(movement.pushRemaining > 0)
        assert(pushNormal.x ~= 0 or pushNormal.y ~= 0)

        eq(rawequal(movement:Stop(), movement), true)
        eq(movement.target, nil)
        eq(movement.pushRemaining, 0)
        eq(rawequal(movement.pushNormal, pushNormal), true)
        eq(movement.pushNormal.x, 0)
        eq(movement.pushNormal.y, 0)
        eq(ship.isMoving, false)

        eq(rawequal(ship.position, position), true)
        eq(ship.position.x, positionX)
        eq(ship.position.y, positionY)
        eq(ship.rotation, rotation)
        eq(rawequal(ship.direction, direction), true)
        eq(ship.direction.x, directionX)
        eq(ship.direction.y, directionY)
        eq(ship.visualTurnRate, turnRate)
        eq(movement.speed, speed)
        eq(movement.level, level)
        eq(ship.radius, shipRadius)
        eq(rawequal(world.moveEntity, worldMoveEntity), true)
        eq(rawequal(movement.camera, camera), true)
        eq(movement.camera.x, cameraX)
        eq(movement.camera.y, cameraY)
        eq(rawequal(movement.wake, wake), true)
        eq(rawequal(runtime.world, world), true)
        eq(rawequal(runtime.world.entities, entities), true)
        eq(rawequal(runtime.world.fixedBarrel, barrel), true)
        eq(barrel.position.x, barrelPosition.x)
        eq(barrel.position.y, barrelPosition.y)
        eq(barrel.radius, barrelRadius)
        eq(barrel.blocking, barrelBlocking)

        eq(rawequal(movement:Stop(), movement), true)
        eq(movement.target, nil)
        eq(movement.pushRemaining, 0)
        eq(movement.pushNormal.x, 0)
        eq(movement.pushNormal.y, 0)
        eq(ship.isMoving, false)
        eq(rawequal(ship.position, position), true)
        eq(ship.position.x, positionX)
        eq(ship.position.y, positionY)
        eq(ship.rotation, rotation)
        eq(movement.speed, speed)
        eq(movement.level, level)
        eq(ship.radius, shipRadius)
        eq(rawequal(world.moveEntity, worldMoveEntity), true)
        eq(barrel.radius, barrelRadius)
        eq(barrel.blocking, barrelBlocking)
    end)
    local departures = {
        { name = "island-one-near", position = point(70, 50), expectedObstacle = { x = 35, y = 25 } },
        { name = "island-one-far", position = point(100, 100), expectedObstacle = { x = 35, y = 25 } },
        { name = "island-two", position = point(-160, 180), expectedObstacle = { x = -80, y = 90 } },
        { name = "open-water", position = point(100, 0) },
        { name = "fixed-barrel", position = point(80, 15), expectedObstacle = { kind = "barrel" } },
        { name = "island-route", position = point(120, 85) },
        { name = "far-water", position = point(500, 500) },
        { name = "world-corner", position = point(1400, -1400) },
    }
    for _, departure in ipairs(departures) do
        for level = 1, 3 do
            for _, reverse in ipairs({ false, true }) do
                local heading = reverse and "reverse" or "forward"
                check("real runtime " .. departure.name .. " level " .. level .. " " .. heading,
                    function()
                        runRealVoyage(departure.position, level, reverse, departure.expectedObstacle)
                    end)
            end
        end
    end

    local passed = 0
    for _, result in ipairs(results) do
        if result.passed then passed = passed + 1 end
    end
    return {
        passed = passed == #results,
        total = #results,
        results = results,
    }
end

return Tests
