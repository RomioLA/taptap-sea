-- Connects the standalone Ocean runtime to the independent Gameplay loop.
-- The loop owns game time/player state; Ocean owns movement and world entities.
local OceanConfig = require("Ocean.Config")
local OceanMath = require("Ocean.Math")
local Loop = require("Gameplay.Loop")
local Game = require("Game.Game")

---@class GameplayOceanBridge
---@field runtime table
---@field loop GameplayLoop
---@field game table
---@field _externalDropReceiver (fun(payload:table, position:GameplayActionPoint):boolean)?
local Bridge = {}
Bridge.__index = Bridge

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

---@param point any
---@return boolean
local function isPoint(point)
    return type(point) == "table"
        and isFiniteNumber(point.x)
        and isFiniteNumber(point.y)
end

---@param point GameplayActionPoint
---@return GameplayActionPoint
local function copyPoint(point)
    return { x = point.x, y = point.y }
end

---@param options table
---@return table
local function copyOptions(options)
    local result = {}
    for key, value in pairs(options) do result[key] = value end
    return result
end

---@param self GameplayOceanBridge
---@param day integer
---@param clearDropTarget boolean
local function refreshDynamicWorld(self, day, clearDropTarget)
    local seed = OceanConfig.world.seed + day - 1
    local departure = self.runtime:GetShipPosition()
    self.runtime:refreshOrdinaryFish(seed, departure)
    self.loop.actions:Reset(clearDropTarget)
end

---@param self GameplayOceanBridge
---@param day integer
local function handleNewDay(self, day)
    refreshDynamicWorld(self, day, true)
    self:Sync()
end

---@param self GameplayOceanBridge
---@param payload table
---@return boolean
local function receiveDrop(self, payload)
    local loop = self.loop
    local target = self.loop.actions:GetDropTarget()
    -- Loop:DropItem sets dropInFlight around this synchronous handoff. Do not
    -- call Ready()/CanStartAction here: those intentionally reject in-flight work.
    if not loop or loop.dropInFlight ~= true or not target or not isPoint(target) then return false end

    local position = copyPoint(target)
    local distanceSquared = OceanMath.distanceSquared(self.runtime:GetShipPosition(), position)
    if distanceSquared > OceanConfig.interaction.maxThrowDistance ^ 2 then return false end

    local spawnOk, entity = pcall(self.runtime.spawnDroppedItem, self.runtime, payload, position)
    if not spawnOk or not entity then return false end

    local externalReceiver = self._externalDropReceiver
    if externalReceiver then
        local callbackOk, accepted = pcall(externalReceiver, payload, copyPoint(position))
        if not callbackOk or accepted ~= true then
            self.runtime:RejectDroppedItem(entity.id)
            return false
        end
    end

    self.loop.actions:SetDropTarget(nil)
    return true
end

---@param runtime table
---@param options table|nil
---@return GameplayOceanBridge
function Bridge.New(runtime, options)
    assert(type(runtime) == "table", "Ocean runtime is required")
    assert(type(runtime.refreshOrdinaryFish) == "function", "runtime.refreshOrdinaryFish is required")
    assert(type(runtime.spawnDroppedItem) == "function", "runtime.spawnDroppedItem is required")
    assert(type(runtime.SetShipLevel) == "function", "runtime.SetShipLevel is required")
    assert(type(runtime.Update) == "function", "runtime.Update is required")

    local supplied = options or {}
    local self = setmetatable({
        runtime = runtime,
        _externalDropReceiver = supplied.dropReceiver,
    }, Bridge)

    local loopOptions = copyOptions(supplied)
    local externalNewDay = supplied.onNewDay
    local externalReset = supplied.resetDynamicWorld
    loopOptions.dropReceiver = function(payload)
        return receiveDrop(self, payload)
    end
    loopOptions.onNewDay = function(day)
        handleNewDay(self, day)
        if externalNewDay then return externalNewDay(day) end
    end
    loopOptions.resetDynamicWorld = function()
        refreshDynamicWorld(self, self.loop.player.day, true)
        self.runtime:ClearMovementTarget()
        self:Sync()
        if externalReset then return externalReset() end
    end

    self.loop = Loop.New(loopOptions)
    self.loop:EnableWorldActions()
    self.game = Game.New(runtime, self.loop)
    self.loop:SetStateObserver(function() self:Sync() end)

    self:Sync()
    return self
end

---Clock pause state is authoritative; Runtime.paused is only its mirror.
---@return boolean paused, integer shipLevel
function Bridge:Sync()
    return self.game:Sync()
end

---Advance the gameplay clock with raw dt; Ocean Runtime applies its own
---simulation clamp internally and does not own the game's day/night clock.
---@param dt number
---@param axisX number|nil
---@param axisY number|nil
---@return boolean, number|string
function Bridge:Update(dt, axisX, axisY)
    if not isFiniteNumber(dt) or dt < 0 then return false, "invalid_dt" end
    self.game:Update(dt, axisX, axisY)
    return true, dt
end

---Toggle only the manual pause reason; other pause owners remain intact.
---@return boolean, boolean
function Bridge:TogglePause()
    self.loop:ToggleManualPause()
    self:Sync()
    return true, self.loop.clock:IsPaused()
end

---@return boolean, string?
function Bridge:NewRun()
    return self.loop:NewRun()
end

---Store an explicit world-space drop target. Runtime spawn remains the final
---authority for the configured throw radius and playable-world validity.
---@param position any
---@return boolean, string?
function Bridge:SetDropTarget(position)
    -- A new pointer selection supersedes any prior target, even if this
    -- selection itself is invalid; a failed click must never drop at an old spot.
    self.loop.actions:SetDropTarget(nil)
    if not isPoint(position) then return false, "invalid_drop_position" end
    local target = copyPoint(position)
    if not self.runtime:IsPositionFree(target, 0) then
        return false, "invalid_drop_position"
    end
    self.loop.actions:SetDropTarget(target)
    return true
end

function Bridge:BeginFishing(center)
    return self.loop.actions:BeginFishing(center, self.runtime)
end

function Bridge:CompleteFishing(token, ...)
    return self.loop.actions:CompleteFishing(self.runtime, token, ...)
end

function Bridge:CancelFishing(token)
    return self.loop.actions:CancelFishing(token)
end

---Persist a location recognition only when the supplied world point is within
---the A interaction radius. No location entity is spawned or required.
---@param locationId string
---@param position any
---@return boolean, boolean|string
function Bridge:RecognizeLocation(locationId, position)
    if type(locationId) ~= "string" or locationId == "" then
        return false, "invalid_location_id"
    end
    if not isPoint(position) then return false, "invalid_location_position" end
    if OceanMath.distanceSquared(self.runtime:GetShipPosition(), position)
        > OceanConfig.interaction.recognitionDistance ^ 2 then
        return false, "location_out_of_range"
    end
    return self.loop:RecognizeLocation(locationId)
end

---Explicitly load saved B player state. Bridge never autoloads in New().
---@param callback fun(ok:boolean, data:any)|nil
---@return boolean started, string|nil reason
function Bridge:LoadSaved(callback)
    local function loaded(ok, data)
        if ok and data ~= nil then
            self.loop.actions:SetDropTarget(nil)
            self.loop.actions:Reset(true)
            self.runtime:ClearMovementTarget()
            local refreshOk, refreshError = pcall(refreshDynamicWorld, self, self.loop.player.day, false)
            if not refreshOk then
                self.loop:SetMessage("已读档，但动态世界刷新失败：" .. tostring(refreshError))
            end
        end
        self:Sync()
        if callback then callback(ok, data) end
    end
    return self.loop:LoadSaved(loaded)
end

return Bridge
