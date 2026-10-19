-- V2.8 固定海上内容的交互事务：0体力观察/拾取、探海镜标记、40体力/4秒打捞与双分支破网。
-- 设计约束：
--   * 时间只由调用方显式传入（与 WorldContentActions 同构），模块内不读时钟；
--   * 所有写入口都先校验生命周期（runtime 身份 / player 容器 / fixedContentGeneration）；
--   * 事务开始不扣费；成功完成才扣体力、发奖、置状态；主动取消/夜尽中断 0扣费0奖励；
--   * 运行态可立即内存置位防同局重复，持久化仍由既有检查点负责。
local Content = require "data.content"
local Items = require "data.items"
local V28 = require "Gameplay.V28Progress"
local WorldContentProgress = require "Gameplay.WorldContentProgress"

---@class V28ContentActions
---@field private _adapter table
---@field private _receipts table<number, table>
---@field private _nextToken integer
---@field private _active number|nil
---@field private _busy boolean
---@field private _observation number
---@field private _observationTarget string|nil
---@field private _lastMark table|nil
---@field private _context table|nil
---@field private _epoch integer
local Actions = {}
Actions.__index = Actions

-- PLAYTEST VALUE（V2.8 封板：≤5m 交互、1s 探海镜、4s 打捞）。
local ACCESS_GAP = 5
local LENS_MARK_DURATION = 1

local DEFINITIONS, CONTENT_IDS = {}, {}
for _, definition in ipairs(Content.fixed) do
    if type(definition.contentId) == "string"
        and (definition.observe or definition.pickup or definition.v28Action
            or definition.lensMark or definition.recognizeText or definition.net) then
        DEFINITIONS[definition.contentId] = definition
        CONTENT_IDS[#CONTENT_IDS + 1] = definition.contentId
    end
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in next, value do result[key] = copy(child) end
    return result
end

local function identity(value)
    return (type(value) == "string" and value ~= "")
        or (finite(value) and value >= 0 and value % 1 == 0)
end

---@param contentId string
---@return table|nil
function Actions.Definition(contentId)
    return DEFINITIONS[contentId]
end

---@return string[]
function Actions.ContentIds()
    local ids = {}
    for index, contentId in ipairs(CONTENT_IDS) do ids[index] = contentId end
    return ids
end

---@param adapter table
---@return table|nil, string|nil
local function readContext(adapter)
    local ok, ctx = pcall(adapter.GetContext, adapter)
    if not ok then return nil, "adapter_error" end
    if type(ctx) ~= "table" or type(ctx.player) ~= "table"
        or not identity(ctx.sessionGeneration) or not identity(ctx.fixedContentGeneration) then
        return nil, "invalid_context"
    end
    return {
        player = ctx.player,
        sessionGeneration = ctx.sessionGeneration,
        runtimeIdentity = ctx.runtimeIdentity,
        fixedContentGeneration = ctx.fixedContentGeneration,
        story = rawget(ctx.player, "story"),
        treasures = rawget(ctx.player, "treasures"),
    }
end

local function sameContext(a, b)
    return a and b and a.player == b.player and a.sessionGeneration == b.sessionGeneration
        and a.runtimeIdentity == b.runtimeIdentity
        and a.fixedContentGeneration == b.fixedContentGeneration
        and a.story == b.story and a.treasures == b.treasures
end

---@param adapter table
---@return V28ContentActions|nil, string|nil
function Actions.New(adapter)
    if type(adapter) ~= "table" then return nil, "invalid_adapter" end
    for _, method in ipairs({ "GetContext", "GetWorldContentAccess", "IsWorldContentInScope" }) do
        if type(adapter[method]) ~= "function" then return nil, "invalid_adapter" end
    end
    local ctx, reason = readContext(adapter)
    if not ctx then return nil, reason end
    local ok, initError = V28.Initialize(ctx.player)
    if not ok then return nil, initError end
    local self = setmetatable({ _adapter = adapter, _receipts = {}, _nextToken = 0,
        _active = nil, _busy = false, _observation = 0, _observationTarget = nil,
        _context = ctx, _epoch = 1 }, Actions)
    return self
end

function Actions:_sync()
    local ctx, reason = readContext(self._adapter)
    if not sameContext(self._context, ctx) then
        if self._active then self:_finish(self._receipts[self._active], "failed", "stale_generation") end
        self._observation, self._observationTarget = 0, nil
        self._epoch = self._epoch + 1
        self._context = nil
        if not ctx then return nil, reason end
        local ok, initError = V28.Initialize(ctx.player)
        if not ok then return nil, initError end
        self._context = ctx
        return ctx, "context_changed"
    end
    if not ctx then return nil, reason end
    local valid, validError = V28.Validate(ctx.player)
    if not valid then
        if self._active then self:_finish(self._receipts[self._active], "failed", validError) end
        return nil, validError
    end
    return ctx
end

function Actions:_finish(receipt, status, reason)
    receipt.status = status
    receipt.result = reason
    if status == "cancelled" then receipt.cancelReason = reason end
    if status == "failed" then receipt.failureReason = reason end
    if self._active == receipt.token then self._active = nil end
end

---同步、无副作用的空间与身份查询。
function Actions:_access(contentId, ctx)
    local definition = DEFINITIONS[contentId]
    if not definition then return nil, "invalid_content_id" end
    local ok, access = pcall(self._adapter.GetWorldContentAccess, self._adapter, contentId)
    if not ok then return nil, "adapter_error" end
    if type(access) ~= "table" then return nil, "content_unavailable" end
    if access.contentId ~= contentId or not identity(access.entityId) then
        return nil, "content_identity_mismatch"
    end
    if access.generation ~= ctx.fixedContentGeneration then return nil, "stale_generation" end
    if not finite(access.surfaceGap) then return nil, "invalid_surface_gap" end
    local radius = definition.observe and definition.observe.radius
        or (definition.pickup and ACCESS_GAP)
        or (definition.vortex and definition.vortex.observeRadius)
        or ACCESS_GAP
    local limit = math.min(ACCESS_GAP, radius)
    if access.surfaceGap > limit + 1e-9 then return nil, "out_of_range" end
    return { contentId = contentId, entityId = access.entityId,
        generation = access.generation, surfaceGap = access.surfaceGap }
end

---是否已由 sea_note_xx 持有状态推导出“已拾取”。
local function bottlePicked(player, definition)
    local pickup = definition.pickup
    if type(pickup) ~= "table" then return false end
    return V28.HasTreasure(player, pickup.treasureId)
end

---构造当前可见的 0体力场景按钮。固定顺序决定优先级。
---@return table|nil
function Actions:_observePrompt(ctx)
    for _, contentId in ipairs(CONTENT_IDS) do
        local definition = DEFINITIONS[contentId]
        if definition.observe and not self._active then
            local access = self:_access(contentId, ctx)
            if access then
                return { operation = "observe", contentId = contentId,
                    text = definition.observe.promptText or "观察",
                    textBody = definition.observe.text, enabled = true }
            end
        end
        if definition.pickup and not self._active and not bottlePicked(ctx.player, definition) then
            local access = self:_access(contentId, ctx)
            if access then
                return { operation = "pickup", contentId = contentId,
                    text = definition.pickup.promptText or "拾取", enabled = true }
            end
        end
        if definition.net and not self._active then
            local state = V28.GetProgressState(ctx.player, contentId)
            if state and state.completed ~= true then
                local access = self:_access(contentId, ctx)
                if access then
                    return { operation = "net", contentId = contentId,
                        text = definition.net.promptText or "处理破渔网", enabled = true }
                end
            end
        end
        if definition.v28Action and not self._active then
            local state = V28.GetProgressState(ctx.player, contentId)
            local eligible = state and state.completed ~= true
            if eligible and definition.lensMark then eligible = state.marked == true end
            if eligible then
                local access = self:_access(contentId, ctx)
                if access then
                    return { operation = "begin", contentId = contentId,
                        actionKind = definition.v28Action.kind,
                        text = definition.v28Action.promptText .. " · "
                            .. tostring(definition.v28Action.staminaCost) .. "体力",
                        staminaCost = definition.v28Action.staminaCost,
                        enabled = true }
                end
            end
        end
    end
    return nil
end

---统一入口：动态场景按钮。
---@return table|nil, string|nil
function Actions:GetPrompt()
    if self._busy then return nil, "busy" end
    local ctx, reason = self:_sync()
    if not ctx then return nil, reason end
    if self._active then
        local receipt = self._receipts[self._active]
        return { operation = "cancel", contentId = receipt.contentId,
            actionKind = receipt.actionKind, token = receipt.token,
            text = "取消" .. (DEFINITIONS[receipt.contentId].v28Action
                and DEFINITIONS[receipt.contentId].v28Action.promptText or "打捞"),
            enabled = true }
    end
    return self:_observePrompt(ctx)
end

---0体力即时观察（礁石/木板/海眼）。可重复，不写状态。
---@param contentId string
---@return boolean, string|nil, table|nil
function Actions:Observe(contentId)
    if self._busy then return false, "busy" end
    self._busy = true
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return false, reason end
    local definition = DEFINITIONS[contentId]
    if not definition or not definition.observe then
        self._busy = false
        return false, "content_not_observable"
    end
    local access, accessError = self:_access(contentId, ctx)
    if not access then self._busy = false; return false, accessError end
    self._busy = false
    return true, "observed", { contentId = contentId, text = definition.observe.text }
end

---0体力即时拾取固定漂流瓶；残页进独立道具栏，海面瓶体隐藏。
---@param contentId string
---@return boolean, string|nil, table|nil
function Actions:Pickup(contentId)
    if self._busy then return false, "busy" end
    self._busy = true
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return false, reason end
    local definition = DEFINITIONS[contentId]
    if not definition or not definition.pickup then
        self._busy = false
        return false, "content_not_pickable"
    end
    if bottlePicked(ctx.player, definition) then
        self._busy = false
        return false, "already_picked"
    end
    local access, accessError = self:_access(contentId, ctx)
    if not access then self._busy = false; return false, accessError end
    local granted, grantError = V28.GrantTreasure(ctx.player, definition.pickup.treasureId)
    self._busy = false
    if not granted then return false, grantError end
    return true, "picked", { contentId = contentId, treasureId = definition.pickup.treasureId,
        text = definition.pickup.text, readTitle = definition.pickup.readTitle,
        readText = definition.pickup.readText }
end

---校验 40体力/4秒动作的全部开始条件（不扣费）。
function Actions:_eligible(contentId, ctx, allowInsufficient)
    local definition = DEFINITIONS[contentId]
    if not definition or not definition.v28Action then return nil, "invalid_content_id" end
    local action = definition.v28Action
    local state, stateError = V28.GetProgressState(ctx.player, contentId)
    if not state then return nil, stateError end
    if state.completed then return nil, "already_completed" end
    if definition.lensMark and state.marked ~= true then return nil, "content_not_marked" end
    if action.requiredTreasure and not V28.HasTreasure(ctx.player, action.requiredTreasure) then
        return nil, "missing_key"
    end
    if not finite(ctx.player.stamina) or ctx.player.stamina < 0 then return nil, "invalid_stamina" end
    local canAfford = ctx.player.stamina >= action.staminaCost
    if not canAfford and allowInsufficient ~= true then return nil, "insufficient_stamina" end
    local freeSlots = action.freeSlots or 0
    if freeSlots > 0 and not ctx.player.inventory:HasSpace(freeSlots) then
        return nil, "inventory_full"
    end
    local access, accessError = self:_access(contentId, ctx)
    if not access then return nil, accessError end
    access.canAffordStamina = canAfford
    access.action = action
    return access
end

function Actions:_createReceipt(ctx, contentId, access)
    self._nextToken = self._nextToken + 1
    local progressSnapshot = assert(V28.Snapshot(ctx.player, contentId))
    local receipt = {
        token = self._nextToken, contentId = contentId, actionKind = access.action.kind,
        entityId = access.entityId, fixedContentGeneration = ctx.fixedContentGeneration,
        sessionGeneration = ctx.sessionGeneration, epoch = self._epoch,
        elapsed = 0, duration = access.action.duration,
        staminaCost = access.action.staminaCost,
        status = "active", commitState = "pending",
        begin = { progress = progressSnapshot, stamina = ctx.player.stamina },
    }
    self._receipts[self._nextToken] = receipt
    self._active = self._nextToken
    return self._nextToken
end

---开始 40体力/4秒打捞动作（沉船 / 浮藻假岛货箱）。
---@param contentId string
---@return number|nil, string|nil
function Actions:BeginAction(contentId)
    if self._busy then return nil, "busy" end
    self._busy = true
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return nil, reason end
    if self._active then self._busy = false; return nil, "action_active" end
    local access, accessError = self:_eligible(contentId, ctx)
    if not access then self._busy = false; return nil, accessError end
    local token = self:_createReceipt(ctx, contentId, access)
    self._busy = false
    return token
end

---破渔网分支 A：40体力/4秒、需2空位，成功得2条小鱼并永久放弃钥匙。
function Actions:BeginNetCollect(contentId)
    if self._busy then return nil, "busy" end
    self._busy = true
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return nil, reason end
    if self._active then self._busy = false; return nil, "action_active" end
    local definition = DEFINITIONS[contentId]
    if not definition or not definition.net then
        self._busy = false
        return nil, "content_not_net"
    end
    local state, stateError = V28.GetProgressState(ctx.player, contentId)
    if not state then self._busy = false; return nil, stateError end
    if state.completed then self._busy = false; return nil, "already_completed" end
    local branch = definition.net.branchA
    if not finite(ctx.player.stamina) or ctx.player.stamina < branch.staminaCost then
        self._busy = false
        return nil, "insufficient_stamina"
    end
    if not ctx.player.inventory:HasSpace(branch.freeSlots or 0) then
        self._busy = false
        return nil, "inventory_full"
    end
    local access, accessError = self:_access(contentId, ctx)
    if not access then self._busy = false; return nil, accessError end
    access.action = branch
    local token = self:_createReceipt(ctx, contentId, access)
    self._busy = false
    return token
end

---破渔网分支 B：0体力即时割网，得本周目唯一生锈钥匙并放出2条真实小鱼。
---@param contentId string
---@param releaseFish fun(species:string, count:integer): boolean|nil, string|nil 由 Ocean 注入
---@return boolean, string|nil, table|nil
function Actions:ResolveNetCut(contentId, releaseFish)
    if self._busy then return false, "busy" end
    self._busy = true
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return false, reason end
    local definition = DEFINITIONS[contentId]
    if not definition or not definition.net then
        self._busy = false
        return false, "content_not_net"
    end
    local state, stateError = V28.GetProgressState(ctx.player, contentId)
    if not state then self._busy = false; return false, stateError end
    if state.completed then self._busy = false; return false, "already_completed" end
    local access, accessError = self:_access(contentId, ctx)
    if not access then self._busy = false; return false, accessError end
    local branch = definition.net.branchB
    -- 先登记钥匙，再放出小鱼；小鱼生成失败时回滚钥匙与状态。
    local snapshot = assert(V28.Snapshot(ctx.player, contentId))
    local granted, grantError = V28.GrantTreasure(ctx.player, branch.treasureId)
    if not granted then self._busy = false; return false, grantError end
    local flagged, flagError = V28.SetFlag(ctx.player, contentId, "completed", true)
    if not flagged then
        V28.Restore(ctx.player, contentId, snapshot)
        self._busy = false
        return false, flagError
    end
    local released = true
    if type(releaseFish) == "function" then
        local ok, accepted = pcall(releaseFish, branch.releaseFish.species, branch.releaseFish.count)
        released = ok and accepted ~= false
    end
    if not released then
        V28.Restore(ctx.player, contentId, snapshot)
        rawset(rawget(ctx.player, "treasures"), branch.treasureId, false)
        self._busy = false
        return false, "fish_release_failed"
    end
    self._busy = false
    return true, "cut", { contentId = contentId, treasureId = branch.treasureId,
        text = branch.successText }
end

---事务提交：重新校验身份/体力/空位/钥匙，再一次性扣费发奖置状态。
function Actions:_commit(receipt, ctx)
    local definition = DEFINITIONS[receipt.contentId]
    local access, reason
    if definition.net and receipt.actionKind == definition.net.branchA.kind then
        local state = V28.GetProgressState(ctx.player, receipt.contentId)
        if not state or state.completed then
            self:_finish(receipt, "failed", "already_completed")
            return false, "already_completed"
        end
        if ctx.player.stamina < definition.net.branchA.staminaCost then
            self:_finish(receipt, "failed", "insufficient_stamina")
            return false, "insufficient_stamina"
        end
        if not ctx.player.inventory:HasSpace(definition.net.branchA.freeSlots or 0) then
            self:_finish(receipt, "failed", "inventory_full")
            return false, "inventory_full"
        end
        access = self:_access(receipt.contentId, ctx)
        if not access then self:_finish(receipt, "failed", "content_unavailable")
            return false, "content_unavailable" end
        access.action = definition.net.branchA
    else
        access, reason = self:_eligible(receipt.contentId, ctx)
        if not access then self:_finish(receipt, "failed", reason); return false, reason end
    end
    if receipt.epoch ~= self._epoch or receipt.entityId ~= access.entityId
        or not sameContext(ctx, readContext(self._adapter)) then
        self:_finish(receipt, "failed", "stale_generation")
        return false, "stale_generation"
    end

    local player = ctx.player
    local action = access.action
    local progressSnapshot = assert(V28.Snapshot(player, receipt.contentId))
    local inventorySnapshot = player.inventory:GetItems()
    local staminaSnapshot = player.stamina
    local treasureId = action.requiredTreasure
    local keySnapshot = treasureId and V28.HasTreasure(player, treasureId) or nil
    receipt.commitState = "committing"
    local function apply()
        local charged, chargeError = player:ConsumeStamina(action.staminaCost)
        if not charged then return false, chargeError or "stamina_charge_failed" end
        local added = {}
        for _, reward in ipairs(action.rewards or {}) do
            for _ = 1, reward.count or 1 do
                local ok, addError = player.inventory:Add(reward.itemId)
                if not ok then
                    return false, addError or "inventory_add_failed"
                end
                added[#added + 1] = reward.itemId
            end
        end
        if action.consumeTreasure then
            local consumed, consumeError = V28.ConsumeTreasure(player, action.requiredTreasure)
            if not consumed then return false, consumeError or "missing_key" end
        end
        local flagged, flagError = V28.SetFlag(player, receipt.contentId, "completed", true)
        if not flagged then return false, flagError end
        local valid, validError = V28.Validate(player)
        if not valid then return false, validError end
        return true, nil
    end
    local ok, committed, err = pcall(apply)
    if not ok or not committed then
        -- 完整回滚：体力、船舱、钥匙、内容状态。
        player.stamina = staminaSnapshot
        player.inventory:RestoreItems(inventorySnapshot)
        if treasureId then rawset(rawget(player, "treasures"), treasureId, keySnapshot == true) end
        V28.Restore(player, receipt.contentId, progressSnapshot)
        receipt.commitState = "rolled_back"
        self:_finish(receipt, "failed", ok and err or "commit_exception")
        return false, ok and err or "commit_exception"
    end
    receipt.commitState = "committed"
    receipt.resultItems = action.rewards
    self:_finish(receipt, "completed", "completed")
    return true, "completed"
end

---推进当前事务（Pause 传 0）。同时推进探海镜 1 秒标记。
---@param explicitElapsed number
---@return boolean, string|nil
function Actions:Advance(explicitElapsed)
    if self._busy then return false, "busy" end
    if not finite(explicitElapsed) or explicitElapsed < 0 then return false, "invalid_elapsed" end
    self._busy = true
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return false, reason end
    local observed, observeError = self:_observe(explicitElapsed, ctx)
    if not observed then
        if self._active then self:_finish(self._receipts[self._active], "failed", observeError) end
        self._busy = false
        return false, observeError
    end
    if not self._active then self._busy = false; return true, "idle" end
    local receipt = self._receipts[self._active]
    receipt.elapsed = math.min(receipt.duration, receipt.elapsed + explicitElapsed)
    if receipt.elapsed < receipt.duration then self._busy = false; return true, "active" end
    local ok, err = self:_commit(receipt, ctx)
    self._busy = false
    return ok, err
end

---探海镜连续照射 1 秒：标记沉船/浮藻货箱，识别巨兽骸骨。
function Actions:_observe(explicitElapsed, ctx)
    if not (ctx.treasures and rawget(ctx.treasures, "scopeLens") == true) then
        self._observation, self._observationTarget = 0, nil
        return true
    end
    local targetId
    for _, contentId in ipairs(CONTENT_IDS) do
        local definition = DEFINITIONS[contentId]
        local needs = definition.lensMark or definition.recognizeText ~= nil
        if needs then
            local state = V28.GetProgressState(ctx.player, contentId)
            if state then
                local pending = (definition.lensMark and state.marked ~= true and state.completed ~= true)
                    or (definition.recognizeText and state.recognized ~= true)
                if pending then
                    local ok, inside = pcall(self._adapter.IsWorldContentInScope, self._adapter, contentId)
                    if ok and inside == true then targetId = contentId; break end
                end
            end
        end
    end
    if not targetId then
        self._observation, self._observationTarget = 0, nil
        return true
    end
    if self._observationTarget ~= targetId then
        self._observation, self._observationTarget = 0, targetId
    end
    self._observation = math.min(LENS_MARK_DURATION, self._observation + explicitElapsed)
    if self._observation < LENS_MARK_DURATION then return true end
    local definition = DEFINITIONS[targetId]
    local message
    if definition.lensMark then
        local ok, flagError = V28.SetFlag(ctx.player, targetId, "marked", true)
        if not ok then return false, flagError end
        message = definition.markText
    end
    if definition.recognizeText then
        local ok, flagError = V28.SetFlag(ctx.player, targetId, "recognized", true)
        if not ok then return false, flagError end
        message = message or definition.recognizeText
    end
    self._observation, self._observationTarget = 0, nil
    self._lastMark = { contentId = targetId, text = message }
    return true
end

---取出并清空最近一次探海镜标记/识别提示（顶部轻提示一次）。
function Actions:ConsumeLensNotice()
    local notice = self._lastMark
    self._lastMark = nil
    return notice
end

---@param token number|nil
---@param reason string|nil
---@return boolean, string|nil
function Actions:Cancel(token, reason)
    if self._busy then return false, "busy" end
    self:_sync()
    local receipt = self._receipts[token or self._active]
    if not receipt then return false, "unknown_token" end
    if receipt.status == "cancelled" then return true, "already_cancelled" end
    if receipt.status ~= "active" then return false, "action_finalized" end
    self:_finish(receipt, "cancelled", reason or "cancelled")
    return true, "cancelled"
end

---@param token number|nil
---@return table|nil, string|nil
function Actions:GetReceipt(token)
    if not self._busy then self:_sync() end
    local receipt = self._receipts[token]
    if not receipt then return nil, "unknown_token" end
    return copy(receipt)
end

---@return table|nil
function Actions:GetActionState()
    if not self._busy then self:_sync() end
    return self._active and self:GetReceipt(self._active) or nil
end

---@return table
function Actions:GetObservationState()
    if not self._busy then self:_sync() end
    return { contentId = self._observationTarget, elapsed = self._observation,
        duration = LENS_MARK_DURATION }
end

function Actions:Invalidate(reason)
    if self._busy then return false, "busy" end
    self._epoch = self._epoch + 1
    self._observation, self._observationTarget, self._lastMark = 0, nil, nil
    if self._active then self:_finish(self._receipts[self._active], "failed", reason or "stale_generation") end
    return true
end

return Actions
