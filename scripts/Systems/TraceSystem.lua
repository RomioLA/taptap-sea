-- Runtime-only traces. Traces are not world entities and never create content.
local Config = require "Ocean.Config"

local TraceSystem = {}
TraceSystem.__index = TraceSystem

local FLOCK = {
    id = "flock_commute",
    traceType = "flock_commute",
    sourceContentId = "island_02",
    birdCount = 3,
    dives = false,
    circlesFish = false,
}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validIdentity(value)
    return type(value) == "string" and value ~= ""
end

local function currentSource(self, trace)
    local world = self.world
    if not world or world.retired or self.generation ~= world.fixedContentGeneration then return nil end
    local source = type(world.fixedContentEntities) == "table"
        and world.fixedContentEntities[trace.sourceContentId] or nil
    if not source or type(world.get) ~= "function" or world:get(source.id) ~= source
        or source.removed or source.alive == false or source.kind ~= "fixed"
        or source.entityType ~= "island" or source.contentId ~= trace.sourceContentId
        or type(source.position) ~= "table" or not finite(source.position.x) or not finite(source.position.y) then
        return nil
    end
    local ship = world.scopeShip
    if not ship or world:get(ship.id) ~= ship or ship.removed or ship.alive == false
        or type(ship.position) ~= "table" or not finite(ship.position.x) or not finite(ship.position.y) then
        return nil
    end
    return source, ship
end

local function snapshot(self, trace)
    local source, ship = currentSource(self, trace)
    if not source then return nil end
    local dx, dy = source.position.x - ship.position.x, source.position.y - ship.position.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if not finite(distance) or distance <= 0 then return nil end
    local bearingRadians = math.atan(dy, dx)
    local bearingDegrees = math.deg(bearingRadians) % 360
    return {
        id = trace.id,
        traceType = trace.traceType,
        sourceContentId = trace.sourceContentId,
        birdCount = trace.birdCount,
        dives = trace.dives,
        circlesFish = trace.circlesFish,
        valid = true,
        generation = self.generation,
        distance = distance,
        bearingRadians = bearingRadians,
        bearingDegrees = bearingDegrees,
        sourcePosition = { x = source.position.x, y = source.position.y },
        playerPosition = { x = ship.position.x, y = ship.position.y },
    }
end

function TraceSystem.New(world)
    local self = setmetatable({
        world = type(world) == "table" and world or nil,
        generation = type(world) == "table" and world.fixedContentGeneration or nil,
        traces = {},
        ready = false,
    }, TraceSystem)
    if self.world and not self.world.retired and finite(self.generation) then
        local registered = self:Register(FLOCK)
        self.ready = registered == true
    end
    return self
end

---Register a trace record without adding a World entity.
---@param spec table
---@return boolean, string?
function TraceSystem:Register(spec)
    if not self.world or self.world.retired then return false, "runtime_unavailable" end
    if self.generation ~= self.world.fixedContentGeneration then return false, "stale_generation" end
    if type(spec) ~= "table" or spec.traceType ~= "flock_commute"
        or spec.id ~= "flock_commute" or spec.sourceContentId ~= "island_02"
        or spec.birdCount ~= 3 or spec.dives ~= false or spec.circlesFish ~= false then
        return false, "unsupported_trace"
    end
    if self.traces[spec.id] then return false, "duplicate_trace" end
    local source = self.world.fixedContentEntities and self.world.fixedContentEntities[spec.sourceContentId]
    if not source or source.entityType ~= "island" or source.kind ~= "fixed" then
        return false, "source_unavailable"
    end
    self.traces[spec.id] = {
        id = spec.id,
        traceType = spec.traceType,
        sourceContentId = spec.sourceContentId,
        birdCount = spec.birdCount,
        dives = spec.dives,
        circlesFish = spec.circlesFish,
        generation = self.generation,
    }
    return true
end

---Update validates the live World/source identity; bearing is read live by Query.
---@param world table
---@param dt number
---@return boolean
function TraceSystem:Update(world, dt)
    if not self.world or world ~= self.world or world.retired
        or self.generation ~= world.fixedContentGeneration or not finite(dt) or dt < 0 then
        self.ready = false
        return false
    end
    local trace = self.traces[FLOCK.id]
    self.ready = trace ~= nil and snapshot(self, trace) ~= nil
    return self.ready
end

---Fresh snapshot; bearing is always player-position -> island_02 center.
---@param traceId string
---@return table?, string?
function TraceSystem:Query(traceId)
    if not self.world or self.world.retired then return nil, "runtime_unavailable" end
    if self.generation ~= self.world.fixedContentGeneration then return nil, "stale_generation" end
    local trace = self.traces[traceId]
    if not trace then return nil, "trace_unavailable" end
    if trace.generation ~= self.generation then return nil, "stale_generation" end
    local result = snapshot(self, trace)
    if not result then return nil, "trace_invalid" end
    return result
end

---Create an observation event only while the visible flock can point at its source.
---@param traceId string
---@param day integer
---@param alreadyRecognized boolean
---@return table?, string?
function TraceSystem:BuildObservation(traceId, day, alreadyRecognized)
    if not finite(day) or day < 1 or day ~= math.floor(day) then return nil, "invalid_day" end
    if alreadyRecognized == true then return nil, "already_recognized" end
    local trace, reason = self:Query(traceId)
    if not trace then return nil, reason end
    if trace.distance <= Config.interaction.recognitionDistance then return nil, "within_recognition_range" end
    return {
        type = "observation_recorded",
        traceType = trace.traceType,
        traceId = trace.id,
        sourceContentId = trace.sourceContentId,
        birdCount = trace.birdCount,
        dives = trace.dives,
        circlesFish = trace.circlesFish,
        day = day,
        bearing = trace.bearingDegrees,
        observable = true,
        generation = trace.generation,
    }
end

return TraceSystem
