-- B 玩法协调器；不依赖船位、World、鱼 FSM 或现有 Ocean 演示状态。
local Config = require("config.gameplay")
local Items = require("data.items")
local PlayerState = require("Gameplay.PlayerState")
local GameClock = require("Gameplay.GameClock")
local Persistence = require("Gameplay.Persistence")
local Actions = require("Gameplay.Actions")
local Diagnostics = require("Gameplay.Diagnostics")
local SoundSystem = require("Systems.SoundSystem")
local audioDiagPushed = false -- 音频诊断一次性上屏标记（真机静音排查，2026-10-08）
local Progress = require("Gameplay.Circle1B2Progress")
local Barrel = require("Gameplay.Circle1B2Barrel")
local WorldContentActions = require("Gameplay.WorldContentActions")
local WorldContentProgress = require("Gameplay.WorldContentProgress")
local V28Progress = require("Gameplay.V28Progress")
local V28ContentActions = require("Gameplay.V28ContentActions")
local MemoryFragments = require("Gameplay.MemoryFragments")
local EvidenceSystem = require("Gameplay.EvidenceSystem")
-- ②③ 认知度/成就系统执行器 + 跨局存档层
local KnowledgeSystem = require("Gameplay.KnowledgeSystem")
local AchievementSystem = require("Gameplay.AchievementSystem")
local ProfileStore = require("Gameplay.ProfileStore")
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
---@field endingAchievementsSettled boolean
---@field endingProfileSaveDispatched boolean
---@field saveStatus string
---@field lastMessage string
---@field shopStock table<string, integer>
---@field actions GameplayActions?
---@field inventoryRollback table?
---@field barrel Circle1B2Barrel
---@field worldContentActions WorldContentActions?
---@field worldContentAdapter table?
---@field v28Actions V28ContentActions?
---@field v28FeedbackToken number?
---@field v28Notice table?
---@field runtime table?
---@field throwSelection table?
---@field storyDialog table?
---@field scopeEnabled boolean
---@field scopeSyncError string?
---@field fishingSelectionHintPending boolean
---@field worldPreparation GameplayWorldPreparation?
---@field initialSaveStatus string
---@field initialSaveBusy boolean
---@field requestSequence integer
---@field lastSettlementSaveId integer?
local Loop = {}
-- V2.8（W-08 定稿）：三枚记忆碎片使用正式标题。
local WORLD_CONTENT_MEMORY_LABELS = {
    island_01 = "《有人牵着我的手》",
    island_02 = "《第一次自己走远》",
    underwater_treasure_01 = "《那盏还亮着的灯》",
}
Loop.__index = Loop

-- 逐物品正式对白尚未配置时，沿用现有交互反馈作为 fallback。
-- 后续内容只需通过 options.elderDialogues[itemId][action] 提供两行文本，
-- 无需改动给予/展示事务或 HUD 气泡结构。
local function elderExchange(self, itemId, action, fallbackPlayerLine, fallbackElderLine)
    local configured = self.options and self.options.elderDialogues
    configured = type(configured) == "table" and configured[itemId] or nil
    configured = type(configured) == "table" and configured[action] or nil
    local playerLine = type(configured) == "table" and configured.playerLine or nil
    local elderLine = type(configured) == "table" and configured.elderLine or nil
    local hasConfiguredCopy = type(playerLine) == "string" and playerLine ~= ""
        and type(elderLine) == "string" and elderLine ~= ""
    return {
        itemId = itemId,
        action = action,
        playerLine = hasConfiguredCopy and playerLine or fallbackPlayerLine,
        elderLine = hasConfiguredCopy and elderLine or fallbackElderLine,
        fallback = not hasConfiguredCopy,
    }
end

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
    self.actionToastSequence = 0
    self:ResetState()
    self.barrel = Barrel.New(self)
end

function Loop:ResetState()
    if self.inventoryRollback then return false, "inventory_rollback_pending" end
    local autoCancelled, autoCancelError = self:CancelAutoReturn("state_reset")
    if not autoCancelled then return false, autoCancelError or "auto_return_cancel_failed" end
    local contentInvalidated, contentInvalidateError = self:InvalidateWorldContent("stale_generation")
    if not contentInvalidated then return false, contentInvalidateError end
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
    local contentInitialized, contentInitializeError = WorldContentProgress.Initialize(self.player)
    assert(contentInitialized, contentInitializeError or "invalid_world_content_progress")
    local evidenceInitialized, evidenceInitializeError = EvidenceSystem.ResetRun(self.player)
    assert(evidenceInitialized, evidenceInitializeError or "invalid_hypothesis_progress")
    Progress.OnDayStarted(self.player)
    -- ②③ 认知度/成就系统接线：profile 跨周目仅建一次；KS/AS 每局随 player 重建
    if not self.profileStore then
        self.profileStore = ProfileStore.New()
        self.profileStore:Load(function(ok)
            if ok then Diagnostics.Call("Loop", "profile_loaded", function() end) end
        end)
    end
    if self.currentWeek == nil then self.currentWeek = 1 end
    self:SetupKnowledgeSystems()
    self:ResetShopStock()
    self.clock = GameClock.New()
    self.inPort = true
    self.inventoryOpen, self.elderOpen = false, false
    self.forcedReturnPending, self.settlementPending = false, false
    self.dayExhausted, self.settlementApplied = false, false
    self.busy, self.loading = false, false
    self.dropInFlight = false
    self.saveStatus, self.lastMessage = "idle", "新周目已开始"
    self.worldContentFeedbackToken, self.actionToast = nil, nil
    self.v28FeedbackToken, self.v28Notice = nil, nil
    self.v28NetChoice = nil
    self.portNightElapsed = 0
    self.settlementForced = false
    self.settlementSnapshot = {}
    -- T1：第 7 天结算进入结局；NewRun/读档重置。
    self.endingPending, self.endingKind = false, nil
    self.endingAchievementsSettled, self.endingProfileSaveDispatched = false, false
    self.throwSelection, self.storyDialog, self.scopeEnabled = nil, nil, false
    self.throwPicker = nil
    self.fishingSelectionHintPending = false
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
    SoundSystem.Reset()
    return true
end

function Loop:Ready()
    return not self.closed and not self.endingPending and not self.entryPending
        and not self.busy and not self.loading and not self.dropInFlight
        and not self.inventoryRollback
        and not self.forcedReturnPending and not self.settlementPending
        and not (self.actions and self.actions:IsBusy())
        and not (self.barrel and self.barrel:IsBusy()) and not self.storyDialog
        and not (self.worldContentActions and self.worldContentActions:GetActionState())
        and not (self.v28Actions and self.v28Actions:GetActionState())
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
    if self.closed then return end
    if self.knowledge then self.knowledge:Update(dt) end  -- ②③ 0.25s 轮询观测 SurfaceSignals
    self:RetryInventoryRollback()
    if self.barrel then self.barrel:Tick() end
    local actions, clock = self.actions, self.clock
    if actions then actions:ValidateGeneration() end
    if actions and clock.exhausted then
        actions:CancelActiveFishing("night_interrupted")
    end
    local worldContentElapsed = 0
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
        SoundSystem.SyncAmbient(clock.phase, not self.inPort)  -- 港内保持暂停声床，出航后同步昼夜声床
        -- 音频诊断（真机静音排查 2026-10-08）：启动 2 秒后把音频状态推到状态行一次，
        -- 不依赖「开发调试」按钮（该按钮曾被透明 catcher 遮挡点不动）。
        if not audioDiagPushed and clock.elapsed >= 2 then
            audioDiagPushed = true
            local okDiag, diag = pcall(SoundSystem.Status)
            if okDiag and type(diag) == "string" and #diag > 0 then
                self.lastMessage = "音频：" .. diag
            end
        end
        -- V2.7（W-15 废止）：入夜不再自动弹系统文字报时；时间判断交给太阳/月亮/天空
        -- 与现有 HUD 时间信息。D1 老人一次性讲清 15/30 秒规则（见 D1 教学）。
        -- 夜尽到港/日结仍可显示客观结果反馈（不在此处提前倒计时）。
        local after = clock.elapsed + (clock.phase == "night" and clock.daySec or 0)
        local gameSeconds = math.max(0, after - before)
        if not clock:IsPaused() and not clock.exhausted and not self.inPort then
            worldContentElapsed = worldContentElapsed + gameSeconds
        end
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
    self:ProcessEmergenceEvents(dt > 0)
    self:ProcessContextTeaching(dt > 0)
    if self.worldContentActions then
        local token = self.worldContentFeedbackToken
        local receipt
        local receiptOk = false
        if token ~= nil then
            receiptOk, receipt = pcall(
                self.worldContentActions.GetReceipt, self.worldContentActions, token)
            if not receiptOk then receipt = nil end
        end
        local completedReceipt = type(receipt) == "table" and receipt.status == "completed"
            and receipt.commitState == "committed"
        local callOk, advanced, result
        if completedReceipt then
            callOk, advanced, result = true, true, "completed"
        else
            callOk, advanced, result = Diagnostics.Call("Loop", "world_content_advance",
                self.worldContentActions.Advance, self.worldContentActions, worldContentElapsed)
        end
        if token ~= nil then
            if callOk and advanced == true and result == "completed" then
                if not completedReceipt then
                    receiptOk, receipt = pcall(
                        self.worldContentActions.GetReceipt, self.worldContentActions, token)
                end
                if receiptOk and type(receipt) == "table" and receipt.status == "completed"
                    and receipt.commitState == "committed" then
                    local newlyOwned = type(receipt.begin) == "table"
                        and receipt.begin.completed == false and receipt.begin.rewardOwned == false
                    local story = newlyOwned
                        and MemoryFragments.GetOwnedStory(self.player, receipt.contentId) or nil
                    -- An earlier story modal (for example D2/D3 teaching) may own this frame.
                    -- Keep the completed receipt token until that modal closes, then show W-08.
                    if not story or not self.storyDialog then
                        local cost = tonumber(receipt.staminaCost) or 0
                        local remaining = math.floor(tonumber(self.player.stamina) or 0)
                        local feedback = string.format("消耗%d体力，剩余%d体力", cost, remaining)
                        local memoryName = WORLD_CONTENT_MEMORY_LABELS[receipt.contentId]
                        if memoryName then
                            self:QueueActionToast("获得记忆：" .. memoryName .. "\n" .. feedback, 3)
                        else
                            self:QueueActionToast(feedback, 3)
                        end
                        if story then
                            self.storyDialog = { token = {}, kind = "memory_fragment",
                                title = story.title, text = story.text }
                            self.clock:Pause("story")
                        end
                        self.lastMessage = ""
                        self.worldContentFeedbackToken = nil
                    end
                else
                    self.lastMessage = ""
                    self.worldContentFeedbackToken = nil
                end
            elseif not callOk or result ~= "active" then
                self.worldContentFeedbackToken = nil
            end
        end
    end
    self:AdvanceV28Actions(worldContentElapsed)
end

---V2.8 固定海上内容的 4 秒事务与探海镜 1 秒标记推进。
---@param elapsed number
function Loop:AdvanceV28Actions(elapsed)
    local actions = self.v28Actions
    if not actions then return end
    local token = self.v28FeedbackToken
    local receipt
    if token ~= nil then
        local ok, value = pcall(actions.GetReceipt, actions, token)
        if ok then receipt = value end
    end
    local completed = type(receipt) == "table" and receipt.status == "completed"
        and receipt.commitState == "committed"
    local callOk, advanced, result
    if completed then
        callOk, advanced, result = true, true, "completed"
    else
        callOk, advanced, result = Diagnostics.Call("Loop", "v28_action_advance",
            actions.Advance, actions, elapsed)
    end
    if token ~= nil then
        if callOk and advanced == true and result == "completed" then
            if not completed then
                local ok, value = pcall(actions.GetReceipt, actions, token)
                if ok then receipt = value end
            end
            if type(receipt) == "table" and receipt.status == "completed"
                and receipt.commitState == "committed" then
                self:FinishV28Receipt(receipt)
            else
                self.lastMessage = ""
                self.v28FeedbackToken = nil
            end
        elseif not callOk or result ~= "active" then
            self.v28FeedbackToken = nil
        end
    end
    -- 探海镜 1 秒标记/识别：顶部轻提示一次，不写盘、不暂停世界。
    local notice = actions:ConsumeLensNotice()
    if notice and type(notice.text) == "string" and notice.text ~= "" then
        self:QueueActionToast(notice.text, 3)
    end
end

---V2.8 4 秒事务成功后的统一反馈（沉船 / 浮藻假岛 / 破渔网分支A）。
---@param receipt table
function Loop:FinishV28Receipt(receipt)
    local definition = V28ContentActions.Definition(receipt.contentId)
    local action = definition and (definition.v28Action
        or (definition.net and definition.net.branchA)) or nil
    local cost = tonumber(receipt.staminaCost) or 0
    local staminaLeft = math.floor(tonumber(self.player.stamina) or 0)
    local lines = {}
    if action and type(action.successText) == "string" and action.successText ~= "" then
        lines[#lines + 1] = action.successText
    end
    if receipt.contentId == "trapped_net_01" then
        lines[#lines + 1] = "你把两条小鱼收进了船舱。网底那把旧钥匙在拉扯中崩断绳结，沉入了深海。"
    end
    lines[#lines + 1] = string.format("消耗%d体力，剩余%d体力", cost, staminaLeft)
    local text = table.concat(lines, "\n")
    self.lastMessage = ""
    self.v28FeedbackToken = nil
    if action and type(action.successText) == "string" and action.successText ~= "" then
        self.storyDialog = { token = {}, kind = "v28_result", text = text }
        self.clock:Pause("story")
    else
        self:QueueActionToast(text, 4)
    end
end

---当前可用的 V2.8 动态场景按钮（观察/拾取/探索/打捞）。
---@return table|nil, string|nil
function Loop:GetV28Prompt()
    local actions = self.v28Actions
    if not actions then return nil, "v28_unavailable" end
    local active = actions:GetActionState()
    if active then return actions:GetPrompt() end
    if self.inPort or self.clock:IsPaused() or self.clock.exhausted or self.inventoryOpen
        or self.elderOpen or self:HasPendingCatch() or not self:Ready() then
        return nil
    end
    -- 捕鱼选点 / 投放选点 / 4 秒动作期间统一隐藏 0 体力场景按钮。
    local fishing = self:GetFishingState()
    if fishing and fishing.state ~= "idle" then return nil end
    if self:GetThrowSelection() or self:GetThrowPicker() then return nil end
    if self:IsMovementBlocked() then return nil end
    return actions:GetPrompt()
end

---0 体力场景观察（礁石 / 木板 / 海眼）。
---@param contentId string
---@return boolean, string|nil
function Loop:ObserveV28Content(contentId)
    local actions = self.v28Actions
    if not actions then return false, "v28_unavailable" end
    if not self:CanStartV28SceneAction() then return false, "action_blocked" end
    local cancelled, cancelError = self:CancelAutoReturn("v28_observe")
    if not cancelled then return false, cancelError or "auto_return_cancel_failed" end
    if self.runtime and type(self.runtime.ClearMovementTarget) == "function" then
        self.runtime:ClearMovementTarget()
    end
    local ok, reason, detail = actions:Observe(contentId)
    if not ok then
        self.lastMessage = tostring(reason or "content_not_observable")
        return false, reason
    end
    self.lastMessage = detail and detail.text or ""
    self.v28Notice = detail
    return true
end

---0 体力拾取固定漂流瓶；残页进独立道具栏。
---@param contentId string
---@return boolean, string|nil
function Loop:PickupV28Content(contentId)
    local actions = self.v28Actions
    if not actions then return false, "v28_unavailable" end
    if not self:CanStartV28SceneAction() then return false, "action_blocked" end
    local cancelled, cancelError = self:CancelAutoReturn("v28_pickup")
    if not cancelled then return false, cancelError or "auto_return_cancel_failed" end
    if self.runtime and type(self.runtime.ClearMovementTarget) == "function" then
        self.runtime:ClearMovementTarget()
    end
    local ok, reason, detail = actions:Pickup(contentId)
    if not ok then
        self.lastMessage = tostring(reason or "content_not_pickable")
        return false, reason
    end
    self.lastMessage = detail and detail.text or ""
    -- 拾取后立即弹出残页阅读模态（可随时重读；不消耗物品）。
    if detail and type(detail.readText) == "string" and detail.readText:match("%S") then
        self.storyDialog = { token = {}, kind = "v28_note",
            title = detail.readTitle or "航海残页", text = detail.readText }
        self.clock:Pause("story")
    end
    return true
end

---0 体力场景动作（观察/拾取）通用门禁。
---@return boolean
function Loop:CanStartV28SceneAction()
    if not self:Ready() or self.inPort or self.clock:IsPaused() or self.clock.exhausted then return false end
    if self:HasPendingCatch() or self:GetThrowSelection() or self:GetThrowPicker() then return false end
    local fishing = self:GetFishingState()
    if fishing and fishing.state ~= "idle" then return false end
    return true
end

---开始 40 体力/4 秒打捞（沉船 / 浮藻假岛货箱）。
---@param contentId string
---@return boolean, string|nil
function Loop:BeginV28Salvage(contentId)
    local actions = self.v28Actions
    if not actions then return false, "v28_unavailable" end
    if not self:CanStartV28SceneAction() then return false, "action_blocked" end
    if self.v28FeedbackToken ~= nil then return false, "action_pending" end
    local definition = V28ContentActions.Definition(contentId)
    local action = definition and definition.v28Action
    if not action then return false, "invalid_content_id" end
    if not self.player:CanConsumeStamina(action.staminaCost) then
        self.lastMessage = action.refusals and action.refusals.insufficient_stamina
            or string.format("体力不足，这个动作需要%d体力。", action.staminaCost)
        return false, "insufficient_stamina"
    end
    local cancelled, cancelError = self:CancelAutoReturn("v28_salvage")
    if not cancelled then return false, cancelError or "auto_return_cancel_failed" end
    local token, reason = actions:BeginAction(contentId)
    if not token then
        local refusal = action.refusals and action.refusals[reason]
        self.lastMessage = refusal or tostring(reason or "action_rejected")
        return false, reason
    end
    self.v28FeedbackToken = token
    self.lastMessage = action.beginText or "开始打捞"
    return true
end

---破渔网双分支：A=40体力/4秒收网，B=0体力即时割网。
---@param contentId string
---@param branch string "A"|"B"
---@return boolean, string|nil
function Loop:ResolveTrappedNet(contentId, branch)
    local actions = self.v28Actions
    if not actions then return false, "v28_unavailable" end
    if not self:CanStartV28SceneAction() then return false, "action_blocked" end
    if branch == "B" then
        local cancelled, cancelError = self:CancelAutoReturn("v28_net_cut")
        if not cancelled then return false, cancelError or "auto_return_cancel_failed" end
        local runtime = self.runtime
        local release = runtime and type(runtime.ReleaseFishAtContent) == "function"
            and function(species, count) return runtime:ReleaseFishAtContent(contentId, species, count) end
            or nil
        local ok, reason, detail = actions:ResolveNetCut(contentId, release)
        if not ok then
            self.lastMessage = tostring(reason or "net_resolution_failed")
            return false, reason
        end
        self.lastMessage = detail and detail.text or ""
        if detail and type(detail.text) == "string" and detail.text:match("%S") then
            self.storyDialog = { token = {}, kind = "v28_result", text = detail.text }
            self.clock:Pause("story")
        end
        return true
    end
    if branch ~= "A" then return false, "invalid_branch" end
    local definition = V28ContentActions.Definition(contentId)
    local action = definition and definition.net and definition.net.branchA
    if not action then return false, "invalid_content_id" end
    if not self.player:CanConsumeStamina(action.staminaCost) then
        self.lastMessage = action.refusals.insufficient_stamina
        return false, "insufficient_stamina"
    end
    if not self.player.inventory:HasSpace(action.freeSlots or 0) then
        self.lastMessage = action.refusals.inventory_full
        return false, "inventory_full"
    end
    local cancelled, cancelError = self:CancelAutoReturn("v28_net_collect")
    if not cancelled then return false, cancelError or "auto_return_cancel_failed" end
    local token, reason = actions:BeginNetCollect(contentId)
    if not token then
        self.lastMessage = (action.refusals and action.refusals[reason]) or tostring(reason or "action_rejected")
        return false, reason
    end
    self.v28FeedbackToken = token
    self.lastMessage = "开始收网"
    return true
end

---V2.8：打开破渔网双分支选择面板（0 体力，不暂停世界）。
---@param contentId string
---@return boolean, string|nil
function Loop:OpenTrappedNetChoice(contentId)
    local definition = V28ContentActions.Definition(contentId)
    if not definition or not definition.net then return false, "content_not_net" end
    local state = V28Progress.GetProgressState(self.player, contentId)
    if not state or state.completed then return false, "already_completed" end
    if not self:CanStartV28SceneAction() then return false, "action_blocked" end
    self.v28NetChoice = contentId
    return true
end

---@return string|nil
function Loop:GetTrappedNetChoice()
    return self.v28NetChoice
end

---@return boolean
function Loop:CloseTrappedNetChoice()
    self.v28NetChoice = nil
    return true
end

---取消当前 V2.8 4 秒事务（免费、不发奖、不改状态）。
---@param token number|nil
---@return boolean, string|nil
function Loop:CancelV28Action(token)
    local actions = self.v28Actions
    if not actions then return true, "idle" end
    local active = actions:GetActionState()
    if not active then return true, "idle" end
    local target = token or active.token
    local cancelled, reason = actions:Cancel(target, "cancelled")
    if cancelled and self.v28FeedbackToken == target then self.v28FeedbackToken = nil end
    return cancelled, reason
end

---V2.8：使用/查看独立道具栏持有物（航海残页重读、生锈钥匙查看）。
---@param treasureId string
---@return boolean, string|nil
function Loop:UseV28Treasure(treasureId)
    if not V28Progress.HasTreasure(self.player, treasureId) then return false, "treasure_unavailable" end
    local definition = Items.GetDefinition(treasureId)
    if not definition then return false, "treasure_unavailable" end
    if not self:CanManageInventory() and not self.inPort then return false, "busy" end
    if type(definition.useText) == "string" and definition.useText ~= "" then
        if definition.readTitle then
            self.storyDialog = { token = {}, kind = "v28_note",
                title = definition.readTitle, text = definition.useText }
            self.clock:Pause("story")
        else
            self.lastMessage = definition.useText
            self:QueueActionToast(definition.useText, 4)
        end
        return true
    end
    self.lastMessage = definition.name .. "没有可用的使用效果。"
    return false, "item_has_no_use"
end

---V2.8：向老人展示独立道具栏持有物（不消耗）。
---@param treasureId string
---@return boolean, string|nil
function Loop:ShowV28TreasureToElder(treasureId)
    local present, reason = self:IsElderPresent()
    if not present then
        self.lastMessage = "老人已经不在了，无法再把东西交给他。"
        return false, reason or "elder_not_present"
    end
    if not self.elderOpen then return false, "elder_dialog_required" end
    if not self:CanManageInventory() then return false, "busy" end
    if not V28Progress.HasTreasure(self.player, treasureId) then return false, "treasure_unavailable" end
    local definition = Items.GetDefinition(treasureId)
    if not definition then return false, "treasure_unavailable" end
    self.lastMessage = definition.elderText or ("向老人展示了" .. definition.name .. "，物品仍保留。")
    return true, self.lastMessage, elderExchange(self, treasureId, "show",
        "展示 " .. definition.name, self.lastMessage)
end

---读取 V2.8 独立道具栏持有物（航海残页 / 生锈钥匙）。
---@return string[]
function Loop:GetV28Treasures()
    local result = {}
    for _, id in ipairs({ "sea_note_01", "sea_note_02", "rusty_key" }) do
        if V28Progress.HasTreasure(self.player, id) then result[#result + 1] = id end
    end
    return result
end

---V2.8 Closure：独立道具栏的逐件操作视图（供 HUD 真实按钮使用）。
---每项固定给出使用/给老人/丢弃三个动作及其是否可用、禁用原因。
---航海残页与生锈钥匙都不可丢弃（策划：独立道具栏、不可丢弃）。
---@return table[]
function Loop:GetV28TreasureActions()
    local result = {}
    local elderPresent = self:IsElderPresent() == true
    for _, id in ipairs(self:GetV28Treasures()) do
        local definition = Items.GetDefinition(id)
        if definition then
            result[#result + 1] = {
                treasureId = id,
                name = definition.name,
                useLabel = definition.readTitle and "重读" or "查看",
                canUse = true,
                canGive = definition.canGive == true,
                giveDisabledReason = elderPresent and nil or "老人已经不在了。",
                canDiscard = false,
                discardDisabledReason = definition.name .. "是独立道具栏的关键物品，不能丢弃。",
            }
        end
    end
    return result
end

---V2.8 Closure：独立道具栏物品的【丢弃】尝试（策划：不可丢弃，给出明确原因）。
---@param treasureId string
---@return boolean, string
function Loop:DiscardV28Treasure(treasureId)
    local definition = Items.GetDefinition(treasureId)
    if not definition or not V28Progress.HasTreasure(self.player, treasureId) then
        self.lastMessage = "物品已不存在。"
        return false, "treasure_unavailable"
    end
    self.lastMessage = definition.name .. "是独立道具栏的关键物品，不能丢弃。"
    return false, "treasure_protected"
end

---V2.8 内容周目状态（供 HUD / 绘制只读查询）。
---@param contentId string
---@return table|nil
function Loop:GetV28State(contentId)
    return V28Progress.GetProgressState(self.player, contentId)
end

---海眼珍珠是否已在周目内领取（卖/丢后仍为 true）。
---@return boolean
function Loop:IsVortexPearlClaimed()
    return V28Progress.IsPearlClaimed(self.player)
end

---V2.8 海眼：本周目首次正式投放大鱼 → 深海珍珠原子结算。
---同一事务里：消耗大鱼（调用方已从船舱移除）→ 释放 1 格 → 珍珠直接进该格
---→ vortexPearlClaimed=true。后置演出失败不回滚本事务。
---@param payload table 已由 WorldDrop 接受的投放载荷
---@return boolean, string|nil
function Loop:ClaimVortexPearl(payload)
    local player = self.player
    if V28Progress.IsPearlClaimed(player) then return false, "pearl_already_claimed" end
    local pearl = "abyss_pearl"
    if not Items.GetDefinition(pearl) then return false, "invalid_pearl_item" end
    -- 释放的 1 格就是刚被移除的大鱼腾出的格位；此处只要求存在空位。
    if not player.inventory:HasSpace(1) then return false, "inventory_full" end
    local items = player.inventory:GetItems()
    local stamina = player.stamina
    local added, addError = player.inventory:Add(pearl)
    if not added then return false, addError or "inventory_add_failed" end
    local flagged, flagError = V28Progress.SetPearlClaimed(player, true)
    if not flagged then
        player.inventory:RestoreItems(items)
        player.stamina = stamina
        return false, flagError or "pearl_claim_failed"
    end
    local valid, validError = V28Progress.Validate(player)
    if not valid then
        player.inventory:RestoreItems(items)
        V28Progress.SetPearlClaimed(player, false)
        return false, validError or "pearl_claim_failed"
    end
    self.lastMessage = "海眼深处翻涌了一下，吐出一颗【深海珍珠】。"
    if payload then payload.vortexPearl = pearl end
    return true, "claimed"
end

---V2.8 海眼：已领取过珍珠后再次投大鱼——仍正常消耗，不再产珍珠。
---@param payload table
---@return boolean
function Loop:ConsumeVortexBigFish(payload)
    if payload then payload.vortexConsumed = true end
    self.lastMessage = "海眼把大鱼卷了进去，这一次没有再吐出什么。"
    return true
end

-- Only a fresh, currently observable commuter-flock event can enter the
-- hypothesis. SurfaceSignals fishing birds do not use this path.
function Loop:ProcessEmergenceEvents(allowObservation)
    local runtime, player, clock = self.runtime, self.player, self.clock
    local world = runtime and runtime.world
    if not world or type(world.DrainEvents) ~= "function" then return false, "world_unavailable" end

    local active = allowObservation == true and not self.closed and not self.inPort
        and clock ~= nil and not clock:IsPaused() and not clock.exhausted
        and player ~= nil and type(player.IsRecognized) == "function"
        and runtime.movement ~= nil and runtime.movement.viewportReady == true
        and type(runtime.BuildTraceObservation) == "function"
    if active then
        local state, stateError = EvidenceSystem.GetState(player, "H-isle-bearing-01")
        local hasEvidence, evidenceError = EvidenceSystem.HasEvidenceForDay(
            player, "H-isle-bearing-01", player.day)
        if state and not state.confirmed and hasEvidence == false and not evidenceError
            and not player:IsRecognized("island_02") then
            local observation = runtime:BuildTraceObservation(
                "flock_commute", player.day, false)
            if observation then world:Emit(observation) end
        elseif stateError or evidenceError then
            Diagnostics.Event("Loop", "hypothesis_observation_rejected", {
                reason = stateError or evidenceError, hypothesis_id = "H-isle-bearing-01",
            })
        end
    end

    local generation = type(runtime.GetFixedContentGeneration) == "function"
        and runtime:GetFixedContentGeneration() or nil
    for _, event in ipairs(world:DrainEvents()) do
        if event.type == "observation_recorded" and active and event.traceId == "flock_commute"
            and event.day == player.day and event.generation == generation then
            local recognized = player:IsRecognized("island_02")
            local current = runtime:BuildTraceObservation("flock_commute", player.day, recognized)
            if current then
                local bearingDelta = math.abs(event.bearing - current.bearing) % 360
                if bearingDelta > 180 then bearingDelta = 360 - bearingDelta end
                if bearingDelta <= 1e-9 and event.sourceContentId == current.sourceContentId
                    and event.traceType == current.traceType and event.birdCount == current.birdCount
                    and event.dives == current.dives and event.circlesFish == current.circlesFish
                    and event.observable == true then
                    local accepted, result, state = EvidenceSystem.RecordObservation(
                        player, event, self.knowledge,
                        { day = player.day, generation = generation })
                    if accepted and result == "confirmed" and state then
                        self.lastMessage = state.hint
                        Diagnostics.Event("Loop", "hypothesis_confirmed", {
                            hypothesis_id = state.hypothesisId, knowledge_id = "K-isl-1",
                            distinct_days = state.distinctDays,
                        })
                    end
                end
            end
        end
    end
    return true
end

-- V2.7 同行情境教学（D2 海鸟 / D3 水花）：使用 Runtime 与 SeaDraw 共用的
-- broad-phase 绘制准入判断当前活跃信号是否具备触发资格；这不是像素级可见证明。
-- 对应日未满足准入则保持未置位，顺延到以后第一次满足时再触发。
-- 世界暂停/在港/已耗尽/已有剧情模态时不判定，避免在错误时机弹出。
local MIN_TEACHING_DAY = { bird = 2, splash = 3 }

---@param allowObservation boolean
---@return boolean
function Loop:ProcessContextTeaching(allowObservation)
    if allowObservation ~= true then return false end
    if self.inPort or self.closed then return false end
    local clock = self.clock
    if not clock or clock:IsPaused() or clock.exhausted then return false end
    if self.storyDialog or self:HasPendingCatch() then return false end
    if not self:IsElderPresent() then return false end
    local runtime = self.runtime
    if not runtime or type(runtime.HasSurfaceSignalInView) ~= "function" then return false end

    local day = tonumber(self.player.day) or 1
    -- 海鸟优先于水花（剧情与事件 R34：前期海鸟教学先于水花教学）。
    if day >= (MIN_TEACHING_DAY.bird or 2)
        and Progress.IsTeachingShown(self.player, "bird") == false then
        local ok, inView = pcall(runtime.HasSurfaceSignalInView, runtime, "bird")
        if ok and inView == true then
            local line = self:TryShowContextTeaching("bird")
            if line then self.lastMessage = line; return true end
        end
    end
    if day >= (MIN_TEACHING_DAY.splash or 3)
        and Progress.IsTeachingShown(self.player, "splash") == false then
        local ok, inView = pcall(runtime.HasSurfaceSignalInView, runtime, "splash")
        if ok and inView == true then
            local line = self:TryShowContextTeaching("splash")
            if line then self.lastMessage = line; return true end
        end
    end
    return false
end

function Loop:RefreshClockStatus()
    if self.clock.exhausted and not self.dayExhausted then
        self:CancelAutoReturn("night_forced_return")
        self:CancelWorldContentAction(nil, "night_interrupted")
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
    if self.clock.pauseReasons.manual then
        self.clock:Resume("manual")
    else
        local cancelled, reason = self:CancelAutoReturn("manual_pause")
        if not cancelled then return false, reason or "auto_return_cancel_failed" end
        self.clock:Pause("manual")
    end
    return true, self.clock:IsPaused()
end

function Loop:CancelAutoReturn(reason)
    local runtime = self.runtime
    if not runtime then return true end
    if type(runtime.CancelAutoReturn) ~= "function" then return false, "auto_return_unavailable" end
    return runtime:CancelAutoReturn(reason)
end

function Loop:GetAutoReturnState()
    local runtime = self.runtime
    if not runtime or type(runtime.GetAutoReturnState) ~= "function" then
        return nil, "auto_return_unavailable"
    end
    local ok, state = pcall(runtime.GetAutoReturnState, runtime)
    if not ok or type(state) ~= "table" then return nil, "auto_return_state_unavailable" end
    -- Keep navigation diagnostics owned by AutoNavigation; callers receive only
    -- the phase needed to present current controls and the failure reason.
    return { phase = state.phase, failureReason = state.failureReason,
        cancelReason = state.cancelReason, distance = state.distance }
end

function Loop:IsAutoReturnActive()
    local state = self:GetAutoReturnState()
    return state ~= nil and (state.phase == "active" or state.phase == "arrival_ready")
end

function Loop:RequestAutoReturn()
    local runtime = self.runtime
    if not runtime or type(runtime.StartAutoReturn) ~= "function" then return false, "auto_return_unavailable" end
    if self.inPort or self.clock:IsPaused() or self.clock.exhausted then return false, "action_blocked" end
    if self:HasPendingCatch() then return false, "pending_catch_required" end
    if not self:Ready() or self:IsMovementBlocked() then return false, "busy" end
    return runtime:StartAutoReturn()
end

function Loop:GetReturnActionMode()
    if self.inPort then return "depart" end
    if self:IsAutoReturnActive() then return "cancel_auto_return" end
    local near = self:CanAccessPort()
    return near and "return_to_port" or "request_auto_return"
end

function Loop:SetMessage(message)
    self.lastMessage = message
end

---入队一个短暂的中央结果提示；HUD 显示后以 id 确认消费。
function Loop:QueueActionToast(text, durationSec)
    if type(text) ~= "string" or text == "" then return false, "invalid_toast_text" end
    self.actionToastSequence = (self.actionToastSequence or 0) + 1
    self.actionToast = {
        id = self.actionToastSequence,
        text = text,
        durationSec = type(durationSec) == "number" and durationSec > 0 and durationSec or 3,
    }
    return true, self.actionToast.id
end

function Loop:GetActionToast()
    -- A story modal has priority; leave its action toast queued for delivery after close.
    if self.storyDialog then return nil end
    local toast = self.actionToast
    if not toast then return nil end
    return { id = toast.id, text = toast.text, durationSec = toast.durationSec }
end

function Loop:AcknowledgeActionToast(id)
    if not self.actionToast or self.actionToast.id ~= id then return false end
    self.actionToast = nil
    return true
end

function Loop:RecognizeLocation(locationId)
    local story = self.player.story
    local storyRecord = type(story) == "table" and story.circle1B2 or nil
    if self.endingPending or (storyRecord and storyRecord.runCompleted == true) then
        return false, "ending_already_pending"
    end
    local wasRecognized = self.player:IsRecognized(locationId)
    local marked, markError = self.player:MarkRecognized(locationId)
    if not marked then return false, markError or "recognition_rejected" end
    local newlyRecognized = not wasRecognized
    -- V2.8：浮藻假岛 20m 识破为藻层——顶部轻提示一次，不新增 shown 存档。
    if newlyRecognized then
        local definition = V28ContentActions.Definition(locationId)
        if definition and type(definition.recognizeText) == "string" then
            V28Progress.MarkRecognized(self.player, locationId)
            self:QueueActionToast(definition.recognizeText, 4)
        end
    end
    return true, newlyRecognized
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
    -- V2.7（系统规则 A16）：4 秒高成本事务进行中禁止打开船舱。
    -- 木桶待领奖（pending）不算 IsBusy，仍允许腾格。
    if not self:Ready() and not (open and self:CanManageInventory()) then return false, "busy" end
    if open then
        local cancelled, reason = self:CancelAutoReturn("inventory_open")
        if not cancelled then return false, reason or "auto_return_cancel_failed" end
    end
    self.inventoryOpen = open
    if open then self.clock:Pause("inventory") else self.clock:Resume("inventory") end
    return true
end

function Loop:SetElderOpen(open)
    local present, reason = self:IsElderPresent()
    if open and not present then
        -- V2.7：老人离世后入口仍可点，只说明原因且不消耗。
        self.lastMessage = "老人已经不在了，无法再把东西交给他。"
        return false, reason or "elder_not_present"
    end
    if type(open) ~= "boolean" then return false, "busy" end
    -- V2.7（系统规则 A16）：4 秒事务期间禁止插入老人互动。
    if not self:Ready() and not self:CanManageInventory() then return false, "busy" end
    if open then
        local cancelled, cancelError = self:CancelAutoReturn("elder_open")
        if not cancelled then return false, cancelError or "auto_return_cancel_failed" end
    end
    self.elderOpen = open
    if open then self.clock:Pause("elder") else self.clock:Resume("elder") end
    if open then SoundSystem.EnterElder() else SoundSystem.ExitElder() end  -- 老人环境声床：拜访期间循环，结束对话切回世界声床
    return true
end

---@return boolean, string?, GameplayPortAccessDetails?
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
    local autoCancelled, autoCancelError = self:CancelAutoReturn(reason or "port_preparation")
    if not autoCancelled then return false, autoCancelError or "auto_return_cancel_failed" end
    self:CancelWorldContentAction(nil, reason or "port_preparation")
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
    local cancelled, cancelError = self:CancelAutoReturn("return_to_port")
    if not cancelled then return reject(cancelError or "auto_return_cancel_failed", "failure") end
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
        SoundSystem.SyncAmbient(self.clock.phase, false)
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
    SoundSystem.SyncAmbient(self.clock.phase, false)
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
    SoundSystem.SyncAmbient(self.clock.phase, true)
    self.lastMessage = "已出航"
    -- V2.7：D1 首次出航进入海上时，由同行老人一次性教停船投饵 + 晚归规则。
    -- 用顶部轻量提示（05 页 R14：教学/知识提示不进模态队列、不暂停世界），
    -- 因此不破坏「出航解除港口暂停」的既有契约。
    -- 两条教学共存时不能互相覆盖：先收集本次真正新触发的文本，
    -- 再合并成一条可读的顶部提示（同一帧不丢任何一条）。
    local teachingLines = {}
    local basicText = self:TryShowContextTeaching("basic")
    if basicText then teachingLines[#teachingLines + 1] = basicText end
    local advancedText = self:TryShowAdvancedTeaching()
    if advancedText then teachingLines[#teachingLines + 1] = advancedText end
    if #teachingLines > 0 then
        self.lastMessage = table.concat(teachingLines, "\n")
    end
    return true
end

-- V2.7（W-03）：救活路线 D4～D7，老人继续同行并每天给一条进阶短教学。
-- 只在当天首次出航时提一次；不要求玩家已取得探海镜或探索成功。
local ADVANCED_TEACHING_TEXT = {
    [4] = "远远看见个影子，不等于知道它是什么。得靠近到二十来米，才认得出来。",
    [5] = "认出来了，再想想能不能动手探索。岛上的东西，可不会自己跑到你船上。",
    [6] = "这片海不会替你做决定。看见、猜一猜，再自己去试。",
    [7] = "这么些天，你已经能自己读懂这片海了。剩下的，往后慢慢看。",
}

---@return boolean
function Loop:TryShowAdvancedTeaching()
    local day = tonumber(self.player.day) or 1
    local text = ADVANCED_TEACHING_TEXT[day]
    if not text then return false end
    if not self:IsElderPresent() then return false end
    if Progress.IsAdvancedTeachingShownForDay(self.player, day) ~= false then return false end
    local marked, newlyShown = Progress.MarkAdvancedTeachingShown(self.player, day)
    if marked ~= true or newlyShown ~= true then return false end
    return "老人：" .. text
end

---情境教学：按 V2.7 规则在真实条件满足时给一次老人提示，并标记 shown。
---呈现方式：顶部轻量提示（不暂停世界、不进模态队列，05 页 R14）。
---条件：老人仍同行；本周目该条未显示；当前无剧情模态。
---@param kind "basic"|"bird"|"splash"
---@return boolean
function Loop:TryShowContextTeaching(kind)
    if kind ~= "basic" and kind ~= "bird" and kind ~= "splash" then return false end
    if not self:IsElderPresent() then return false end
    if self.storyDialog then return false end
    local shown = Progress.IsTeachingShown(self.player, kind)
    if shown ~= false then return false end
    -- D1 基础教学在首次出航时无条件触发；海鸟/水花按真实看到现象触发（调用方已判定）。
    local text
    if kind == "basic" then
        text = "风挺大啊……老头子这两天有些乏，不碍事。记住两件事："
            .. "船一动，小鱼就躲你，想投饵先把船停稳；"
            .. "还有，天黑后头15秒赶回来还算安全，再拖就会影响明天的体力，真熬到夜深就只能强制返港了。"
    elseif kind == "bird" then
        text = "鸟在那边盘旋，附近应该有小鱼，投点饵试试。"
    else
        text = "留意水花留下的方向，那是大鱼经过的痕迹。"
    end
    local marked, newlyShown = Progress.MarkTeachingShown(self.player, kind)
    if marked ~= true or newlyShown ~= true then return false end
    -- 返回本次新触发的文本，由调用方决定如何展示（便于合并）。
    return "老人：" .. text
end

---D6 未救路线：日初一次苹果篮回想。
---@return boolean
function Loop:TryOpenAppleBasketRecall()
    if self.player.day ~= 6 then return false, "recall_day_required" end
    if self:IsElderPresent() then return false, "elder_present" end
    local shown = Progress.IsAppleBasketRecallShown(self.player)
    if shown ~= false then return false, "recall_already_shown" end
    if self.storyDialog then return false end
    if not self.inPort or not self:Ready() or self:HasPendingCatch() then return false, "busy" end
    local marked, newlyShown = Progress.MarkAppleBasketRecallShown(self.player)
    if marked ~= true or newlyShown ~= true then return false, "recall_already_shown" end
    self.storyDialog = { token = {}, kind = "apple_basket",
        text = "整理船舱时，你看见角落那只装苹果的旧篮子。前几天，老人有几次望着它出神，"
            .. "那时你没多想。要是当时……你没再想下去。" }
    self.clock:Pause("story")
    return true
end

function Loop:EndToday()
    if self.endingPending then return false, "ending_already_pending" end
    if self:HasPendingCatch() then return false, "pending_catch_required" end
    if not self:Ready() or not self.inPort then return false, "port_required" end
    if self.player.day >= Config.clock.maxDay then
        local paperShown, paperReason = Progress.IsPaperShown(self.player)
        if paperShown ~= true then
            local opened, openReason = self:OpenDay7PaperBeforeEnding()
            if opened then return true, "paper_opened" end
            return false, paperReason or openReason or "day7_paper_required"
        end
    end
    local near, reason = self:CanAccessPort()
    if not near then return false, reason end
    self.settlementPending, self.settlementForced = true, false
    self.clock:Pause("settlement")
    self.lastMessage = "确认结束今天并进入下一天？"
    return true
end

function Loop:ConfirmForcedReturn()
    if self.endingPending then return false, "ending_already_pending" end
    -- ②③ A6 晚归强返：记录超出宽限后的晚归秒数（用于无强返判定）
    if self.achievements then
        local elapsed = self.clock.phase == "night" and self.clock.elapsed or 0
        local late = math.max(0, elapsed - (Config.clock.graceSec or 0))
        self.achievements:NoteLateReturn(late)
    end
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
    local finalStoryRecord, finalElderRecord
    if self.player.day >= Config.clock.maxDay then
        if self.player.day ~= Config.clock.maxDay then return reject("invalid_run_day") end
        local paperShown, paperReason = Progress.IsPaperShown(self.player)
        if paperShown ~= true then return reject(paperReason or "day7_paper_required") end
        finalStoryRecord = self.player.story and self.player.story.circle1B2
        if type(finalStoryRecord) ~= "table" or type(finalStoryRecord.runCompleted) ~= "boolean" then
            return reject("invalid_run_completed")
        end
        if finalStoryRecord.runCompleted then return reject("run_already_completed") end
        finalElderRecord = self.player.elder and self.player.elder.circle1B2
        if not finalElderRecord
            or (finalElderRecord.decision ~= "saved" and finalElderRecord.decision ~= "dead") then
            return reject("elder_decision_pending")
        end
    end
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
    -- T1（2026-10-06 用户裁决）：第 7 天结算即本周目结局，不推进到第 8 天。
    -- 两支结局：3 苹果救活（elder.decision=="saved"）=改变结局，否则普通结局。
    -- 结局文案为占位，正式文本按 Q-006 由 B 侧内容生产替换后仅改 HUD 文案。
    if finalStoryRecord then
        self.endingKind = finalElderRecord.decision == "saved" and "changed" or "normal"
        finalStoryRecord.runCompleted = true
        self.endingPending = true
        self.settlementApplied = true
        local snapshotOk, snapshot = Diagnostics.Call(
            "Loop", "new_day_snapshot", Persistence.Snapshot, self.player)
        if not snapshotOk then
            self.settlementSnapshot, self.saveStatus = nil, "error"
            self:SetMessage("结局快照暂未生成，可重试；本次出海进度已保留。")
            emit(self, "new_day_preparation", {
                kind = "failure", result = "failed", reason = "ending_snapshot_failed", day = self.player.day,
            })
            return false, "ending_snapshot_failed"
        end
        self.settlementSnapshot = snapshot
        self:SetMessage("第 7 天结束，本次出海迎来了结局。")
        emit(self, "new_day_preparation", {
            kind = "operation", result = "ending", endingKind = self.endingKind, day = self.player.day,
        })

        return true
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
    SoundSystem.ExitElder()  -- 安全网：切日/回港时若残留老人声床则切回世界声床
    -- V2.7：探海镜开关在换日时重置为关闭（持有权不变）。
    if self.scopeEnabled then
        self.scopeEnabled = false
        self:SyncScope()
    end
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
    -- Day-seven entry still prepares its ocean; only the terminal settlement skips refresh.
    if not self.endingPending and self.options.onNewDay then
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
    -- T1：第 7 天结局结算的提示语不提"下一天"。
    if saved then
        self.lastMessage = self.endingPending
            and "本次出海已结束，进度已保存。"
            or "每日结算已保存，下一天已就绪"
    elseif self.endingPending then
        self.lastMessage = "已跳过终局存档等待；当前结局只保留在内存中，重启后可能恢复此前检查点；已发出的保存请求仍可能稍后写入。"
    else
        self.lastMessage = "已跳过本次保存等待，下一天已就绪；未保存进度可能在退出后丢失，已发出的保存请求仍可能稍后写入。"
    end
    if self.inPort and not self.endingPending then
        self:OpenDayEntryStory()
    end
    emit(self, "new_day_preparation", {
        kind = "operation", result = "ready", reason = saved and "saved" or "explicitly_skipped",
        day = self.player.day,
    })
    return true
end

local function prepareEndingSettlement(self)
    if not self.endingPending then return true end

    if not self.endingAchievementsSettled then
        local ok = Diagnostics.Call("Loop", "ending_achievement_settlement", function()
            if self.achievements then
                if self.endingKind == "changed" then self.achievements:NoteUnusualBranch() end
                self.achievements:SettleRun()
            end
        end)
        if not ok then
            self.saveStatus = "error"
            self:SetMessage("终局成就结算暂未完成，可重试。")
            emit(self, "ending_settlement", {
                kind = "failure", result = "failed", reason = "achievement_settlement_failed",
            })
            return false, "ending_achievement_settlement_failed"
        end
        self.endingAchievementsSettled = true
    end

    if self.profileStore and not self.endingProfileSaveDispatched then
        local ok = Diagnostics.Call("Loop", "ending_profile_save_call", function()
            self.profileStore:Save(function() end)
        end)
        if not ok then
            self.saveStatus = "error"
            self:SetMessage("终局档案保存调用失败，可重试终局结算。")
            emit(self, "ending_settlement", {
                kind = "failure", result = "failed", reason = "profile_save_call_failed",
            })
            return false, "ending_profile_save_call_failed"
        end
        self.endingProfileSaveDispatched = true
    end
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
    local endingPrepared, endingReason = prepareEndingSettlement(self)
    if not endingPrepared then return false, endingReason end
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
    if self.endingPending then return false, "ending_already_pending" end
    if self.achievements then self.achievements:SettleDay() end  -- ②③ A2 单日零空网 / A5 大鱼率 日结
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
    if self.closed then return true end
    local autoCancelled, autoCancelError = self:CancelAutoReturn("scene_closed")
    if not autoCancelled then return false, autoCancelError or "auto_return_cancel_failed" end
    local contentInvalidated, contentInvalidateError = self:InvalidateWorldContent("scene_closed")
    if not contentInvalidated then return false, contentInvalidateError or "busy" end
    self.generation = self.generation + 1
    self.closed, self.activeRequest = true, nil
    self.busy, self.loading = false, false
    self.initialSaveBusy = false
    self.clock:Pause("closed")
    SoundSystem.Shutdown()
    return true
end

function Loop:LoadSaved(done)
    if self.endingPending then return false, "ending_already_pending" end
    local autoCancelled, autoCancelError = self:CancelAutoReturn("load_requested")
    if not autoCancelled then return false, autoCancelError or "auto_return_cancel_failed" end
    local contentInvalidated, contentInvalidateError = self:InvalidateWorldContent("stale_generation")
    if not contentInvalidated then return false, contentInvalidateError or "busy" end
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
                local evidenceOk, evidenceError = EvidenceSystem.Validate(player)
                if not evidenceOk then
                    restoreOk, err = false, evidenceError or "invalid_hypothesis_progress"
                end
            end
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
                local storyRecord = self.player.story and self.player.story.circle1B2
                local runCompleted = storyRecord and storyRecord.runCompleted == true or false
                self.endingPending = runCompleted
                self.endingAchievementsSettled, self.endingProfileSaveDispatched = runCompleted, runCompleted
                self.endingKind = nil
                if runCompleted then
                    local elderRecord = self.player.elder and self.player.elder.circle1B2
                    self.endingKind = elderRecord.decision == "saved" and "changed" or "normal"
                else
                    Progress.OnDayStarted(self.player)
                end
                self.scopeEnabled, self.throwSelection, self.storyDialog = false, nil, nil
                self.fishingSelectionHintPending = false
                self:ResetShopStock()
                self.clock:Reset()
                self.clock:Pause("port")
                self.inventoryOpen, self.elderOpen = false, false
                SoundSystem.ExitElder()  -- 安全网：读档若残留老人声床则切回世界声床
                self.portNightElapsed = 0
                self.inPort, self.dayExhausted = true, false
                self.entryPending = false
                self.worldContentFeedbackToken, self.actionToast = nil, nil
    self.v28FeedbackToken, self.v28Notice = nil, nil
    self.v28NetChoice = nil
                self.loadStatus, self.saveStatus = "loaded", "saved"
                self.lastMessage = "已加载每日结算存档"
                if not runCompleted then
                    self:OpenDayEntryStory()
                end
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
    local autoCancelled, autoCancelError = self:CancelAutoReturn("new_run")
    if not autoCancelled then return reject(autoCancelError or "auto_return_cancel_failed") end
    local contentInvalidated, contentInvalidateError = self:InvalidateWorldContent("stale_generation")
    if not contentInvalidated then return reject(contentInvalidateError or "busy") end
    -- ②③ 进入新周目前先落盘本周目已获图鉴/成就（跨周目保留）
    if self.profileStore then self.profileStore:Save(function() end) end
    self.currentWeek = (self.currentWeek or 1) + 1
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
    if not self:Ready() and not self.entryPending and not self.endingPending then return reject("busy") end
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
    if not self:CanManageInventory() then
        self.lastMessage = "现在不能使用物品，请先完成或取消当前动作。"
        return false, "busy"
    end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition then
        self.lastMessage = "物品已不存在。"
        return false, "invalid_item"
    end
    -- V2.8：交易品与关键道具的「使用」= 查看/重读，不消耗、不恢复体力。
    if definition.useText and type(definition.useText) == "string" and definition.useText ~= "" then
        if definition.readTitle then
            self.storyDialog = { token = {}, kind = "v28_note",
                title = definition.readTitle, text = definition.useText }
            self.clock:Pause("story")
        else
            self.lastMessage = definition.useText
            self:QueueActionToast(definition.useText, 4)
        end
        return true
    end
    if not definition.heal or definition.heal <= 0 then
        -- V2.7：每个物品的每个选项都有反馈，不用置灰代替。
        self.lastMessage = definition.name .. "没有可用的使用效果。"
        return false, "item_has_no_use"
    end
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
    if not self:CanManageInventory() then
        self.lastMessage = "现在不能丢弃物品，请先完成或取消当前动作。"
        return false, "busy"
    end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition then
        self.lastMessage = "物品已不存在。"
        return false, "invalid_item"
    end
    -- A9（S3）：关键物品不可丢弃（05 页），给明确解释且不消耗。
    if definition.protected then
        self.lastMessage = definition.name .. "是关键物品，不能丢弃。"
        return false, "protected_item"
    end
    if definition.category == "treasure" then
        -- V2.7：宝藏不占船舱格，丢弃不能腾格；给客观原因。
        self.lastMessage = definition.name .. "是宝藏，不能丢弃。"
        return false, "treasure_protected"
    end
    -- V2.7（P-06/C-08）鱼饵例外：点「丢弃」= 船边即时投饵，不进入投放选点；
    -- 若在港内或贴岸无合法水域，则直接移除完成腾格，不报错卡死。
    if definition.category == "bait" then
        return self:DropBaitBesideShip(index, definition)
    end
    if self.inPort then
        -- V2.7：港内丢弃被拒绝时也要给出原因（不用置灰代替反馈）。
        self.lastMessage = "船上才能丢弃物品，请先出海。"
        return false, "sea_required"
    end
    -- V2.8 Closure：区分「丢弃」与「投放」。
    -- 【丢弃】= 从船舱删除物品腾格，不产生 WorldDrop、不参与鱼 AI、不参与海眼、
    -- 不需要海面坐标；【投放】才是底部【投放】→ 选点 → WorldDrop。
    -- 只有显式登记在 Items.CanWorldDrop 的生态物（苹果/鱼饵/小鱼/大鱼）
    -- 才走下面的 WorldDrop 交接；其余普通交易品（珠宝/珊瑚枝/深海珍珠/
    -- 海底金属货箱）直接销毁腾格。
    if not Items.CanWorldDrop(id) then
        local removed, reason = self.player.inventory:Remove(index)
        if removed ~= true then
            self.lastMessage = "物品已不存在。"
            return false, reason or "inventory_remove_failed"
        end
        self.lastMessage = "你把" .. definition.name .. "丢进了海里，船舱腾出了一格。"
        self:CancelThrowSelection()
        return true, "discarded"
    end
    if not self.options.dropReceiver then
        self.lastMessage = "附近没有接收地点，物品仍保留在船舱里。"
        return false, "drop_receiver_unavailable"
    end
    -- V2.8：区分「正式投放」与「背包丢弃」。
    -- 只有通过 SetDropTarget 显式选定的海面投放点（底部【投放】/ 鱼饵“使用”选点）
    -- 才是正式 WorldDrop；物品菜单【丢弃】与 ThrowItemAtShip 快捷路径没有该选点，
    -- 因此绝不触发海眼特殊回应。
    local officialThrow = self.actions ~= nil
        and type(self.actions.GetDropTarget) == "function"
        and self.actions:GetDropTarget() ~= nil
    local payload = { itemId = id, category = definition.category,
        worldEffect = definition.worldEffect, lifetimeSec = definition.lifetimeSec,
        officialThrow = officialThrow == true }
    self.dropInFlight = true
    local removed, previous, stamina = self:RemoveCargo(index)
    if not removed then self.dropInFlight = false; return false, previous end
    -- receiver 必须同步确认交接成功（true）。没有世界坐标的 B 不自行创建对象。
    local ok, accepted = Diagnostics.Call("Loop", "drop_receiver", self.options.dropReceiver, payload)
    self.dropInFlight = false
    if not ok or accepted ~= true then return self:RollbackInventory(previous, stamina, "drop_rejected") end
    -- V2.8：海眼等接收方可以给出自己的反馈，优先于默认的“已交接投放请求”。
    if type(payload.vortexFeedback) == "string" and payload.vortexFeedback ~= "" then
        self.lastMessage = payload.vortexFeedback
    else
        self.lastMessage = "已交接投放请求：" .. definition.name
    end
    if self.knowledge and payload and payload.worldEffect then
        self.knowledge:OnDropItem(payload)  -- ②③ attractOnBait/birdSignalCast/repeatCastNoBird
    end
    self:CancelThrowSelection()
    return true, payload
end

---V2.7（P-06/C-08）：鱼饵「丢弃」——船边即时投饵；
---港内或贴岸无合法水域时直接移除完成腾格，不报错卡死。
---注意：超距不属于本例外（超距必须拒绝并保留物品）。
---@param index integer
---@param definition ItemDefinition
---@return boolean, table|string
function Loop:DropBaitBesideShip(index, definition)
    definition = definition or Items.GetDefinition(self.player.inventory:GetItems()[index])
    if not definition then
        self.lastMessage = "物品已不存在。"
        return false, "invalid_item"
    end
    -- V2.8：鱼饵「丢弃」= 船边即时投饵，不是正式投放；明确标记为非正式，
    -- 因此即使落在海眼核心也不会触发海眼特殊回应。
    local payload = { itemId = definition.id, category = definition.category,
        worldEffect = definition.worldEffect, lifetimeSec = definition.lifetimeSec,
        officialThrow = false }

    -- 港内：没有可投饵水域，直接移除完成腾格（C-08 已确认）。
    if self.inPort then
        local removed, reason = self.player.inventory:Remove(index)
        if removed ~= true then return false, reason or "inventory_remove_failed" end
        self.lastMessage = "你把鱼饵丢进了水里。"
        self:CancelThrowSelection()
        return true, payload
    end

    if not self.options.dropReceiver then
        self.lastMessage = "附近没有接收地点，物品仍保留在船舱里。"
        return false, "drop_receiver_unavailable"
    end

    self.dropInFlight = true
    local removed, previous, stamina = self:RemoveCargo(index)
    if not removed then
        self.dropInFlight = false
        return false, previous
    end
    local ok, accepted = Diagnostics.Call("Loop", "drop_receiver", self.options.dropReceiver, payload)
    self.dropInFlight = false
    if ok and accepted == true then
        self.lastMessage = "鱼饵沉入水中，泛起一点细小的波纹。也许附近的小鱼很快就会察觉。"
        if self.knowledge and payload.worldEffect then
            self.knowledge:OnDropItem(payload)
        end
        self:CancelThrowSelection()
        return true, payload
    end

    -- 世界未接受：贴岸无法水域时按 C-08 直接移除腾格；
    -- 但超距必须拒绝并保留物品，因此需区分拒绝原因。
    local reasonText = type(accepted) == "string" and accepted or ""
    local outOfRange = reasonText:find("distance", 1, true) ~= nil
        or reasonText:find("range", 1, true) ~= nil
        or reasonText:find("far", 1, true) ~= nil
        or reasonText:find("throw_out_of_range", 1, true) ~= nil
    if outOfRange then
        return self:RollbackInventory(previous, stamina, "drop_rejected")
    end
    -- 其它拒绝（如无法水域）：保留物品并给出原因，不强行移除。
    return self:RollbackInventory(previous, stamina, "drop_rejected")
end

function Loop:GiveToElder(index)
    local present, presenceReason = self:IsElderPresent()
    if not present then
        -- V2.7：老人离世后入口仍可点，只说明原因且不消耗。
        self.lastMessage = "老人已经不在了，无法再把东西交给他。"
        return false, presenceReason or "elder_not_present"
    end
    if self:HasPendingCatch() and not self.elderOpen then return false, "elder_dialog_required" end
    if not self:CanManageInventory() or not self.elderOpen then
        self.lastMessage = "现在不能与老人交接物品，请先完成或取消当前动作。"
        return false, "elder_dialog_required"
    end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition then
        self.lastMessage = "物品已不存在。"
        return false, "invalid_item"
    end
    if not definition.canGive then
        -- V2.7：三个选项固定展示，不能执行时给出原因。
        self.lastMessage = definition.name .. "不适合交给老人。"
        return false, "cannot_give_item"
    end
    if definition.category ~= "food" then
        self.lastMessage = "向老人展示了" .. definition.name .. "，物品仍保留，没有额外奖励。"
        return true, self.lastMessage, elderExchange(
            self, id, "show", "展示 " .. definition.name, self.lastMessage)
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
        if self.achievements then self.achievements:NoteAppleGiven(self.player.day) end  -- ②③ A3 三个苹果
    end
    self.player.elder.lastGivenItemId = id
    self.lastMessage = message or "老人收下了物品。"
    self:CancelThrowSelection()
    return true, self.lastMessage, elderExchange(
        self, id, "give", "给予 " .. definition.name, self.lastMessage)
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
    -- V2.8：新增交易品（珠宝/珊瑚枝/深海珍珠/海底金属货箱）为 category=misc，
    -- 仍占普通船舱 1 格、可在港口出售；独立道具栏持有物不可出售。
    if not definition or definition.independentBar
        or not V28Progress.IsSellableCargo(definition) then
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
        local keptProtected = 0
        -- 倒序移除，避免 Remove 造成的索引位移。
        for index = #items, 1, -1 do
            local id = items[index]
            local definition = id and Items.GetDefinition(id)
            if definition and V28Progress.IsSellableCargo(definition)
                and not definition.independentBar then
                -- A9（S3）：关键物品不可卖掉（05 页），整体出售时跳过并保留在船舱。
                if definition.protected then
                    keptProtected = keptProtected + 1
                else
                    local ok = self.player.inventory:Remove(index)
                    if ok then
                        total = total + definition.sellPrice
                        count = count + 1
                    end
                end
            end
        end
        if count == 0 then
            if keptProtected > 0 then
                self.lastMessage = "关键物品不能出售，已保留在船舱。"
            end
            return false, "nothing_to_sell"
        end
        local paid, payReason = self.player:ChangeMoney(total)
        if not paid then return false, payReason end
        self.lastMessage = string.format("共出售 %d 件渔获，收入 ¥%d", count, total)
        if keptProtected > 0 then self.lastMessage = self.lastMessage .. "；关键物品保留在船舱。" end
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
    -- A2（2026-10-05 用户裁决）：捕鱼动作（选点/收网）进行中再点捕鱼键=取消（免费），
    -- 不新增按钮；清理/结算 pending 态仍走 CancelFishingAction 的重试清理路径。
    if self.actions:IsBusy() then
        self.fishingSelectionHintPending = false
        return self:CancelFishingAction()
    end
    self.fishingSelectionHintPending = false
    local cancelled, cancelError = self:CancelAutoReturn("fishing_selection")
    if not cancelled then return false, cancelError end
    local started, reason = self.actions:BeginSelection()
    if started ~= true then return started, reason end
    local fishingState = self.actions:GetFishingState()
    if type(fishingState) ~= "table" or fishingState.state ~= "selecting" then
        return false, "fishing_selection_not_started"
    end
    local marked, newlyShown = Progress.MarkFishingSelectionHintShown(self.player)
    if marked ~= true then
        self.actions:CancelActiveFishing("progress_invalid")
        return false, newlyShown
    end
    if newlyShown == true then self.fishingSelectionHintPending = true end
    return true
end
function Loop:TakeFishingSelectionHint()
    if self.fishingSelectionHintPending ~= true then return false end
    self.fishingSelectionHintPending = false
    return true
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
    self.fishingSelectionHintPending = false
    if not self.actions then return true end
    return self.actions:CancelActiveFishing("cancelled")
end
---S6 教学：首次成功捕获（含满舱 claim 入包）= "投饵→捕鱼→结果反馈" 闭环完成
---（05 页 P6 口径），标记后老人对话面板的教学对白区收起。幂等。
function Loop:NotifyCatchObtained()
    local Progress = require("Gameplay.Circle1B2Progress")
    return Progress.MarkTeachingDone(self.player)
end
function Loop:IsTeachingDone()
    local Progress = require("Gameplay.Circle1B2Progress")
    local done = Progress.IsTeachingDone(self.player)
    return done == true
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
        or (self.worldContentActions and self.worldContentActions:GetActionState() ~= nil)
        or (self.v28Actions and self.v28Actions:GetActionState() ~= nil)
        or self.throwSelection ~= nil
end
function Loop:CanManageInventory()
    if self.busy or self.loading or self.dropInFlight or (self.actions and self.actions:IsBusy())
        or (self.barrel and self.barrel:IsBusy()) or self.storyDialog then return false end
    if self.worldContentActions and self.worldContentActions:GetActionState() then return false end
    if self.v28Actions and self.v28Actions:GetActionState() then return false end
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
    local charged = self.player:ConsumeStamina(Config.stamina.eventOperationCost)
    if charged == true then
        SoundSystem.StartAction()  -- 需求 行动：40 体力事件实操开始（圈2 事件上线后生效）
    end
    return charged
end

function Loop:InvalidateWorldContent(reason)
    if self.v28Actions then
        local ok, err = self.v28Actions:Invalidate(reason or "stale_generation")
        if not ok then return false, err end
    end
    if not self.worldContentActions then return true end
    return self.worldContentActions:Invalidate(reason or "stale_generation")
end

function Loop:GetWorldContentActionState()
    return self.worldContentActions and self.worldContentActions:GetActionState() or nil
end

function Loop:GetWorldContentPrompt()
    local actions = self.worldContentActions
    if not actions then return nil, "world_content_unavailable" end
    if actions:GetActionState() then return actions:GetWorldContentPrompt() end
    if self.worldContentFeedbackToken ~= nil then return nil end
    if self.inPort or self.clock:IsPaused() or self.clock.exhausted or self.inventoryOpen or self.elderOpen
        or self:HasPendingCatch() or not self:Ready() then return nil end
    return actions:GetWorldContentPrompt()
end

function Loop:BeginWorldContentAction(contentId, actionKind)
    local actions = self.worldContentActions
    if not actions then return false, "world_content_unavailable" end
    if self.inPort or self.clock:IsPaused() or self.clock.exhausted or self.inventoryOpen or self.elderOpen
        or self:HasPendingCatch() or not self:Ready() or self:IsMovementBlocked() then
        return false, "action_blocked"
    end
    if self.worldContentFeedbackToken ~= nil then return false, "world_content_feedback_pending" end
    local method = actionKind == "explore" and actions.BeginExplore
        or actionKind == "salvage" and actions.BeginSalvage
    if type(method) ~= "function" then return false, "invalid_action_kind" end
    local canPay = self.player:CanConsumeStamina(Config.stamina.salvageCost)
    if not canPay then
        local text, messageCode = actionKind == "explore"
            and "探索" or "打捞", actionKind == "explore"
            and "insufficient_stamina_explore" or "insufficient_stamina_salvage"
        self.lastMessage = string.format("体力不足，%s需要%d体力。", text, Config.stamina.salvageCost)
        return false, messageCode
    end
    local cancelled, cancelError = self:CancelAutoReturn("world_content_action")
    if not cancelled then return false, cancelError or "auto_return_cancel_failed" end
    local token, reason = method(actions, contentId)
    if not token then return false, reason or "action_rejected" end
    self.worldContentFeedbackToken = token
    self.lastMessage = actionKind == "explore" and "开始探索" or "开始打捞"
    return token
end

function Loop:CancelWorldContentAction(token, reason)
    local actions = self.worldContentActions
    if not actions then return true, "idle" end
    local active = actions:GetActionState()
    if not active then return true, "idle" end
    local targetToken = token or active.token
    local cancelled, result = actions:Cancel(targetToken, reason or "cancelled")
    if cancelled and self.worldContentFeedbackToken == targetToken then
        self.worldContentFeedbackToken = nil
    end
    return cancelled, result
end

function Loop:GetOwnedTreasures()
    if not self.worldContentActions then return {} end
    return self.worldContentActions:GetOwnedTreasures()
end

function Loop:IsWorldContentMarked(contentId)
    local state, reason = WorldContentProgress.GetState(self.player, contentId)
    if not state then return false, reason end
    return state.marked == true
end

function Loop:ShowTreasureToElder(treasureId)
    local present, reason = self:IsElderPresent()
    if not present then return false, reason or "elder_not_present" end
    if not self.elderOpen then return false, "elder_dialog_required" end
    if not self:CanManageInventory() then return false, "busy" end
    local owned, ownershipError = self:GetOwnedTreasures()
    if type(owned) ~= "table" then return false, ownershipError or "treasure_unavailable" end
    local found = false
    for _, id in ipairs(owned) do if id == treasureId then found = true; break end end
    if not found then return false, "treasure_unavailable" end
    self.lastMessage = "已展示记忆，记忆仍保留。"
    return true, self.lastMessage, elderExchange(self, treasureId, "show", "展示记忆", self.lastMessage)
end

function Loop:BindRuntime(runtime)
    if type(runtime) ~= "table" then return false, "runtime_required" end
    local replaced = self.runtime ~= nil and self.runtime ~= runtime
    if replaced then
        local autoCancelled, autoCancelError = self:CancelAutoReturn("runtime_replaced")
        if not autoCancelled then return false, autoCancelError or "auto_return_cancel_failed" end
        local invalidated, invalidateError = self:InvalidateWorldContent("stale_generation")
        if not invalidated then return false, invalidateError end
    end
    self.runtime = runtime
    self.barrel:BindRuntime(runtime)
    if not self.worldContentActions then
        local loop = self
        local adapter = {}
        function adapter:GetContext()
            local current = loop.runtime
            if not current or type(current.GetFixedContentGeneration) ~= "function"
                or type(current.GetWorldContentAccess) ~= "function" then
                return nil, "runtime_unavailable"
            end
            local generation = current:GetFixedContentGeneration()
            if generation == nil or type(current.world) ~= "table" then return nil, "runtime_identity_unavailable" end
            return { player = loop.player, sessionGeneration = loop.generation,
                runtimeIdentity = current.world, fixedContentGeneration = generation }
        end
        function adapter:GetWorldContentAccess(contentId)
            local current = loop.runtime
            if not current or type(current.GetWorldContentAccess) ~= "function" then
                return nil, "world_content_access_unavailable"
            end
            return current:GetWorldContentAccess(contentId)
        end
        function adapter:IsWorldContentInScope(contentId)
            local current = loop.runtime
            if not current or type(current.IsWorldContentInScope) ~= "function" then
                return nil, "scope_unavailable"
            end
            return current:IsWorldContentInScope(contentId)
        end
        local actions, actionError = WorldContentActions.New(adapter)
        assert(actions, actionError or "world_content_initialization_failed")
        self.worldContentActions, self.worldContentAdapter = actions, adapter
        -- V2.8 固定海上内容复用同一 adapter 契约（只读空间查询 + 固定内容代际）。
        local v28, v28Error = V28ContentActions.New(adapter)
        assert(v28, v28Error or "v28_content_initialization_failed")
        self.v28Actions = v28
    end
    self:SetupKnowledgeSystems()  -- runtime 就绪后补建 KS/AS（首帧 Init 时 runtime 可能尚未绑定）
    return self
end

-- ②③ 构建认知度/成就执行器；runtime.surfaceSignals 与 player 就绪后才建（幂等，每次 NewRun 重建以绑定新 player）
function Loop:SetupKnowledgeSystems()
    if not (self.runtime and self.runtime.surfaceSignals and self.player and self.profileStore) then return end
    self.knowledge = KnowledgeSystem.New{
        data = require("data.knowledge"),
        surfaceSignals = self.runtime.surfaceSignals,
        profile = self.profileStore,
        currentWeek = self.currentWeek or 1,
    }
    self.achievements = AchievementSystem.New{
        data = require("data.achievements"),
        knowledge = self.knowledge,
        profile = self.profileStore,
        player = self.player,
    }
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
    self.lastMessage = "向老人展示了探海镜，宝物仍保留，没有额外奖励。"
    return true, self.lastMessage, elderExchange(
        self, id, "show", "展示 探海镜", self.lastMessage)
end
function Loop:BeginBarrelInspection()
    local cancelled, reason = self:CancelAutoReturn("barrel_inspection")
    if not cancelled then return false, reason end
    return self.barrel:Begin()
end
function Loop:CancelBarrelInspection() return self.barrel:Cancel("cancelled") end
function Loop:GetBarrelState() return self.barrel:GetState() end
function Loop:HasLens() return Progress.HasLens(self.player) end
function Loop:IsScopeEnabled() return self:HasLens() and self.scopeEnabled == true end
function Loop:DisableScope()
    self.scopeEnabled = false
    return self:SyncScope()
end
function Loop:SyncScope()
    -- 每帧热路径（Game:Sync 逐帧调用）：不创建 finish 闭包，直接返回，
    -- 消除逐帧闭包分配带来的 GC 抖动。
    if not self:HasLens() then self.scopeEnabled = false end
    local runtime = self.runtime
    if not runtime or type(runtime.SetScopeEnabled) ~= "function" or type(runtime.IsScopeEnabled) ~= "function" then
        self.scopeSyncError = "scope_interface_unavailable"
        return false, "scope_interface_unavailable"
    end
    local readOk, enabled = pcall(runtime.IsScopeEnabled, runtime)
    if not readOk then
        self.scopeSyncError = "scope_sync_failed"
        return false, "scope_sync_failed"
    end
    if enabled ~= self.scopeEnabled then
        local setOk = pcall(runtime.SetScopeEnabled, runtime, self.scopeEnabled)
        if not setOk then
            self.scopeSyncError = "scope_sync_failed"
            return false, "scope_sync_failed"
        end
    end
    local verifyOk, observed = pcall(runtime.IsScopeEnabled, runtime)
    if not verifyOk or observed ~= self.scopeEnabled then
        self.scopeSyncError = "scope_sync_failed"
        return false, "scope_sync_failed"
    end
    self.scopeSyncError = nil
    return true
end
function Loop:ToggleScope()
    if not self:HasLens() then return false, "scope_not_owned" end
    -- V2.8（系统规则）：所有约 4 秒高成本事务进行中禁止切换探海镜。
    if (self.worldContentActions and self.worldContentActions:GetActionState())
        or (self.v28Actions and self.v28Actions:GetActionState())
        or (self.barrel and self.barrel:IsBusy()) then
        self.lastMessage = "动作进行中，无法切换探海镜。"
        return false, "action_blocked"
    end
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
    if not definition then return false, "invalid_item" end
    -- V2.8 Closure：投放入口统一用显式能力表，与 GetThrowCandidates 同源。
    -- 否则玩家可以绕过列表直接调用此接口把普通交易品送进 WorldDrop。
    if not Items.CanWorldDrop(item) then
        self.lastMessage = definition.name .. "不能投放到海里。"
        return false, "item_not_throwable"
    end
    local cancelled, cancelError = self:CancelAutoReturn("throw_selection")
    if not cancelled then return false, cancelError or "auto_return_cancel_failed" end
    self.throwSelection = { index = index, itemId = item }
    self.throwPicker = nil
    if self.actions then self.actions:SetDropTarget(nil) end
    if self.runtime and type(self.runtime.ClearMovementTarget) == "function" then self.runtime:ClearMovementTarget() end
    self:SetMessage("已选择" .. definition.name .. "，请点击12米内海面投掷；也可以取消。")
    return true
end
function Loop:GetThrowSelection()
    local selected = self.throwSelection
    return selected and { index = selected.index, itemId = selected.itemId } or nil
end

---V2.7（P-06/S-01）：底部【投放】列表 —— 按物品类型合并同类数量。
---仅列出世界接受的普通可投放物（不含宝藏/关键物品）；每项带最靠前一格的库位索引。
---@return table[]
function Loop:GetThrowCandidates()
    local result = {}
    if not self.player or not self.player.inventory then return result end
    local byId, order = {}, {}
    local items = self.player.inventory:GetItems()
    for index = 1, #items do
        local itemId = items[index]
        local definition = Items.GetDefinition(itemId)
        -- V2.8 Closure：底部【投放】只用显式能力表 Items.CanWorldDrop。
        -- 不再用 category ~= "treasure" / not protected 推断，否则
        -- worldEffect=NONE 的普通交易品（珠宝/珊瑚枝/深海珍珠/货箱）会
        -- 自动进入投放列表。
        if definition and Items.CanWorldDrop(itemId) then
            if not byId[itemId] then
                byId[itemId] = { itemId = itemId, name = definition.name,
                    category = definition.category, count = 0, index = index }
                order[#order + 1] = itemId
            end
            byId[itemId].count = byId[itemId].count + 1
        end
    end
    for _, itemId in ipairs(order) do result[#result + 1] = byId[itemId] end
    return result
end

---V2.7（S-01）：点击底部【投放】。
---列表为空时不弹模态，用顶部轻量文字提示“船舱里没有可以投放的物品。”。
---@return boolean, string|table
function Loop:OpenThrowPicker()
    if self.inPort then
        self.lastMessage = "请先出海再投放。"
        return false, "sea_required"
    end
    if not self:CanManageInventory() then
        self.lastMessage = "现在不能投放，请先完成或取消当前动作。"
        return false, "busy"
    end
    -- V2.7（S-01）：再点【投放】就取消当前选点/列表，不消耗物品。
    if self:GetThrowSelection() then
        self:CancelThrowSelection()
        self.throwPicker = nil
        return false, "cancelled"
    end
    if self.throwPicker then
        self.throwPicker = nil
        return false, "cancelled"
    end
    local candidates = self:GetThrowCandidates()
    if #candidates == 0 then
        self.lastMessage = "船舱里没有可以投放的物品。"
        return false, "no_throwable_item"
    end
    self.throwPicker = candidates
    return true, candidates
end

---@return table[]|nil
function Loop:GetThrowPicker()
    return self.throwPicker
end

function Loop:CloseThrowPicker()
    self.throwPicker = nil
    return true
end
function Loop:CancelThrowSelection()
    -- V2.7：取消投放选点时也要收起列表，避免返港/换日后残留。
    self.throwSelection = nil
    self.throwPicker = nil
    return true
end

---背包内一键投掷：以船当前位置为投放点直接执行投放。
---真机反馈（2026-10-05）：先 BeginThrowItem 再点海面的两段式流程会被背包
---抽屉遮罩挡住海面点击，玩家卡死在背包页。此接口保持 BeginThrowItem /
---HandleThrowPointer 海面选点流程不变，仅新增"船当前位置"快捷路径。
---@param index integer
---@return boolean, string?
function Loop:ThrowItemAtShip(index)
    if not self:CanManageInventory() or self.inPort then return false, "sea_required" end
    local item = self.player.inventory:GetItems()[index]
    local definition = item and Items.GetDefinition(item)
    if not definition then return false, "invalid_item" end
    -- V2.8 Closure：快捷投掷与底部【投放】共用同一能力表，不得绕过。
    if not Items.CanWorldDrop(item) then
        self.lastMessage = definition.name .. "不能投放到海里。"
        return false, "item_not_throwable"
    end
    if not self.actions then return false, "fishing_runtime_interface_unavailable" end
    local position = self.runtime and type(self.runtime.GetShipPosition) == "function"
        and self.runtime:GetShipPosition() or nil
    if type(position) ~= "table" or type(position.x) ~= "number" or type(position.y) ~= "number" then
        return false, "invalid_drop_position"
    end
    -- 投放点=船当前位置（距离 0 ≤ maxThrowDistance），交接由 dropReceiver 同步确认。
    self.actions:SetDropTarget({ x = position.x, y = position.y })
    local ok, reason = self:DropItem(index)
    if not ok then self.actions:SetDropTarget(nil) end
    return ok, reason
end
function Loop:OpenDay4ElderFate()
    -- V2.7：D4 结果模态每周目只弹一次，不限制“必须是 day==4”才能补显：
    -- 若 D4 日结被“放弃保存”后玩家在 D5/D6 读旧检查点，仍应能补看这一次结果。
    if (tonumber(self.player.day) or 1) < 4 then return false, "elder_fate_day_required" end
    local status = self:GetElderStatus()
    if status.decision ~= "saved" and status.decision ~= "dead" then
        return false, "elder_decision_pending"
    end
    local shown, shownError = Progress.IsElderFateShown(self.player)
    if shownError then return false, shownError end
    if shown then return false, "elder_fate_already_shown" end
    if self.storyDialog then return true end
    if not self.inPort or not self:Ready() or self:HasPendingCatch() then return false, "busy" end
    local text
    if status.decision == "saved" then
        -- V2.7（W-03）：救活结果必须明确告知“状态转好”，不直接暴露 3 苹果条件。
        text = "第四天清晨，老人还在。\n"
            .. "他缓缓坐起身，眼里恢复了些神气：“缓过来了……这天，还能跟你一起出海。”\n"
            .. "这趟航行，你们还能继续同行。"
    else
        -- V2.7（W-02，文案回审已采纳）：离世结果 + 随后一句自然语言润色。
        text = "清晨，船边安静得出奇。老人没像往常那样叫你起身。你走近时才发现，他已经没有了呼吸。\n"
            .. "海浪依旧拍着船舷，仿佛不知道少了一个人。\n"
            .. "你独自把船整理好，甲板上静悄悄的……日子还是得照样过。"
    end
    self.storyDialog = { token = {}, kind = "elder_fate", text = text }
    self.clock:Pause("story")
    return true
end

---日初剧情入口：D4 老人命运 → D6 未救苹果篮回想 → D7 纸条。
---同一时刻只开一个；已有剧情模态时不排队（下一次日结/读档会再尝试）。
---@return boolean
function Loop:OpenDayEntryStory()
    if self.storyDialog then return false end
    if self.endingPending then return false end
    local day = tonumber(self.player.day) or 1
    -- V2.7：日初剧情属于当天，不跨日补显。
    -- D4 结果只在 D4 日初（含 D3→D4 换日、D4 读档）打开；
    -- 若 D4 日结放弃保存后重启，读回的是 D3 检查点，D4 会整体重演。
    if day == 4 then
        local status = self:GetElderStatus()
        if status.decision == "saved" or status.decision == "dead" then
            if Progress.IsElderFateShown(self.player) == false then
                if self:OpenDay4ElderFate() then return true end
            end
        end
    end
    if day == 6 and self:TryOpenAppleBasketRecall() then return true end
    if day == 7 then
        if Progress.IsPaperShown(self.player) == false then
            if self:OpenDay7PaperBeforeEnding() then return true end
        end
    end
    return false
end

function Loop:OpenDay7PaperBeforeEnding()
    if self.player.day ~= 7 then return false, "paper_day_required" end
    local paperShown, paperError = Progress.IsPaperShown(self.player)
    if paperError then return false, paperError end
    if paperShown then return false, "paper_already_shown" end
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
        text = "海边那只木桶还有秘密，快去再探探。" }
    self.clock:Pause("story")
    return true
end
function Loop:GetStoryDialog()
    local dialog = self.storyDialog
    if not dialog then return nil end
    return { token = dialog.token, kind = dialog.kind, title = dialog.title, text = dialog.text,
        teachingKind = dialog.teachingKind }
end
function Loop:NotifyStoryShown(token)
    if not self.storyDialog or token ~= self.storyDialog.token then return false, "stale_story_dialog" end
    if self.storyDialog.kind == "paper" then return Progress.MarkPaperShown(self.player) end
    if self.storyDialog.kind == "elder_fate" then return Progress.MarkElderFateShown(self.player) end
    -- V2.7：教学/回想类只在打开时标记 shown（由 TryOpen* 完成），关闭不额外写盘。
    if self.storyDialog.kind == "teaching" or self.storyDialog.kind == "apple_basket" then
        return true
    end
    -- W-08 copy uses the existing modal without a separate persisted shown marker.
    if self.storyDialog.kind == "memory_fragment" then return true end
    -- V2.8：航海残页重读与 4 秒事务结果复用同一模态，不新增 shown 存档。
    if self.storyDialog.kind == "v28_note" or self.storyDialog.kind == "v28_result" then return true end
    return false, "unknown_story_kind"
end
function Loop:CloseStoryDialog()
    if self.storyDialog and self.storyDialog.kind == "paper" then
        local shown, reason = Progress.IsPaperShown(self.player)
        if shown ~= true then return false, reason or "paper_not_shown_yet" end
    elseif self.storyDialog and self.storyDialog.kind == "elder_fate" then
        local shown, reason = Progress.IsElderFateShown(self.player)
        if shown ~= true then return false, reason or "elder_fate_not_shown_yet" end
    end
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
