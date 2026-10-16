-- Owns barrel receipts, cargo escrow, and game-time progress. Ocean owns the fixed barrel entity.
local Config = require("config.gameplay")
local Progress = require("Gameplay.Circle1B2Progress")
---@class Circle1B2BarrelRecord
---@field token table
---@field runtime table
---@field id string|number
---@field generation string|number
---@field loopGeneration number
---@field stage integer
---@field state string
---@field elapsed number
---@field result table?
---@field cancel (fun())?
---@field reason string?
---@field rollback {items:string[],stamina:number,stage:integer,lens:boolean}?

---@class Circle1B2BarrelPending
---@field items string[]
---@field record Circle1B2BarrelRecord
---@field claiming boolean?
---@field rollbackItems string[]?

---@class Circle1B2Barrel
---@field loop GameplayLoop
---@field runtime table?
---@field receipts table<table,Circle1B2BarrelRecord>
---@field active Circle1B2BarrelRecord?
---@field pending Circle1B2BarrelPending?
local Barrel = {}
Barrel.__index = Barrel

local function copy(values)
    local result = {}
    for index, value in ipairs(values) do result[index] = value end
    return result
end
local function query(runtime)
    if not runtime or type(runtime.GetFixedBarrel) ~= "function"
        or type(runtime.CanInteractWithBarrel) ~= "function" then return nil, "barrel_interface_unavailable" end
    local ok, target = pcall(runtime.GetFixedBarrel, runtime)
    if not ok or type(target) ~= "table" or target.contentId ~= "driftwood_barrel"
        or target.id == nil or target.generation == nil then return nil, "barrel_unavailable" end
    return target
end

---@param loop GameplayLoop
---@return Circle1B2Barrel
function Barrel.New(loop)
    return setmetatable({ loop = loop, receipts = setmetatable({}, { __mode = "k" }) }, Barrel)
end
function Barrel:BindRuntime(runtime) self.runtime = runtime end
function Barrel:IsBusy() return self.active ~= nil end
function Barrel:HasPending() return self.pending ~= nil end
function Barrel:CanEditCargo()
    return not self.active and not (self.pending and (self.pending.claiming or self.pending.rollbackItems))
end
function Barrel:GetPending()
    if not self.pending then return nil end
    return { itemIds = copy(self.pending.items), requiredSlots = #self.pending.items, source = "barrel" }
end
function Barrel:GetState()
    return { stage = Progress.GetBarrelStage(self.loop.player), active = self.active ~= nil,
        elapsed = self.active and self.active.elapsed or 0, duration = Config.barrel.durationSec,
        remaining = self.active and math.max(0, Config.barrel.durationSec - self.active.elapsed) or 0,
        pending = self.pending ~= nil, timingAvailable = true,
        interfaceAvailable = self.runtime ~= nil and type(self.runtime.GetFixedBarrel) == "function"
            and type(self.runtime.CanInteractWithBarrel) == "function" }
end
---@param record Circle1B2BarrelRecord
function Barrel:Valid(record)
    if record.loopGeneration ~= self.loop.generation then return false, "stale_barrel_action" end
    local target, reason = query(record.runtime)
    if not target then return false, reason end
    if target.id ~= record.id or target.generation ~= record.generation then return false, "stale_barrel_action" end
    local ok, allowed, why = pcall(record.runtime.CanInteractWithBarrel, record.runtime, record.id, record.generation)
    if not ok or allowed ~= true then return false, why or "barrel_out_of_range" end
    if Progress.GetBarrelStage(self.loop.player) ~= record.stage then return false, "stale_barrel_stage" end
    return true
end
function Barrel:Cancel(reason)
    local record = self.active
    if not record then return true end
    if record.rollback then return self:RetryRollback() end
    -- Close the receipt before cancellation callbacks, so a late completion cannot grant.
    record.state, record.result = "cancelled", table.pack(false, reason or "cancelled")
    self.active = nil
    if record.cancel then
        local ok = pcall(record.cancel)
        if not ok then return false, "barrel_cancel_failed" end
    end
    return true
end
function Barrel:Reset()
    if self.pending then return false, "pending_catch_required" end
    local ok, reason = self:Cancel("reset_interrupted")
    if not ok then return false, reason end
    self.receipts = setmetatable({}, { __mode = "k" })
    return true
end
function Barrel:RetryRollback()
    local record = self.active
    if not record or not record.rollback then return true end
    local prior = record.rollback
    local ok, restored = pcall(function()
        local accepted = self.loop:RestoreActionResources(prior.items, prior.stamina)
        if accepted ~= true then return false end
        self.loop.player.treasures.scopeLens = prior.lens
        return Progress.SetBarrelStage(self.loop.player, prior.stage) == true
    end)
    if not ok or restored ~= true then return false, "barrel_rollback_pending" end
    record.rollback = nil
    record.state, record.result = "failed", table.pack(false, record.reason)
    self.active = nil
    return true
end
function Barrel:Tick()
    if self.pending and self.pending.rollbackItems then self:RetryPendingRollback() end
    if not self.active then return end
    if self.active.rollback then self:RetryRollback(); return end
    local valid, reason = self:Valid(self.active)
    if not valid or self.loop.clock.exhausted then self:Cancel(reason or "night_interrupted") end
end
function Barrel:SecondsToBoundary()
    local record = self.active
    if not record or record.rollback then return math.huge end
    return math.max(0, Config.barrel.durationSec - record.elapsed)
end
function Barrel:Advance(gameSeconds)
    local record = self.active
    if not record or record.rollback then return false end
    if gameSeconds > 0 then record.elapsed = math.min(Config.barrel.durationSec, record.elapsed + gameSeconds) end
    if record.elapsed + 1e-9 < Config.barrel.durationSec then return false end
    -- Normalize the authoritative clock boundary before making completion evidence.
    -- Keep externally supplied executor evidence subject to the existing strict check.
    record.elapsed = Config.barrel.durationSec
    return self:AcceptCompletion(record, { completed = true, durationSec = record.elapsed })
end
function Barrel:RetryPendingRollback()
    local pending = self.pending
    if not pending or not pending.rollbackItems then return true end
    local ok, restored = pcall(self.loop.player.inventory.RestoreItems,
        self.loop.player.inventory, pending.rollbackItems)
    if not ok or restored ~= true then return false, "barrel_rollback_pending" end
    local stageOk, stageRestored = pcall(Progress.SetBarrelStage, self.loop.player, 0)
    if not stageOk or stageRestored ~= true then return false, "barrel_rollback_pending" end
    pending.rollbackItems = nil
    return true
end
function Barrel:Begin()
    if self.pending or self.loop:HasPendingCatch() then return false, "pending_catch_required" end
    if self.loop:GetThrowSelection() then return false, "throw_selection_pending" end
    if not self.loop:Ready() or self.loop.inPort or self.loop.clock:IsPaused() then return false, "action_blocked" end
    local stage, stageReason = Progress.GetBarrelStage(self.loop.player)
    if stage == nil then return false, stageReason end
    if stage >= 3 then return false, "barrel_finished" end
    local enough, reason = self.loop.player:CanConsumeStamina(Config.barrel.cost)
    if not enough then return false, reason end
    local target, why = query(self.runtime)
    if not target then return false, why end
    -- The optional executor is a deterministic test seam. Production actions use
    -- Loop:Update and the authoritative game clock for their full duration.
    local executor = self.loop.options.barrelActionExecutor
    local token = {}
    ---@type Circle1B2BarrelRecord
    local record = { token = token, runtime = assert(self.runtime), id = target.id, generation = target.generation,
        loopGeneration = self.loop.generation, stage = stage, state = "waiting", elapsed = 0 }
    local valid, invalidReason = self:Valid(record)
    if not valid then return false, invalidReason end
    self.active, self.receipts[token] = record, record
    if type(executor) ~= "function" then return token end
    local ok, cancel = pcall(executor, { id = record.id, generation = record.generation,
        stage = record.stage, durationSec = Config.barrel.durationSec }, function(evidence)
        return self:AcceptCompletion(record, evidence)
    end)
    -- A synchronous completion already closed this receipt; an executor error
    -- after that point must not misreport a committed receipt as a free failure.
    if record.result then
        if record.result[1] == true then return token end
        return false, record.result[2]
    end
    if not ok or cancel == false then self:Cancel("barrel_executor_failed"); return false, "barrel_executor_failed" end
    if type(cancel) == "function" then record.cancel = cancel end
    return token
end
---@param record Circle1B2BarrelRecord
---@param evidence table?
function Barrel:AcceptCompletion(record, evidence)
    if record.result then return table.unpack(record.result, 1, record.result.n) end
    if self.active ~= record or record.state ~= "waiting" then return false, "stale_barrel_action" end
    if type(evidence) ~= "table" or evidence.completed ~= true or type(evidence.durationSec) ~= "number"
        or evidence.durationSec ~= evidence.durationSec or evidence.durationSec == math.huge
        or evidence.durationSec < Config.barrel.durationSec then return false, "barrel_action_not_completed" end
    local valid, reason = self:Valid(record)
    if not valid then self:Cancel(reason); return false, reason end
    if self.loop.clock.exhausted and record.elapsed + 1e-9 < Config.barrel.durationSec then
        self:Cancel("night_interrupted")
        return false, "night_interrupted"
    end
    local inventory = self.loop.player.inventory
    local readOk, priorItems, space = pcall(function()
        return inventory:GetItems(), inventory:HasSpace(#Config.barrel.firstReward)
    end)
    if not readOk then self:Cancel("inventory_snapshot_failed"); return false, "inventory_snapshot_failed" end
    record.rollback = { items = priorItems, stamina = self.loop.player.stamina,
        stage = record.stage, lens = Progress.HasLens(self.loop.player) }
    record.state = "committing"
    local ok, accepted = pcall(function()
        if self.loop.player:ConsumeStamina(Config.barrel.cost) ~= true then return false end
        if record.stage == 0 then
            if space then
                for _, id in ipairs(Config.barrel.firstReward) do if inventory:Add(id) ~= true then return false end end
                if Progress.SetBarrelStage(self.loop.player, 1) ~= true then return false end
            end
        elseif record.stage == 1 then
            if Progress.SetBarrelStage(self.loop.player, 2) ~= true then return false end
        else
            if Progress.GrantLens(self.loop.player) ~= true then return false end
            if Progress.SetBarrelStage(self.loop.player, 3) ~= true then return false end
        end
        return true
    end)
    if not ok or accepted ~= true then
        record.reason, record.state = "barrel_commit_failed", "rollback_pending"
        self:RetryRollback()
        return false, "barrel_commit_failed"
    end
    record.rollback = nil
    record.state = "complete"
    self.active = nil
    if record.stage == 0 and not space then
        self.pending = { items = copy(Config.barrel.firstReward), record = record }
        record.result = table.pack(true, "pending_reward")
        pcall(self.loop.SetInventoryOpen, self.loop, true)
        pcall(self.loop.SetMessage, self.loop, "木桶补给已保留，请腾出两格后同时领取苹果和鱼饵。")
    else
        record.result = table.pack(true, record.stage == 1 and "empty" or "rewarded")
        pcall(self.loop.SetMessage, self.loop, record.stage == 1 and "什么都没有捕捞到"
            or (record.stage == 0 and "取得1个苹果和1个鱼饵。" or "已取得透镜。"))
    end
    return table.unpack(record.result, 1, record.result.n)
end
function Barrel:Claim()
    local pending = self.pending
    if not pending then return false, "no_pending_catch" end
    if pending.claiming or self.loop.inventoryRollback or self.loop.dropInFlight or self.loop.busy or self.loop.loading then return false, "busy" end
    local inventory = self.loop.player.inventory
    if pending.rollbackItems then
        local restored, restoreReason = self:RetryPendingRollback()
        if not restored then return false, restoreReason end
    end
    local ok, before, space = pcall(function() return inventory:GetItems(), inventory:HasSpace(#pending.items) end)
    if not ok then return false, "inventory_snapshot_failed" end
    if not space then return false, "inventory_full" end
    pending.claiming = true
    local accepted, committed = pcall(function()
        for _, id in ipairs(pending.items) do if inventory:Add(id) ~= true then return false end end
        return Progress.SetBarrelStage(self.loop.player, 1) == true
    end)
    pending.claiming = false
    if not accepted or committed ~= true then
        pending.rollbackItems = before
        local restoredCall, restored = pcall(inventory.RestoreItems, inventory, before)
        local stageOk, stageRestored = pcall(Progress.SetBarrelStage, self.loop.player, 0)
        if not restoredCall or restored ~= true or not stageOk or stageRestored ~= true then
            return false, "barrel_rollback_pending"
        end
        pending.rollbackItems = nil
        return false, "inventory_add_failed"
    end
    self.pending = nil
    pcall(self.loop.SetMessage, self.loop, "已同时领取木桶补给，不再扣体力。")
    return true
end
return Barrel
