-- B 玩法协调器；不依赖船位、World、鱼 FSM 或现有 Ocean 演示状态。
local Config = require("config.gameplay")
local Items = require("data.items")
local PlayerState = require("Gameplay.PlayerState")
local GameClock = require("Gameplay.GameClock")
local Persistence = require("Gameplay.Persistence")
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
---@field saveStatus string
---@field lastMessage string
---@field shopStock table<string, integer>
local Loop = {}
Loop.__index = Loop

function Loop.New(options)
    local self = setmetatable({}, Loop)
    self:Init(options or {})
    return self
end

function Loop:Init(options)
    self.options = options
    self.store = options.store or Persistence.Cloud(options.cloud)
    self.generation = 0
    self:ResetState()
end

function Loop:ResetState()
    self.generation = self.generation + 1
    self.player = assert(PlayerState.New())
    self:ResetShopStock()
    self.clock = GameClock.New()
    self.inPort = true
    self.inventoryOpen, self.elderOpen = false, false
    self.forcedReturnPending, self.settlementPending = false, false
    self.dayExhausted, self.settlementApplied = false, false
    self.busy, self.loading = false, false
    self.dropInFlight = false
    self.saveStatus, self.lastMessage = "idle", "新周目已开始"
    self.portNightElapsed = 0
    self.settlementForced = false
    self.settlementSnapshot = {}
    self.clock:Pause("port")
end

function Loop:Ready()
    return not self.busy and not self.loading and not self.dropInFlight
        and not self.forcedReturnPending and not self.settlementPending
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

function Loop:Update(dt)
    self.clock:Update(dt)
    if self.clock.exhausted and not self.dayExhausted then
        self.dayExhausted = true
        self.forcedReturnPending = true
        self.clock:Pause("forced_return")
        self.lastMessage = "夜深了，你必须返港。"
    end
end

function Loop:SetInventoryOpen(open)
    if type(open) ~= "boolean" or not self:Ready() then return false, "busy" end
    self.inventoryOpen = open
    if open then self.clock:Pause("inventory") else self.clock:Resume("inventory") end
    return true
end

function Loop:SetElderOpen(open)
    if type(open) ~= "boolean" or not self:Ready() then return false, "busy" end
    self.elderOpen = open
    if open then self.clock:Pause("elder") else self.clock:Resume("elder") end
    return true
end

function Loop:ReturnToPort()
    if not self:Ready() then return false, "busy" end
    if self.inPort then return true end
    self.inPort = true
    self.portNightElapsed = self.clock.phase == "night" and self.clock.elapsed or 0
    self.clock:Pause("port")
    self.lastMessage = "已返港，可交易、结束今天或再次出航"
    return true
end

function Loop:Depart()
    if not self:Ready() or self.dayExhausted or self.clock.exhausted then return false, "day_finished" end
    if self.inventoryOpen or self.elderOpen then return false, "close_dialog_first" end
    self.inPort = false
    self.clock:Resume("port")
    self.lastMessage = "已出航"
    return true
end

function Loop:EndToday()
    if not self:Ready() or not self.inPort then return false, "port_required" end
    self.settlementPending, self.settlementForced = true, false
    self.clock:Pause("settlement")
    self.lastMessage = "确认结束今天并进入下一天？"
    return true
end

function Loop:ConfirmForcedReturn()
    if not self.forcedReturnPending or self.busy or self.loading then return false, "no_forced_return" end
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
    local penalty = math.floor(math.max(0, elapsed - Config.clock.graceSec) * Config.clock.penaltyPerSec)
    return math.max(0, self.player.maxStamina - penalty)
end

function Loop:BeginNewDay()
    -- 对外只允许由已经确认的结算调用，防止海上绕过处罚/自动存档。
    if not self.settlementPending or self.settlementApplied then return false, "settlement_required" end
    local stamina = self:GetNextDayStamina(self.settlementForced)
    self.player.day = self.player.day + 1
    self:ResetShopStock()
    self.player.stamina = stamina
    self.clock:Reset()
    self.clock:Pause("port")
    self.clock:Pause("settlement")
    self.inPort, self.dayExhausted = true, false
    self.inventoryOpen, self.elderOpen = false, false
    self.portNightElapsed = 0
    self.settlementApplied = true
    self.settlementSnapshot = Persistence.Snapshot(self.player)
    return true
end

function Loop:ConfirmSettlement()
    if not self.settlementPending or self.busy or self.loading then return false, "no_settlement" end
    if not self.settlementApplied then self:BeginNewDay() end
    self.busy, self.saveStatus = true, "saving"
    local generation = self.generation
    local completed = false
    local function done(ok, reason)
        if completed or generation ~= self.generation then return end
        completed = true
        self.busy = false
        self.saveStatus = ok and "saved" or "error"
        if not ok then
            self.lastMessage = "结算存档失败，可重试同一结算：" .. tostring(reason)
            return
        end
        self.settlementPending, self.settlementApplied = false, false
        self.clock:Resume("settlement")
        self.lastMessage = "每日结算已保存，下一天已就绪"
        if self.options.onNewDay then
            local hookOk, hookErr = pcall(self.options.onNewDay, self.player.day)
            if not hookOk then self.lastMessage = "存档成功，世界刷新接口失败：" .. tostring(hookErr) end
        end
    end
    local ok, err = pcall(self.store.Save, self.store, self.settlementSnapshot, done)
    if not ok then done(false, err) end
    return true
end

function Loop:SettleDay()
    if not self.inPort then local ok, err = self:ReturnToPort(); if not ok then return false, err end end
    return self:EndToday()
end

function Loop:LoadSaved(done)
    if not self:Ready() or not self.inPort then return false, "busy_or_at_sea" end
    self.loading = true
    self.clock:Pause("loading")
    local generation = self.generation
    local completed = false
    local function loaded(ok, data)
        if completed or generation ~= self.generation then return end
        completed = true
        self.loading = false
        self.clock:Resume("loading")
        if ok and data ~= nil then
            local restoreOk, player, err = pcall(Persistence.Restore, data)
            if restoreOk and player then
                self.player = player
                self:ResetShopStock()
                self.clock:Reset()
                self.clock:Pause("port")
                self.inventoryOpen, self.elderOpen = false, false
                self.portNightElapsed = 0
                self.lastMessage = "已加载每日结算存档"
            else ok, data = false, restoreOk and err or player end
        end
        if not ok then self.lastMessage = "读档失败，保留当前状态：" .. tostring(data) end
        if done then done(ok, data) end
    end
    local ok, err = pcall(self.store.Load, self.store, loaded)
    if not ok then loaded(false, err) end
    return true
end

function Loop:NewRun()
    if not self:Ready() then return false, "busy" end
    self:ResetState()
    if self.options.resetDynamicWorld then
        local ok, err = pcall(self.options.resetDynamicWorld)
        if not ok then self.lastMessage = "新周目已重置，世界接口失败：" .. tostring(err) end
    end
    -- 新周目不创建额外正常存档点；下一次结算覆盖旧存档。
    return true
end

function Loop:CanStartAction(action)
    if not self:Ready() or self.inPort or self.clock:IsPaused() then return false, "action_blocked" end
    local cost = action == "fishing" and Config.stamina.fishingCost
        or action == "salvage" and Config.stamina.salvageCost
    if not cost then return false, "unknown_action" end
    return self.player:CanConsumeStamina(cost)
end

function Loop:CompleteAction(action)
    local ok, err = self:CanStartAction(action)
    if not ok then return false, err end
    local cost = action == "fishing" and Config.stamina.fishingCost or Config.stamina.salvageCost
    return self.player:ConsumeStamina(cost)
end

function Loop:UseItem(index)
    if not self:Ready() then return false, "busy" end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition then return false, "invalid_item" end
    if not definition.heal or definition.heal <= 0 then return self:DropItem(index) end
    local ok, err = self.player.inventory:Remove(index)
    if not ok then return false, err end
    self.player:RestoreStamina(definition.heal)
    self.lastMessage = "使用了" .. definition.name
    return true
end

function Loop:DropItem(index)
    if not self:Ready() or self.inPort then return false, "sea_required" end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition then return false, "invalid_item" end
    if not self.options.dropReceiver then return false, "drop_receiver_unavailable" end
    local payload = { itemId = id, category = definition.category,
        worldEffect = definition.worldEffect, lifetimeSec = definition.lifetimeSec }
    self.dropInFlight = true
    -- receiver 必须同步确认交接成功（true）。没有世界坐标的 B 不自行创建对象。
    local ok, accepted = pcall(self.options.dropReceiver, payload)
    self.dropInFlight = false
    if not ok or accepted ~= true then return false, "drop_rejected" end
    self.player.inventory:Remove(index)
    self.lastMessage = "已交接投放请求：" .. definition.name
    return true, payload
end

function Loop:GiveToElder(index)
    if not self:Ready() or not self.elderOpen then return false, "elder_dialog_required" end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition or not definition.canGive then return false, "invalid_item" end
    self.dropInFlight = true
    local ok, accepted, message = true, true, "老人收下了" .. definition.name
    if self.options.elderReceiver then ok, accepted, message = pcall(self.options.elderReceiver, id) end
    self.dropInFlight = false
    if not ok or accepted ~= true then return false, "elder_rejected" end
    self.player.inventory:Remove(index)
    self.player.elder.lastGivenItemId = id
    self.lastMessage = message or "老人收下了物品。"
    return true
end

function Loop:Buy(itemId)
    if not self:Ready() or not self.inPort then return false, "port_required" end
    local definition = Items.GetDefinition(itemId)
    if not definition or not definition.buyPrice then return false, "not_for_sale" end
    if self:GetShopStock(itemId) <= 0 then return false, "shop_sold_out" end
    if self.player.money < definition.buyPrice then return false, "insufficient_money" end
    if not self.player.inventory:HasSpace() then return false, "inventory_full" end
    local ok, err = self.player.inventory:Add(itemId)
    if not ok then return false, err end
    self.player:ChangeMoney(-definition.buyPrice)
    self.shopStock[itemId] = self.shopStock[itemId] - 1
    self.lastMessage = "已购买" .. definition.name
    return true
end

function Loop:Sell(index)
    if not self:Ready() or not self.inPort then return false, "port_required" end
    local id = self.player.inventory:GetItems()[index]
    local definition = id and Items.GetDefinition(id)
    if not definition or not definition.sellPrice or definition.sellPrice <= 0 then return false, "not_sellable" end
    local ok, err = self.player.inventory:Remove(index)
    if not ok then return false, err end
    self.player:ChangeMoney(definition.sellPrice)
    self.lastMessage = "已出售" .. definition.name
    return true
end

function Loop:UpgradeInventory()
    if not self:Ready() or not self.inPort then return false, "port_required" end
    local price = Config.upgrades.inventory.prices[self.player.inventory:GetLevel()]
    if not price then return false, "maximum_level" end
    if self.player.money < price then return false, "insufficient_money" end
    local ok, err = self.player.inventory:Upgrade()
    if not ok then return false, err end
    self.player:ChangeMoney(-price)
    self.lastMessage = "船舱已扩容"
    return true
end

function Loop:GetStaminaLevel()
    for level, maximum in ipairs(Config.upgrades.stamina.maxima) do
        if self.player.maxStamina == maximum then return level end
    end
    return nil -- 兼容已有自定义上限，不能猜测对应的购买等级。
end

function Loop:UpgradeStamina()
    if not self:Ready() or not self.inPort then return false, "port_required" end
    local level = self:GetStaminaLevel()
    if not level then return false, "unsupported_stamina_level" end
    local price = Config.upgrades.stamina.prices[level]
    if not price then return false, "maximum_level" end
    if self.player.money < price then return false, "insufficient_money" end
    local maximum = Config.upgrades.stamina.maxima[level + 1]
    if not maximum then return false, "invalid_upgrade_configuration" end
    self.player.stamina = self.player.stamina + maximum - self.player.maxStamina
    self.player.maxStamina = maximum
    self.player:ChangeMoney(-price)
    self.lastMessage = "体力上限已升级"
    return true
end

function Loop:UpgradeBoatSpeed()
    if not self:Ready() or not self.inPort then return false, "port_required" end
    local price = Config.upgrades.boatSpeed.prices[self.player.boatSpeedLevel]
    if not price then return false, "maximum_level" end
    if self.player.money < price then return false, "insufficient_money" end
    self.player.boatSpeedLevel = self.player.boatSpeedLevel + 1
    self.player:ChangeMoney(-price)
    self.lastMessage = "航速等级已购买，实际速度由世界侧应用"
    return true
end

-- A 确认动作成立后提交 0/1 捕获数量；空网也扣成本。物品交付仍走 Inventory:Add。
function Loop:CompleteFishing(catchCount)
    if catchCount ~= 0 and catchCount ~= 1 then return false, "invalid_catch_count" end
    return self:CompleteAction("fishing")
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
    return self.player:ConsumeStamina(Config.stamina.eventOperationCost)
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
