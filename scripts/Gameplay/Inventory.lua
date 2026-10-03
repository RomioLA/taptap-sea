-- 非堆叠背包：每个格子保存一个物品 ID。
local GameConfig = require "config.gameplay"
local Items = require "data.items"

---@class Inventory
---@field _level integer
---@field _items string[]
---@field _revision integer
local Inventory = {}
Inventory.__index = Inventory

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function IsInteger(value)
    return IsFiniteNumber(value) and value % 1 == 0
end

local function IsPositiveInteger(value)
    return IsInteger(value) and value >= 1
end

---@param itemIds table
---@return string[]|nil, string|nil
local function CopyAndValidateItems(itemIds)
    if type(itemIds) ~= "table" then
        return nil, "items must be an array"
    end

    local count = 0
    local maxIndex = 0
    for key in next, itemIds do
        if not IsPositiveInteger(key) then
            return nil, "items must be a dense array"
        end
        count = count + 1
        if key > maxIndex then
            maxIndex = key
        end
    end
    if count ~= maxIndex then
        return nil, "items must be a dense array"
    end

    local copy = {}
    for index = 1, count do
        local itemId = rawget(itemIds, index)
        if type(itemId) ~= "string" or not Items.GetDefinition(itemId) then
            return nil, "items contains an unknown item id"
        end
        copy[index] = itemId
    end
    return copy
end

---创建背包；默认等级为 1，省略 items 时使用配置中的初始物品。
---@param level number|nil
---@param items string[]|nil
---@return Inventory|nil, string|nil
function Inventory.New(level, items)
    local self = setmetatable({}, Inventory)
    local ok, reason = self:init(level, items)
    if not ok then
        return nil, reason
    end
    return self
end

---@param level number|nil
---@param items string[]|nil
---@return boolean, string|nil
function Inventory:init(level, items)
    local resolvedLevel = level
    if resolvedLevel == nil then
        resolvedLevel = 1
    end

    local capacities = GameConfig.inventory.capacities
    if not IsPositiveInteger(resolvedLevel) or resolvedLevel > #capacities then
        return false, "level is outside the supported range"
    end

    local sourceItems = items
    if sourceItems == nil then
        sourceItems = GameConfig.initial.items
    end
    local copiedItems, itemError = CopyAndValidateItems(sourceItems)
    if not copiedItems then
        return false, itemError
    end

    local integerLevel = math.floor(resolvedLevel)
    local capacity = assert(capacities[integerLevel])
    if #copiedItems > capacity then
        return false, "initial items exceed inventory capacity"
    end

    self._level = integerLevel
    self._items = copiedItems
    self._revision = (self._revision or 0) + 1
    return true
end

---返回独立副本，调用方修改数组不会影响背包。
---@return string[]
function Inventory:GetItems()
    local copy = {}
    for index = 1, #self._items do
        copy[index] = self._items[index]
    end
    return copy
end

-- Runtime-only identity for a rendered cargo action. Never serialized.
function Inventory:GetRevision()
    return self._revision
end

-- Restore a transaction's validated contents and upgrade level together.
function Inventory:RestoreSnapshot(level, items)
    local snapshot, reason = Inventory.New(level, items)
    if not snapshot then return false, reason end
    self._items, self._level = snapshot:GetItems(), snapshot:GetLevel()
    self._revision = self._revision + 1
    return true
end

---Restore an entire validated inventory snapshot, including mutation-then-error rollback.
---@param items string[]
---@return boolean, string?
function Inventory:RestoreItems(items)
    local restored, reason = CopyAndValidateItems(items)
    if not restored then return false, reason end
    if #restored > self:GetCapacity() then return false, "inventory_full" end
    self._items = restored
    self._revision = self._revision + 1
    return true
end

---@return integer
function Inventory:GetLevel()
    return self._level
end

---@return number
function Inventory:GetCapacity()
    local capacity = assert(GameConfig.inventory.capacities[self._level])
    return capacity
end

---@param itemId string
---@return boolean, string|nil
function Inventory:Add(itemId)
    if type(itemId) ~= "string" or not Items.GetDefinition(itemId) then
        return false, "unknown item id"
    end

    local hasSpace, reason = self:HasSpace(1)
    if not hasSpace then
        return false, reason or "inventory is full"
    end

    self._items[#self._items + 1] = itemId
    self._revision = self._revision + 1
    return true
end

---@param index number
---@return boolean, string|nil
function Inventory:Remove(index)
    if not IsPositiveInteger(index) then
        return false, "index must be a positive integer"
    end
    if index > #self._items then
        return false, "index is outside the inventory"
    end

    table.remove(self._items, math.floor(index))
    self._revision = self._revision + 1
    return true
end

---@param count number|nil
---@return boolean, string|nil
function Inventory:HasSpace(count)
    local requested = count
    if requested == nil then
        requested = 1
    end
    if not IsInteger(requested) or requested < 0 then
        return false, "count must be a non-negative integer"
    end

    return #self._items + requested <= self:GetCapacity()
end

---@return boolean, string|nil
function Inventory:Upgrade()
    local maxLevel = #GameConfig.inventory.capacities
    if self._level >= maxLevel then
        return false, "inventory is already at maximum level"
    end

    self._level = self._level + 1
    self._revision = self._revision + 1
    return true
end

return Inventory

