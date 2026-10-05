-- B 玩法协调器；不依赖船位、World、鱼 FSM 或现有 Ocean 演示状态。
local Config = require("config.gameplay")
local Items = require("data.items")
local PlayerState = require("Gameplay.PlayerState")
local GameClock = require("Gameplay.GameClock")
local Persistence = require("Gameplay.Persistence")
local Actions = require("Gameplay.Actions")
local Diagnostics = require("Gameplay.Diagnostics")
local Progress = require("Gameplay.Circle1B2Progress")
local Barrel = require("Gameplay.Circle1B2Barrel")
---@alias GameplayWorldPreparation {generation:number, day:integer, worldIdentity:number}
---@class GameplayPortAccessDetails
---@field shipX number
---@field shipY number
---@field portX number
---@field portY number
---@field distance number
---@field radius number

---@class GameplayLoop
---@field player PlayerState
---@field clock GameClock
---@field inPort boolean
---@field inventoryOpen boolean
---@field elderOpen boolean
---@field forcedReturnPending boolean
---@field settlementPending boolean
---@field dayExhausted boolean
---@field settlementApplied boolean
---@field busy boolean
---@field loading boolean
---@field dropInFlight boolean
---@field settlementForced boolean
---@field portNightElapsed number
---@field generation number
---@field options table
---@field store table
---@field settlementSnapshot table
---@field saveStatus string
---@field lastMessage string
---@field shopStock table<string, integer>
---@field actions GameplayActions?
---@field inventoryRollback table?
---@field barrel Circle1B2Barrel
---@field runtime table?
---@field throwSelection table?
---@field storyDialog table?
---@field scopeEnabled boolean
---@field scopeSyncError string?
---@field worldPreparation GameplayWorldPreparation?
---@field initialSaveStatus string
---@field initialSaveBusy boolean
---@field requestSequence integer
---@field lastSettlementSaveId integer?
local Loop = {}
Loop.__index = Loop

function Loop.New(options)
    local self = setmetatable({}, Loop)
    self:Init(options or {})
    return self
end

function Loop:Init(options)
    self.options = options
    self.store = options.store or Persistence.Dual(options.cloud)
    self.generation = 0
    self.requestSequence = 0
    self:ResetState()
    self.barrel = Barrel.New(self)
end

function Loop:ResetState()
    if self.inventoryRollback then return false, "inventory_rollback_pending" end
    if self.actions then
        local resetOk, reason = self.actions:Reset(true)
        if not resetOk then return false, reason end
    end
    if self.barrel then
        local ok, reason = self.barrel:Reset()
        if not ok then return false, reason end
    end
    self.generation = self.generation + 1
    self.player = assert(PlayerState.New())
    Progress.Initialize(self.player)
    Progress.OnDayStarted(self.player)
    self:ResetShopStock()
    self.clock = GameClock.New()
    self.inPort = true
    self.inventoryOpen, self.elderOpen = false, false
    self.forcedReturnPending, self.settlementPending = false, false
    self.dayExhausted, self.settlementApplied = false, false
    self.busy, self.loading = false, false
    self.dropInFlight = false
    self.saveStatus, self.lastMessage = "idle", "新周目已开始"
    self.portNightElapsed = 0
    self.settlementForced = false
    self.settlementSnapshot = {}
    self.throwSelection, self.storyDialog, self.scopeEnabled = nil, nil, false
    self.scopeSyncError = nil
    self.closed = false
    self.loadStatus = "idle"
    self.portPreparedForSettlement = false
    self.forcedAtPort = false
    self.entryPending = false
    self.activeRequest = nil
    self.initialSaveStatus, self.initialSaveBusy, self.initialSaveSnapshot = "idle", false, nil
    self.dayPreparationError = false
    self.settlementSaveDecision = nil
    self.worldPreparation = nil
    self.clock:Pause("port")
    return true
end

function Loop:Ready()
    return not self.closed and not self.entryPending and not self.busy and not self.loading and not self.dropInFlight
        and not self.inventoryRollback
        and not self.forcedReturnPending and not self.settlementPending
        and not (self.actions and self.actions:IsBusy())
        and not (self.barrel and self.barrel:IsBusy()) and not self.storyDialog
end

-- 仅新周目、下一天应用或成功恢复每日结算快照时补货。
function Loop:ResetShopStock()
    self.shopStock = {}
    for itemId, quantity in pairs(Config.shop.dailyStock) do
        self.shopStock[itemId] = quantity
    end
end

function Loop:GetShopStock(itemId)
    return self.shopStock[itemId] or 0
end

local function emit(self, event, fields)
    fields.generation = fields.generation or self.generation
    Diagnostics.Event("Loop", event, fields)
end

local function newRequest(self, kind)
    self.requestSequence = self.requestSequence + 1
    return { kind = kind, id = self.requestSequence }
end

function Loop:Update(dt, advanceWorld)
    self:RetryInventoryRollback()
    if self.barrel then self.barrel:Tick() end
    local actions, clock = self.actions, self.clock
    if actions then actions:ValidateGeneration() end
    if actions and clock.exhausted then
        actions:CancelActiveFishing("night_interrupted")
    end
    local remaining = dt
    repeat
        local slice = remaining
        if actions and not clock:IsPaused() and not clock.exhausted then
            slice = math.min(slice, actions:SecondsToBoundary() / clock.timeScale)
        end
        if self.barrel and not clock:IsPaused() and not clock.exhausted then
            local barrelBoundary = self.barrel:SecondsToBoundary()
            if barrelBoundary < math.huge then
                slice = math.min(slice, barrelBoundary / clock.timeScale)
            end
        end
        if slice <= 1e-9 and remaining > 0 then
            if actions then actions:ResolveBoundary() end
            if self.barrel and not clock:IsPaused() and not clock.exhausted
                and self.barrel:SecondsToBoundary() <= 1e-9 then
                self.barrel:Advance(0)
            end
            slice = remaining
            if actions and not clock:IsPaused() and not clock.exhausted then
                slice = math.min(slice, actions:SecondsToBoundary() / clock.timeScale)
            end
            if self.barrel and not clock:IsPaused() and not clock.exhausted then
                slice = math.min(slice, self.barrel:SecondsToBoundary() / clock.timeScale)
            end
            if slice <= 1e-9 then slice = remaining end
        end
        if not clock:IsPaused() and not clock.exhausted then
            local untilNight = clock.nightSec - clock.elapsed
            if clock.phase == "day" then untilNight = clock.daySec - clock.elapsed + clock.nightSec end
            slice = math.min(slice, untilNight / clock.timeScale)
        end
        local before = clock.elapsed + (clock.phase == "night" and clock.daySec or 0)
        local previousPhase = clock.phase
        clock:Update(slice)
        if previousPhase == "day" and clock.phase == "night" and not clock.exhausted then
            self.lastMessage = "黄昏已至，请留意返港：夜晚前30秒返港体力全满；之后每晚归1秒次日少1体力，夜尽强返恢复上限的一半。"
        end
        local after = clock.elapsed + (clock.phase == "night" and clock.daySec or 0)
        local gameSeconds = math.max(0, after - before)
        if actions then actions:AdvanceFishing(gameSeconds) end
        if clock.exhausted then
            -- Resolve exact-tie actions before the forced pause, then prevent any
            -- Ocean simulation after night ends.
            if self.barrel then self.barrel:Advance(gameSeconds) end
            if actions then actions:ResolveBoundary() end
            self:RefreshClockStatus()
            if advanceWorld then advanceWorld(slice) end
        else
            if advanceWorld then advanceWorld(slice) end
            if self.barrel then self.barrel:Advance(gameSeconds) end
            if actions then actions:ResolveBoundary() end
            self:RefreshClockStatus()
        end
        remaining = math.max(0, remaining - slice)
    until remaining <= 1e-9
end

function Loop:RefreshClockStatus()
    if self.clock.exhausted and not self.dayExhausted then
        if self.actions then self.actions:CancelActiveFishing("night_interrupted") end
        self.dayExhausted = true
        self.forcedReturnPending = true
        self.clock:Pause("forced_return")
        self.lastMessage = "夜深了，你必须返港。"
        if self.barrel and self.barrel:IsBusy() then self.barrel:Cancel("night_interrupted") end
        -- Completed catches are retained for explicit claim, including at night end.
        if not self:HasPendingCatch() then
            local returned = self:PreparePort("forced_return")
            if returned then
                self.inPort, self.forcedAtPort, self.portPreparedForSettlement = true, true, true
                self.clock:Pause("port")
            else
                self.lastMessage = "夜深了，你必须返港。实际返港暂未完成，请重试返港。"
            end
        end
    end
end

-- Binding is explicit so the standalone Gameplay contract remains usable without Ocean.
function Loop:EnableWorldActions()
    if self.actions then return self.actions end
    self.actions = Actions.New(self)
    self.CompleteFishing = function()
        return false, "fishing_requires_bridge_token"
    end
    return self.actions
end

function Loop:SetStateObserver(observer)
    assert(type(observer) == "function", "state observer must be a function")
    assert(not self.stateObserver, "state observer already installed")
    self.stateObserver = observer
    for _, name in ipairs({ "SetInventoryOpen", "SetElderOpen", "ReturnToPort", "Depart",
        "EndToday", "ConfirmForcedReturn", "ConfirmSettlement", "ContinueWithoutSaving", "SettleDay",
        "LoadSaved", "NewRun", "RetryInitialSave", "UpgradeBoatSpeed", "SellAll" }) do
        local original = self[name]
        self[name] = function(_, ...)
            local result = table.pack(Diagnostics.Call("Loop", "operation_" .. name, original, self, ...))
            local syncOk, syncError = Diagnostics.Call("Loop", "state_observer", observer)
            if not result[1] then error(result[2], 0) end
            if not syncOk then error(syncError, 0) end
            return table.unpack(result, 2, result.n)
        end
    end
end

function Loop:ToggleManualPause()
    if self.clock.pauseReasons.manual then self.clock:Resume("manual")
    else self.clock:Pause("manual") end
end

function Loop:SetMessage(message)
    self.lastMessage = message
end

function Loop:RecognizeLocation(locationId)
    local wasRecognized = self.player:IsRecognized(locationId)
    local marked, markError = self.player:MarkRecognized(locationId)
    if not marked then return false, markError or "recognition_rejected" end
    return true, not wasRecognized
end

function Loop:RestoreActionResources(previousItems, oldStamina, portSnapshot)
    if previousItems then
        local restored, reason
        if portSnapshot then
            restored, reason = self.player.inventory:RestoreSnapshot(portSnapshot.level, previousItems)
        else
            restored, reason = self.player.inventory:RestoreItems(previousItems)
        end
        if not restored then return false, reason end
    end
    self.player.stamina = oldStamina
    if portSnapshot then
        local speedChanged = self.player.boatSpeedLevel ~= portSnapshot.boatSpeedLevel
        self.player.money, self.player.maxStamina = portSnapshot.money, portSnapshot.maxStamina
        self.player.boatSpeedLevel = portSnapshot.boatSpeedLevel
        self.shopStock = portSnapshot.stock
        if self.runtime and (speedChanged or portSnapshot.restoreShipLevel) then
            portSnapshot.restoreShipLevel = true
            local applied = self.runtime:SetShipLevel(portSnapshot.boatSpeedLevel)
            if applied == false then return false, "speed_upgrade_failed" end
            if type(applied) == "number" and applied ~= Config.upgrades.boatSpeed.metersPerSec[portSnapshot.boatSpeedLevel] then
                return false, "speed_upgrade_failed"
            end
            portSnapshot.restoreShipLevel = nil
        end
    end
    return true
end

-- Cargo is removed before the external handoff. A rejected handoff restores the
-- full snapshot; failed restoration blocks further edits until a later retry.
function Loop:RetryInventoryRollback()
    local pending = self.inventoryRollback
    if not pending then return true end
    local ok, restored
    if pending.diagnosticExceptionLogged then
        ok, restored = pcall(self.RestoreActionResources, self, pending.items, pending.stamina, pending.portSnapshot)
    else
        ok, restored = Diagnostics.Call(
            "Loop", "inventory_rollback", self.RestoreActionResources,
            self, pending.items, pending.stamina, pending.portSnapshot)
        if not ok then pending.diagnosticExceptionLogged = true end
    end
    if not ok or restored ~= true then return false, "inventory_rollback_pending" end
    if pending.diagnosticExceptionLogged then
        emit(self, "inventory_rollback", { kind = "operation", result = "recovered", reason = "rollback_restored" })
    end
    self.inventoryRollback = nil
    return true
end

function Loop:RollbackInventory(items, stamina, reason)
    self.inventoryRollback = { items = items, stamina = stamina }
    local restored, rollbackReason = self:RetryInventoryRollback()
    return false, restored and reason or rollbackReason
end

function Loop:RemoveCargo(index)
    local inventory = self.player.inventory
    local readOk, previous = Diagnostics.Call("Loop", "cargo_snapshot", inventory.GetItems, inventory)
    if not readOk then return false, "inventory_snapshot_failed" end
    local stamina = self.player.stamina
    local ok, removed, reason = Diagnostics.Call("Loop", "cargo_remove", inventory.Remove, inventory, index)
    if not ok or removed ~= true then
        return self:RollbackInventory(previous, stamina, ok and reason or "inventory_remove_failed")
    end
    return true, previous, stamina
end

function Loop:SetInventoryOpen(open)
    if open == false and self:HasPendingCatch() then return false, "pending_catch_required" end
    if type(open) ~= "boolean" then return false, "busy" end
    local bucketOnlyBusy = self.barrel and self.barrel:IsBusy() and (open or self.inventoryOpen)
        and not self.closed and not self.entryPending and not self.busy and not self.loading
        and not self.initialSaveBusy and not self.dropInFlight and not self.inventoryRollback
        and not self.forcedReturnPending and not self.settlementPending
        and not (self.actions and self.actions:IsBusy()) and not self.storyDialog
    if not self:Ready() and not (open and self:CanManageInventory()) and not bucketOnlyBusy then return false, "busy" end
    self.inventoryOpen = open
    if open then self.clock:Pause("inventory") else self.clock:Resume("inventory") end
    return true
end

function Loop:SetElderOpen(open)
    local present, reason = self:IsElderPresent()
    if open and not present then return false, reason or "elder_not_present" end
    if type(open) ~= "boolean" then return false, "busy" end
    local bucketOnlyBusy = self.barrel and self.barrel:IsBusy() and (open or self.elderOpen)
        and not self.closed and not self.entryPending and not self.busy and not self.loading
        and not self.initialSaveBusy and not self.dropInFlight and not self.inventoryRollback
        and not self.forcedReturnPending and not self.settlementPending
        and not (self.actions and self.actions:IsBusy()) and not self.storyDialog
    if not self:Ready() and not self:CanManageInventory() and not bucketOnlyBusy then return false, "busy" end
    self.elderOpen = open
    if open then self.clock:Pause("elder") else self.clock:Resume("elder") end
    return true
end

local function readPortAccess(runtime)
    if not runtime then return true end
    if type(runtime.GetPortPosition) ~= "function" or type(runtime.GetShipPosition) ~= "function" then
        return false, "port_interface_unavailable"
    end
    local port, ship = runtime:GetPortPosition(), runtime:GetShipPosition()
    local dx, dy = ship.x - port.x, ship.y - port.y
    local distance = math.sqrt(dx * dx + dy * dy)
    assert(distance == distance and distance < math.huge)
    local radius = require("Ocean.Config").interaction.portDistance
    local details = {
        shipX = ship.x, shipY = ship.y, portX = port.x, portY = port.y,
        distance = distance, radius = radius,
    }
    if distance <= radius then return true, nil, details end
    return false, "port_out_of_range", details
end

local function portFields(self, kind, result, reason, details, purpose)
    local fields = {
        kind = kind, result = result, reason = reason, purpose = purpose,
        generation = self.generation, radius = details and details.radius or 10,
        position_status = details and "available" or "unavailable",
    }
    if details then
        fields.ship_x, fields.ship_y = details.shipX, details.shipY
        fields.port_x, fields.port_y = details.portX, details.portY
        fields.distance, fields.radius = details.distance, details.radius
    end
    return fields
end

-- Standalone rules have no spatial world. A bound product must prove access.
---@return boolean, string?, GameplayPortAccessDetails?
function Loop:CanAccessPort()
    if not self.runtime then return true end
    local ok, near, reason, details = pcall(readPortAccess, self.runtime)
    if not ok then return false, "port_interface_unavailable" end
    return near, reason, details
end

---新手教程木桶方位与可达性（供 HUD 按钮显隐）；只读，不改任何状态。
---@return boolean, string?, GameplayBarrelAccessDetails?
function Loop:GetBarrelAccess()
    if not self.runtime or type(self.runtime.GetFixedBarrel) ~= "function"
        or type(self.runtime.GetShipPosition) ~= "function" then
        return false, "barrel_interface_unavailable"
    end
    local ok, barrel = pcall(self.runtime.GetFixedBarrel, self.runtime)
    if not ok or type(barrel) ~= "table" or type(barrel.position) ~= "table"
        or type(barrel.position.x) ~= "number" then
        return false, "barrel_unavailable"
    end
    local okShip, ship = pcall(self.runtime.GetShipPosition, self.runtime)
    if not okShip or type(ship) ~= "table" or type(ship.x) ~= "number" then
        return false, "barrel_position_unavailable"
    end
    local operateDistance = 5
    if type(self.runtime.GetBarrelOperateDistance) == "function" then
        local okDist, dist = pcall(self.runtime.GetBarrelOperateDistance, self.runtime)
        if okDist and type(dist) == "number" then operateDistance = dist end
    end
    local dx = barrel.position.x - ship.x
    local dy = barrel.position.y - ship.y
    local distance = math.sqrt(dx * dx + dy * dy)
    local near = distance <= operateDistance
    ---@class GameplayBarrelAccessDetails
    local details = { distance = distance, shipX = ship.x, shipY = ship.y,
        barrelX = barrel.position.x, barrelY = barrel.position.y, operateDistance = operateDistance }
    return near, near and nil or "barrel_out_of_range", details
end

-- Only forced return, new-day preparation, new run and restore call this.
function Loop:PreparePort(reason)
    if not self.runtime then return true end
    if type(self.runtime.ResetShipAtPort) ~= "function" then
        emit(self, "port_preparation", portFields(self, "failure", "failed", "port_reset_unavailable", nil, reason))
        return false, "port_reset_unavailable"
    end
    local ok, accepted, errorReason = Diagnostics.Call(
        "Loop", "port_reset", self.runtime.ResetShipAtPort, self.runtime)
    if not ok or accepted ~= true then
        local failure = errorReason or "port_reset_failed"
        emit(self, "port_preparation", portFields(self, "failure", "failed", failure, nil, reason))
        return false, failure
    end
    local accessOk, atPort, portReason, details = Diagnostics.Call(
        "Loop", "port_access_after_reset", readPortAccess, self.runtime)
    if not accessOk then atPort, portReason = false, "port_interface_unavailable" end
    if not atPort then
        emit(self, "port_preparation", portFields(self, "failure", "failed", portReason, details, reason))
        return false, portReason
    end
    if type(self.runtime.ClearMovementTarget) == "function" then
        local clearOk, clearError = Diagnostics.Call("Loop", "port_clear_movement", function()
            return self.runtime:ClearMovementTarget()
        end)
        if not clearOk then error(clearError, 0) end
    end
    emit(self, "port_preparation", portFields(self, "operation", "prepared", nil, details, reason))
    return true
end

function Loop:GetCargoRevision()
    return self.player.inventory:GetRevision()
end

function Loop:IsWorldPrepared(day, worldIdentity)
    local receipt = self.worldPreparation
    return receipt ~= nil and receipt.generation == self.generation
        and receipt.day == day and receipt.worldIdentity == worldIdentity
end

function Loop:MarkWorldPrepared(day, worldIdentity)
    self.worldPreparation = { generation = self.generation, day = day, worldIdentity = worldIdentity }
end

-- F2: 港口方位文案。世界坐标 Y 向上（见 Ocean/Draw.lua 屏幕反转注释），dx>0=东、dy>0=北。
local function compassText(details)
    local dx = details.portX - details.shipX
    local dy = details.portY - details.shipY
    local axisX = dx > 0 and "东" or dx < 0 and "西" or ""
    local axisY = dy > 0 and "北" or dy < 0 and "南" or ""
    local direction = axisX .. axisY
    if direction == "" then return "脚下" end
    return direction
end

function Loop:ReturnToPort()
    ---@type GameplayPortAccessDetails?
    local details
    local function reject(reason, kind)
        emit(self, "return_to_port", portFields(self, kind or "rejected", "rejected", reason, details))
        return false, reason
    end
    local detailRead, detailNear, detailReason, detailValue = Diagnostics.Call(
        "Loop", "return_port_access", readPortAccess, self.runtime)
    if detailRead then details = detailValue end
    if self:HasPendingCatch() then return reject("pending_catch_required") end
    if not self:Ready() then return reject("busy") end
    if not detailRead then return reject("port_interface_unavailable", "failure") end
    local near, reason = detailNear, detailReason
    if not near then
        -- F2: 返港引导——拒绝时给出港口方位与距离，玩家不再对着 port_out_of_range 找不到方向。
        if reason == "port_out_of_range" and details then
            self.lastMessage = string.format(
                "距港 %.0f 米：港口在%s方向，朝港口航行到 %d 米内再返港。",
                details.distance, compassText(details), details.radius)
        end
        return reject(reason or "port_interface_unavailable")
    end
    if self.inPort then
        emit(self, "return_to_port", portFields(self, "operation", "already_at_port", nil, details))
        return true
    end
    if self.runtime then
        local clearOk, clearError = Diagnostics.Call("Loop", "return_port_clear_movement", function()
            return self.runtime:ClearMovementTarget()
        end)
        if not clearOk then error(clearError, 0) end
    end
    self:CancelThrowSelection()
    self.inPort = true
    self.portNightElapsed = self.clock.phase == "night" and self.clock.elapsed or 0
    self.clock:Pause("port")
    self.lastMessage = "已返港，可交易、结束今天或再次出航"
    emit(self, "return_to_port", portFields(self, "operation", "returned", nil, details))
    return true
end

function Loop:Depart()
    if self:HasPendingCatch() then return false, "pending_catch_required" end
    if not self:Ready() or self.dayExhausted or self.clock.exhausted then return false, "day_finished" end
    if self.inventoryOpen or self.elderOpen then return false, "close_dialog_first" end
    self.inPort = false
    self.clock:Resume("port")
    self.lastMessage = "已出航"
    return true
end

function Loop:EndToday()
    if self:HasPendingCatch() then return false, "pending_catch_required" end
    if not self:Ready() or not self.inPort then return false, "port_required" end
    local near, reason = self:CanAccessPort()
    if not near then return false, reason end
    self.settlementPending, self.settlementForced = true, false
    self.clock:Pause("settlement")
    self.lastMessage = "确认结束今天并进入下一天？"
    return true
end

function Loop:ConfirmForcedReturn()
    if self:HasPendingCatch() then return false, "pending_catch_required" end
    if self.inventoryRollback or (self.actions and self.actions:IsBusy()) then return false, "busy" end
    if (self.barrel and self.barrel:IsBusy()) or self.storyDialog then return false, "busy" end
    if not self.forcedReturnPending or self.busy or self.loading then return false, "no_forced_return" end
    if not self.forcedAtPort then
        local returned, reason = self:PreparePort("forced_return")
        if not returned then return false, reason end
        self.forcedAtPort, self.portPreparedForSettlement = true, true
    end
    self.forcedReturnPending = false
    self.inPort = true
    self.clock:Pause("port")
    self.clock:Resume("forced_return")
    self.settlementPending, self.settlementForced = true, true
    self.clock:Pause("settlement")
    -- 强制返港确认同时确认结算，不能重新出航。
    return self:ConfirmSettlement()
end

function Loop:GetNextDayStamina(forced)
    if forced then return math.floor(self.player.maxStamina * Config.clock.forcedStaminaRatio) end
    local elapsed = self.inPort and self.portNightElapsed
        or (self.clock.phase == "night" and self.clock.elapsed or 0)
    local penalty = math.max(0, elapsed - Config.clock.graceSec) * Config.clock.penaltyPerSec
    return math.max(0, self.player.maxStamina - penalty)
end

function Loop:BeginNewDay()
    emit(self, "new_day_preparation", {
        kind = "operation", result = "started", day = self.player.day,
    })
    local function reject(reason)
        emit(self, "new_day_preparation", {
            kind = "rejected", result = "rejected", reason = reason, day = self.player.day,
        })
        return false, reason
    end
    if self:HasPendingCatch() then return reject("pending_catch_required") end
    if self.inventoryRollback or (self.actions and self.actions:IsBusy()) then return reject("busy") end
    if (self.barrel and self.barrel:IsBusy()) or self.storyDialog then return reject("busy") end
    -- 对外只允许由已经确认的结算调用，防止海上绕过处罚/自动存档。
    if not self.settlementPending or self.settlementApplied then return reject("settlement_required") end
    if not self.portPreparedForSettlement then
        local prepared, reason = self:PreparePort("new_day")
        if not prepared then
            emit(self, "new_day_preparation", {
                kind = "failure", result = "failed", reason = reason or "port_preparation_failed",
                day = self.player.day,
            })
            return false, reason
        end
        self.portPreparedForSettlement = true
    end
    local stamina = self:GetNextDayStamina(self.settlementForced)
    self.player.day = self.player.day + 1
    Progress.OnDayStarted(self.player)
    self:ResetShopStock()
    self.player.stamina = stamina
    self.clock:Reset()
    self.clock:Pause("port")
    self.clock:Pause("settlement")
    self.inPort, self.dayExhausted = true, false
    self.inventoryOpen, self.elderOpen = false, false
    self.portNightElapsed = 0
    self:CancelThrowSelection()
    self.settlementApplied = true
    self.forcedAtPort = false
    local snapshotOk, snapshot = Diagnostics.Call(
        "Loop", "new_day_snapshot", Persistence.Snapshot, self.player)
    if not snapshotOk then
        self.settlementSnapshot, self.saveStatus = nil, "error"
        self:SetMessage("日结快照暂未生成，可重试；当天进度已保留。")
        emit(self, "new_day_preparation", {
            kind = "failure", result = "failed", reason = "settlement_snapshot_failed", day = self.player.day,
        })
        return false, "settlement_snapshot_failed"
    end
    self.settlementSnapshot = snapshot
    emit(self, "new_day_preparation", { kind = "operation", result = "prepared", day = self.player.day })
    return true
end

---@param self GameplayLoop
local function finishSettlement(self, saved)
    if not self.settlementPending or not self.settlementApplied or self.busy or self.loading then
        return false, "no_settlement"
    end
    self.settlementSaveDecision = saved and "saved" or "skipped"
    if self.options.onNewDay then
        local hookOk, accepted, hookReason = Diagnostics.Call(
            "Loop", "new_day_world_prepare", self.options.onNewDay, self.player.day)
        if not hookOk or accepted == false then
            self.dayPreparationError = true
            self.lastMessage = "新日海洋准备失败，仍停留在港口；请重试准备。"
            emit(self, "new_day_preparation", {
                kind = "failure", result = "failed",
                reason = hookOk and (hookReason or "new_day_preparation_rejected") or "new_day_preparation_failed",
                day = self.player.day,
            })
            return false, "new_day_preparation_failed"
        end
    end
    self.dayPreparationError = false
    self.settlementPending, self.settlementApplied = false, false
    self.portPreparedForSettlement = false
    self.saveStatus = saved and "saved" or "skipped"
    self.clock:Resume("settlement")
    self.lastMessage = saved and "每日结算已保存，下一天已就绪"
        or "已跳过本次保存等待，下一天已就绪；未保存进度可能在退出后丢失，已发出的保存请求仍可能稍后写入。"
    emit(self, "new_day_preparation", {
        kind = "operation", result = "ready", reason = saved and "saved" or "explicitly_skipped",
        day = self.player.day,
    })
    return true
end

function Loop:ContinueWithoutSaving()
    if self.dayPreparationError and self.settlementSaveDecision == "skipped" then
        emit(self, "settlement_skip", { kind = "operation", result = "retry_preparation", reason = "explicitly_skipped" })
        return finishSettlement(self, false)
    end
    if self.entryPending and (self.initialSaveStatus == "saving" or self.initialSaveStatus == "error") then
        local request = self.activeRequest
        self.activeRequest = nil
        self.initialSaveBusy = false
        self.initialSaveSnapshot = nil
        self.initialSaveStatus, self.saveStatus = "skipped", "skipped"
        self.entryPending = false
        self.clock:Resume("entry")
        self.lastMessage = "已不等待新周目初始存档并继续；保存请求仍可能稍后完成，若未写入，旧云档可能在下次启动时恢复。"
        emit(self, "initial_save", {
            kind = "operation", result = "skipped", reason = "explicitly_skipped",
            id = request and request.id,
        })
        return true
    end
    if not self.settlementPending or not self.settlementApplied or self.loading
        or (self.saveStatus ~= "saving" and self.saveStatus ~= "error") then
        return false, "no_failed_settlement"
    end
    if self.busy then
        if not self.activeRequest or self.activeRequest.kind ~= "settlement_save" then
            return false, "no_failed_settlement"
        end
        local request = self.activeRequest
        -- The cloud call may still finish remotely. Invalidate its local callback so
        -- a later response cannot change the explicit skip decision.
        self.activeRequest, self.busy = nil, false
        emit(self, "settlement_save", {
            kind = "operation", result = "skipped", reason = "explicitly_skipped", id = request.id,
        })
    else
        emit(self, "settlement_save", {
            kind = "operation", result = "skipped", reason = "explicitly_skipped", id = self.lastSettlementSaveId,
        })
    end
    return finishSettlement(self, false)
end

function Loop:ConfirmSettlement()
    if self.closed then return false, "scene_closed" end
    if self:HasPendingCatch() then return false, "pending_catch_required" end
    if self.inventoryRollback or (self.actions and self.actions:IsBusy()) then return false, "busy" end
    if (self.barrel and self.barrel:IsBusy()) or self.storyDialog then return false, "busy" end
    if not self.settlementPending or self.busy or self.loading then return false, "no_settlement" end
    if self.dayPreparationError then return finishSettlement(self, self.settlementSaveDecision == "saved") end
    if not self.settlementApplied then
        local started, reason = self:BeginNewDay()
        if not started then return false, reason end
    end
    if not self.settlementSnapshot then
        local snapshotOk, snapshot = Diagnostics.Call(
            "Loop", "settlement_snapshot", Persistence.Snapshot, self.player)
        if not snapshotOk then
            emit(self, "settlement_save", {
                kind = "failure", result = "failed", reason = "settlement_snapshot_failed",
            })
            return false, "settlement_snapshot_failed"
        end
        self.settlementSnapshot = snapshot
    end
    local retrying = self.saveStatus == "error"
    self.busy, self.saveStatus = true, "saving"
    local generation = self.generation
    local request = newRequest(self, "settlement_save")
    self.lastSettlementSaveId = request.id
    self.activeRequest = request
    local completed = false
    local function done(ok, reason)
        if completed then
            emit(self, "settlement_save_callback", {
                kind = "rejected", result = "ignored", reason = "duplicate_callback",
                generation = generation, id = request.id,
            })
            return
        end
        if self.closed or generation ~= self.generation or self.activeRequest ~= request then
            local ignoredReason = self.closed and "scene_closed" or generation ~= self.generation
                and "generation_changed" or "request_replaced"
            emit(self, "settlement_save_callback", {
                kind = "rejected", result = "ignored", reason = ignoredReason,
                generation = generation, current_generation = self.generation, id = request.id,
            })
            return
        end
        completed = true
        self.activeRequest = nil
        self.busy = false
        self.saveStatus = ok and "saved" or "error"
        emit(self, "settlement_save", {
            kind = ok and "operation" or "failure", result = ok and "saved" or "failed",
            reason = ok and "saved" or "backend_failure", reason_type = type(reason), id = request.id,
        })
        if not ok then
            self.lastMessage = "结算存档失败，可重试保存，或明确放弃本次保存进入下一天。旧存档仍保留。"
            return
        end
        finishSettlement(self, true)
    end
    emit(self, "settlement_save", {
        kind = "operation", result = retrying and "retry_started" or "started", id = request.id,
    })
    local ok, accepted, err = Diagnostics.Call("Loop", "settlement_save_call", function()
        return self.store:Save(self.settlementSnapshot, done)
    end)
    if not ok then done(false, accepted) elseif accepted == false then done(false, err) end
    return true
end

function Loop:SettleDay()
    if not self.inPort then local ok, err = self:ReturnToPort(); if not ok then return false, err end end
    return self:EndToday()
end

function Loop:BeginEntry()
    self.entryPending = true
    self.clock:Pause("entry")
end

local function notifyState(self)
    if self.stateObserver then Diagnostics.Call("Loop", "state_observer", self.stateObserver) end
end

function Loop:SaveInitialState()
    if self.closed then return false, "scene_closed" end
    if not self.entryPending or self.initialSaveBusy then return false, "busy" end
    local snapshotOk, snapshot = Diagnostics.Call(
        "Loop", "initial_save_snapshot", Persistence.Snapshot, self.player)
    if not snapshotOk then
        self.initialSaveStatus, self.saveStatus = "error", "error"
        self.lastMessage = "新周目初始存档暂未生成；可重试，或不保存继续。"
        emit(self, "initial_save", {
            kind = "failure", result = "failed", reason = "initial_snapshot_failed",
        })
        return true
    end
    self.initialSaveSnapshot = snapshot
    self.initialSaveBusy = true
    self.initialSaveStatus, self.saveStatus = "saving", "saving"
    self.lastMessage = "正在保存新周目初始状态；成功后会立即开始游戏。"
    local generation = self.generation
    local request = newRequest(self, "initial_save")
    self.activeRequest = request
    local completed = false
    local function done(ok, reason)
        if completed then
            emit(self, "initial_save_callback", {
                kind = "rejected", result = "ignored", reason = "duplicate_callback",
                generation = generation, id = request.id,
            })
            return
        end
        if self.closed or generation ~= self.generation or self.activeRequest ~= request then
            local ignoredReason = self.closed and "scene_closed" or generation ~= self.generation
                and "generation_changed" or "request_replaced"
            emit(self, "initial_save_callback", {
                kind = "rejected", result = "ignored", reason = ignoredReason,
                generation = generation, current_generation = self.generation, id = request.id,
            })
            return
        end
        completed = true
        self.activeRequest = nil
        self.initialSaveBusy = false
        self.initialSaveStatus = ok and "saved" or "error"
        self.saveStatus = self.initialSaveStatus
        emit(self, "initial_save", {
            kind = ok and "operation" or "failure", result = ok and "saved" or "failed",
            reason = ok and "saved" or "backend_failure", reason_type = type(reason), id = request.id,
        })
        if ok then
            self.initialSaveSnapshot = nil
            self.entryPending = false
            self.clock:Resume("entry")
            self.lastMessage = "新周目起始状态已保存，冒险开始。"
        else
            self.lastMessage = "新周目初始存档失败，可重试，或不保存继续；旧云档仍保留。"
        end
        notifyState(self)
    end
    emit(self, "initial_save", { kind = "operation", result = "started", id = request.id })
    local ok, accepted, err = Diagnostics.Call("Loop", "initial_save_call", function()
        return self.store:Save(snapshot, done)
    end)
    if not ok then done(false, accepted) elseif accepted == false then done(false, err) end
    return true
end

function Loop:RetryInitialSave()
    if not self.entryPending or self.initialSaveBusy or self.initialSaveStatus ~= "error" then
        emit(self, "initial_save_retry", {
            kind = "rejected", result = "rejected", reason = "initial_save_not_retryable",
        })
        return false, "initial_save_not_retryable"
    end
    emit(self, "initial_save_retry", { kind = "operation", result = "started" })
    return self:SaveInitialState()
end

function Loop:Close()
    self.generation = self.generation + 1
    self.closed, self.activeRequest = true, nil
    self.busy, self.loading = false, false
    self.initialSaveBusy = false
    self.clock:Pause("closed")
    return true
end

function Loop:LoadSaved(done)
    if self:HasPendingCatch() then return false, "pending_catch_required" end
    if self.closed or self.busy or self.loading or self.initialSaveBusy or self.dropInFlight or self.settlementPending
        or self.forcedReturnPending or self.inventoryRollback or not self.inPort
        or (self.actions and self.actions:IsBusy()) or (self.barrel and self.barrel:IsBusy())
        or self.storyDialog then return false, "busy_or_at_sea" end
    local retrying = self.loadStatus == "error"
    self.loading = true
    self.loadStatus = "loading"
    self.clock:Pause("loading")
    local generation = self.generation
    local request = newRequest(self, "load")
    self.activeRequest = request
    local completed = false
    local function loaded(ok, data)
        if completed then
            emit(self, "load_callback", {
                kind = "rejected", result = "ignored", reason = "duplicate_callback",
                generation = generation, id = request.id,
            })
            return
        end
        if self.closed or generation ~= self.generation or self.activeRequest ~= request then
            local ignoredReason = self.closed and "scene_closed" or generation ~= self.generation
                and "generation_changed" or "request_replaced"
            emit(self, "load_callback", {
                kind = "rejected", result = "ignored", reason = ignoredReason,
                generation = generation, current_generation = self.generation, id = request.id,
            })
            return
        end
        completed = true
        self.activeRequest = nil
        self.loading = false
        self.clock:Resume("loading")
        if ok and data ~= nil then
            local restoreOk, player, err = Diagnostics.Call(
                "Loop", "load_restore", Persistence.Restore, data)
            if restoreOk and player then
                local prepared, prepareReason = self:PreparePort("restore")
                if prepared and self.options.prepareLoadedWorld then
                    local hookOk, accepted = Diagnostics.Call(
                        "Loop", "loaded_world_prepare", self.options.prepareLoadedWorld, player.day)
                    prepared = hookOk and accepted ~= false
                    prepareReason = "new_day_preparation_failed"
                end
                if not prepared then
                    self.loadStatus = "error"
                    self.lastMessage = "存档已读取，但港口与海洋准备失败；当前玩家状态保留，请重试读取。"
                    emit(self, "load", {
                        kind = "failure", result = "failed", reason = "world_preparation_failed",
                        reason_type = type(prepareReason), id = request.id,
                    })
                    if done then done(false, prepareReason) end
                    return
                end
                self.generation = self.generation + 1
                self.player = player
                Progress.OnDayStarted(self.player)
                self.scopeEnabled, self.throwSelection, self.storyDialog = false, nil, nil
                self:ResetShopStock()
                self.clock:Reset()
                self.clock:Pause("port")
                self.inventoryOpen, self.elderOpen = false, false
                self.portNightElapsed = 0
                self.inPort, self.dayExhausted = true, false
                self.entryPending = false
                self.loadStatus, self.saveStatus = "loaded", "saved"
                self.lastMessage = "已加载每日结算存档"
            else ok, data = false, restoreOk and err or player end
        end
        if ok and data == nil then
            self.loadStatus = "empty"
            self.lastMessage = "没有云存档，可开始新周目。"
            emit(self, "load", {
                kind = "operation", result = "empty", reason = "no_saved_data", id = request.id,
            })
        elseif not ok then
            self.loadStatus = "error"
            self.lastMessage = "云存档读档失败，当前状态保留；可重试读取或明确开始新周目。"
            emit(self, "load", {
                kind = "failure", result = "failed", reason = "backend_failure",
                reason_type = type(data), id = request.id,
            })
        else
            emit(self, "load", { kind = "operation", result = "loaded", id = request.id })
        end
        if done then done(ok, data) end
    end
    emit(self, "load", {
        kind = "operation", result = retrying and "retry_started" or "started", id = request.id,
    })
    local ok, accepted, err = Diagnostics.Call("Loop", "load_call", function()
        return self.store:Load(loaded)
    end)
    if not ok then loaded(false, accepted) elseif accepted == false then loaded(false, err) end
    return true
end

function Loop:NewRun()
    emit(self, "new_run_preparation", { kind = "operation", result = "started" })
    local function reject(reason)
        emit(self, "new_run_preparation", {
            kind = "rejected", result = "rejected", reason = reason,
        })
        return false, reason
    end
    if self.closed then return reject("scene_closed") end
    if self:HasPendingCatch() then return reject("pending_catch_required") end
    if self.busy or self.loading or self.initialSaveBusy or self.dropInFlight or self.forcedReturnPending or self.settlementPending then
        return reject("busy")
    end
    if self.actions then
        local cancelled, reason = self.actions:CancelActiveFishing("reset_interrupted")
        if not cancelled then return reject(reason or "busy") end
    end
    if self.barrel then
        local cancelled, reason = self.barrel:Cancel("reset_interrupted")
        if not cancelled then return reject(reason or "busy") end
    end
    self:CloseStoryDialog()
    self:CancelThrowSelection()
    if not self:Ready() and not self.entryPending then return reject("busy") end
    local prepared, prepareReason = self:PreparePort("new_run")
    if not prepared then
        emit(self, "new_run_preparation", {
            kind = "failure", result = "failed", reason = prepareReason or "port_preparation_failed",
        })
        return false, prepareReason
    end
    local resetOk, resetReason = self:ResetState()
    if not resetOk then
        emit(self, "new_run_preparation", { kind = "failure", result = "failed", reason = resetReason })
        return false, resetReason
    end
    if self.options.resetDynamicWorld then
        local ok, accepted = Diagnostics.Call(
            "Loop", "new_run_world_prepare", self.options.resetDynamicWorld)
        if not ok or accepted == false then
            self:BeginEntry()
            self.lastMessage = "新周目港口准备未能完成，请重试开始新周目。"
            emit(self, "new_run_preparation", {
                kind = "failure", result = "failed",
                reason = ok and "new_day_preparation_rejected" or "new_day_preparation_failed",
            })
            return false, "new_day_preparation_failed"
        end
    end
    emit(self, "new_run_preparation", { kind = "operation", result = "prepared" })
    -- Replace the old cloud snapshot before gameplay starts so another process
    -- cannot restore the previous run after this run has begun.
    self:BeginEntry()
    self.lastMessage = "正在保存新周目初始状态…"
    return self:SaveInitialState()
end

function Loop:CanStartAction(action)
    if self.throwSelection then return false, "throw_selection_pending" end
    if self:HasPendingCatch() then return false, "pending_catch_required" end
    if not self:Ready() or self.inPort or self.clock:IsPaused() then return false, "action_blocked" end
    local cost = action == "fishing" and Config.stamina.fishingCost
        or action == "salvage" and Config.stamina.salvageCost
    if not cost then return false, "unknown_action" end
    return self.player:CanConsumeStamina(cost)
end

function Loop:CompleteAction(action)
    if action == "fishing" and self.actions then return false, "fishing_requires_bridge_token" end
    local ok, err = self:CanStartAction(action)
    if not ok then return false, err end
    local cost = action == "fishing" and Config.stamina.fishingCost or Config.stamina.salvageCost
    return self.player:ConsumeStamina(cost)
end

function Loop:UseItem(index)
    if not self:CanManageInventory() then return false, "busy" end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition then return false, "invalid_item" end
    if not definition.heal or definition.heal <= 0 then return false, "item_has_no_use" end
    self.dropInFlight = true
    local removed, previous, stamina = self:RemoveCargo(index)
    if not removed then self.dropInFlight = false; return false, previous end
    local restoredCall, restored = Diagnostics.Call(
        "Loop", "item_restore_stamina", self.player.RestoreStamina, self.player, definition.heal)
    self.dropInFlight = false
    if not restoredCall or restored ~= true then return self:RollbackInventory(previous, stamina, "inventory_use_failed") end
    self.lastMessage = "使用了" .. definition.name
    self:CancelThrowSelection()
    return true
end

function Loop:DropItem(index)
    if not self:CanManageInventory() or self.inPort then return false, "sea_required" end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition then return false, "invalid_item" end
    if not self.options.dropReceiver then return false, "drop_receiver_unavailable" end
    local payload = { itemId = id, category = definition.category,
        worldEffect = definition.worldEffect, lifetimeSec = definition.lifetimeSec }
    self.dropInFlight = true
    local removed, previous, stamina = self:RemoveCargo(index)
    if not removed then self.dropInFlight = false; return false, previous end
    -- receiver 必须同步确认交接成功（true）。没有世界坐标的 B 不自行创建对象。
    local ok, accepted = Diagnostics.Call("Loop", "drop_receiver", self.options.dropReceiver, payload)
    self.dropInFlight = false
    if not ok or accepted ~= true then return self:RollbackInventory(previous, stamina, "drop_rejected") end
    self.lastMessage = "已交接投放请求：" .. definition.name
    self:CancelThrowSelection()
    return true, payload
end

function Loop:GiveToElder(index)
    local present, presenceReason = self:IsElderPresent()
    if not present then return false, presenceReason or "elder_not_present" end
    if self:HasPendingCatch() and not self.elderOpen then return false, "elder_dialog_required" end
    if not self:CanManageInventory() or not self.elderOpen then return false, "elder_dialog_required" end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition or not definition.canGive then return false, "invalid_item" end
    if definition.category ~= "food" then
        self.lastMessage = "向老人展示了" .. definition.name .. "，物品仍保留，没有额外奖励。"
        return true, self.lastMessage
    end
    self.dropInFlight = true
    local removed, previous, stamina = self:RemoveCargo(index)
    if not removed then self.dropInFlight = false; return false, previous end
    local ok, accepted, message = true, true, "老人收下了" .. definition.name
    if self.options.elderReceiver then
        ok, accepted, message = Diagnostics.Call("Loop", "elder_receiver", self.options.elderReceiver, id)
    end
    self.dropInFlight = false
    if not ok or accepted ~= true then return self:RollbackInventory(previous, stamina, "elder_rejected") end
    if id == "apple" and self.player.day <= 3 then
        local record = self.player.elder.circle1B2
        local priorCount = record.applesGiven
        local countOk, counted = Diagnostics.Call("Loop", "elder_record_apple", Progress.RecordApple, self.player)
        if not countOk or counted ~= true then
            record.applesGiven = priorCount
            return self:RollbackInventory(previous, stamina, "elder_progress_failed")
        end
    end
    self.player.elder.lastGivenItemId = id
    self.lastMessage = message or "老人收下了物品。"
    self:CancelThrowSelection()
    return true, self.lastMessage
end

function Loop:PortTransaction(action)
    if not self:Ready() or not self.inPort then return false, "port_required" end
    local near, reason = self:CanAccessPort()
    if not near then return false, reason end
    local readOk, before = Diagnostics.Call("Loop", "port_transaction_snapshot", function()
        local stock = {}
        for key, value in pairs(self.shopStock) do stock[key] = value end
        return { items = self.player.inventory:GetItems(), level = self.player.inventory:GetLevel(),
            stamina = self.player.stamina, maxStamina = self.player.maxStamina,
            money = self.player.money, boatSpeedLevel = self.player.boatSpeedLevel, stock = stock }
    end)
    if not readOk then return false, "transaction_snapshot_failed" end
    self.dropInFlight = true
    local ok, accepted, actionReason = Diagnostics.Call("Loop", "port_transaction_action", action)
    self.dropInFlight = false
    if not ok or accepted ~= true then
        self.inventoryRollback = { items = before.items, stamina = before.stamina, portSnapshot = before }
        local restored = self:RetryInventoryRollback()
        return false, restored and (ok and actionReason or "transaction_failed") or "inventory_rollback_pending"
    end
    return true
end

function Loop:Buy(itemId)
    return self:PortTransaction(function()
    local definition = Items.GetDefinition(itemId)
    if not definition or not definition.buyPrice then return false, "not_for_sale" end
    if self:GetShopStock(itemId) <= 0 then return false, "shop_sold_out" end
    if self.player.money < definition.buyPrice then return false, "insufficient_money" end
    if not self.player.inventory:HasSpace() then return false, "inventory_full" end
    local ok, err = self.player.inventory:Add(itemId)
    if not ok then return false, err end
    local paid, payReason = self.player:ChangeMoney(-definition.buyPrice)
    if not paid then return false, payReason end
    self.shopStock[itemId] = self.shopStock[itemId] - 1
    self.lastMessage = "已购买" .. definition.name
    return true
    end)
end

function Loop:Sell(index, expectedItemId, expectedRevision)
    if expectedRevision ~= nil and expectedRevision ~= self:GetCargoRevision() then return false, "cargo_changed" end
    local id = self.player.inventory:GetItems()[index]
    if expectedItemId ~= nil and expectedItemId ~= id then return false, "cargo_changed" end
    return self:PortTransaction(function()
    local definition = id and Items.GetDefinition(id)
    if not definition or definition.category ~= "fish" or not definition.sellPrice or definition.sellPrice <= 0 then
        return false, "not_sellable"
    end
    local ok, err = self.player.inventory:Remove(index)
    if not ok then return false, err end
    local paid, payReason = self.player:ChangeMoney(definition.sellPrice)
    if not paid then return false, payReason end
    self.lastMessage = "已出售" .. definition.name
    return true
    end)
end

-- F2: 一键卖出全部渔获（category=fish 且有正售价），原子交易，空手而归拒绝。
function Loop:SellAll()
    return self:PortTransaction(function()
        local items = self.player.inventory:GetItems()
        local total, count = 0, 0
        -- 倒序移除，避免 Remove 造成的索引位移。
        for index = #items, 1, -1 do
            local id = items[index]
            local definition = id and Items.GetDefinition(id)
            if definition and definition.category == "fish"
                and definition.sellPrice and definition.sellPrice > 0 then
                local ok = self.player.inventory:Remove(index)
                if ok then
                    total = total + definition.sellPrice
                    count = count + 1
                end
            end
        end
        if count == 0 then return false, "nothing_to_sell" end
        local paid, payReason = self.player:ChangeMoney(total)
        if not paid then return false, payReason end
        self.lastMessage = string.format("共出售 %d 件渔获，收入 ¥%d", count, total)
        return true
    end)
end

function Loop:UpgradeInventory()
    return self:PortTransaction(function()
    local price = Config.upgrades.inventory.prices[self.player.inventory:GetLevel()]
    if not price then return false, "maximum_level" end
    if self.player.money < price then return false, "insufficient_money" end
    local ok, err = self.player.inventory:Upgrade()
    if not ok then return false, err end
    local paid, payReason = self.player:ChangeMoney(-price)
    if not paid then return false, payReason end
    self.lastMessage = "船舱已扩容"
    return true
    end)
end

function Loop:GetStaminaLevel()
    for level, maximum in ipairs(Config.upgrades.stamina.maxima) do
        if self.player.maxStamina == maximum then return level end
    end
    return nil -- 兼容已有自定义上限，不能猜测对应的购买等级。
end

function Loop:UpgradeStamina()
    return self:PortTransaction(function()
    local level = self:GetStaminaLevel()
    if not level then return false, "unsupported_stamina_level" end
    local price = Config.upgrades.stamina.prices[level]
    if not price then return false, "maximum_level" end
    if self.player.money < price then return false, "insufficient_money" end
    local maximum = Config.upgrades.stamina.maxima[level + 1]
    if not maximum then return false, "invalid_upgrade_configuration" end
    self.player.stamina = math.min(maximum, self.player.stamina + maximum - self.player.maxStamina)
    self.player.maxStamina = maximum
    local paid, payReason = self.player:ChangeMoney(-price)
    if not paid then return false, payReason end
    self.lastMessage = "体力上限已升级"
    return true
    end)
end

function Loop:UpgradeBoatSpeed()
    return self:PortTransaction(function()
    local price = Config.upgrades.boatSpeed.prices[self.player.boatSpeedLevel]
    if not price then return false, "maximum_level" end
    if self.player.money < price then return false, "insufficient_money" end
    self.player.boatSpeedLevel = self.player.boatSpeedLevel + 1
    if self.runtime then
        local speed, applyReason = self.runtime:SetShipLevel(self.player.boatSpeedLevel)
        if speed == false then return false, applyReason or "speed_upgrade_failed" end
        if type(speed) == "number" and speed ~= Config.upgrades.boatSpeed.metersPerSec[self.player.boatSpeedLevel] then
            return false, "speed_upgrade_failed"
        end
    end
    local paid, payReason = self.player:ChangeMoney(-price)
    if not paid then return false, payReason end
    self.lastMessage = "船只航速已升级"
    return true
    end)
end

-- Standalone rule contract; a world-bound loop rejects this direct path in EnableWorldActions.
function Loop:CompleteFishing(catchCount)
    if catchCount ~= 0 and catchCount ~= 1 then return false, "invalid_catch_count" end
    if catchCount == 0 then return self:CanStartAction("fishing") end
    return self:CompleteAction("fishing")
end

function Loop:BeginFishingSelection()
    if not self.actions then return false, "fishing_runtime_interface_unavailable" end
    return self.actions:BeginSelection()
end
function Loop:SetFishingCenter(center)
    if not self.actions then return false, "fishing_runtime_interface_unavailable" end
    return self.actions:SetFishingCenter(center)
end
function Loop:ConfirmFishing()
    if not self.actions then return false, "fishing_runtime_interface_unavailable" end
    return self.actions:ConfirmFishing()
end
function Loop:CancelFishingAction()
    if not self.actions then return true end
    return self.actions:CancelActiveFishing("cancelled")
end
function Loop:GetFishingState()
    return self.actions and self.actions:GetFishingState() or { state = "idle", elapsed = 0, duration = Config.fishing.durationSec }
end
function Loop:HasPendingCatch()
    return (self.actions ~= nil and self.actions:HasPendingCatch())
        or (self.barrel ~= nil and self.barrel:HasPending())
end
function Loop:GetPendingCatch()
    if self.barrel and self.barrel:HasPending() then return self.barrel:GetPending() end
    return self.actions and self.actions:GetPendingCatch() or nil
end
function Loop:ClaimPendingCatch()
    if self.barrel and self.barrel:HasPending() then return self.barrel:Claim() end
    if not self.actions then return false, "no_pending_catch" end
    return self.actions:ClaimPendingCatch()
end
function Loop:IsMovementBlocked()
    return (self.actions ~= nil and self.actions:IsBusy()) or (self.barrel and self.barrel:IsBusy())
        or self.throwSelection ~= nil
end
function Loop:CanManageInventory()
    if self.busy or self.loading or self.dropInFlight or (self.actions and self.actions:IsBusy())
        or (self.barrel and self.barrel:IsBusy()) or self.storyDialog then return false end
    if self.inventoryRollback then return false end
    if self.actions and self.actions:IsClaimBlocked() then return false end
    if self.barrel and not self.barrel:CanEditCargo() then return false end
    return self:Ready() or self:HasPendingCatch()
end

-- 事件发现/判断不扣体力；仅明确选择且完成实际操作时调用付费接口。
function Loop:CanStartEventOperation()
    if not self:Ready() or self.inPort or self.inventoryOpen or self.elderOpen
        or self.clock.exhausted then return false, "action_blocked" end
    for reason in pairs(self.clock.pauseReasons) do
        if reason ~= "special_event" then return false, "action_blocked" end
    end
    return self.player:CanConsumeStamina(Config.stamina.eventOperationCost)
end

function Loop:CompleteEventOperation()
    local ok, err = self:CanStartEventOperation()
    if not ok then return false, err end
    return self.player:ConsumeStamina(Config.stamina.eventOperationCost)
end

function Loop:BindRuntime(runtime)
    self.runtime = runtime
    self.barrel:BindRuntime(runtime)
end
function Loop:IsElderPresent() return Progress.IsElderPresent(self.player) end
function Loop:GetElderStatus()
    local status = self.player.elder.circle1B2
    return { applesGiven = status.applesGiven, decision = status.decision, present = self:IsElderPresent() }
end
function Loop:GiveTreasureToElder(id)
    local present, reason = self:IsElderPresent()
    if not present then return false, reason or "elder_not_present" end
    if not self.elderOpen then return false, "elder_dialog_required" end
    if not self:CanManageInventory() then return false, "busy" end
    if id ~= "scopeLens" or not self:HasLens() then return false, "treasure_unavailable" end
    self.lastMessage = "向老人展示了透镜，宝物仍保留，没有额外奖励。"
    return true, self.lastMessage
end
function Loop:BeginBarrelInspection() return self.barrel:Begin() end
function Loop:CancelBarrelInspection() return self.barrel:Cancel("cancelled") end
function Loop:GetBarrelState() return self.barrel:GetState() end
function Loop:HasLens() return Progress.HasLens(self.player) end
function Loop:IsScopeEnabled() return self:HasLens() and self.scopeEnabled == true end
function Loop:DisableScope()
    self.scopeEnabled = false
    return self:SyncScope()
end
function Loop:SyncScope()
    local function finish(ok, reason)
        self.scopeSyncError = reason
        return ok, reason
    end
    if not self:HasLens() then self.scopeEnabled = false end
    local runtime = self.runtime
    if not runtime or type(runtime.SetScopeEnabled) ~= "function" or type(runtime.IsScopeEnabled) ~= "function" then
        return finish(false, "scope_interface_unavailable")
    end
    local readOk, enabled = pcall(runtime.IsScopeEnabled, runtime)
    if not readOk then return finish(false, "scope_sync_failed") end
    if enabled ~= self.scopeEnabled then
        local setOk = pcall(runtime.SetScopeEnabled, runtime, self.scopeEnabled)
        if not setOk then return finish(false, "scope_sync_failed") end
    end
    local verifyOk, observed = pcall(runtime.IsScopeEnabled, runtime)
    if not verifyOk or observed ~= self.scopeEnabled then return finish(false, "scope_sync_failed") end
    return finish(true)
end
function Loop:ToggleScope()
    if not self:HasLens() then return false, "scope_not_owned" end
    local before = self.scopeEnabled
    self.scopeEnabled = not before
    local ok, reason = self:SyncScope()
    if not ok then self.scopeEnabled = before; self:SyncScope(); return false, reason end
    return true
end
function Loop:BeginThrowItem(index)
    if not self:CanManageInventory() or self.inPort then return false, "sea_required" end
    local item = self.player.inventory:GetItems()[index]
    local definition = item and Items.GetDefinition(item)
    if not definition or definition.category == "treasure" then return false, "invalid_item" end
    self.throwSelection = { index = index, itemId = item }
    if self.actions then self.actions:SetDropTarget(nil) end
    if self.runtime and type(self.runtime.ClearMovementTarget) == "function" then self.runtime:ClearMovementTarget() end
    self:SetMessage("已选择" .. definition.name .. "，请点击12米内海面投掷；也可以取消。")
    return true
end
function Loop:GetThrowSelection()
    local selected = self.throwSelection
    return selected and { index = selected.index, itemId = selected.itemId } or nil
end
function Loop:CancelThrowSelection() self.throwSelection = nil; return true end
function Loop:OpenDay7PaperBeforeEnding()
    if self.player.day ~= 7 then return false, "paper_day_required" end
    if Progress.IsPaperShown(self.player) then return false, "paper_already_shown" end
    if self.storyDialog then return true end
    local bucketOnlyBusy = self.barrel and self.barrel:IsBusy()
        and not self.closed and not self.entryPending and not self.busy and not self.loading
        and not self.initialSaveBusy and not self.dropInFlight and not self.inventoryRollback
        and not self.forcedReturnPending and not self.settlementPending
        and not (self.actions and self.actions:IsBusy())
    if (not self:Ready() and not bucketOnlyBusy) or self:HasPendingCatch() or self:GetThrowSelection() then
        return false, "busy"
    end
    self.storyDialog = { token = {}, kind = "paper",
        text = "海岸边那只木桶，下面一定有什么东西，我想多打捞几次就能打捞上来吧。" }
    self.clock:Pause("story")
    return true
end
function Loop:GetStoryDialog()
    local dialog = self.storyDialog
    return dialog and { token = dialog.token, kind = dialog.kind, text = dialog.text } or nil
end
function Loop:NotifyStoryShown(token)
    if not self.storyDialog or token ~= self.storyDialog.token then return false, "stale_story_dialog" end
    return Progress.MarkPaperShown(self.player)
end
function Loop:CloseStoryDialog()
    self.storyDialog = nil
    self.clock:Resume("story")
    return true
end

function Loop:InspectEvent(kind)
    if not self:Ready() then return false, "busy" end
    if kind ~= "observation" and kind ~= "discovery" and kind ~= "dialogue"
        and kind ~= "information" and kind ~= "elder_dialogue" then
        return false, "unknown_event_interaction"
    end
    return true -- 免费交互不改玩家状态，不创建事件或奖励。
end

return Loop
