-- 固定内容的独立 Gameplay 事务。调用者显式提供 elapsed；此模块不读取任何时钟。
local Progress = require "Gameplay.WorldContentProgress"

---@class WorldContentActions
---@field private _adapter table
---@field private _receipts table<number, table>
---@field private _observation number
---@field private _epoch integer
---@field private _active number|nil
---@field private _busy boolean
---@field private _context table|nil
local Actions = {}
Actions.__index = Actions

-- PLAYTEST VALUE，非永久平衡常数。
local DURATION, STAMINA_COST, OBSERVATION_DURATION, ACCESS_GAP = 4, 40, 1, 5
local IDS = { "island_01", "island_02", "underwater_treasure_01" }
local DEFINITIONS = {
    island_01 = { kind = "explore", reward = "memory_island_01" },
    island_02 = { kind = "explore", reward = "memory_island_02" },
    underwater_treasure_01 = { kind = "salvage", reward = "memory_treasure_01" },
}
local nextToken = 0

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function identity(value)
    return (type(value) == "string" and value ~= "")
        or (finite(value) and value >= 0 and value % 1 == 0)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in next, value do result[key] = copy(item) end
    return result
end

-- adapter 只提供同步、无副作用的查询；不允许在这些查询中驱动其它更新链。
local function query(adapter, method, ...)
    local ok, value, reason = pcall(adapter[method], adapter, ...)
    if not ok then return nil, "adapter_error" end
    return value, reason
end

---@param adapter table
---@return table|nil, string|nil
local function readContext(adapter)
    local ctx, reason = query(adapter, "GetContext")
    if type(ctx) ~= "table" then return nil, reason or "context_unavailable" end
    if type(ctx.player) ~= "table" or not identity(ctx.sessionGeneration)
        or not identity(ctx.fixedContentGeneration)
        or (not identity(ctx.runtimeIdentity) and type(ctx.runtimeIdentity) ~= "table") then
        return nil, "invalid_context"
    end
    return {
        player = ctx.player, sessionGeneration = ctx.sessionGeneration,
        runtimeIdentity = ctx.runtimeIdentity, fixedContentGeneration = ctx.fixedContentGeneration,
        story = rawget(ctx.player, "story"), treasures = rawget(ctx.player, "treasures"),
        records = type(ctx.player.story) == "table" and rawget(ctx.player.story, "worldContent") or nil,
    }
end

local function sameContext(a, b)
    return a and b and a.player == b.player and a.sessionGeneration == b.sessionGeneration
        and a.runtimeIdentity == b.runtimeIdentity and a.fixedContentGeneration == b.fixedContentGeneration
        and a.story == b.story and a.treasures == b.treasures and a.records == b.records
end

local function finish(self, receipt, status, reason)
    receipt.status = status
    receipt.result = reason
    if status == "cancelled" then receipt.cancelReason = reason end
    if status == "failed" then receipt.failureReason = reason end
    if self._active == receipt.token then self._active = nil end
end

---adapter 契约见 docs/V25_WORK_C_INTEGRATION.md；没有真实 SeaRuntime 依赖。
---@param adapter table
---@return WorldContentActions|nil, string|nil
function Actions.New(adapter)
    if type(adapter) ~= "table" then return nil, "invalid_adapter" end
    for _, method in ipairs({ "GetContext", "GetWorldContentAccess", "IsWorldContentInScope" }) do
        if type(adapter[method]) ~= "function" then return nil, "invalid_adapter" end
    end
    local ctx, reason = readContext(adapter)
    if not ctx then return nil, reason end
    local ok, err = Progress.Initialize(ctx.player)
    if not ok then return nil, err end
    local self = setmetatable({ _adapter = adapter, _receipts = {}, _observation = 0, _epoch = 1,
        _busy = false }, Actions)
    local initializedContext, contextError = readContext(adapter)
    if not initializedContext then return nil, contextError end
    if initializedContext.player ~= ctx.player or initializedContext.sessionGeneration ~= ctx.sessionGeneration
        or initializedContext.runtimeIdentity ~= ctx.runtimeIdentity
        or initializedContext.fixedContentGeneration ~= ctx.fixedContentGeneration then
        return nil, "stale_generation"
    end
    self._context = initializedContext
    return self
end

-- 所有写入口先检查生命周期。替换时废弃活动事务，并重新绑定新的 Gameplay 状态。
function Actions:_sync()
    local ctx, reason = readContext(self._adapter)
    if not sameContext(self._context, ctx) then
        if self._active then finish(self, self._receipts[self._active], "failed", "stale_generation") end
        self._observation = 0
        self._epoch = self._epoch + 1
        self._context = nil
        if not ctx then return nil, reason end
        local ok, err = Progress.Initialize(ctx.player)
        if not ok then return nil, err end
        ctx, reason = readContext(self._adapter)
        if not ctx then return nil, reason end
        self._context = ctx
        return ctx, "context_changed"
    end
    if not ctx then return nil, reason end
    local valid, err = Progress.Validate(ctx.player)
    if not valid then
        if self._active then finish(self, self._receipts[self._active], "failed", err) end
        return nil, err
    end
    return ctx
end

function Actions:_access(contentId, ctx)
    local access, reason = query(self._adapter, "GetWorldContentAccess", contentId)
    if type(access) ~= "table" then return nil, reason or "content_unavailable" end
    if access.contentId ~= contentId or not identity(access.entityId) then
        return nil, "content_identity_mismatch"
    end
    if access.generation ~= ctx.fixedContentGeneration then return nil, "stale_generation" end
    if not finite(access.surfaceGap) then return nil, "invalid_surface_gap" end
    if access.surfaceGap > ACCESS_GAP then return nil, "out_of_range" end
    return { contentId = contentId, entityId = access.entityId, generation = access.generation }
end

function Actions:_eligible(contentId, kind, ctx)
    local definition = DEFINITIONS[contentId]
    if not definition then return nil, "invalid_content_id" end
    if definition.kind ~= kind then return nil, "invalid_action_kind" end
    local state, reason = Progress.GetState(ctx.player, contentId)
    if not state then return nil, reason end
    if state.completed then return nil, "already_completed" end
    if state.rewardOwned then return nil, "reward_already_owned" end
    if kind == "salvage" and not state.marked then return nil, "content_not_marked" end
    if not finite(ctx.player.stamina) or ctx.player.stamina < 0 then return nil, "invalid_stamina" end
    if ctx.player.stamina < STAMINA_COST then return nil, "insufficient_stamina" end
    return self:_access(contentId, ctx)
end

function Actions:_begin(contentId, kind)
    if self._busy then return nil, "busy" end
    self._busy = true
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return nil, reason end
    if self._active then self._busy = false; return nil, "action_active" end
    local access, err = self:_eligible(contentId, kind, ctx)
    if not access then self._busy = false; return nil, err end
    local current = readContext(self._adapter)
    if not sameContext(ctx, current) then self._busy = false; return nil, "stale_generation" end
    nextToken = nextToken + 1
    local snapshot = assert(Progress.Snapshot(ctx.player, contentId))
    snapshot.stamina = ctx.player.stamina
    local receipt = { token = nextToken, contentId = contentId, actionKind = kind,
        entityId = access.entityId, fixedContentGeneration = ctx.fixedContentGeneration,
        sessionGeneration = ctx.sessionGeneration, epoch = self._epoch, begin = snapshot,
        elapsed = 0, duration = DURATION, staminaCost = STAMINA_COST,
        status = "active", commitState = "pending", rollback = "not_needed" }
    self._receipts[nextToken] = receipt
    self._active = nextToken
    self._busy = false
    return nextToken
end

function Actions:BeginExplore(contentId)
    return self:_begin(contentId, "explore")
end

function Actions:BeginSalvage(contentId)
    return self:_begin(contentId, "salvage")
end

-- 仅恢复本次提交触碰的字段；即使半写入导致 Validate 失败，也能恢复。
local function restoreCommit(player, story, records, treasures, record, contentId, snapshot)
    rawset(record, "completed", snapshot.completed)
    if snapshot.marked ~= nil then rawset(record, "marked", snapshot.marked) end
    rawset(treasures, DEFINITIONS[contentId].reward, snapshot.rewardOwned)
    -- Player.Reset/Load 替换容器后，旧事务不得覆盖新玩家的体力。
    if rawget(player, "story") == story and rawget(player, "treasures") == treasures
        and rawget(story, "worldContent") == records then
        rawset(player, "stamina", snapshot.stamina)
    end
end

function Actions:_commit(receipt, ctx)
    local access, reason = self:_eligible(receipt.contentId, receipt.actionKind, ctx)
    if not access then finish(self, receipt, "failed", reason); return false, reason end
    if receipt.epoch ~= self._epoch or receipt.entityId ~= access.entityId
        or not sameContext(ctx, readContext(self._adapter)) then
        finish(self, receipt, "failed", "stale_generation")
        return false, "stale_generation"
    end
    local player = ctx.player
    local snapshot = assert(Progress.Snapshot(player, receipt.contentId))
    snapshot.stamina = player.stamina
    local record = rawget(ctx.records, receipt.contentId)
    receipt.commitState = "committing"
    ---@return boolean, string|nil
    local function applyCommit()
        -- 使用玩家公开扣费能力；测试可注入失败，提交外围负责恢复全部字段。
        local charged, chargeError = player:ConsumeStamina(STAMINA_COST)
        if not charged then return false, chargeError or "stamina_charge_failed" end
        if not sameContext(ctx, readContext(self._adapter)) then return false, "stale_generation" end
        local completed, commitError = Progress.Commit(player, receipt.contentId)
        if not completed or commitError == "already_completed" then
            return false, commitError or "progress_commit_failed"
        end
        if not sameContext(ctx, readContext(self._adapter)) then return false, "stale_generation" end
        local valid, validationError = Progress.Validate(player)
        if not valid then return false, validationError end
        local state = assert(Progress.GetState(player, receipt.contentId))
        if not state.completed or not state.rewardOwned or player.stamina ~= snapshot.stamina - STAMINA_COST then
            return false, "commit_consistency_failed"
        end
        return true, nil
    end
    local ok, committed, err = pcall(applyCommit)
    if not ok or not committed then
        restoreCommit(player, ctx.story, ctx.records, ctx.treasures, record, receipt.contentId, snapshot)
        receipt.commitState = "rolled_back"
        receipt.rollback = "restored"
        reason = ok and err or "commit_exception"
        finish(self, receipt, "failed", reason)
        return false, reason
    end
    receipt.commitState = "committed"
    finish(self, receipt, "completed", "completed")
    return true, "completed"
end

function Actions:_observe(explicitElapsed, ctx)
    local state, reason = Progress.GetState(ctx.player, "underwater_treasure_01")
    if not state then return false, reason end
    if state.marked or state.completed then self._observation = 0; return true end
    if ctx.player.treasures.scopeLens ~= true then self._observation = 0; return true end
    local inside, err = query(self._adapter, "IsWorldContentInScope", "underwater_treasure_01")
    if inside ~= true then
        self._observation = 0
        if inside == nil then return false, err or "scope_unavailable" end
        return true
    end
    if not sameContext(ctx, readContext(self._adapter)) then self._observation = 0; return false, "stale_generation" end
    self._observation = math.min(OBSERVATION_DURATION, self._observation + explicitElapsed)
    if self._observation >= OBSERVATION_DURATION then
        return Progress.Mark(ctx.player, "underwater_treasure_01")
    end
    return true
end

---调用方在唯一帧调度链传入 elapsed；Pause 传 0。世界/昼夜推进由调用方负责。
---@param explicitElapsed number
---@return boolean, string|nil
function Actions:Advance(explicitElapsed)
    if self._busy then return false, "busy" end
    if not finite(explicitElapsed) or explicitElapsed < 0 then return false, "invalid_elapsed" end
    self._busy = true
    local oldActive = self._active
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return false, reason end
    if oldActive and not self._active then self._busy = false; return false, "stale_generation" end
    local observed, observationError = self:_observe(explicitElapsed, ctx)
    if not observed then
        if self._active then finish(self, self._receipts[self._active], "failed", observationError) end
        self._busy = false
        return false, observationError
    end
    if not self._active then self._busy = false; return true, "idle" end
    local receipt = self._receipts[self._active]
    receipt.elapsed = math.min(receipt.duration, receipt.elapsed + explicitElapsed)
    if receipt.elapsed < receipt.duration then self._busy = false; return true, "active" end
    local ok, err = self:_commit(receipt, ctx)
    self._busy = false
    return ok, err
end

function Actions:Cancel(token, reason)
    if self._busy then return false, "busy" end
    self:_sync()
    local receipt = self._receipts[token or self._active]
    if not receipt then return false, "unknown_token" end
    if receipt.status == "cancelled" then return true, "already_cancelled" end
    if receipt.status ~= "active" then return false, "action_finalized" end
    finish(self, receipt, "cancelled", reason or "cancelled")
    return true, "cancelled"
end

---LoadSaved/NewRun/Reset/runtime 替换前调用；此外自动身份校验负责漏接保护。
function Actions:Invalidate(reason)
    if self._busy then return false, "busy" end
    self._epoch = self._epoch + 1
    self._observation = 0
    if self._active then finish(self, self._receipts[self._active], "failed", reason or "stale_generation") end
    return true
end

function Actions:GetReceipt(token)
    if not self._busy then self:_sync() end
    local receipt = self._receipts[token]
    if not receipt then return nil, "unknown_token" end
    return copy(receipt)
end

function Actions:GetActionState()
    if not self._busy then self:_sync() end
    return self._active and self:GetReceipt(self._active) or nil
end

function Actions:GetObservationState()
    if not self._busy then self:_sync() end
    return { contentId = "underwater_treasure_01", elapsed = self._observation, duration = OBSERVATION_DURATION }
end

function Actions:GetOwnedTreasures()
    if self._busy then return nil, "busy" end
    local ctx, reason = self:_sync()
    if not ctx then return nil, reason end
    local result = {}
    for _, id in ipairs(IDS) do
        local reward = DEFINITIONS[id].reward
        if rawget(ctx.treasures, reward) == true then result[#result + 1] = reward end
    end
    return result
end

---动态入口：一个 begin/cancel 提示；固定顺序决定多个合法目标同时出现时的优先级。
function Actions:GetWorldContentPrompt()
    if self._busy then return nil, "busy" end
    local ctx, reason = self:_sync()
    if not ctx then return nil, reason end
    if self._active then
        local receipt = self._receipts[self._active]
        return { text = receipt.actionKind == "explore" and "取消探索" or "取消打捞",
            operation = "cancel", contentId = receipt.contentId, actionKind = receipt.actionKind,
            token = receipt.token, enabled = true }
    end
    for _, id in ipairs(IDS) do
        local kind = DEFINITIONS[id].kind
        local eligible = self:_eligible(id, kind, ctx)
        if eligible then
            return { text = kind == "explore" and "探索岛屿" or "打捞宝藏", operation = "begin",
                contentId = id, actionKind = kind, enabled = true }
        end
    end
    return nil, "no_eligible_content"
end

return Actions
