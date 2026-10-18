-- 固定内容的独立 Gameplay 事务。调用者显式提供 elapsed；此模块不读取任何时钟。
local Progress = require "Gameplay.WorldContentProgress"
local Content = require "data.content"

---@class WorldContentActions
---@field private _adapter table
---@field private _receipts table<number, table>
---@field private _observation number
---@field private _observationTarget string|nil
---@field private _epoch integer
---@field private _active number|nil
---@field private _busy boolean
---@field private _context table|nil
local Actions = {}
Actions.__index = Actions

-- PLAYTEST VALUE，非永久平衡常数。
local DURATION, STAMINA_COST, OBSERVATION_DURATION, ACCESS_GAP = 4, 40, 1, 5
local IDS, DEFINITIONS = {}, {}
local KEY_SOURCE_DEFINITIONS, INVALID_KEY_SOURCE_IDS = {}, {}
local LENS_CONTENT_IDS = { "underwater_treasure_01" }

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function keySourceAction(definition)
    local action = definition.action
    if definition.keySource ~= true or definition.revealMethod ~= "lens"
        or definition.markable ~= true or definition.rewardId ~= nil
        or type(definition.keyId) ~= "string" or definition.keyId == ""
        or type(action) ~= "table" or type(action.kind) ~= "string" or action.kind == ""
        or not finite(action.duration) or action.duration <= 0
        or not finite(action.staminaCost) or action.staminaCost < 0 then
        return nil
    end
    return { kind = action.kind, duration = action.duration, staminaCost = action.staminaCost }
end

for _, definition in ipairs(Content.fixed) do
    if definition.actionKind ~= nil then
        assert(type(definition.actionKind) == "string" and type(definition.rewardId) == "string",
            "fixed content action metadata is incomplete")
        IDS[#IDS + 1] = definition.contentId
        DEFINITIONS[definition.contentId] = {
            kind = definition.actionKind, rewardId = definition.rewardId,
            markable = definition.markable, keyRequired = definition.keyRequired,
            consumeKey = definition.consumeKey,
        }
    end
    if definition.keySource == true and type(definition.contentId) == "string" then
        local action = keySourceAction(definition)
        if action then
            KEY_SOURCE_DEFINITIONS[definition.contentId] = {
                keyId = definition.keyId, action = action,
            }
            if definition.contentId ~= "underwater_treasure_01" then
                LENS_CONTENT_IDS[#LENS_CONTENT_IDS + 1] = definition.contentId
            end
        elseif definition.revealMethod == "lens" then
            INVALID_KEY_SOURCE_IDS[definition.contentId] = true
        end
    end
end
local nextToken = 0

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

local function resetObservation(self)
    self._observation = 0
    self._observationTarget = nil
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
    local self = setmetatable({ _adapter = adapter, _receipts = {}, _observation = 0,
        _observationTarget = nil, _epoch = 1, _busy = false }, Actions)
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
        resetObservation(self)
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

local function keyRequirement(player, definition)
    local keyId = definition.keyRequired
    if keyId == nil then
        if definition.consumeKey ~= nil then return nil, "invalid_key_config" end
        return { id = nil }
    end
    if definition.kind ~= "salvage" or type(keyId) ~= "string" or keyId == ""
        or type(definition.consumeKey) ~= "boolean" then
        return nil, "invalid_key_config"
    end

    local treasures = rawget(player, "treasures")
    local keys = type(treasures) == "table" and rawget(treasures, "keys") or nil
    if type(keys) ~= "table" then return nil, "invalid_key_progress" end
    for id, owned in next, keys do
        if type(id) ~= "string" or id == "" or type(owned) ~= "boolean" then
            return nil, "invalid_key_progress"
        end
    end
    if rawget(keys, keyId) ~= true then return nil, "missing_key" end
    return { id = keyId, consume = definition.consumeKey, map = keys, owned = true }
end

function Actions:_eligible(contentId, kind, ctx, allowInsufficientStamina)
    local definition = DEFINITIONS[contentId]
    if not definition then return nil, "invalid_content_id" end
    if definition.kind ~= kind then return nil, "invalid_action_kind" end
    local state, reason = Progress.GetState(ctx.player, contentId)
    if not state then return nil, reason end
    if state.completed then return nil, "already_completed" end
    if state.rewardOwned then return nil, "reward_already_owned" end
    if kind == "salvage" and not state.marked then return nil, "content_not_marked" end
    local key, keyError = keyRequirement(ctx.player, definition)
    if not key then return nil, keyError end
    if not finite(ctx.player.stamina) or ctx.player.stamina < 0 then return nil, "invalid_stamina" end
    local canAffordStamina = ctx.player.stamina >= STAMINA_COST
    if not canAffordStamina and allowInsufficientStamina ~= true then
        return nil, "insufficient_stamina"
    end
    local access, accessError = self:_access(contentId, ctx)
    if not access then return nil, accessError end
    access.key = key
    access.staminaCost = STAMINA_COST
    access.canAffordStamina = canAffordStamina
    return access
end

function Actions:_eligibleKeySource(contentId, ctx)
    local source = KEY_SOURCE_DEFINITIONS[contentId]
    if not source then
        if INVALID_KEY_SOURCE_IDS[contentId] then return nil, "invalid_action_config" end
        return nil, "invalid_content_id"
    end
    local state, reason = Progress.GetState(ctx.player, contentId)
    if not state then return nil, reason end
    if not state.marked then return nil, "content_not_marked" end

    local treasures = rawget(ctx.player, "treasures")
    local keys = type(treasures) == "table" and rawget(treasures, "keys") or nil
    if type(keys) ~= "table" then return nil, "invalid_key_progress" end
    for id, owned in next, keys do
        if type(id) ~= "string" or id == "" or type(owned) ~= "boolean" then
            return nil, "invalid_key_progress"
        end
    end
    local owned = rawget(keys, source.keyId)
    if owned == true then return nil, "key_already_owned" end
    if not finite(ctx.player.stamina) or ctx.player.stamina < 0 then return nil, "invalid_stamina" end
    if ctx.player.stamina < source.action.staminaCost then return nil, "insufficient_stamina" end

    local access, accessError = self:_access(contentId, ctx)
    if not access then return nil, accessError end
    access.key = { id = source.keyId, map = keys, owned = owned }
    return access
end

local function createReceipt(self, ctx, contentId, kind, duration, staminaCost, access)
    nextToken = nextToken + 1
    local snapshot = assert(Progress.Snapshot(ctx.player, contentId))
    snapshot.stamina = ctx.player.stamina
    local receipt = { token = nextToken, contentId = contentId, actionKind = kind,
        entityId = access.entityId, fixedContentGeneration = ctx.fixedContentGeneration,
        sessionGeneration = ctx.sessionGeneration, epoch = self._epoch, begin = snapshot,
        elapsed = 0, duration = duration, staminaCost = staminaCost,
        status = "active", commitState = "pending", rollback = "not_needed" }
    self._receipts[nextToken] = receipt
    self._active = nextToken
    return nextToken
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
    local token = createReceipt(self, ctx, contentId, kind, DURATION, STAMINA_COST, access)
    self._busy = false
    return token
end

function Actions:BeginExplore(contentId)
    return self:_begin(contentId, "explore")
end

function Actions:BeginSalvage(contentId)
    return self:_begin(contentId, "salvage")
end

---开始 fixture/配置中显式声明的 lens key source 领取动作。
---@param contentId string
---@return number|nil, string|nil
function Actions:BeginKeySource(contentId)
    if self._busy then return nil, "busy" end
    self._busy = true
    local ctx, reason = self:_sync()
    if not ctx then self._busy = false; return nil, reason end
    if self._active then self._busy = false; return nil, "action_active" end
    local source = KEY_SOURCE_DEFINITIONS[contentId]
    if not source then
        local sourceError = INVALID_KEY_SOURCE_IDS[contentId] and "invalid_action_config" or "invalid_content_id"
        self._busy = false
        return nil, sourceError
    end
    local access, err = self:_eligibleKeySource(contentId, ctx)
    if not access then self._busy = false; return nil, err end
    local current = readContext(self._adapter)
    if not sameContext(ctx, current) then self._busy = false; return nil, "stale_generation" end
    local token = createReceipt(self, ctx, contentId, source.action.kind,
        source.action.duration, source.action.staminaCost, access)
    self._busy = false
    return token
end

-- 仅恢复本次提交触碰的字段；即使半写入导致 Validate 失败，也能恢复。
local function restoreCommit(player, story, records, treasures, record, contentId, snapshot)
    if DEFINITIONS[contentId] then
        rawset(record, "completed", snapshot.completed)
        if snapshot.marked ~= nil then rawset(record, "marked", snapshot.marked) end
        rawset(treasures, DEFINITIONS[contentId].rewardId, snapshot.rewardOwned)
    elseif snapshot.marked ~= nil then
        rawset(record, "marked", snapshot.marked)
    end
    if snapshot.keyConsumed then
        rawset(snapshot.keyMap, snapshot.keyId, snapshot.keyOwned)
    end
    if snapshot.keyGranted then
        rawset(snapshot.keyMap, snapshot.keyId, snapshot.keyOwned)
    end
    -- Player.Reset/Load 替换容器后，旧事务不得覆盖新玩家的体力。
    if rawget(player, "story") == story and rawget(player, "treasures") == treasures
        and rawget(story, "worldContent") == records then
        rawset(player, "stamina", snapshot.stamina)
    end
end

function Actions:_commit(receipt, ctx)
    local source = KEY_SOURCE_DEFINITIONS[receipt.contentId]
    local access, reason
    if source then
        access, reason = self:_eligibleKeySource(receipt.contentId, ctx)
        if access and (receipt.actionKind ~= source.action.kind
            or receipt.duration ~= source.action.duration
            or receipt.staminaCost ~= source.action.staminaCost) then
            access, reason = nil, "invalid_action_config"
        end
    else
        access, reason = self:_eligible(receipt.contentId, receipt.actionKind, ctx)
    end
    if not access then finish(self, receipt, "failed", reason); return false, reason end
    if receipt.epoch ~= self._epoch or receipt.entityId ~= access.entityId
        or not sameContext(ctx, readContext(self._adapter)) then
        finish(self, receipt, "failed", "stale_generation")
        return false, "stale_generation"
    end
    local player = ctx.player
    local snapshot = assert(Progress.Snapshot(player, receipt.contentId))
    snapshot.stamina = player.stamina
    local key = access.key
    if key.id ~= nil then
        snapshot.keyId, snapshot.keyMap, snapshot.keyOwned = key.id, key.map, key.owned
    end
    local record = rawget(ctx.records, receipt.contentId)
    receipt.commitState = "committing"
    ---@return boolean, string|nil
    local function applyCommit()
        -- 使用玩家公开扣费能力；测试可注入失败，提交外围负责恢复全部字段。
        local charged, chargeError = player:ConsumeStamina(receipt.staminaCost)
        if not charged then return false, chargeError or "stamina_charge_failed" end
        if not sameContext(ctx, readContext(self._adapter)) then return false, "stale_generation" end
        if source then
            local currentTreasures = rawget(player, "treasures")
            if type(currentTreasures) ~= "table" or rawget(currentTreasures, "keys") ~= key.map
                or rawget(key.map, key.id) ~= key.owned then
                return false, "key_source_changed"
            end
            local state, stateError = Progress.GetState(player, receipt.contentId)
            if not state then return false, stateError end
            if not state.marked then return false, "content_not_marked" end
            if key.owned == true then return false, "key_already_owned" end
            rawset(key.map, key.id, true)
            snapshot.keyGranted = true
        else
            local completed, commitError = Progress.Commit(player, receipt.contentId)
            if not completed or commitError == "already_completed" then
                return false, commitError or "progress_commit_failed"
            end
            if not sameContext(ctx, readContext(self._adapter)) then return false, "stale_generation" end
            if key.id ~= nil then
                local currentTreasures = rawget(player, "treasures")
                if type(currentTreasures) ~= "table" or rawget(currentTreasures, "keys") ~= key.map
                    or rawget(key.map, key.id) ~= true then
                    return false, "missing_key"
                end
                if key.consume then
                    rawset(key.map, key.id, false)
                    snapshot.keyConsumed = true
                end
            end
        end
        local valid, validationError = Progress.Validate(player)
        if not valid then return false, validationError end
        local state = assert(Progress.GetState(player, receipt.contentId))
        if source then
            if not state.marked or rawget(key.map, key.id) ~= true
                or player.stamina ~= snapshot.stamina - receipt.staminaCost then
                return false, "commit_consistency_failed"
            end
        elseif not state.completed or not state.rewardOwned
            or player.stamina ~= snapshot.stamina - receipt.staminaCost then
            return false, "commit_consistency_failed"
        end
        if key.id ~= nil and not source then
            local expectedKeyState = true
            if key.consume then expectedKeyState = false end
            if rawget(key.map, key.id) ~= expectedKeyState then
                return false, "key_consistency_failed"
            end
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
    if ctx.player.treasures.scopeLens ~= true then resetObservation(self); return true end
    local targetContentId
    for _, contentId in ipairs(LENS_CONTENT_IDS) do
        local state, reason = Progress.GetState(ctx.player, contentId)
        if not state then return false, reason end
        if not state.marked and not state.completed then
            local inside, err = query(self._adapter, "IsWorldContentInScope", contentId)
            if inside == true then
                targetContentId = contentId
                break
            elseif inside == nil then
                resetObservation(self)
                return false, err or "scope_unavailable"
            end
        end
    end
    if not targetContentId then resetObservation(self); return true end
    if self._observationTarget ~= targetContentId then resetObservation(self) end
    self._observationTarget = targetContentId
    if not sameContext(ctx, readContext(self._adapter)) then
        resetObservation(self)
        return false, "stale_generation"
    end
    self._observation = math.min(OBSERVATION_DURATION, self._observation + explicitElapsed)
    if self._observation >= OBSERVATION_DURATION then
        local marked, markError = Progress.Mark(ctx.player, targetContentId)
        if marked then resetObservation(self) end
        return marked, markError
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
    resetObservation(self)
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
    return { contentId = self._observationTarget or "underwater_treasure_01",
        elapsed = self._observation, duration = OBSERVATION_DURATION }
end

function Actions:GetOwnedTreasures()
    if self._busy then return nil, "busy" end
    local ctx, reason = self:_sync()
    if not ctx then return nil, reason end
    local result = {}
    for _, id in ipairs(IDS) do
        local reward = DEFINITIONS[id].rewardId
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
        local access = self:_eligible(id, kind, ctx, true)
        if access then
            local actionName = kind == "explore" and "探索岛屿" or "打捞宝藏"
            return { text = string.format("%s · %d体力", actionName, access.staminaCost),
                operation = "begin", contentId = id, actionKind = kind,
                staminaCost = access.staminaCost, canAffordStamina = access.canAffordStamina, enabled = true }
        end
    end
    return nil, "no_eligible_content"
end

return Actions
