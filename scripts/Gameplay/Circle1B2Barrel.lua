-- Owns barrel receipts, cargo escrow, and game-time progress. Ocean owns the fixed barrel entity.
local Config = require("config.gameplay")
local Progress = require("Gameplay.Circle1B2Progress")
local Diagnostics = require("Gameplay.Diagnostics")
---@class Circle1B2BarrelRecord
---@field token table
---@field runtime table
---@field id string|number
---@field generation string|number
---@field actionId integer
---@field loopGeneration number
---@field stage integer
---@field state string
---@field elapsed number
---@field result table?
---@field cancel (fun())?
---@field reason string?
---@field rollback {items:string[],stamina:number,stage:integer,lens:boolean}?
---@field callbackIgnoredLogged boolean?
---@field rollbackStartedLogged boolean?
---@field rollbackFailureLogged boolean?
---@field rollbackExceptionLogged boolean?

---@class Circle1B2BarrelPending
---@field items string[]
---@field record Circle1B2BarrelRecord
---@field claiming boolean?
---@field rollbackItems string[]?
---@field rollbackRestoreExceptionLogged boolean?
---@field rollbackStageExceptionLogged boolean?

---@class Circle1B2Barrel
---@field loop GameplayLoop
---@field runtime table?
---@field receipts table<table,Circle1B2BarrelRecord>
---@field active Circle1B2BarrelRecord?
---@field pending Circle1B2BarrelPending?
local Barrel = {}
Barrel.__index = Barrel
local nextActionId = 0

local function copy(values)
    local result = {}
    for index, value in ipairs(values) do result[index] = value end
    return result
end
local function emit(eventName, kind, record, extra)
    local fields = { kind = kind }
    if record then
        fields.actionId, fields.id, fields.generation = record.actionId, record.id, record.generation
        fields.loopGeneration, fields.stage = record.loopGeneration, record.stage
    end
    for key, value in pairs(extra or {}) do fields[key] = value end
    Diagnostics.Event("barrel", eventName, fields)
end
local function rejectBegin(reason, stage, target)
    local fields = { reason = reason }
    if stage ~= nil then fields.stage = stage end
    if target then fields.id, fields.generation = target.id, target.generation end
    emit("begin_rejected", "rejected", nil, fields)
    return false, reason
end
local function ignoreCallback(record, reason)
    if record.callbackIgnoredLogged then return end
    record.callbackIgnoredLogged = true
    emit("callback_ignored", "rejected", record, { reason = reason, state = record.state })
end
local function query(runtime, diagnoseFailure)
    if not runtime or type(runtime.GetFixedBarrel) ~= "function"
        or type(runtime.CanInteractWithBarrel) ~= "function" then return nil, "barrel_interface_unavailable" end
    local ok, target
    if diagnoseFailure then
        ok, target = Diagnostics.Call("barrel", "target_query", runtime.GetFixedBarrel, runtime)
    else
        ok, target = pcall(runtime.GetFixedBarrel, runtime)
    end
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
function Barrel:Valid(record, diagnoseFailure)
    if record.loopGeneration ~= self.loop.generation then return false, "stale_barrel_action" end
    local target, reason = query(record.runtime, diagnoseFailure)
    if not target then return false, reason end
    if target.id ~= record.id or target.generation ~= record.generation then return false, "stale_barrel_action" end
    local ok, allowed, why
    if diagnoseFailure then
        ok, allowed, why = Diagnostics.Call("barrel", "target_validation",
            record.runtime.CanInteractWithBarrel, record.runtime, record.id, record.generation)
    else
        ok, allowed, why = pcall(record.runtime.CanInteractWithBarrel, record.runtime, record.id, record.generation)
    end
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
    local failed = reason == "barrel_executor_failed"
    emit(failed and "action_failed" or "cancelled", failed and "failure" or "operation", record,
        { reason = reason or "cancelled", outcome = "cancelled" })
    if record.cancel then
        local ok = Diagnostics.Call("barrel", "cancel_callback", record.cancel)
        if not ok then
            emit("cancel_failed", "failure", record, { reason = "barrel_cancel_failed" })
            return false, "barrel_cancel_failed"
        end
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
    if not record.rollbackStartedLogged then
        record.rollbackStartedLogged = true
        emit("rollback_started", "operation", record, { reason = record.reason })
    end
    local function restore()
        local accepted = self.loop:RestoreActionResources(prior.items, prior.stamina)
        if accepted ~= true then return false end
        self.loop.player.treasures.scopeLens = prior.lens
        return Progress.SetBarrelStage(self.loop.player, prior.stage) == true
    end
    local ok, restored
    if record.rollbackExceptionLogged then
        ok, restored = pcall(restore)
    else
        ok, restored = Diagnostics.Call("barrel", "rollback", restore)
        if not ok then record.rollbackExceptionLogged = true end
    end
    if not ok or restored ~= true then
        if not record.rollbackFailureLogged then
            record.rollbackFailureLogged = true
            emit("rollback_failed", "failure", record, { reason = "barrel_rollback_pending" })
        end
        return false, "barrel_rollback_pending"
    end
    record.rollback = nil
    record.state, record.result = "failed", table.pack(false, record.reason)
    self.active = nil
    emit(record.rollbackFailureLogged and "rollback_recovered" or "rollback_completed", "operation", record,
        { reason = record.reason })
    return true
end
function Barrel:Tick()
    if self.pending and self.pending.rollbackItems then self:RetryPendingRollback() end
    if not self.active then return end
    if self.active.rollback then self:RetryRollback(); return end
    local valid, reason = self:Valid(self.active, true)
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
    local ok, restored
    if pending.rollbackRestoreExceptionLogged then
        ok, restored = pcall(self.loop.player.inventory.RestoreItems,
            self.loop.player.inventory, pending.rollbackItems)
    else
        ok, restored = Diagnostics.Call("barrel", "pending_rollback_restore",
            self.loop.player.inventory.RestoreItems, self.loop.player.inventory, pending.rollbackItems)
        if not ok then pending.rollbackRestoreExceptionLogged = true end
    end
    if not ok or restored ~= true then return false, "barrel_rollback_pending" end
    local stageOk, stageRestored
    if pending.rollbackStageExceptionLogged then
        stageOk, stageRestored = pcall(Progress.SetBarrelStage, self.loop.player, 0)
    else
        stageOk, stageRestored = Diagnostics.Call("barrel", "pending_rollback_stage",
            Progress.SetBarrelStage, self.loop.player, 0)
        if not stageOk then pending.rollbackStageExceptionLogged = true end
    end
    if not stageOk or stageRestored ~= true then return false, "barrel_rollback_pending" end
    pending.rollbackItems = nil
    emit("pending_rollback_recovered", "operation", pending.record, { reason = "barrel_rollback_pending" })
    return true
end
function Barrel:Begin()
    if self.pending or self.loop:HasPendingCatch() then return rejectBegin("pending_catch_required") end
    if self.loop:GetThrowSelection() then return rejectBegin("throw_selection_pending") end
    if not self.loop:Ready() or self.loop.inPort or self.loop.clock:IsPaused() then return rejectBegin("action_blocked") end
    local stage, stageReason = Progress.GetBarrelStage(self.loop.player)
    if stage == nil then return rejectBegin(stageReason, stage) end
    if stage >= 3 then return rejectBegin("barrel_finished", stage) end
    local enough, reason = self.loop.player:CanConsumeStamina(Config.barrel.cost)
    if not enough then return rejectBegin(reason, stage) end
    local target, why = query(self.runtime, true)
    if not target then return rejectBegin(why, stage) end
    -- The optional executor is a deterministic test seam. Production actions use
    -- Loop:Update and the authoritative game clock for their full duration.
    local executor = self.loop.options.barrelActionExecutor
    local token = {}
    nextActionId = nextActionId + 1
    ---@type Circle1B2BarrelRecord
    local record = { token = token, runtime = assert(self.runtime), id = target.id, generation = target.generation,
        actionId = nextActionId,
        loopGeneration = self.loop.generation, stage = stage, state = "waiting", elapsed = 0 }
    local valid, invalidReason = self:Valid(record, true)
    if not valid then return rejectBegin(invalidReason, stage, target) end
    self.active, self.receipts[token] = record, record
    emit("begin_started", "operation", record, { action = "inspect" })
    if type(executor) ~= "function" then return token end
    local ok, cancel = Diagnostics.Call("barrel", "executor", executor, { id = record.id, generation = record.generation,
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
    if record.result then
        ignoreCallback(record, record.state == "complete" and "duplicate_completion" or "late_after_terminal_state")
        return table.unpack(record.result, 1, record.result.n)
    end
    if self.active ~= record or record.state ~= "waiting" then
        ignoreCallback(record, "stale_barrel_action")
        return false, "stale_barrel_action"
    end
    if type(evidence) ~= "table" or evidence.completed ~= true or type(evidence.durationSec) ~= "number"
        or evidence.durationSec ~= evidence.durationSec or evidence.durationSec == math.huge
        or evidence.durationSec < Config.barrel.durationSec then
        emit("completion_rejected", "rejected", record, { reason = "barrel_action_not_completed" })
        return false, "barrel_action_not_completed"
    end
    local valid, reason = self:Valid(record, true)
    if not valid then self:Cancel(reason); return false, reason end
    if self.loop.clock.exhausted and record.elapsed + 1e-9 < Config.barrel.durationSec then
        self:Cancel("night_interrupted")
        return false, "night_interrupted"
    end
    local inventory = self.loop.player.inventory
    local readOk, priorItems, space = Diagnostics.Call("barrel", "inventory_snapshot", function()
        return inventory:GetItems(), inventory:HasSpace(#Config.barrel.firstReward)
    end)
    if not readOk then
        emit("action_failed", "failure", record, { reason = "inventory_snapshot_failed" })
        self:Cancel("inventory_snapshot_failed")
        return false, "inventory_snapshot_failed"
    end
    record.rollback = { items = priorItems, stamina = self.loop.player.stamina,
        stage = record.stage, lens = Progress.HasLens(self.loop.player) }
    record.state = "committing"
    local ok, accepted = Diagnostics.Call("barrel", "commit", function()
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
        emit("action_failed", "failure", record, { reason = "barrel_commit_failed" })
        self:RetryRollback()
        return false, "barrel_commit_failed"
    end
    record.rollback = nil
    record.state = "complete"
    self.active = nil
    if record.stage == 0 and not space then
        self.pending = { items = copy(Config.barrel.firstReward), record = record }
        record.result = table.pack(true, "pending_reward")
        Diagnostics.Call("barrel", "open_inventory", self.loop.SetInventoryOpen, self.loop, true)
        Diagnostics.Call("barrel", "message", self.loop.SetMessage, self.loop,
            "木桶补给已保留，请腾出两格后同时领取苹果和鱼饵。")
    else
        record.result = table.pack(true, record.stage == 1 and "empty" or "rewarded")
        Diagnostics.Call("barrel", "message", self.loop.SetMessage, self.loop, record.stage == 1 and "什么都没有捕捞到"
            or (record.stage == 0 and "取得1个苹果和1个鱼饵。" or "已取得透镜。"))
    end
    emit("completed", "operation", record, { outcome = record.result[2], pending = self.pending ~= nil })
    return table.unpack(record.result, 1, record.result.n)
end
function Barrel:Claim()
    local pending = self.pending
    if not pending then
        emit("claim_rejected", "rejected", nil, { reason = "no_pending_catch" })
        return false, "no_pending_catch"
    end
    if pending.claiming or self.loop.inventoryRollback or self.loop.dropInFlight or self.loop.busy or self.loop.loading then
        emit("claim_rejected", "rejected", pending.record, { reason = "busy" })
        return false, "busy"
    end
    local inventory = self.loop.player.inventory
    if pending.rollbackItems then
        local restored, restoreReason = self:RetryPendingRollback()
        if not restored then return false, restoreReason end
    end
    local ok, before, space = Diagnostics.Call("barrel", "claim_snapshot", function()
        return inventory:GetItems(), inventory:HasSpace(#pending.items)
    end)
    if not ok then
        emit("claim_failed", "failure", pending.record, { reason = "inventory_snapshot_failed" })
        return false, "inventory_snapshot_failed"
    end
    if not space then
        emit("claim_rejected", "rejected", pending.record, { reason = "inventory_full" })
        return false, "inventory_full"
    end
    pending.claiming = true
    emit("claim_started", "operation", pending.record, { itemCount = #pending.items })
    local accepted, committed = Diagnostics.Call("barrel", "claim_commit", function()
        for _, id in ipairs(pending.items) do if inventory:Add(id) ~= true then return false end end
        return Progress.SetBarrelStage(self.loop.player, 1) == true
    end)
    pending.claiming = false
    if not accepted or committed ~= true then
        pending.rollbackItems = before
        if not pending.rollbackStartedLogged then
            pending.rollbackStartedLogged = true
            emit("claim_rollback_started", "operation", pending.record, { reason = "inventory_add_failed" })
        end
        local restoredCall, restored = Diagnostics.Call("barrel", "claim_rollback_inventory",
            inventory.RestoreItems, inventory, before)
        local stageOk, stageRestored = Diagnostics.Call("barrel", "claim_rollback_stage",
            Progress.SetBarrelStage, self.loop.player, 0)
        if not restoredCall then pending.rollbackRestoreExceptionLogged = true end
        if not stageOk then pending.rollbackStageExceptionLogged = true end
        if not restoredCall or restored ~= true or not stageOk or stageRestored ~= true then
            if not pending.rollbackFailureLogged then
                pending.rollbackFailureLogged = true
                emit("claim_rollback_failed", "failure", pending.record, { reason = "barrel_rollback_pending" })
            end
            return false, "barrel_rollback_pending"
        end
        pending.rollbackItems = nil
        emit("claim_rollback_completed", "operation", pending.record, { reason = "inventory_add_failed" })
        emit("claim_failed", "failure", pending.record, { reason = "inventory_add_failed" })
        return false, "inventory_add_failed"
    end
    self.pending = nil
    Diagnostics.Call("barrel", "message", self.loop.SetMessage, self.loop, "已同时领取木桶补给，不再扣体力。")
    emit("claim_completed", "operation", pending.record, { outcome = "claimed", itemCount = #pending.items })
    return true
end
return Barrel
