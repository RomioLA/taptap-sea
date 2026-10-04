-- Connects the standalone Ocean runtime to the independent Gameplay loop.
-- The loop owns game time/player state; Ocean owns movement and world entities.
local OceanConfig = require("Ocean.Config")
local OceanMath = require("Ocean.Math")
local Loop = require("Gameplay.Loop")
local Game = require("Game.Game")
local Diagnostics = require("Gameplay.Diagnostics")

---@class GameplayOceanBridge
---@field runtime table
---@field loop GameplayLoop
---@field game SeaGameplayGame
---@field _externalDropReceiver (fun(payload:table, position:GameplayActionPoint):boolean)?
---@field _barrelReadErrorLogged boolean? Diagnostic latch only; no action state.
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

local function getWorldIdentity(runtime)
    if type(runtime.GetFishingGeneration) ~= "function" then error("world_identity_unavailable", 0) end
    local ok, identity = Diagnostics.Call("Integration", "world_identity", runtime.GetFishingGeneration, runtime)
    if not ok or type(identity) ~= "number" or identity ~= identity
        or identity < 0 or identity == math.huge or identity ~= math.floor(identity) then
        error("world_identity_unavailable", 0)
    end
    return identity
end

---@param self GameplayOceanBridge
---@param day integer
---@param clearDropTarget boolean
local function refreshDynamicWorld(self, day, clearDropTarget)
    local identity = getWorldIdentity(self.runtime)
    if self.loop:IsWorldPrepared(day, identity) then return true end
    local reset, reason = assert(self.loop.actions):Reset(clearDropTarget)
    if not reset then error(reason or "action_reset_failed", 0) end
    local seed = OceanConfig.world.seed + day - 1
    local departure = self.runtime:GetShipPosition()
    local accepted = self.runtime:refreshOrdinaryFish(seed, departure)
    if accepted == false then error("new_day_preparation_failed", 0) end
    self.loop:MarkWorldPrepared(day, getWorldIdentity(self.runtime))
    return true
end

---@param self GameplayOceanBridge
---@param day integer
local function handleNewDay(self, day)
    refreshDynamicWorld(self, day, true)
    self:Sync()
    return true
end

---@param self GameplayOceanBridge
---@param payload table
---@return boolean
local function receiveDrop(self, payload)
    local loop = self.loop
    local target = assert(self.loop.actions):GetDropTarget()
    -- Loop:DropItem sets dropInFlight around this synchronous handoff. Do not
    -- call Ready()/CanStartAction here: those intentionally reject in-flight work.
    if not loop or loop.dropInFlight ~= true or not target or not isPoint(target) then return false end

    local position = copyPoint(target)
    local distanceSquared = OceanMath.distanceSquared(self.runtime:GetShipPosition(), position)
    if distanceSquared > OceanConfig.interaction.maxThrowDistance ^ 2 then return false end

    local spawnOk, entity = Diagnostics.Call("Integration", "drop_spawn", self.runtime.spawnDroppedItem, self.runtime, payload, position)
    if not spawnOk or not entity then return false end

    local externalReceiver = self._externalDropReceiver
    if externalReceiver then
        local callbackOk, accepted = Diagnostics.Call("Integration", "drop_receiver", externalReceiver, payload, copyPoint(position))
        if not callbackOk or accepted ~= true then
            self.runtime:RejectDroppedItem(entity.id)
            return false
        end
    end

    assert(self.loop.actions):SetDropTarget(nil)
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
        return true
    end
    loopOptions.prepareLoadedWorld = function(day)
        return refreshDynamicWorld(self, day, true)
    end

    self.loop = Loop.New(loopOptions)
    self.loop:EnableWorldActions():BindRuntime(runtime)
    self.loop:BindRuntime(runtime)
    self.game = Game.New(runtime, self.loop)
    self.loop:SetStateObserver(function() self:Sync() end)

    self:Sync()
    return self
end

---Clock pause state is authoritative; Runtime.paused is only its mirror.
---@return boolean paused, number shipLevel, boolean scopeSynced, string? scopeReason
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
    local runtime = self.runtime
    if type(runtime.GetFixedBarrel) == "function" then
        local ok, barrel = xpcall(runtime.GetFixedBarrel, function(err)
            if not self._barrelReadErrorLogged then
                self._barrelReadErrorLogged = true
                Diagnostics.Exception("Integration", "barrel_read", err)
            end
            return err
        end, runtime)
        if ok then self._barrelReadErrorLogged = false end
        if ok and barrel and type(barrel.contentId) == "string" and barrel.position then
            self:RecognizeLocation(barrel.contentId, barrel.position)
        end
    end
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
    assert(self.loop.actions):SetDropTarget(nil)
    if not isPoint(position) then return false, "invalid_drop_position" end
    local target = copyPoint(position)
    if not self.runtime:IsPositionFree(target, 0) then
        return false, "invalid_drop_position"
    end
    assert(self.loop.actions):SetDropTarget(target)
    return true
end

function Bridge:BeginFishing(center)
    return assert(self.loop.actions):BeginFishing(center, self.runtime)
end

function Bridge:CompleteFishing(token, ...)
    return assert(self.loop.actions):CompleteFishing(self.runtime, token, ...)
end

function Bridge:CancelFishing(token)
    return assert(self.loop.actions):CancelFishing(token)
end

function Bridge:HandleThrowPointer(position)
    local selected = self.loop:GetThrowSelection()
    if not selected then return false, "throw_selection_required" end
    if self.loop.player.inventory:GetItems()[selected.index] ~= selected.itemId then
        self.loop:CancelThrowSelection()
        return false, "throw_item_changed"
    end
    local valid, reason = self:SetDropTarget(position)
    self.runtime:ClearMovementTarget()
    if not valid then return false, reason end
    local dropped, dropReason = self.loop:DropItem(selected.index)
    self:Sync()
    return dropped, dropReason
end

-- The consumption return value is the new Ocean input protocol. Clearing its
-- movement target also protects the older local adapter that ignores this value.
function Bridge:OnSeaPointer(position)
    local fishing = self.loop:GetFishingState()
    if fishing.state == "selecting" then
        self.runtime:ClearMovementTarget()
        local ok, reason = self.loop:SetFishingCenter(position)
        -- One legal mouse/touch sea pointer starts the cast. Invalid positions
        -- keep selection active and never fall through to navigation.
        if ok then ok, reason = self.loop:ConfirmFishing() end
        if not ok then self.loop:SetMessage(tostring(reason)) end
        return true
    end
    if self.loop:IsMovementBlocked() and not self.loop:GetThrowSelection() then
        self.runtime:ClearMovementTarget()
        return true
    end
    if self.loop:GetThrowSelection() then
        local ok, reason = self:HandleThrowPointer(position)
        if not ok then self.loop:SetMessage(tostring(reason)) end
        return true
    end
    return false
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
    if self.loop:HasPendingCatch() then return false, "pending_catch_required" end
    local function loaded(ok, data)
        if ok and data ~= nil then
            assert(self.loop.actions):SetDropTarget(nil)
            assert(self.loop.actions):Reset(true)
            self.runtime:ClearMovementTarget()
        end
        self:Sync()
        if callback then callback(ok, data) end
    end
    return self.loop:LoadSaved(loaded)
end

return Bridge
