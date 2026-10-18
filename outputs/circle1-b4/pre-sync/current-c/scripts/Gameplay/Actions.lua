-- Owns transient player actions; all sea state changes go through Runtime public APIs.
local Items = require("data.items")
---@class GameplayActionPoint
---@field x number
---@field y number

---@class GameplayFishingToken

---@class GameplayFishingRecord
---@field token GameplayFishingToken
---@field targetId string|nil
---@field generation number
---@field seaGeneration number
---@field state string
---@field result table|nil

---@class GameplayActions
---@field loop GameplayLoop
---@field dropTarget GameplayActionPoint?
---@field _fishingTokens table<GameplayFishingToken, GameplayFishingRecord>
---@field _pendingFishing GameplayFishingRecord?
---@field _completeLoopFishing fun(loop:GameplayLoop, catchCount:integer): boolean, string?
local Actions = {}
Actions.__index = Actions

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

function Actions.New(loop)
    local self = setmetatable({ loop = loop, _completeLoopFishing = loop.CompleteFishing }, Actions)
    self:Reset(true)
    return self
end

function Actions:Reset(clearDropTarget)
    self._fishingTokens = {}
    self._pendingFishing = nil
    if clearDropTarget then self.dropTarget = nil end
end

function Actions:SetDropTarget(position)
    self.dropTarget = position and copyPoint(position) or nil
end

function Actions:GetDropTarget()
    return self.dropTarget and copyPoint(self.dropTarget) or nil
end

---Begin a one-fish fishing transaction. A valid empty cast still gets a token.
---@param center any
---@return GameplayFishingToken|nil, string|nil
function Actions:BeginFishing(center, runtime)
    if self._pendingFishing and self._pendingFishing.seaGeneration ~= runtime:GetFishingGeneration() then
        self:Reset(true)
    end
    if self._pendingFishing then return nil, "fishing_already_pending" end
    local canStart, actionError = self.loop:CanStartAction("fishing")
    if not canStart then return nil, actionError end
    local hasSpace, inventoryError = self.loop.player.inventory:HasSpace(1)
    if not hasSpace then return nil, inventoryError or "inventory_full" end
    if not isPoint(center) then return nil, "invalid_cast_position" end

    local selected, target, selectionError = pcall(
        runtime.selectFishingTarget, runtime, center)
    if not selected then return nil, "fishing_selection_failed" end
    if not target and selectionError then return nil, selectionError end
    if target then
        local definition = Items.GetDefinition(target.species)
        if not definition or definition.category ~= "fish" then
            return nil, "unsupported_fish_item"
        end
    end

    ---@type GameplayFishingToken
    local token = {}
    ---@type GameplayFishingRecord
    local record = {
        token = token,
        targetId = target and target.id or nil,
        generation = self.loop.generation,
        seaGeneration = runtime:GetFishingGeneration(),
        state = "pending",
        result = nil,
    }
    self._fishingTokens[token] = record
    self._pendingFishing = record
    return token
end

---Complete the token's internally selected 0/1 outcome exactly once.
---@param token GameplayFishingToken
---@return boolean, string, string?
function Actions:CompleteFishing(runtime, token, ...)
    if select("#", ...) ~= 0 then return false, "unexpected_argument" end
    local record = self._fishingTokens[token]
    if not record then return false, "stale_fishing_token" end
    if record.state == "complete" then
        return table.unpack(record.result, 1, record.result.n)
    end
    if record.seaGeneration ~= runtime:GetFishingGeneration() then
        record.state = "expired"
        if self._pendingFishing == record then self._pendingFishing = nil end
        return false, "stale_fishing_token"
    end
    if record.state ~= "pending" or self._pendingFishing ~= record
        or record.generation ~= self.loop.generation then
        return false, "stale_fishing_token"
    end

    local canStart, actionError = self.loop:CanStartAction("fishing")
    if not canStart then return false, actionError end
    local inventory = self.loop.player.inventory
    local hasSpace, inventoryError = inventory:HasSpace(1)
    if not hasSpace then return false, inventoryError or "inventory_full" end

    local target = record.targetId and runtime:GetFishingTarget(record.targetId) or nil
    local itemId
    if record.targetId then
        if not target or target.removed then
            record.state = "expired"
            self._pendingFishing = nil
            return false, "fishing_target_expired"
        end
        local definition = Items.GetDefinition(target.species)
        if not definition or definition.category ~= "fish" then
            record.state = "expired"
            self._pendingFishing = nil
            return false, "unsupported_fish_item"
        end
        itemId = definition.id
    end

    record.state = "committing"
    local oldStamina = self.loop.player.stamina
    local previousItems = inventory:GetItems()
    local fishSnapshot = target and runtime:SnapshotFishingTarget(target) or nil
    local charged, chargeResult, chargeError = pcall(
        self._completeLoopFishing, self.loop, target and 1 or 0)
    if not charged or chargeResult ~= true then
        self.loop:RestoreActionResources(nil, oldStamina)
        record.state = "pending"
        return false, charged and (chargeError or "fishing_charge_rejected") or "fishing_charge_failed"
    end

    if target then
        local addCallOk, addOk, addError = pcall(inventory.Add, inventory, itemId)
        if not addCallOk or addOk ~= true then
            self.loop:RestoreActionResources(previousItems, oldStamina)
            record.state = "pending"
            return false, addCallOk and (addError or "inventory_add_rejected") or "inventory_add_failed"
        end

        local removeCallOk, removed = pcall(runtime.RemoveFishingTarget, runtime, target.id)
        if not removeCallOk or removed ~= true then
            self.loop:RestoreActionResources(previousItems, oldStamina)
            runtime:RestoreFishingTarget(target, fishSnapshot)
            record.state = "pending"
            return false, "world_remove_failed"
        end
        runtime:ForgetFishingBehavior(target.id)
    end

    record.state = "complete"
    self._pendingFishing = nil
    if target then
        record.result = table.pack(true, "caught", itemId)
    else
        record.result = table.pack(true, "empty")
    end
    return table.unpack(record.result, 1, record.result.n)
end

---@param token GameplayFishingToken
---@return boolean, string?
function Actions:CancelFishing(token)
    local record = self._fishingTokens[token]
    if not record or record.state ~= "pending" or self._pendingFishing ~= record then
        return false, "stale_fishing_token"
    end
    record.state = "cancelled"
    self._pendingFishing = nil
    return true
end

return Actions
