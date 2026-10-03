-- Bounded, world-space wake samples. Update is driven by the voyage step,
-- never by the renderer, so paused time does not age the wake.
local Config = require("Ocean.Config")

---@class OceanWakePoint
---@field x number
---@field y number

---@class OceanWakeRecord
---@field position OceanWakePoint
---@field rotation number Actual displacement heading in radians.
---@field age number Sample age in seconds.

---@class OceanWakeSettings
---@field lifetimeSec number
---@field spacingMeters number
---@field minSpeed number
---@field maxSamples integer
---@field initialWidth number
---@field spreadPerSec number
---@field sternOffset number
---@field opacity number

---@class OceanWake
---@field records OceanWakeRecord[] Read-only render-facing samples: position, rotation, age.
---@field settings OceanWakeSettings
---@field distanceUntilNext number
---@field lastPosition OceanWakePoint?
local Wake = {}
Wake.__index = Wake

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function pointCopy(position)
    if type(position) ~= "table" or not finite(position.x) or not finite(position.y) then return nil end
    return { x = position.x, y = position.y }
end

local function numberOr(value, fallback)
    if finite(value) then return value end
    return fallback
end

local function buildSettings()
    local visual = Config.visual or {}
    local source = visual.wake or {}
    local settings = {
        lifetimeSec = math.max(0.1, numberOr(source.lifetimeSec, 3)),
        spacingMeters = math.max(0.05, numberOr(source.spacingMeters, 0.6)),
        minSpeed = math.max(0, numberOr(source.minSpeed, 0.15)),
        maxSamples = math.max(1, math.floor(numberOr(source.maxSamples, 96))),
        initialWidth = math.max(0.05, numberOr(source.initialWidth, 0.65)),
        spreadPerSec = math.max(0, numberOr(source.spreadPerSec, 0.45)),
        sternOffset = math.max(0, numberOr(source.sternOffset, 2.5)),
        opacity = math.max(0, math.min(255, numberOr(source.opacity, 125))),
    }
    return settings
end

---@param ship table?
---@return OceanWake
function Wake.New(ship)
    local self = setmetatable({}, Wake)
    self:Init(ship)
    return self
end

---@param ship table?
function Wake:Init(ship)
    self.records = {}
    self.settings = buildSettings()
    self.distanceUntilNext = self.settings.spacingMeters
    self.lastPosition = type(ship) == "table" and pointCopy(ship.position) or nil
end

local function trimRecords(records, maximum)
    while #records > maximum do
        table.remove(records, 1)
    end
end

local function ageRecords(records, step, lifetime)
    if step <= 0 then return end
    for index = #records, 1, -1 do
        local record = records[index]
        record.age = record.age + step
        if record.age >= lifetime then table.remove(records, index) end
    end
end

function Wake:_AppendSample(previousPosition, dx, dy, distance, pathDistance)
    local directionX, directionY = dx / distance, dy / distance
    local sampleX = previousPosition.x + directionX * pathDistance
    local sampleY = previousPosition.y + directionY * pathDistance
    local heading = math.atan(dy, dx)
    local settings = self.settings
    self.records[#self.records + 1] = {
        position = {
            x = sampleX - directionX * settings.sternOffset,
            y = sampleY - directionY * settings.sternOffset,
        },
        rotation = heading,
        age = 0,
    }
    trimRecords(self.records, settings.maxSamples)
end

-- Sample only the measured ship displacement. Collision response and turning are
-- already reflected in currentPosition - previousPosition.
---@param step number
---@param ship table
---@param previousPosition OceanWakePoint?
function Wake:Update(step, ship, previousPosition)
    step = math.max(0, numberOr(step, 0))
    ageRecords(self.records, step, self.settings.lifetimeSec)

    local currentPosition = type(ship) == "table" and pointCopy(ship.position) or nil
    if not currentPosition then return end
    local startPosition = pointCopy(previousPosition) or pointCopy(self.lastPosition)
    self.lastPosition = currentPosition
    if not startPosition or step <= 0 then return end

    local dx = currentPosition.x - startPosition.x
    local dy = currentPosition.y - startPosition.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= 1e-8 or distance / step < self.settings.minSpeed then return end

    local spacing = self.settings.spacingMeters
    local maxSamples = self.settings.maxSamples
    local maxTraceLength = spacing * maxSamples

    -- A teleport or unusually large catch-up step starts a bounded recent segment
    -- instead of drawing one continuous wake over the entire gap.
    if distance > maxTraceLength then
        local traceStart = distance - maxTraceLength
        for sampleIndex = 1, maxSamples do
            self:_AppendSample(startPosition, dx, dy, distance, traceStart + sampleIndex * spacing)
        end
        self.distanceUntilNext = spacing
        return
    end

    local nextDistance = self.distanceUntilNext
    local appended = 0
    while nextDistance <= distance + 1e-8 and appended < maxSamples do
        self:_AppendSample(startPosition, dx, dy, distance, math.min(nextDistance, distance))
        nextDistance = nextDistance + spacing
        appended = appended + 1
    end
    self.distanceUntilNext = math.max(1e-8, nextDistance - distance)
end

-- Clears all samples and starts measuring from the supplied ship position.
---@param ship table?
function Wake:Reset(ship)
    self.records = {}
    self.distanceUntilNext = self.settings.spacingMeters
    self.lastPosition = type(ship) == "table" and pointCopy(ship.position) or nil
end

return Wake
