-- 玩家运行时基础状态；序列化由上层持久化模块负责。
local GameConfig = require "config.gameplay"
local Inventory = require "Gameplay.Inventory"
local Progress = require "Gameplay.Circle1B2Progress"

---@class PlayerState
---@field stamina number
---@field maxStamina number
---@field money number
---@field day integer
---@field boatSpeedLevel integer
---@field inventory Inventory
---@field recognizedLocations table<string, boolean>
---@field treasures table
---@field story table
---@field elder table
local PlayerState = {}
PlayerState.__index = PlayerState

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

---创建玩家状态并载入配置中的初始值。
---@return PlayerState|nil, string|nil
function PlayerState.New()
    local self = setmetatable({}, PlayerState)
    local ok, reason = self:init()
    if not ok then
        return nil, reason
    end
    return self
end

---@return boolean, string|nil
function PlayerState:init()
    local initial = GameConfig.initial
    if not IsFiniteNumber(initial.maxStamina)
        or initial.maxStamina <= 0
        or not IsFiniteNumber(initial.stamina)
        or initial.stamina < 0
        or initial.stamina > initial.maxStamina
        or not IsFiniteNumber(initial.money)
        or initial.money < 0
        or initial.money % 1 ~= 0
        or not IsFiniteNumber(initial.day)
        or initial.day < 1
        or initial.day % 1 ~= 0
    then
        return false, "invalid initial player configuration"
    end

    local inventory, inventoryError = Inventory.New(1, initial.items)
    if not inventory then
        return false, inventoryError
    end

    self.stamina = initial.stamina
    self.maxStamina = initial.maxStamina
    self.money = initial.money
    self.day = initial.day
    self.boatSpeedLevel = 1
    self.inventory = inventory
    self.recognizedLocations = {}
    self.treasures = {}
    self.story = {}
    self.elder = {}
    return Progress.Initialize(self)
end

---@param cost number
---@return boolean, string|nil
function PlayerState:CanConsumeStamina(cost)
    if not IsFiniteNumber(cost) or cost < 0 then
        return false, "cost must be a finite non-negative number"
    end
    if cost > self.stamina then
        return false, "insufficient stamina"
    end
    return true
end

---@param cost number
---@return boolean, string|nil
function PlayerState:ConsumeStamina(cost)
    local canConsume, reason = self:CanConsumeStamina(cost)
    if not canConsume then
        return false, reason
    end

    self.stamina = self.stamina - cost
    return true
end

---@param amount number
---@return boolean, string|nil
function PlayerState:RestoreStamina(amount)
    if not IsFiniteNumber(amount) or amount < 0 then
        return false, "amount must be a finite non-negative number"
    end

    local missing = self.maxStamina - self.stamina
    if amount >= missing then
        self.stamina = self.maxStamina
    else
        self.stamina = self.stamina + amount
    end
    return true
end

---@param delta number
---@return boolean, string|nil
function PlayerState:ChangeMoney(delta)
    if not IsFiniteNumber(delta) or delta % 1 ~= 0 then
        return false, "delta must be a finite integer"
    end

    local newBalance = self.money + delta
    if not IsFiniteNumber(newBalance) then
        return false, "money change is outside the supported range"
    end
    if newBalance < 0 then
        return false, "insufficient money"
    end

    self.money = newBalance
    return true
end

---@param locationId string
---@return boolean, string|nil
function PlayerState:IsRecognized(locationId)
    if type(locationId) ~= "string" or locationId == "" then
        return false, "location id must be a non-empty string"
    end
    return self.recognizedLocations[locationId] == true
end

---@param locationId string
---@return boolean, string|nil
function PlayerState:MarkRecognized(locationId)
    if type(locationId) ~= "string" or locationId == "" then
        return false, "location id must be a non-empty string"
    end
    self.recognizedLocations[locationId] = true
    return true
end

---恢复配置中的初始玩家状态。
---@return boolean, string|nil
function PlayerState:Reset()
    return self:init()
end

return PlayerState
