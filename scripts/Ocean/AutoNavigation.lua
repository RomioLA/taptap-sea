-- Bounded local obstacle navigation; Movement and World remain motion/collision authorities.
-- One current waypoint, no global graph, no player or clock state.
local Config = require("Ocean.Config")

-- Collision / planning geometry (meters):
--                       W (one current waypoint)
--                      / \
--                     /   \  same-side tangent legs
--             S -----/ (C) \----- P (port)
-- hard circle = obstacle.radius + ship.radius; candidates use hard + margin.
-- Reaching W rechecks S(actual position)->P against HARD circles, so the
-- waypoint arrival tolerance never recursively routes around its own margin.
-- 8m > 16/pi (5.09m turning radius) + 1.5m arrival + 16*.05 (.8m substep).
-- A collision push is at most 3*.3=.9m: require 1m distance improvement so
-- isolated push/jitter cannot count as meaningful route progress.
-- 4s allows a <=1s reverse-heading turn plus existing .3s push feedback.
-- 2 stuck retries => failure at the third window (~12 simulated seconds).
-- 16 plans covers three authored blockers with bounded recovery headroom.
-- 600s/leg, 900s/run bound slow drift; map diagonal / 9m/s is about 453s.
-- Snapshot/planner cap 128 blockers; each plan makes at most two candidates.
-- Physical-leg refresh every .5s; normal substeps otherwise do scalar work.
local Defaults = {
    safetyMargin = 8,
    waypointRadius = Config.ship.arrivalRadius,
    portRadius = 10,
    epsilon = Config.world.epsilon,
    stuckWindowSec = 4,
    progressMeters = 1,
    maxStuckRetries = 2,
    maxPlans = 16,
    maxLegSec = 600,
    maxDurationSec = 900,
    checkIntervalSec = 0.5,
    maxBlockers = 128,
}

local AutoNavigation = {}
local Geometry = {}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function isPoint(point)
    return type(point) == "table"
        and isFiniteNumber(point.x)
        and isFiniteNumber(point.y)
end

local function copyPoint(point)
    return { x = point.x, y = point.y }
end

local function distanceSquared(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    return dx * dx + dy * dy
end

local function distance(a, b)
    return math.sqrt(distanceSquared(a, b))
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function cross(ax, ay, bx, by)
    return ax * by - ay * bx
end

local function isInteger(value)
    return isFiniteNumber(value) and value >= 0 and value == math.floor(value)
end

local function resolvedSettings(overrides)
    if overrides ~= nil and type(overrides) ~= "table" then return nil end

    local settings = {}
    for key, value in pairs(Defaults) do settings[key] = value end
    if overrides ~= nil then
        for key, value in pairs(overrides) do
            if Defaults[key] ~= nil then settings[key] = value end
        end
    end

    if not isFiniteNumber(settings.safetyMargin) or settings.safetyMargin < 0
        or not isFiniteNumber(settings.waypointRadius) or settings.waypointRadius < 0
        or not isFiniteNumber(settings.portRadius) or settings.portRadius <= 0
        or not isFiniteNumber(settings.epsilon) or settings.epsilon < 0
        or not isFiniteNumber(settings.stuckWindowSec) or settings.stuckWindowSec <= 0
        or not isFiniteNumber(settings.progressMeters) or settings.progressMeters <= 0
        or not isInteger(settings.maxStuckRetries)
        or not isInteger(settings.maxPlans) or settings.maxPlans <= 0
        or not isFiniteNumber(settings.maxLegSec) or settings.maxLegSec <= 0
        or not isFiniteNumber(settings.maxDurationSec) or settings.maxDurationSec <= 0
        or not isFiniteNumber(settings.checkIntervalSec) or settings.checkIntervalSec <= 0
        or not isInteger(settings.maxBlockers) or settings.maxBlockers <= 0 then
        return nil
    end
    for _, key in ipairs({ "maxPlans", "maxStuckRetries", "maxBlockers", "maxLegSec", "maxDurationSec" }) do
        if settings[key] > Defaults[key] then return nil end
    end
    return settings
end

local function activeBlocker(blocker)
    return type(blocker) == "table"
        and blocker.blocking == true
        and blocker.removed ~= true
end

local function validBlockerShape(blocker, shipRadius, margin)
    if not activeBlocker(blocker) then return true end
    return type(blocker.id) == "string"
        and #blocker.id > 0
        and isPoint(blocker.position)
        and isFiniteNumber(blocker.radius)
        and blocker.radius >= 0
        and isFiniteNumber(blocker.radius + shipRadius + margin)
end

local function validateSnapshot(blockers, shipRadius, margin, maxBlockers)
    if type(blockers) ~= "table" then return false, "invalid_runtime" end

    local count = 0
    local maxIndex = 0
    local ids = {}
    for key, blocker in pairs(blockers) do
        if not isInteger(key) or key < 1 then return false, "invalid_runtime" end
        count = count + 1
        if key > maxIndex then maxIndex = key end
        if count > maxBlockers then return false, "blocker_limit" end
        if type(blocker) ~= "table" then return false, "invalid_runtime" end
        if blocker.blocking ~= nil and type(blocker.blocking) ~= "boolean" then
            return false, "invalid_runtime"
        end
        if blocker.removed ~= nil and type(blocker.removed) ~= "boolean" then
            return false, "invalid_runtime"
        end
        if not validBlockerShape(blocker, shipRadius, margin) then
            return false, "invalid_runtime"
        end
        if activeBlocker(blocker) then
            if ids[blocker.id] then return false, "invalid_runtime" end
            ids[blocker.id] = true
        end
    end
    if maxIndex ~= count then return false, "invalid_runtime" end
    return true
end

local function segmentEntry(a, b, center, radius, epsilon)
    if not isPoint(a) or not isPoint(b) or not isPoint(center)
        or not isFiniteNumber(radius) or radius < 0
        or not isFiniteNumber(epsilon) or epsilon < 0 then
        return nil
    end

    local dx = b.x - a.x
    local dy = b.y - a.y
    local lengthSquared = dx * dx + dy * dy
    local effectiveRadius = radius + epsilon
    if not isFiniteNumber(lengthSquared) or not isFiniteNumber(effectiveRadius) then return nil end

    local fx = a.x - center.x
    local fy = a.y - center.y
    local effectiveRadiusSquared = effectiveRadius * effectiveRadius
    local startDistanceSquared = fx * fx + fy * fy
    if not isFiniteNumber(effectiveRadiusSquared) or not isFiniteNumber(startDistanceSquared) then return nil end
    if startDistanceSquared <= effectiveRadiusSquared then return 0 end
    if lengthSquared <= epsilon * epsilon then return nil end

    local projection = -(fx * dx + fy * dy) / lengthSquared
    if not isFiniteNumber(projection) then return nil end

    -- The clamped closest point only decides whether the finite segment reaches
    -- the circle. Chord length must use the perpendicular distance to the
    -- infinite line, even when the perpendicular foot lies beyond an endpoint.
    local closestT = clamp(projection, 0, 1)
    local closestX = fx + closestT * dx
    local closestY = fy + closestT * dy
    local closestDistanceSquared = closestX * closestX + closestY * closestY
    if not isFiniteNumber(closestDistanceSquared)
        or closestDistanceSquared > effectiveRadiusSquared then
        return nil
    end

    local perpendicularX = fx + projection * dx
    local perpendicularY = fy + projection * dy
    local perpendicularDistanceSquared = perpendicularX * perpendicularX
        + perpendicularY * perpendicularY
    if not isFiniteNumber(perpendicularDistanceSquared) then return nil end
    local halfChordSquared = (effectiveRadiusSquared - perpendicularDistanceSquared) / lengthSquared
    if not isFiniteNumber(halfChordSquared) or halfChordSquared < -epsilon then return nil end
    local halfChord = math.sqrt(math.max(0, halfChordSquared))
    local entryT = projection - halfChord
    local exitT = projection + halfChord
    if not isFiniteNumber(entryT) or not isFiniteNumber(exitT) then return nil end
    if exitT < 0 or entryT > 1 then return nil end
    if entryT <= 0 and exitT >= 0 then return 0 end
    if entryT < 0 then return nil end
    return clamp(entryT, 0, 1)
end

function Geometry.SegmentEntry(a, b, center, radius)
    return segmentEntry(a, b, center, radius, Defaults.epsilon)
end

local function nearestBlocker(start, goal, blockers, shipRadius, margin, epsilon)
    if not isPoint(start) or not isPoint(goal) or type(blockers) ~= "table"
        or not isFiniteNumber(shipRadius) or shipRadius < 0
        or not isFiniteNumber(margin) or margin < 0 then
        return nil, nil
    end

    local best
    local bestT
    for _, blocker in ipairs(blockers) do
        if activeBlocker(blocker)
            and isPoint(blocker.position)
            and isFiniteNumber(blocker.radius)
            and blocker.radius >= 0
            and type(blocker.id) == "string" then
            local radius = blocker.radius + shipRadius + margin
            local t = segmentEntry(start, goal, blocker.position, radius, epsilon)
            if t ~= nil then
                if best == nil or t < bestT - epsilon then
                    best = blocker
                    bestT = t
                elseif math.abs(t - bestT) <= epsilon and blocker.id < best.id then
                    best = blocker
                    bestT = t
                end
            end
        end
    end
    return best, bestT
end

function Geometry.NearestBlocker(start, goal, blockers, shipRadius, margin)
    return nearestBlocker(start, goal, blockers, shipRadius, margin, Defaults.epsilon)
end

local function tangentPoints(point, center, radius, epsilon)
    if not isPoint(point) or not isPoint(center) or not isFiniteNumber(radius)
        or radius <= 0 or not isFiniteNumber(epsilon) or epsilon < 0 then
        return nil, nil
    end

    local dx = point.x - center.x
    local dy = point.y - center.y
    local distanceSq = dx * dx + dy * dy
    local radiusSq = radius * radius
    if not isFiniteNumber(distanceSq) or not isFiniteNumber(radiusSq)
        or distanceSq <= (radius + epsilon) * (radius + epsilon) then
        return nil, nil
    end

    local baseScale = radiusSq / distanceSq
    local offsetScale = radius * math.sqrt(distanceSq - radiusSq) / distanceSq
    local baseX = center.x + baseScale * dx
    local baseY = center.y + baseScale * dy
    local offsetX = -offsetScale * dy
    local offsetY = offsetScale * dx
    local first = { x = baseX + offsetX, y = baseY + offsetY }
    local second = { x = baseX - offsetX, y = baseY - offsetY }
    if not isPoint(first) or not isPoint(second) then return nil, nil end
    return first, second
end

local function chooseSideTangent(point, center, radius, normalX, normalY, wantLeft, epsilon)
    local first, second = tangentPoints(point, center, radius, epsilon)
    if first == nil then return nil end

    local firstDot = (first.x - center.x) * normalX + (first.y - center.y) * normalY
    local secondDot = (second.x - center.x) * normalX + (second.y - center.y) * normalY
    if wantLeft then
        if firstDot >= secondDot then return first end
        return second
    end
    if firstDot <= secondDot then return first end
    return second
end

local function tangentLineIntersection(start, goal, startTangent, goalTangent, epsilon)
    local ux = startTangent.x - start.x
    local uy = startTangent.y - start.y
    local vx = goalTangent.x - goal.x
    local vy = goalTangent.y - goal.y
    local startLength = math.sqrt(ux * ux + uy * uy)
    local goalLength = math.sqrt(vx * vx + vy * vy)
    local denominator = cross(ux, uy, vx, vy)
    local parallelTolerance = epsilon * startLength * goalLength
    if not isFiniteNumber(startLength) or not isFiniteNumber(goalLength)
        or not isFiniteNumber(denominator) or not isFiniteNumber(parallelTolerance)
        or startLength <= 0 or goalLength <= 0
        or math.abs(denominator) <= parallelTolerance then
        return nil
    end

    local betweenX = goal.x - start.x
    local betweenY = goal.y - start.y
    local startParameter = cross(betweenX, betweenY, vx, vy) / denominator
    local goalParameter = cross(betweenX, betweenY, ux, uy) / denominator
    if not isFiniteNumber(startParameter) or not isFiniteNumber(goalParameter)
        or startParameter < 1 - epsilon or goalParameter < 1 - epsilon then
        return nil
    end

    local candidate = {
        x = start.x + startParameter * ux,
        y = start.y + startParameter * uy,
    }
    if not isPoint(candidate) then return nil end
    return candidate
end

local function generateCandidates(start, goal, obstacle, shipRadius, margin, epsilon)
    local result = { left = nil, right = nil }
    if not isPoint(start) or not isPoint(goal) or type(obstacle) ~= "table"
        or not isPoint(obstacle.position)
        or not isFiniteNumber(obstacle.radius) or obstacle.radius < 0
        or not isFiniteNumber(shipRadius) or shipRadius < 0
        or not isFiniteNumber(margin) or margin < 0
        or not isFiniteNumber(epsilon) or epsilon < 0 then
        return result
    end

    local routeX = goal.x - start.x
    local routeY = goal.y - start.y
    local routeLength = math.sqrt(routeX * routeX + routeY * routeY)
    if not isFiniteNumber(routeLength) or routeLength <= epsilon then return result end
    local normalX = -routeY / routeLength
    local normalY = routeX / routeLength
    local radius = obstacle.radius + shipRadius + margin
    if not isFiniteNumber(radius) or radius <= 0 then return result end

    for _, side in ipairs({ "left", "right" }) do
        local wantLeft = side == "left"
        local startTangent = chooseSideTangent(
            start, obstacle.position, radius, normalX, normalY, wantLeft, epsilon)
        local goalTangent = chooseSideTangent(
            goal, obstacle.position, radius, normalX, normalY, wantLeft, epsilon)
        if startTangent ~= nil and goalTangent ~= nil then
            result[side] = tangentLineIntersection(
                start, goal, startTangent, goalTangent, epsilon)
        end
    end
    return result
end

function Geometry.GenerateCandidates(start, goal, obstacle, shipRadius, margin)
    return generateCandidates(start, goal, obstacle, shipRadius, margin, Defaults.epsilon)
end

local function strictlyInside(point, center, radius, epsilon)
    if not isPoint(point) or not isPoint(center) or not isFiniteNumber(radius) then return false end
    local interiorRadius = math.max(0, radius - epsilon)
    if interiorRadius <= 0 then return false end
    local d2 = distanceSquared(point, center)
    return isFiniteNumber(d2) and d2 < interiorRadius * interiorRadius
end

local strictlyInsideSegment
local function segmentClearAgainst(a, b, blocker, shipRadius, margin, epsilon)
    if not activeBlocker(blocker) or not isPoint(blocker.position)
        or not isFiniteNumber(blocker.radius) or blocker.radius < 0 then
        return true
    end
    local radius = blocker.radius + shipRadius + margin
    return not strictlyInsideSegment(a, b, blocker.position, radius, epsilon)
end

strictlyInsideSegment = function(a, b, center, radius, epsilon)
    if not isPoint(a) or not isPoint(b) or not isPoint(center)
        or not isFiniteNumber(radius) or radius < 0 then
        return false
    end
    local dx = b.x - a.x
    local dy = b.y - a.y
    local lengthSquared = dx * dx + dy * dy
    if not isFiniteNumber(lengthSquared) then return false end
    local closestT = 0
    if lengthSquared > epsilon * epsilon then
        closestT = clamp(((center.x - a.x) * dx + (center.y - a.y) * dy) / lengthSquared, 0, 1)
    end
    local closest = { x = a.x + closestT * dx, y = a.y + closestT * dy }
    return strictlyInside(closest, center, radius, epsilon)
end

local function pointWithinWorld(point, limit)
    return isPoint(point)
        and isFiniteNumber(limit)
        and limit >= 0
        and math.abs(point.x) <= limit
        and math.abs(point.y) <= limit
end

local function candidateValid(start, goal, candidate, obstacle, blockers, shipRadius, margin, halfSize, epsilon)
    if not isPoint(start) or not isPoint(goal) or not isPoint(candidate)
        or type(obstacle) ~= "table"
        or not isPoint(obstacle.position)
        or not isFiniteNumber(obstacle.radius) or obstacle.radius < 0
        or type(blockers) ~= "table"
        or not isFiniteNumber(shipRadius) or shipRadius < 0
        or not isFiniteNumber(margin) or margin < 0
        or not isFiniteNumber(halfSize) or halfSize <= shipRadius
        or not isFiniteNumber(epsilon) or epsilon < 0 then
        return false, "no_viable_detour"
    end

    local limit = halfSize - shipRadius
    if not pointWithinWorld(candidate, limit) then return false, "world_bounds" end

    local obstacleRadius = obstacle.radius + shipRadius + margin
    if strictlyInside(candidate, obstacle.position, obstacleRadius, epsilon) then
        return false, "no_viable_detour"
    end
    for _, blocker in ipairs(blockers) do
        if activeBlocker(blocker) and validBlockerShape(blocker, shipRadius, margin) then
            local radius = blocker.radius + shipRadius + margin
            if strictlyInside(candidate, blocker.position, radius, epsilon) then
                return false, "no_viable_detour"
            end
            if not segmentClearAgainst(start, candidate, blocker, shipRadius, margin, epsilon) then
                return false, "no_viable_detour"
            end
        end
    end
    if not segmentClearAgainst(start, candidate, obstacle, shipRadius, margin, epsilon)
        or not segmentClearAgainst(candidate, goal, obstacle, shipRadius, margin, epsilon) then
        return false, "no_viable_detour"
    end
    return true
end

function Geometry.CandidateValid(start, goal, candidate, obstacle, blockers, shipRadius, margin, halfSize)
    return candidateValid(
        start, goal, candidate, obstacle, blockers, shipRadius, margin, halfSize, Defaults.epsilon)
end

local function targetInsideActualBlocker(target, blockers, shipRadius, epsilon)
    for _, blocker in ipairs(blockers) do
        if activeBlocker(blocker) then
            local radius = blocker.radius + shipRadius
            if strictlyInside(target, blocker.position, radius, epsilon) then return true end
        end
    end
    return false
end

function Geometry.Plan(start, goal, blockers, shipRadius, halfSize, config)
    local settings = resolvedSettings(config)
    if settings == nil then return nil, "invalid_runtime" end
    if not isPoint(start) then return nil, "invalid_runtime" end
    if not isPoint(goal) then return nil, "invalid_target" end
    if not isFiniteNumber(shipRadius) or shipRadius <= 0
        or not isFiniteNumber(halfSize) or halfSize <= shipRadius then
        return nil, "invalid_runtime"
    end

    local worldLimit = halfSize - shipRadius
    if not pointWithinWorld(start, worldLimit) then return nil, "invalid_runtime" end
    if not pointWithinWorld(goal, worldLimit) then return nil, "invalid_target" end

    local snapshotValid, snapshotReason = validateSnapshot(
        blockers, shipRadius, settings.safetyMargin, settings.maxBlockers)
    if not snapshotValid then return nil, snapshotReason end
    if targetInsideActualBlocker(start, blockers, shipRadius, settings.epsilon) then
        return nil, "invalid_runtime"
    end
    if targetInsideActualBlocker(goal, blockers, shipRadius, settings.epsilon) then
        return nil, "invalid_target"
    end

    local obstacle = nearestBlocker(
        start, goal, blockers, shipRadius, 0, settings.epsilon)
    if obstacle == nil then
        return { target = copyPoint(goal), kind = "direct" }
    end

    local candidates = generateCandidates(
        start, goal, obstacle, shipRadius, settings.safetyMargin, settings.epsilon)
    local accepted = {}
    local reasons = {}
    for _, side in ipairs({ "left", "right" }) do
        local candidate = candidates[side]
        if candidate ~= nil then
            local valid, reason = candidateValid(
                start, goal, candidate, obstacle, blockers, shipRadius,
                settings.safetyMargin, halfSize, settings.epsilon)
            reasons[side] = reason
            if valid then
                accepted[#accepted + 1] = {
                    target = candidate,
                    side = side,
                    length = distance(start, candidate) + distance(candidate, goal),
                }
            end
        end
    end

    if #accepted == 0 then
        if candidates.left ~= nil and candidates.right ~= nil
            and reasons.left == "world_bounds" and reasons.right == "world_bounds" then
            return nil, "world_bounds"
        end
        return nil, "no_viable_detour"
    end

    local chosen = accepted[1]
    if #accepted == 2 then
        local tieEpsilon = settings.epsilon
        if accepted[2].length < chosen.length - tieEpsilon
            or (math.abs(accepted[2].length - chosen.length) <= tieEpsilon
                and accepted[2].side == "left") then
            chosen = accepted[2]
        end
    end

    return {
        target = copyPoint(chosen.target),
        kind = "detour",
        obstacleId = obstacle.id,
        side = chosen.side,
    }
end

AutoNavigation.Geometry = Geometry
AutoNavigation.Defaults = Defaults


-- All cross-frame navigation state lives here. Adapters only read snapshots or
-- forward target intent; this controller never writes a ship/world/player.
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function point(value)
    return type(value) == "table" and finite(value.x) and finite(value.y)
end

local function copy(value)
    if value then return { x = value.x, y = value.y } end
    return nil
end

local function distance(a, b)
    return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
end

---@class OceanAutoNavigation
---@field adapter table
---@field config table
---@field phase string
---@field target OceanPoint?
---@field waypoint OceanPoint?
---@field portPosition OceanPoint?
---@field ownedTarget table?
---@field obstacleId string?
---@field side string?
---@field failureReason string?
---@field cancelReason string?
---@field arrival table?
---@field planCount integer
---@field retryCount integer
---@field requestId integer
---@field elapsed number
---@field legElapsed number
---@field noProgressSec number
---@field checkElapsed number
---@field bestDistance number
---@field distanceToPort number?
AutoNavigation.__index = AutoNavigation

function AutoNavigation.New(adapter, config)
    local self = setmetatable({}, AutoNavigation)
    self:Init(adapter, config)
    return self
end

function AutoNavigation:Init(adapter, config)
    self.adapter = adapter or {}
    self.config = {}
    for key, value in pairs(AutoNavigation.Defaults) do self.config[key] = value end
    for key, value in pairs(config or {}) do self.config[key] = value end
    self.phase = "idle"
    self.target, self.waypoint, self.portPosition = nil, nil, nil
    self.ownedTarget, self.obstacleId, self.side = nil, nil, nil
    self.failureReason, self.cancelReason, self.arrival = nil, nil, nil
    self.planCount, self.retryCount, self.requestId = 0, 0, 0
    self.elapsed, self.legElapsed, self.noProgressSec, self.checkElapsed = 0, 0, 0, 0
    self.bestDistance, self.distanceToPort = math.huge, nil
end

function AutoNavigation:_Event(event, reason)
    local fields = { reason = reason, obstacleId = self.obstacleId, side = self.side,
        retryCount = self.retryCount, planCount = self.planCount,
        distance = self.distanceToPort, requestId = self.requestId }
    if type(self.adapter.diagnostic) == "function" then
        -- Logging must not take ownership of navigation or break its cleanup.
        pcall(self.adapter.diagnostic, event, fields)
    else
        print(string.format("%s reason=%s obstacleId=%s side=%s retryCount=%d planCount=%d distance=%s requestId=%d",
            event, tostring(reason or ""), tostring(self.obstacleId or ""),
            tostring(self.side or ""), self.retryCount, self.planCount,
            tostring(self.distanceToPort or ""), self.requestId))
    end
end

function AutoNavigation:_Position()
    local adapter, config = self.adapter, self.config
    if type(adapter.getPosition) ~= "function" or type(adapter.getBlockers) ~= "function"
        or type(adapter.getTarget) ~= "function" or type(adapter.setTarget) ~= "function"
        or type(adapter.isValid) ~= "function"
        or not finite(adapter.shipRadius) or adapter.shipRadius < 0
        or not finite(adapter.halfSize) or adapter.halfSize <= adapter.shipRadius then
        return nil
    end
    for _, key in ipairs({ "safetyMargin", "waypointRadius", "portRadius", "epsilon",
        "stuckWindowSec", "progressMeters", "maxStuckRetries", "maxPlans",
        "maxLegSec", "maxDurationSec", "checkIntervalSec", "maxBlockers" }) do
        if not finite(config[key]) or config[key] < 0 then return nil end
    end
    if config.epsilon <= 0 or config.waypointRadius < Config.ship.arrivalRadius
        or config.portRadius ~= AutoNavigation.Defaults.portRadius
        or config.stuckWindowSec <= 0 or config.progressMeters <= 0
        or config.maxPlans < 1 or config.maxPlans % 1 ~= 0
        or config.maxStuckRetries % 1 ~= 0 or config.maxBlockers < 1 or config.maxBlockers % 1 ~= 0
        or config.maxLegSec <= 0 or config.maxDurationSec <= 0
        or config.checkIntervalSec <= 0 then return nil end
    for _, key in ipairs({ "maxPlans", "maxStuckRetries", "maxBlockers", "maxLegSec", "maxDurationSec" }) do
        if config[key] > AutoNavigation.Defaults[key] then return nil end
    end
    local validOK, valid = pcall(adapter.isValid)
    local positionOK, position = pcall(adapter.getPosition)
    if not validOK or valid ~= true or not positionOK or not point(position) then return nil end
    local bound = adapter.halfSize - adapter.shipRadius
    if math.abs(position.x) > bound or math.abs(position.y) > bound then return nil end
    return copy(position)
end

function AutoNavigation:_Blockers()
    local ok, values = pcall(self.adapter.getBlockers)
    if not ok or type(values) ~= "table" then return nil, "invalid_runtime" end
    local result, ids, count, maxIndex = {}, {}, 0, 0
    -- Bound traversal as well as array length; reject holes/extra keys so a
    -- malformed snapshot cannot silently hide a blocker behind an ipairs gap.
    for key, value in pairs(values) do
        count = count + 1
        if count > self.config.maxBlockers then return nil, "blocker_limit" end
        if not finite(key) or key < 1 or key % 1 ~= 0 then return nil, "invalid_runtime" end
        maxIndex = math.max(maxIndex, key)
        if type(value) ~= "table" or (value.blocking ~= nil and type(value.blocking) ~= "boolean")
            or (value.removed ~= nil and type(value.removed) ~= "boolean") then
            return nil, "invalid_runtime"
        end
        if value.blocking == true and not value.removed then
            if type(value.id) ~= "string" or value.id == "" or ids[value.id] or not point(value.position)
                or not finite(value.radius) or value.radius < 0 then return nil, "invalid_runtime" end
            ids[value.id] = true
            result[#result + 1] = { id = value.id, position = copy(value.position),
                radius = value.radius, blocking = true }
        end
    end
    if count ~= maxIndex then return nil, "invalid_runtime" end
    return result
end

function AutoNavigation:_ClearOwnedTarget()
    if self.ownedTarget ~= nil and type(self.adapter.getTarget) == "function"
        and type(self.adapter.setTarget) == "function" then
        local ok, target = pcall(self.adapter.getTarget)
        if ok and rawequal(target, self.ownedTarget) then pcall(self.adapter.setTarget, nil) end
    end
    self.ownedTarget, self.target, self.waypoint = nil, nil, nil
    self.obstacleId, self.side = nil, nil
end

function AutoNavigation:_Fail(reason)
    self.failureReason, self.arrival, self.phase = reason, nil, "failed"
    self:_Event("AUTO_RETURN_FAILED", reason)
    self:_ClearOwnedTarget()
    return false, reason
end

function AutoNavigation:_Arrival(position)
    self.distanceToPort = distance(position, self.portPosition)
    self.arrival = { portPosition = copy(self.portPosition),
        distance = self.distanceToPort, requestId = self.requestId }
    self.phase = "arrival_ready"
    self:_Event("AUTO_RETURN_ARRIVAL_READY")
    self:_ClearOwnedTarget()
end

function AutoNavigation:_Plan(position, blockers)
    if self.planCount >= self.config.maxPlans then return self:_Fail("retry_limit") end
    self.planCount = self.planCount + 1
    local plan, reason = AutoNavigation.Geometry.Plan(position, self.portPosition, blockers,
        self.adapter.shipRadius, self.adapter.halfSize, self.config)
    if not plan then
        self:_Event("AUTO_RETURN_PLAN_FAILED", reason)
        return self:_Fail(reason or "no_viable_detour")
    end
    self.target = copy(plan.target)
    self.waypoint = plan.kind == "detour" and copy(plan.target) or nil
    self.obstacleId, self.side = plan.obstacleId, plan.side
    local ok, owned = pcall(self.adapter.setTarget, copy(self.target))
    if not ok or type(owned) ~= "table" then return self:_Fail("invalid_runtime") end
    self.ownedTarget = owned
    self.bestDistance = distance(position, self.target)
    self.noProgressSec, self.legElapsed, self.checkElapsed = 0, 0, 0
    self:_Event("AUTO_RETURN_PLAN_OK", plan.kind)
    if self.waypoint then self:_Event("AUTO_RETURN_WAYPOINT") end
    return true
end

-- Duplicate Start explicitly refuses; failure/cancel/consumed attempts may start
-- fresh from the current physical position. No old waypoint is ever resumed.
function AutoNavigation:Start(portPosition)
    if self.phase == "active" then return false, "already_active" end
    if self.phase == "arrival_ready" then return false, "arrival_pending" end
    self:_ClearOwnedTarget()
    self.requestId = self.requestId + 1
    self.planCount, self.retryCount = 0, 0
    self.elapsed, self.legElapsed, self.noProgressSec, self.checkElapsed = 0, 0, 0, 0
    self.failureReason, self.cancelReason, self.arrival = nil, nil, nil
    self.portPosition, self.distanceToPort = nil, nil
    local position = self:_Position()
    if not position then return self:_Fail("invalid_runtime") end
    -- A new explicit Start transfers the previous movement intent to this
    -- attempt. If its first plan fails, stop that intent instead of silently
    -- continuing the old manual voyage. Later manual replacements still have
    -- different identities and are never cleared by Cancel/Failure cleanup.
    local targetOK, previousTarget = pcall(self.adapter.getTarget)
    if not targetOK then return self:_Fail("invalid_runtime") end
    self.ownedTarget = previousTarget
    if not point(portPosition) then return self:_Fail("invalid_target") end
    self.portPosition = copy(portPosition)
    local bound = self.adapter.halfSize - self.adapter.shipRadius
    if math.abs(portPosition.x) > bound or math.abs(portPosition.y) > bound then
        return self:_Fail("world_bounds")
    end
    self.distanceToPort = distance(position, self.portPosition)
    if self.distanceToPort <= self.config.portRadius then return self:_Fail("already_near_port") end
    local blockers, reason = self:_Blockers()
    if not blockers then return self:_Fail(reason) end
    self.phase = "active"
    self:_Event("AUTO_RETURN_START")
    return self:_Plan(position, blockers)
end

function AutoNavigation:Cancel(reason)
    if self.phase == "active" or self.phase == "arrival_ready" then
        self.phase, self.cancelReason, self.arrival = "cancelled",
            type(reason) == "string" and reason or "cancelled_by_user", nil
        self:_Event("AUTO_RETURN_CANCEL", self.cancelReason)
        self:_ClearOwnedTarget()
    end
    return true
end

-- Called AFTER Movement with the simulated substep, never raw wall-clock time.
function AutoNavigation:Update(dt)
    if self.phase ~= "active" then return end
    local position = self:_Position()
    if not position or not finite(dt) then self:_Fail("invalid_runtime"); return end
    local targetOK, actualTarget = pcall(self.adapter.getTarget)
    if not targetOK then self:_Fail("invalid_runtime"); return end
    local targetDistance = distance(position, self.target)
    -- Movement clears a reached target itself. An external replacement is
    -- detected by reference identity, including a new target at identical x/y.
    if not rawequal(actualTarget, self.ownedTarget)
        and not (actualTarget == nil and targetDistance <= self.config.waypointRadius) then
        self:Cancel("movement_overridden")
        return
    end
    self.distanceToPort = distance(position, self.portPosition)
    if self.distanceToPort <= self.config.portRadius then self:_Arrival(position); return end
    dt = math.max(0, math.min(dt, Config.world.maxFrameSec))
    self.elapsed, self.legElapsed = self.elapsed + dt, self.legElapsed + dt
    if self.elapsed >= self.config.maxDurationSec or self.legElapsed >= self.config.maxLegSec then
        self:_Fail("retry_limit"); return
    end
    if self.waypoint and targetDistance <= self.config.waypointRadius then
        local blockers, reason = self:_Blockers()
        if not blockers then self:_Fail(reason); return end
        self:_Event("AUTO_RETURN_REPLAN", "waypoint_reached")
        self:_Plan(position, blockers)
        return
    end
    if self.bestDistance - targetDistance >= self.config.progressMeters then
        self.bestDistance, self.noProgressSec = targetDistance, 0
    else
        self.noProgressSec = self.noProgressSec + dt
    end
    if self.noProgressSec + self.config.epsilon >= self.config.stuckWindowSec then
        self:_Event("AUTO_RETURN_STUCK", "no_progress")
        if self.retryCount >= self.config.maxStuckRetries then self:_Fail("stuck"); return end
        self.retryCount = self.retryCount + 1
        local blockers, reason = self:_Blockers()
        if not blockers then self:_Fail(reason); return end
        self:_Event("AUTO_RETURN_REPLAN", "stuck")
        self:_Plan(position, blockers)
        return
    end
    self.checkElapsed = self.checkElapsed + dt
    if self.checkElapsed + self.config.epsilon >= self.config.checkIntervalSec then
        self.checkElapsed = 0
        local blockers, reason = self:_Blockers()
        if not blockers then self:_Fail(reason); return end
        -- Check physical clearance here. Planning already reserves the 8m
        -- steering/arrival margin; retesting that margin would flag its own
        -- tangents/corner rounding as a new obstacle every interval.
        local blocker = AutoNavigation.Geometry.NearestBlocker(position, self.target,
            blockers, self.adapter.shipRadius, 0)
        if blocker then
            self:_Event("AUTO_RETURN_REPLAN", "leg_blocked")
            self:_Plan(position, blockers)
        end
    end
end

function AutoNavigation:GetState()
    return { phase = self.phase, active = self.phase == "active",
        target = copy(self.target), waypoint = copy(self.waypoint),
        portPosition = copy(self.portPosition), obstacleId = self.obstacleId,
        side = self.side, planCount = self.planCount, retryCount = self.retryCount,
        failureReason = self.failureReason, cancelReason = self.cancelReason,
        requestId = self.requestId, distance = self.distanceToPort,
        elapsed = self.elapsed, noProgressSec = self.noProgressSec }
end

function AutoNavigation:ConsumeArrival()
    if self.phase ~= "arrival_ready" then return nil end
    local value = self.arrival
    self.arrival, self.phase = nil, "arrival_consumed"
    self:_Event("AUTO_RETURN_ARRIVAL_CONSUMED")
    return { portPosition = copy(value.portPosition), distance = value.distance, requestId = value.requestId }
end

function AutoNavigation:RejectArrival(reason)
    if self.phase ~= "arrival_consumed" then return false, "arrival_not_consumed" end
    self:_Fail(type(reason) == "string" and reason or "return_rejected")
    return true
end

function AutoNavigation:GetFailure()
    return self.failureReason
end

return AutoNavigation
