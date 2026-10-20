-- Connects the standalone Ocean runtime to the independent Gameplay loop.
-- The loop owns game time/player state; Ocean owns movement and world entities.
local OceanConfig = require("Ocean.Config")
local OceanMath = require("Ocean.Math")
local Loop = require("Gameplay.Loop")
local Items = require("data.items")
local V28Progress = require("Gameplay.V28Progress")
local Game = require("Game.Game")
local Diagnostics = require("Gameplay.Diagnostics")

---@class GameplayOceanBridge
---@field runtime table
---@field loop GameplayLoop
---@field game SeaGameplayGame
---@field _externalDropReceiver (fun(payload:table, position:GameplayActionPoint):boolean)?
---@field _barrelReadErrorLogged boolean? Diagnostic latch only; no action state.
local Bridge = {}
Bridge.__index = Bridge

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

---@param options table
---@return table
local function copyOptions(options)
    local result = {}
    for key, value in pairs(options) do result[key] = value end
    return result
end

local function getWorldIdentity(runtime)
    if type(runtime.GetFishingGeneration) ~= "function" then error("world_identity_unavailable", 0) end
    local ok, identity = Diagnostics.Call("Integration", "world_identity", runtime.GetFishingGeneration, runtime)
    if not ok or type(identity) ~= "number" or identity ~= identity
        or identity < 0 or identity == math.huge or identity ~= math.floor(identity) then
        error("world_identity_unavailable", 0)
    end
    return identity
end

---@param self GameplayOceanBridge
---@param day integer
---@param clearDropTarget boolean
local function refreshDynamicWorld(self, day, clearDropTarget)
    local identity = getWorldIdentity(self.runtime)
    if self.loop:IsWorldPrepared(day, identity) then return true end
    local reset, reason = assert(self.loop.actions):Reset(clearDropTarget)
    if not reset then error(reason or "action_reset_failed", 0) end
    local seed = OceanConfig.world.seed + day - 1
    local departure = self.runtime:GetShipPosition()
    local accepted = self.runtime:refreshOrdinaryFish(seed, departure)
    if accepted == false then error("new_day_preparation_failed", 0) end
    self.loop:MarkWorldPrepared(day, getWorldIdentity(self.runtime))
    return true
end

-- Hoisted xpcall handler: no per-frame closure allocation.
local function handleBarrelReadError(err)
    return err
end

-- V2.8：浮藻假岛 20m 识破 + 巨骨海面慢气泡（纯只读提示，不写存档）。
---@param self GameplayOceanBridge
local function recognizeV28Proximity(self)
    local runtime, loop = self.runtime, self.loop
    if type(runtime.GetShipPosition) ~= "function" then return end
    local position = runtime:GetShipPosition()
    if not isPoint(position) then return end
    for _, contentId in ipairs({ "kelp_mirage_01" }) do
        local content = type(runtime.GetWorldContent) == "function"
            and runtime:GetWorldContent(contentId) or nil
        if content and type(content.position) == "table" then
            local dx, dy = content.position.x - position.x, content.position.y - position.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance <= 20 and not loop.player:IsRecognized(contentId) then
                self:RecognizeLocation(contentId, content.position)
            end
        end
    end
end

---@param self GameplayOceanBridge
local function recognizeFixedBarrel(self)
    local runtime = self.runtime
    if type(runtime.GetFixedBarrel) ~= "function" then return end
    local ok, barrel = xpcall(runtime.GetFixedBarrel, handleBarrelReadError, runtime)
    if ok then
        self._barrelReadErrorLogged = false
    elseif not self._barrelReadErrorLogged then
        self._barrelReadErrorLogged = true
        Diagnostics.Exception("Integration", "barrel_read", barrel)
    end
    if ok and barrel and type(barrel.contentId) == "string" and barrel.position then
        self:RecognizeLocation(barrel.contentId, barrel.position)
    end
end

---@param self GameplayOceanBridge
---@param day integer
local function handleNewDay(self, day)
    refreshDynamicWorld(self, day, true)
    self:Sync()
    return true
end

---V2.8 海眼：正式 WorldDrop 落在核心 ≤5m 时的原子结算。
---只在 receiveDrop（底部【投放】选点 / 鱼饵“使用”选点）里调用；
---背包【丢弃】与鱼饵船边即时投饵都不走这里，因此绝不触发海眼。
---物品类型一律由 Items.VortexRole 的显式身份表决定，不用 worldEffect 推断：
---worldEffect=NONE 同时也是珠宝/珊瑚枝/深海珍珠/货箱的值，拿它当“大鱼”会串类型。
---@param self GameplayOceanBridge
---@param payload table
---@param position table
---@return boolean, table|nil 已处理=true 时不再走常规掉落
local function receiveVortexDrop(self, payload, position)
    local runtime, loop = self.runtime, self.loop
    if type(runtime.HandleVortexDrop) ~= "function" then return nil end
    local inside = type(runtime.IsInsideVortexDropRadius) == "function"
        and runtime:IsInsideVortexDropRadius(position)
    if not inside then return nil end

    -- 海眼只接受明确登记过的生态物；其余物品当作普通掉落处理（不触发海眼）。
    -- 三态返回：nil = 不归海眼管（走普通掉落）；true = 已处理；false = 归海眼管但本次拒绝。
    local role = Items.VortexRole(payload.itemId)
    if role == nil then return nil end

    if role == "pearl" then
        -- 大鱼：本周目首次 → 同一事务里消耗大鱼、释放 1 格、珍珠直接进该格。
        if not V28Progress.IsPearlClaimed(loop.player) then
            -- 原子性（V2.8 Closure）：先确认海眼后置表现真的可执行，
            -- 再提交珍珠/claim 状态。否则会出现「鱼被消耗 + 珍珠已发 + claim=true，
            -- 但海眼表现失败」的半完成态，且后续再投大鱼会落入「已领过」分支。
            local probeOk, probe = pcall(runtime.HandleVortexDrop, runtime, payload, position)
            if probeOk and probe then
                local claimed, reason = loop:ClaimVortexPearl(payload)
                payload.vortexFeedback = loop.lastMessage
                if claimed then return true end
                -- 珍珠发放失败：没有任何状态变更（ClaimVortexPearl 自回滚），
                -- 本次投放按普通掉落继续，不吞鱼。
                Diagnostics.Event("Integration", "vortex_pearl_claim_failed", {
                    kind = "failure", reason = tostring(reason or "pearl_claim_failed") })
                return false
            end
            -- 海眼后置表现不可执行：不消耗大鱼、不发珍珠、不置 claim。
            Diagnostics.Event("Integration", "vortex_post_effect_unavailable", {
                kind = "failure", reason = "post_effect_unavailable" })
            return false
        end
        -- 已领取过：仍消耗大鱼、不再产珍珠，只给反馈。
        local consumed = loop:ConsumeVortexBigFish(payload)
        payload.vortexFeedback = loop.lastMessage
        if consumed then
            runtime:HandleVortexDrop(payload, position)
            return true
        end
        return false
    end

    -- V2.8 Closure（第二轮审查）：HandleVortexDrop 只返回**一个**表（失败时返回 nil, reason），
    -- 旧实现写 `local handled, result = runtime:HandleVortexDrop(...)`，于是 result 恒为 nil，
    -- 下面两个 kind 分支永远不会命中 —— 苹果/小鱼投放只得到通用“已交接投放请求”，
    -- 玩家看不到海眼专属反馈。这里按真实返回值收。
    local result = runtime:HandleVortexDrop(payload, position)
    if not result then return false end
    if result.kind == "small" then
        payload.vortexFeedback = "吃食被卷入旋转的海眼，顺着水底暗流，气味向更远的海域扩散开去。"
    elseif result.kind == "big" then
        payload.vortexFeedback = "小鱼被海眼的暗流卷住，血腥与动静顺着涡流远远传开，远处的水面似乎有了躁动。"
    end
    return true
end

---@param self GameplayOceanBridge
---@param payload table
---@return boolean
local function receiveDrop(self, payload)
    local loop = self.loop
    local target = assert(self.loop.actions):GetDropTarget()
    -- Loop:DropItem sets dropInFlight around this synchronous handoff. Do not
    -- call Ready()/CanStartAction here: those intentionally reject in-flight work.
    if not loop or loop.dropInFlight ~= true or not target or not isPoint(target) then return false end

    local position = copyPoint(target)
    local distanceSquared = OceanMath.distanceSquared(self.runtime:GetShipPosition(), position)
    if distanceSquared > OceanConfig.interaction.maxThrowDistance ^ 2 then return false end

    -- V2.8 海眼：只响应正式投放（底部【投放】/ 鱼饵“使用”选点）。
    -- 背包【丢弃】与鱼饵船边即时投饵没有 officialThrow 标记，绝不触发。
    if payload.officialThrow == true then
        -- receiveVortexDrop 三态：nil = 不归海眼管（走普通掉落）；
        -- true = 已处理；false = 归海眼管但本次拒绝。
        local vortexHandled = receiveVortexDrop(self, payload, position)
        if vortexHandled == false then
            -- 本该由海眼处理的物品被拒（例如珍珠写入失败）：必须终止整个投放并让
            -- DropItem 回滚，不能掉进普通 WorldDrop——否则会出现“鱼被消耗、珍珠没发”。
            assert(self.loop.actions):SetDropTarget(nil)
            return false
        elseif vortexHandled == true then
            assert(self.loop.actions):SetDropTarget(nil)
            return true
        end
    end

    local spawnOk, entity = Diagnostics.Call("Integration", "drop_spawn", self.runtime.spawnDroppedItem, self.runtime, payload, position)
    if not spawnOk or not entity then return false end

    local externalReceiver = self._externalDropReceiver
    if externalReceiver then
        local callbackOk, accepted = Diagnostics.Call("Integration", "drop_receiver", externalReceiver, payload, copyPoint(position))
        if not callbackOk or accepted ~= true then
            self.runtime:RejectDroppedItem(entity.id)
            return false
        end
    end

    assert(self.loop.actions):SetDropTarget(nil)
    return true
end

---@param runtime table
---@param options table|nil
---@return GameplayOceanBridge
function Bridge.New(runtime, options)
    assert(type(runtime) == "table", "Ocean runtime is required")
    assert(type(runtime.refreshOrdinaryFish) == "function", "runtime.refreshOrdinaryFish is required")
    assert(type(runtime.spawnDroppedItem) == "function", "runtime.spawnDroppedItem is required")
    assert(type(runtime.SetShipLevel) == "function", "runtime.SetShipLevel is required")
    assert(type(runtime.Update) == "function", "runtime.Update is required")

    local supplied = options or {}
    local self = setmetatable({
        runtime = runtime,
        _externalDropReceiver = supplied.dropReceiver,
    }, Bridge)

    local loopOptions = copyOptions(supplied)
    local externalNewDay = supplied.onNewDay
    local externalReset = supplied.resetDynamicWorld
    loopOptions.dropReceiver = function(payload)
        return receiveDrop(self, payload)
    end
    loopOptions.onNewDay = function(day)
        handleNewDay(self, day)
        if externalNewDay then return externalNewDay(day) end
    end
    loopOptions.resetDynamicWorld = function()
        refreshDynamicWorld(self, self.loop.player.day, true)
        self.runtime:ClearMovementTarget()
        self:Sync()
        if externalReset then return externalReset() end
        return true
    end
    loopOptions.prepareLoadedWorld = function(day)
        return refreshDynamicWorld(self, day, true)
    end

    self.loop = Loop.New(loopOptions)
    self.loop:EnableWorldActions():BindRuntime(runtime)
    self.loop:BindRuntime(runtime)
    -- V2.8：绘制侧只读查询——漂流瓶是否已拾取（由残页持有派生）。
    runtime.isV28Picked = function(contentId)
        return V28Progress.IsBottlePicked(self.loop.player, contentId)
    end
    self.game = Game.New(runtime, self.loop)
    self.game.afterWorldUpdate = function() self:ProcessAutoReturnArrival() end
    self.loop:SetStateObserver(function() self:Sync() end)

    self:Sync()
    return self
end

---Clock pause state is authoritative; Runtime.paused is only its mirror.
---@return boolean paused, number shipLevel, boolean scopeSynced, string? scopeReason
function Bridge:Sync()
    return self.game:Sync()
end

---Advance the gameplay clock with raw dt; Ocean Runtime applies its own
---simulation clamp internally and does not own the game's day/night clock.
---@param dt number
---@param axisX number|nil
---@param axisY number|nil
---@return boolean, number|string
function Bridge:Update(dt, axisX, axisY)
    if not isFiniteNumber(dt) or dt < 0 then return false, "invalid_dt" end
    local keyboardActive = isFiniteNumber(axisX) and math.abs(axisX) > OceanConfig.world.epsilon
        or isFiniteNumber(axisY) and math.abs(axisY) > OceanConfig.world.epsilon
    if keyboardActive then
        local cancelled, reason = self.loop:CancelAutoReturn("keyboard_movement")
        if not cancelled then return false, reason or "auto_return_cancel_failed" end
    end
    self.game:Update(dt, axisX, axisY)
    -- 逐帧识别（契约：getter 异常只记一次直至恢复；快照必须每次新鲜）。
    -- GC 优化只做无闭包化（handler 提升），不节流、不改快照语义。
    recognizeFixedBarrel(self)
    recognizeV28Proximity(self)
    return true, dt
end

---Toggle only the manual pause reason; other pause owners remain intact.
---@return boolean, boolean
function Bridge:TogglePause()
    local toggled, reason = self.loop:ToggleManualPause()
    if not toggled then return false, reason end
    self:Sync()
    return true, self.loop.clock:IsPaused()
end

---@return boolean, string?
function Bridge:NewRun()
    return self.loop:NewRun()
end

---Store an explicit world-space drop target. Runtime spawn remains the final
---authority for the configured throw radius and playable-world validity.
---@param position any
---@return boolean, string?
function Bridge:SetDropTarget(position)
    -- A new pointer selection supersedes any prior target, even if this
    -- selection itself is invalid; a failed click must never drop at an old spot.
    assert(self.loop.actions):SetDropTarget(nil)
    if not isPoint(position) then return false, "invalid_drop_position" end
    local target = copyPoint(position)
    if not self.runtime:IsPositionFree(target, 0) then
        return false, "invalid_drop_position"
    end
    assert(self.loop.actions):SetDropTarget(target)
    return true
end

function Bridge:BeginFishing(center)
    local cancelled, reason = self.loop:CancelAutoReturn("fishing")
    if not cancelled then return false, reason end
    return assert(self.loop.actions):BeginFishing(center, self.runtime)
end

function Bridge:CompleteFishing(token, ...)
    return assert(self.loop.actions):CompleteFishing(self.runtime, token, ...)
end

function Bridge:CancelFishing(token)
    return assert(self.loop.actions):CancelFishing(token)
end

function Bridge:HandleThrowPointer(position)
    local selected = self.loop:GetThrowSelection()
    if not selected then return false, "throw_selection_required" end
    if self.loop.player.inventory:GetItems()[selected.index] ~= selected.itemId then
        self.loop:CancelThrowSelection()
        return false, "throw_item_changed"
    end
    local valid, reason = self:SetDropTarget(position)
    self.runtime:ClearMovementTarget()
    if not valid then return false, reason end
    local dropped, dropReason = self.loop:DropItem(selected.index)
    self:Sync()
    return dropped, dropReason
end

-- The consumption return value is the new Ocean input protocol. Clearing its
-- movement target also protects the older local adapter that ignores this value.
function Bridge:OnSeaPointer(position)
    local cancelled, cancelReason = self.loop:CancelAutoReturn("manual_sea_pointer")
    if not cancelled then
        self.loop:SetMessage(tostring(cancelReason or "auto_return_cancel_failed"))
        return true
    end
    local fishing = self.loop:GetFishingState()
    if fishing.state == "selecting" then
        self.runtime:ClearMovementTarget()
        local ok, reason = self.loop:SetFishingCenter(position)
        -- One legal mouse/touch sea pointer starts the cast. Invalid positions
        -- keep selection active and never fall through to navigation.
        if ok then ok, reason = self.loop:ConfirmFishing() end
        if not ok then self.loop:SetMessage(tostring(reason)) end
        return true
    end
    if self.loop:IsMovementBlocked() and not self.loop:GetThrowSelection() then
        self.runtime:ClearMovementTarget()
        return true
    end
    if self.loop:GetThrowSelection() then
        local ok, reason = self:HandleThrowPointer(position)
        if not ok then self.loop:SetMessage(tostring(reason)) end
        return true
    end
    return false
end

---Persist a location recognition only when the supplied world point is within
---the A interaction radius. No location entity is spawned or required.
---@param locationId string
---@param position any
---@return boolean, boolean|string
function Bridge:ProcessAutoReturnArrival()
    local runtime = self.runtime
    if type(runtime.ConsumeAutoReturnArrival) ~= "function" then return true end
    local consumed, arrival = Diagnostics.Call("Integration", "auto_return_consume_arrival",
        runtime.ConsumeAutoReturnArrival, runtime)
    if not consumed then return false, "auto_return_arrival_read_failed" end
    if not arrival then return true end
    local returnedOk, returned, reason = Diagnostics.Call("Integration", "auto_return_return_to_port",
        self.loop.ReturnToPort, self.loop)
    if not returnedOk then reason, returned = returned, false end
    if returned == true then return true end
    local failureReason = type(reason) == "string" and reason or "return_to_port_rejected"
    local rejected, accepted = Diagnostics.Call("Integration", "auto_return_reject_arrival",
        runtime.RejectAutoReturnArrival, runtime, failureReason)
    if not rejected or accepted == false then
        Diagnostics.Event("Integration", "auto_return_arrival_rejection_failed", {
            kind = "failure", reason = failureReason })
    end
    return false, failureReason
end

function Bridge:RequestAutoReturn()
    return self.loop:RequestAutoReturn()
end

function Bridge:CancelAutoReturn(reason)
    return self.loop:CancelAutoReturn(reason)
end

function Bridge:GetAutoReturnState()
    return self.loop:GetAutoReturnState()
end

function Bridge:GetWorldContentPrompt()
    return self.loop:GetWorldContentPrompt()
end

function Bridge:BeginWorldContentAction(contentId, actionKind)
    return self.loop:BeginWorldContentAction(contentId, actionKind)
end

function Bridge:CancelWorldContentAction(token, reason)
    return self.loop:CancelWorldContentAction(token, reason)
end

function Bridge:GetWorldContentActionState()
    return self.loop:GetWorldContentActionState()
end

function Bridge:GetOwnedTreasures()
    return self.loop:GetOwnedTreasures()
end

function Bridge:ShowTreasureToElder(treasureId)
    return self.loop:ShowTreasureToElder(treasureId)
end

function Bridge:RecognizeLocation(locationId, position)
    if type(locationId) ~= "string" or locationId == "" then
        return false, "invalid_location_id"
    end
    if not isPoint(position) then return false, "invalid_location_position" end
    if OceanMath.distanceSquared(self.runtime:GetShipPosition(), position)
        > OceanConfig.interaction.recognitionDistance ^ 2 then
        return false, "location_out_of_range"
    end
    return self.loop:RecognizeLocation(locationId)
end

---Explicitly load saved B player state. Bridge never autoloads in New().
---@param callback fun(ok:boolean, data:any)|nil
---@return boolean started, string|nil reason
function Bridge:LoadSaved(callback)
    if self.loop:HasPendingCatch() then return false, "pending_catch_required" end
    local function loaded(ok, data)
        if ok and data ~= nil then
            assert(self.loop.actions):SetDropTarget(nil)
            assert(self.loop.actions):Reset(true)
            self.runtime:ClearMovementTarget()
        end
        self:Sync()
        if callback then callback(ok, data) end
    end
    return self.loop:LoadSaved(loaded)
end

return Bridge
