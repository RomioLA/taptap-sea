-- B 玩法 HUD 原型。UI 生命周期由宿主负责，本模块只创建和管理自己的子树。
local UI = require("urhox-libs/UI")
local Config = require("config.gameplay")
local Items = require("data.items")
local Diagnostics = require("Gameplay.Diagnostics")

local HUD = {}

---@class HUDFishingCenter
---@field x number
---@field y number

---@class HUDFishingState
---@field state "idle"|"selecting"|"casting"|"landed"|"complete"|"failed"|"cancelled"|"cleanup_pending"|"rollback_pending"|"committing"
---@field center HUDFishingCenter?
---@field elapsed number?
---@field duration number?
---@field reason string?

---@class HUDPendingCatch
---@field itemIds string[]
---@field requiredSlots number

---@class HUDElderStatus
---@field applesGiven number
---@field decision "pending"|"saved"|"dead"|string
---@field present boolean

---@class HUDBarrelState
---@field stage number
---@field active boolean
---@field pending boolean
---@field elapsed number
---@field duration number
---@field remaining number
---@field timingAvailable boolean
---@field interfaceAvailable boolean

---@class HUDStoryDialog
---@field token table
---@field kind "paper"
---@field text string

---@class HUDThrowSelection
---@field index number
---@field itemId string

local ERROR_MESSAGES = {
    busy = "当前操作尚未完成",
    port_interface_unavailable = "港口位置接口暂不可用，无法确认交易权限。",
    port_out_of_range = "距港超过10米；请航行到港口标记10米内，再返港或交易。",
    port_reset_unavailable = "实际返港接口暂不可用，请稍后重试。",
    port_reset_failed = "船只未能回到港口，请重试。",
    cargo_changed = "船舱物品已变化，请重新选择要出售的鱼。",
    transaction_failed = "交易未完成，金钱与物品已恢复，请重试。",
    transaction_snapshot_failed = "暂时无法核对交易物品，请重试。",
    inventory_rollback_pending = "物品正在恢复，请稍后重试。",
    speed_upgrade_failed = "海洋船速未能更新，本次升级已撤销，请重试。",
    maximum_level = "已经达到最高等级。",
    unsupported_stamina_level = "当前体力上限没有对应的升级方案。",
    invalid_upgrade_configuration = "升级数据暂不可用。",
    busy_or_at_sea = "请先在港口结束当前操作，再读取存档。",
    scene_closed = "场景已经关闭。",
    no_settlement = "当前没有待确认的日结。",
    no_failed_settlement = "当前没有可放弃的保存。",
    new_day_preparation_failed = "港口或海洋准备未完成，请重试。",
    settlement_snapshot_failed = "日结快照尚未生成，请重试保存。",
    fishing_runtime_interface_unavailable = "捕鱼接口暂未就绪，请稍后重试。",
    fishing_requires_bridge_token = "请从正式捕鱼按钮开始操作。",
    pending_catch_required = "请先处理已有待接收收获；物品会完整保留。",
    no_forced_return = "当前没有待确认的强制返港。",
    ["insufficient money"] = "余额不足。",
    day_finished = "今天已经结束",
    port_required = "请先返港",
    close_dialog_first = "请先关闭当前界面",
    inventory_full = "背包已满",
    unknown_item = "未知物品",
    not_enough_money = "钱不够",
    not_enough_stamina = "体力不足",
    ["insufficient stamina"] = "体力不足",
    cannot_use_item = "现在无法使用该物品",
    cannot_give_item = "老人不收这件物品",
    insufficient_money = "钱不够",
    not_for_sale = "该物品不出售",
    shop_sold_out = "今日已售罄，明天补货",
    invalid_item = "物品已不存在或无法使用",
    sea_required = "请先出海",
    elder_dialog_required = "请先打开老人对话",
    elder_not_present = "老人不在船上，当前无法赠送。",
    item_has_no_use = "该物品没有可用效果，无法使用。",
    throw_selection_pending = "请先完成或取消当前投掷选择。",
    treasure_unavailable = "当前没有可展示的透镜。",
    scope_not_owned = "尚未获得透镜。",
    elder_progress_failed = "老人救助进度未能更新，苹果已保留，请重试。",
    scope_interface_unavailable = "望远镜控制接口暂不可用。",
    scope_sync_failed = "望远镜状态同步失败，请重试关闭。",
    stale_barrel_action = "木桶已变化，当前检查已取消，请重新开始。",
    stale_barrel_stage = "木桶进度已变化，请重新检查。",
    barrel_executor_failed = "木桶检查未能完成，本次不扣体力。",
    barrel_timing_unconfirmed = "木桶检查暂未开放。",
    barrel_interface_unavailable = "木桶检查暂未开放。",
    barrel_unavailable = "木桶检查暂未开放。",
    barrel_out_of_range = "请靠近海岸边的木桶。",
    barrel_finished = "木桶调查已完成。",
    barrel_cancel_failed = "木桶检查取消失败，请稍后重试。",
    barrel_commit_failed = "木桶检查结果未能保存，请稍后重试。",
    barrel_rollback_pending = "木桶检查正在恢复物品，请稍后重试。",
    barrel_action_not_completed = "木桶检查尚未完成。",
    paper_day_required = "这张纸条要到第 7 天才能查看。",
    day_required = "这张纸条要到第 7 天才能查看。",
    paper_already_shown = "这张纸条已经看过了。",
    stale_story_dialog = "纸条状态已更新，请重新打开。",
    drop_receiver_unavailable = "附近没有接收地点，物品仍保留在背包里",
    drop_rejected = "没有接收地点接收物品，物品仍保留在背包里",
    invalid_drop_position = "请在海面选择有效投放点。",
    throw_out_of_range = "投掷距离太远，请点击 12 米内的海面。",
    throw_selection_required = "请先选择要投掷的物品。",
    throw_item_changed = "所选物品已变化，请重新选择。",
    elder_rejected = "老人没有收下这件物品",
    not_sellable = "这件物品不能出售",
    action_blocked = "当前不能进行该动作",
    elapsed_exceeds_phase = "跳转时间超过了该昼夜阶段长度",
    invalid_elapsed = "请输入有效的跳转秒数",
    development_only = "仅开发模式允许此操作",
    time_scale_not_configured = "时间倍率不在配置列表中",
    invalid_time_scale = "请输入有效的时间倍率",
    unknown_debug_command = "未知调试命令",
}

local function userMessage(value)
    if value == nil then return "" end
    local text = tostring(value)
    if ERROR_MESSAGES[text] then return ERROR_MESSAGES[text] end
    if text:find("[A-Za-z_]") and not text:find("[\128-\255]") then
        return "操作暂未完成，当前进度保留，请稍后重试。"
    end
    return text
end

local function saveText(loop)
    if loop.loading then return "读取存档中…" end
    local status = loop.saveStatus
    if status == "idle" or status == nil then return "尚未保存" end
    if status == "saving" then return "正在自动保存…" end
    if status == "saved" then return "已自动保存" end
    if status == "error" then return "自动保存失败，可重试" end
    if status == "skipped" then return "本次结算未保存" end
    return "存档状态：" .. tostring(status)
end

---@return string[]
local function copyItems(loop)
    local inventory = loop.player and loop.player.inventory
    if not inventory then return {} end
    local source = inventory:GetItems()
    local result = {}
    for index, itemId in ipairs(source or {}) do result[index] = itemId end
    return result
end

local function itemName(itemId)
    local definition = Items.GetDefinition(itemId)
    return definition and definition.name or tostring(itemId)
end

local function makeLabel(text, size, color, weight)
    return UI.Label {
        text = text,
        fontSize = size or 14,
        fontColor = color or { 237, 231, 215, 255 },
        fontWeight = weight or "normal",
        whiteSpace = "normal",
    }
end

local function makeButton(text, onClick, variant, width)
    return UI.Button {
        text = text,
        variant = variant or "secondary",
        width = width or "auto",
        minHeight = 38,
        fontSize = 13,
        onClick = function() onClick() end,
    }
end

function HUD.Create(loop, parent, debugTools)
    if not loop then error("HUD.Create requires a gameplay loop", 2) end

    ---@class HUDLocalState
    ---@field destroyed boolean
    ---@field localMessage string
    ---@field inventorySignature string
    ---@field lastTexts table<string, string>
    ---@field seekText string
    ---@field addItemText string
    ---@field selectedItemIndex number|nil
    ---@field storyShownToken table|nil
    ---@type HUDLocalState
    local state = {
        destroyed = false,
        localMessage = "",
        inventorySignature = "",
        lastTexts = {},
        seekText = "",
        addItemText = "",
        selectedItemIndex = nil,
        storyShownToken = nil,
    }
    ---@type table<string, any>
    local refs = {}
    local refresh = function() end
    ---@type fun(methodName: string, ...: any)
    local invokeLoop = function(methodName, ...) end
    ---@type fun(command: string, argument?: number|string)
    local invokeDebug = function(command, argument) end

    local function setText(widget, key, value)
        local text = tostring(value or "")
        if state.lastTexts[key] == text then return end
        state.lastTexts[key] = text
        widget:SetText(text)
    end

    local function card(title)
        local panel = UI.Panel {
            width = "100%",
            padding = 10,
            gap = 7,
            flexDirection = "column",
            backgroundColor = { 31, 48, 51, 238 },
            borderColor = { 102, 133, 124, 210 },
            borderWidth = 1,
            borderRadius = 8,
        }
        panel:AddChild(makeLabel(title, 16, { 237, 213, 159, 255 }, "bold"))
        return panel
    end

    local root = UI.SafeAreaView {
        width = "100%",
        height = "100%",
        padding = 12,
        gap = 8,
        flexDirection = "column",
        pointerEvents = "box-none",
    }

    local header = UI.Panel {
        width = "100%",
        minHeight = 48,
        flexDirection = "row",
        alignItems = "center",
        gap = 8,
        paddingHorizontal = 10,
        backgroundColor = { 27, 42, 48, 238 },
        borderRadius = 8,
    }
    refs.title = makeLabel("渔夫漂流记", 19, { 246, 223, 171, 255 }, "bold")
    refs.day = makeLabel("第 1 天", 14)
    refs.phase = makeLabel("白天 · 剩余 -- 秒", 14)
    refs.money = makeLabel("钱：0", 14, { 249, 211, 118, 255 }, "bold")
    header:AddChild(refs.title)
    header:AddChild(refs.day)
    header:AddChild(refs.phase)
    header:AddChild(UI.Spacer())
    header:AddChild(refs.money)
    refs.debugToggle = makeButton("开发调试", function()
        if refs.debugPanel then refs.debugPanel:SetVisible(not refs.debugPanel:IsVisible()) end
    end, "secondary", 92)
    if debugTools and debugTools.enabled == true then header:AddChild(refs.debugToggle) end
    root:AddChild(header)

    local stats = UI.Panel {
        width = "100%",
        minHeight = 42,
        flexDirection = "row",
        alignItems = "center",
        gap = 14,
        paddingHorizontal = 10,
        backgroundColor = { 42, 59, 59, 225 },
        borderRadius = 7,
    }
    refs.stamina = makeLabel("体力：0/0", 14)
    refs.pauseReasons = makeLabel("暂停：无", 12, { 180, 203, 191, 255 })
    refs.save = makeLabel("尚未保存", 12, { 181, 203, 193, 255 })
    stats:AddChild(refs.stamina)
    stats:AddChild(refs.pauseReasons)
    stats:AddChild(UI.Spacer())
    stats:AddChild(refs.save)
    root:AddChild(stats)

    refs.inventorySummary = makeLabel("背包 0 / 0 格：空", 12, { 184, 204, 190, 255 })
    root:AddChild(refs.inventorySummary)

    refs.message = makeLabel("", 13, { 245, 223, 174, 255 })
    refs.messagePanel = UI.Panel {
        width = "100%",
        minHeight = 28,
        paddingHorizontal = 10,
        justifyContent = "center",
        backgroundColor = { 42, 59, 59, 190 },
        borderRadius = 6,
        children = { refs.message },
    }
    root:AddChild(refs.messagePanel)

    refs.portAccessReason = makeLabel("锚形标记=港口（交易中心）· 返港/交易需距港≤10米。", 12, { 203, 218, 202, 255 })
    root:AddChild(refs.portAccessReason)

    refs.fishingPanel = card("捕鱼")
    refs.fishingStatus = makeLabel("选择海面网心开始捕鱼。", 13)
    refs.fishingProgress = makeLabel("动作进度：0%", 12, { 180, 203, 191, 255 })
    refs.fishingResult = makeLabel("", 13, { 249, 211, 118, 255 }, "bold")
    refs.fishingPanel:AddChild(refs.fishingStatus)
    refs.fishingPanel:AddChild(refs.fishingProgress)
    refs.fishingPanel:AddChild(refs.fishingResult)
    local fishingButtons = UI.Panel {
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
        gap = 7,
    }
    refs.beginFishing = makeButton("捕鱼 · 选择网心", function()
        invokeLoop("BeginFishingSelection")
    end, "primary", 138)
    refs.confirmFishing = makeButton("确认抛网", function()
        invokeLoop("ConfirmFishing")
    end, "primary", 96)
    refs.cancelFishing = makeButton("取消捕鱼", function()
        invokeLoop("CancelFishingAction")
    end, "danger", 88)
    fishingButtons:AddChild(refs.beginFishing)
    fishingButtons:AddChild(refs.confirmFishing)
    fishingButtons:AddChild(refs.cancelFishing)
    refs.fishingPanel:AddChild(fishingButtons)
    root:AddChild(refs.fishingPanel)

    local actionBar = UI.Panel {
        width = "100%",
        minHeight = 42,
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
        gap = 7,
    }
    refs.depart = makeButton("出航", function() invokeLoop("Depart") end, "primary", 80)
    refs.returnToPort = makeButton("返港", function() invokeLoop("ReturnToPort") end, "secondary", 80)
    refs.endToday = makeButton("结束今日", function() invokeLoop("EndToday") end, "primary", 98)
    refs.loadSaved = makeButton("读取云存档", function() invokeLoop("LoadSaved") end, "secondary", 110)
    refs.newRun = makeButton("开始新周目", function() invokeLoop("NewRun") end, "secondary", 110)
    refs.inventoryToggle = makeButton("背包", function()
        invokeLoop("SetInventoryOpen", not (loop.inventoryOpen == true))
    end, "secondary", 80)
    refs.elderToggle = makeButton("拜访老人", function()
        invokeLoop("SetElderOpen", not (loop.elderOpen == true))
    end, "secondary", 98)
    actionBar:AddChild(refs.depart)
    actionBar:AddChild(refs.returnToPort)
    actionBar:AddChild(refs.endToday)
    actionBar:AddChild(refs.inventoryToggle)
    actionBar:AddChild(refs.elderToggle)
    actionBar:AddChild(refs.loadSaved)
    actionBar:AddChild(refs.newRun)
    root:AddChild(actionBar)

    local contentScroll = UI.ScrollView {
        id = "gameplayContentScroll",
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        scrollY = true,
        showScrollbar = true,
    }
    local content = UI.Panel {
        width = "100%",
        gap = 8,
        flexDirection = "column",
    }
    contentScroll:AddChild(content)

    refs.throwSelectionPanel = card("投掷物品")
    refs.throwSelectionText = makeLabel("", 13, { 255, 236, 207, 255 }, "bold")
    refs.throwSelectionPanel:AddChild(refs.throwSelectionText)
    refs.throwSelectionCancel = makeButton("取消投掷", function()
        invokeLoop("CancelThrowSelection")
    end, "secondary", 94)
    refs.throwSelectionPanel:AddChild(refs.throwSelectionCancel)
    refs.throwSelectionPanel:SetVisible(false)
    content:AddChild(refs.throwSelectionPanel)

    refs.barrelPanel = card("海岸木桶")
    refs.barrelStatus = makeLabel("木桶检查暂未开放。", 13)
    refs.barrelPanel:AddChild(refs.barrelStatus)
    refs.barrelBegin = makeButton("检查木桶", function()
        invokeLoop("BeginBarrelInspection")
    end, "primary", 92)
    refs.barrelCancel = makeButton("取消检查", function()
        invokeLoop("CancelBarrelInspection")
    end, "secondary", 92)
    refs.barrelPanel:AddChild(refs.barrelBegin)
    refs.barrelPanel:AddChild(refs.barrelCancel)
    refs.barrelPanel:SetVisible(false)
    content:AddChild(refs.barrelPanel)

    refs.scopePanel = card("宝物与望远镜")
    refs.scopeStatus = makeLabel("尚未获得透镜；无法查看或切换望远镜功能。", 13)
    refs.scopePanel:AddChild(refs.scopeStatus)
    refs.scopeToggle = makeButton("切换望远镜", function()
        invokeLoop(loop.scopeSyncError and "DisableScope" or "ToggleScope")
    end, "secondary", 112)
    refs.scopePanel:AddChild(refs.scopeToggle)
    content:AddChild(refs.scopePanel)

    refs.inventoryPanel = card("背包")
    refs.inventoryCount = makeLabel("0 / 0 格", 12, { 180, 203, 191, 255 })
    refs.upgrade = makeButton("扩容", function() invokeLoop("UpgradeInventory") end, "secondary", 148)
    local inventoryHeader = UI.Panel {
        width = "100%",
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        children = {
            refs.inventoryCount,
            UI.Spacer(),
            refs.upgrade,
        },
    }
    refs.inventoryPanel:AddChild(inventoryHeader)
    refs.itemMenu = UI.Panel {
        width = "100%",
        padding = 8,
        gap = 6,
        flexDirection = "column",
        backgroundColor = { 45, 64, 61, 220 },
        borderRadius = 5,
    }
    refs.itemMenuTitle = makeLabel("物品操作", 12, { 237, 213, 159, 255 }, "bold")
    refs.itemMenu:AddChild(refs.itemMenuTitle)
    refs.itemUseReason = makeLabel("", 12, { 213, 193, 161, 255 })
    refs.itemMenu:AddChild(refs.itemUseReason)
    local itemMenuActions = UI.Panel {
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
        gap = 5,
    }
    refs.itemUse = makeButton("使用", function()
        if state.selectedItemIndex then invokeLoop("UseItem", state.selectedItemIndex) end
    end, "success", 56)
    refs.itemGive = makeButton("给老人", function()
        if state.selectedItemIndex then invokeLoop("GiveToElder", state.selectedItemIndex) end
    end, "primary", 72)
    refs.itemDrop = makeButton("丢弃", function()
        if state.selectedItemIndex then invokeLoop("DropItem", state.selectedItemIndex) end
    end, "danger", 56)
    refs.itemThrow = makeButton("投掷", function()
        if state.selectedItemIndex then invokeLoop("BeginThrowItem", state.selectedItemIndex) end
    end, "secondary", 56)
    refs.itemMenuBack = makeButton("返回", function()
        state.selectedItemIndex = nil
        refresh()
    end, "secondary", 56)
    itemMenuActions:AddChild(refs.itemUse)
    itemMenuActions:AddChild(refs.itemGive)
    itemMenuActions:AddChild(refs.itemDrop)
    itemMenuActions:AddChild(refs.itemThrow)
    itemMenuActions:AddChild(refs.itemMenuBack)
    refs.itemMenu:AddChild(itemMenuActions)
    refs.itemMenu:SetVisible(false)
    refs.inventoryPanel:AddChild(refs.itemMenu)
    refs.pendingCatchPanel = UI.Panel {
        width = "100%",
        padding = 8,
        gap = 6,
        flexDirection = "column",
        backgroundColor = { 72, 61, 42, 235 },
        borderColor = { 159, 133, 88, 230 },
        borderWidth = 1,
        borderRadius = 6,
    }
    refs.pendingCatchText = makeLabel("有渔获等待接收。", 13, { 255, 236, 207, 255 }, "bold")
    refs.pendingCatchPanel:AddChild(makeLabel("需要丢弃时，先点击海面选择投放点；船舱保持打开，世界仍暂停。", 12))
    refs.pendingCatchClaim = makeButton("领取渔获", function()
        invokeLoop("ClaimPendingCatch")
    end, "primary", 108)
    refs.pendingCatchPanel:AddChild(refs.pendingCatchText)
    refs.pendingCatchPanel:AddChild(refs.pendingCatchClaim)
    refs.pendingCatchPanel:SetVisible(false)
    refs.inventoryPanel:AddChild(refs.pendingCatchPanel)
    refs.inventoryRows = UI.Panel { width = "100%", flexDirection = "column", gap = 4 }
    refs.inventoryScroll = UI.ScrollView {
        width = "100%",
        height = 210,
        scrollY = true,
        showScrollbar = true,
        children = { refs.inventoryRows },
    }
    refs.inventoryPanel:AddChild(refs.inventoryScroll)
    refs.inventoryPanel:SetVisible(false)
    content:AddChild(refs.inventoryPanel)

    refs.portPanel = card("港口商店")
    refs.loadStatus = makeLabel("", 12)
    refs.portPanel:AddChild(refs.loadStatus)
    refs.portPanel:AddChild(makeLabel("新周目起始状态会在开始时保存；入口处可读取已有云存档。", 12))
    refs.staminaUpgrade = makeButton("升级体力", function() invokeLoop("UpgradeStamina") end, "secondary", 180)
    refs.speedUpgrade = makeButton("升级航速", function() invokeLoop("UpgradeBoatSpeed") end, "secondary", 180)
    refs.portPanel:AddChild(refs.staminaUpgrade)
    refs.portPanel:AddChild(refs.speedUpgrade)
    refs.portPanel:AddChild(makeLabel("购买补给", 13, { 203, 218, 202, 255 }))
    local buyRow = UI.Panel {
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        gap = 7,
    }
    refs.shopButtons = {}
    refs.shopStockLabels = {}
    for _, itemId in ipairs({ "apple", "bait" }) do
        local buyId = itemId
        local definition = Items.GetDefinition(buyId)
        local itemLabel = definition and definition.name or buyId
        local price = definition and definition.buyPrice
        local label = price and (itemLabel .. " · ¥" .. tostring(price)) or (itemLabel .. " · 价格未定")
        local shopButton = makeButton(label, function() invokeLoop("Buy", buyId) end, "primary", 142)
        if not price then shopButton:SetDisabled(true) end
        refs.shopButtons[buyId] = shopButton
        refs.shopStockLabels[buyId] = makeLabel("", 12)
        buyRow:AddChild(refs.shopStockLabels[buyId])
        buyRow:AddChild(shopButton)
    end
    refs.portPanel:AddChild(buyRow)
    refs.portPanel:AddChild(makeLabel("出售渔获", 13, { 203, 218, 202, 255 }))
    refs.portSales = UI.Panel { width = "100%", flexDirection = "column", gap = 4 }
    refs.portSalesScroll = UI.ScrollView {
        width = "100%",
        height = 150,
        scrollY = true,
        showScrollbar = true,
        children = { refs.portSales },
    }
    refs.portPanel:AddChild(refs.portSalesScroll)
    refs.portPanel:SetVisible(false)
    content:AddChild(refs.portPanel)

    if debugTools and debugTools.enabled == true then
        refs.debugPanel = card("开发调试")
        refs.debugPanel:SetVisible(false)
        refs.debugStatus = makeLabel("调试命令仅在开发模式启用", 12, { 189, 211, 190, 255 })
        refs.debugPanel:AddChild(refs.debugStatus)

        local scaleRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 5 }
        scaleRow:AddChild(makeLabel("时间倍率", 12))
        for _, scale in ipairs(Config.debug.timeScales or {}) do
            local configuredScale = scale
            scaleRow:AddChild(makeButton(tostring(configuredScale) .. "×", function()
                invokeDebug("timeScale", configuredScale)
            end, "secondary", 54))
        end
        refs.debugPanel:AddChild(scaleRow)

        local staminaRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 5 }
        staminaRow:AddChild(makeButton("体力 +", function() invokeDebug("staminaPlus") end, "secondary", 82))
        staminaRow:AddChild(makeButton("体力 −", function() invokeDebug("staminaMinus") end, "secondary", 82))
        staminaRow:AddChild(makeButton("金钱 +", function() invokeDebug("moneyPlus") end, "secondary", 82))
        staminaRow:AddChild(makeButton("清空背包", function() invokeDebug("clearInventory") end, "danger", 92))
        refs.debugFishing = makeButton("钓鱼（" .. tostring(Config.stamina.fishingCost) .. "体力）", function()
            invokeDebug("fishing")
        end, "primary", 112)
        refs.debugSalvage = makeButton("打捞（" .. tostring(Config.stamina.salvageCost) .. "体力）", function()
            invokeDebug("salvage")
        end, "primary", 112)
        staminaRow:AddChild(refs.debugFishing)
        staminaRow:AddChild(refs.debugSalvage)
        refs.debugPanel:AddChild(staminaRow)

        local seekRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", alignItems = "center", gap = 5 }
        seekRow:AddChild(makeLabel("跳转秒数", 12))
        refs.seekField = UI.TextField {
            value = "",
            placeholder = "输入 elapsed",
            width = 118,
            height = 36,
            onChange = function(_, value) state.seekText = tostring(value or "") end,
        }
        seekRow:AddChild(refs.seekField)
        seekRow:AddChild(makeButton("白天", function() invokeDebug("seekDay", state.seekText) end, "secondary", 58))
        seekRow:AddChild(makeButton("夜晚", function() invokeDebug("seekNight", state.seekText) end, "secondary", 58))
        refs.debugPanel:AddChild(seekRow)

        local itemRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", alignItems = "center", gap = 5 }
        refs.addItemField = UI.TextField {
            value = "",
            placeholder = "apple / bait / sardine / tuna",
            width = 190,
            height = 36,
            onChange = function(_, value) state.addItemText = tostring(value or "") end,
        }
        itemRow:AddChild(refs.addItemField)
        itemRow:AddChild(makeButton("加入物品", function() invokeDebug("addItem", state.addItemText) end, "secondary", 86))
        itemRow:AddChild(makeButton("结算今日", function() invokeDebug("settleDay") end, "primary", 86))
        itemRow:AddChild(makeButton("暂停原因", function() invokeDebug("pauseReasons") end, "secondary", 86))
        refs.debugPanel:AddChild(itemRow)

        content:AddChild(refs.debugPanel)
    end

    root:AddChild(contentScroll)

    -- 统一遮罩承载强制返港、每日结算和拜访老人的反馈。
    refs.overlay = UI.Panel {
        position = "absolute",
        top = 0,
        left = 0,
        width = "100%",
        height = "100%",
        zIndex = 100,
        justifyContent = "center",
        alignItems = "center",
        padding = 12,
        backgroundColor = { 8, 16, 18, 190 },
        pointerEvents = "auto",
    }
    refs.modalCard = UI.Panel {
        width = 380,
        maxWidth = "94%",
        height = "90%",
        maxHeight = 430,
        padding = 14,
        gap = 9,
        flexDirection = "column",
        backgroundColor = { 33, 51, 52, 255 },
        borderColor = { 159, 133, 88, 255 },
        borderWidth = 2,
        borderRadius = 10,
    }
    refs.modalTitle = makeLabel("", 18, { 246, 223, 171, 255 }, "bold")
    refs.modalCard:AddChild(refs.modalTitle)

    refs.entryBody = UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 12 }
    refs.entryText = makeLabel("正在读取云存档…", 14)
    refs.entryBody:AddChild(refs.entryText)
    refs.entryLoad = makeButton("重试读取", function() invokeLoop("LoadSaved") end, "primary", 130)
    refs.entryNew = makeButton("开始新周目", function() invokeLoop("NewRun") end, "secondary", 130)
    refs.entryRetrySave = makeButton("重试初始保存", function() invokeLoop("RetryInitialSave") end, "primary", 150)
    refs.entryContinue = makeButton("不保存继续", function() invokeLoop("ContinueWithoutSaving") end, "secondary", 150)
    refs.entryRetrySave:Hide()
    refs.entryContinue:Hide()
    refs.entryBody:AddChild(refs.entryLoad)
    refs.entryBody:AddChild(refs.entryNew)
    refs.entryBody:AddChild(refs.entryRetrySave)
    refs.entryBody:AddChild(refs.entryContinue)
    refs.entryBody:AddChild(makeLabel("开始新周目会立即尝试覆盖旧云存档；若失败，可重试或明确不保存继续。", 12))
    refs.modalCard:AddChild(refs.entryBody)

    refs.forcedBody = UI.Panel { width = "100%", flexGrow = 1, justifyContent = "center", gap = 12 }
    refs.forcedText = makeLabel("夜深了，你必须返港。", 16, { 255, 236, 207, 255 }, "bold")
    refs.forcedBody:AddChild(refs.forcedText)
    refs.forcedBody:AddChild(makeLabel("返港后会自动完成今日结算并保存。", 13))
    refs.forcedConfirm = makeButton("确认返港", function() invokeLoop("ConfirmForcedReturn") end, "primary", 130)
    refs.forcedBody:AddChild(refs.forcedConfirm)
    refs.modalCard:AddChild(refs.forcedBody)

    refs.settlementBody = UI.Panel { width = "100%", flexGrow = 1, gap = 12 }
    refs.settlementText = makeLabel("结束今日并进入下一天？确认后会自动保存。", 14)
    refs.settlementBody:AddChild(refs.settlementText)
    refs.settlementConfirm = makeButton("确认结算", function() invokeLoop("ConfirmSettlement") end, "primary", 130)
    refs.settlementBody:AddChild(refs.settlementConfirm)
    refs.settlementSkip = makeButton("放弃本次保存，进入下一天", function() invokeLoop("ContinueWithoutSaving") end, "secondary", 270)
    refs.settlementSkip:Hide()
    refs.settlementBody:AddChild(refs.settlementSkip)
    refs.modalCard:AddChild(refs.settlementBody)

    refs.elderBody = UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 8 }
    refs.elderMessage = makeLabel("食物可给予老人；鱼和鱼饵可向老人展示。", 13)
    refs.elderBody:AddChild(refs.elderMessage)
    refs.elderStatus = makeLabel("", 12, { 237, 213, 159, 255 }, "bold")
    refs.elderBody:AddChild(refs.elderStatus)
    refs.elderTreasure = UI.Panel {
        width = "100%", padding = 7, gap = 5, flexDirection = "column",
        backgroundColor = { 45, 64, 61, 220 }, borderRadius = 5,
    }
    refs.elderTreasure:AddChild(makeLabel("宝物", 12, { 237, 213, 159, 255 }, "bold"))
    refs.elderLensStatus = makeLabel("尚未获得透镜。", 12)
    refs.elderTreasure:AddChild(refs.elderLensStatus)
    refs.elderLensGive = makeButton("展示透镜", function()
        invokeLoop("GiveTreasureToElder", "scopeLens")
    end, "primary", 92)
    refs.elderTreasure:AddChild(refs.elderLensGive)
    refs.elderBody:AddChild(refs.elderTreasure)
    refs.elderGiftRows = UI.Panel { width = "100%", flexDirection = "column", gap = 4 }
    refs.elderGiftScroll = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        scrollY = true,
        showScrollbar = true,
        children = { refs.elderGiftRows },
    }
    refs.elderBody:AddChild(refs.elderGiftScroll)
    refs.elderBody:AddChild(makeButton("结束对话", function() invokeLoop("SetElderOpen", false) end, "secondary", 104))
    refs.modalCard:AddChild(refs.elderBody)

    refs.storyBody = UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 12 }
    refs.storyText = UI.Label {
        id = "storyDialogText",
        text = "",
        fontSize = 15,
        fontColor = { 255, 236, 207, 255 },
        whiteSpace = "normal",
    }
    refs.storyBody:AddChild(refs.storyText)
    refs.storyClose = makeButton("结束对话", function() invokeLoop("CloseStoryDialog") end, "primary", 104)
    refs.storyBody:AddChild(refs.storyClose)
    refs.modalCard:AddChild(refs.storyBody)
    refs.overlay:AddChild(refs.modalCard)
    refs.overlay:Hide()
    refs.forcedBody:Hide()
    refs.settlementBody:Hide()
    refs.elderBody:Hide()
    refs.storyBody:Hide()
    root:AddChild(refs.overlay)

    invokeLoop = function(methodName, ...)
        if state.destroyed then return end
        local method = loop[methodName]
        if type(method) ~= "function" then
            state.localMessage = "当前玩法暂不支持：" .. methodName
            refresh()
            return
        end
        local ok, result, reason = Diagnostics.Call("HUD", "invoke_loop", method, loop, ...)
        if not ok then
            state.localMessage = "操作失败，当前进度保留，请稍后重试。"
        elseif result == false then
            state.localMessage = "操作未完成：" .. userMessage(reason)
        else
            state.localMessage = ""
        end
        refresh()
    end

    invokeDebug = function(command, argument)
        if state.destroyed or not debugTools then return end
        local ok, result, reason = Diagnostics.Call(
            "HUD", "invoke_debug", debugTools.Execute, debugTools, command, argument)
        if not ok then
            local errorText = (type(result) == "string" or type(result) == "number") and tostring(result) or "未知异常"
            state.localMessage = "调试命令失败：" .. errorText
        elseif result == false then
            state.localMessage = "调试命令失败：" .. userMessage(reason)
        else
            state.localMessage = tostring(reason or "")
        end
        if refs.debugStatus then setText(refs.debugStatus, "debugStatus", state.localMessage) end
        refresh()
    end

    local function addEmptyMessage(rows, text)
        rows:AddChild(makeLabel(text, 12, { 169, 191, 181, 255 }))
    end

    local function destroyChildren(container)
        local source = container:GetChildren()
        local snapshot = {}
        for index, child in ipairs(source) do snapshot[index] = child end
        for _, child in ipairs(snapshot) do child:Destroy() end
        container:ClearChildren()
    end

    local function rebuildItemRows(items, inPort, elderOpen, actionsBlocked)
        local cargoRevision = loop:GetCargoRevision()
        destroyChildren(refs.inventoryRows)
        destroyChildren(refs.portSales)
        destroyChildren(refs.elderGiftRows)

        if #items == 0 then addEmptyMessage(refs.inventoryRows, "背包是空的。") end
        local saleCount, giftCount = 0, 0
        for index, itemId in ipairs(items) do
            local itemIndex = index
            local definition = Items.GetDefinition(itemId)
            local name = definition and definition.name or tostring(itemId)
            local inventoryRow = UI.Panel {
                width = "100%",
                minHeight = 38,
                flexDirection = "row",
                alignItems = "center",
                gap = 4,
                paddingHorizontal = 4,
                backgroundColor = { 45, 64, 61, 220 },
                borderRadius = 5,
            }
            inventoryRow:AddChild(makeLabel(string.format("%02d · %s", itemIndex, name), 12))
            local itemActions = makeButton("操作", function()
                state.selectedItemIndex = itemIndex
                refresh()
            end, "secondary", 56)
            itemActions:SetDisabled(actionsBlocked)
            inventoryRow:AddChild(itemActions)
            if inPort and (itemId == "sardine" or itemId == "tuna") and definition then
                local price = definition.sellPrice
                local label = price and ("出售 ¥" .. tostring(price)) or "售价未定"
                local sellButton = makeButton(label, function() invokeLoop("Sell", itemIndex, itemId, cargoRevision) end, "primary", 82)
                if not price or actionsBlocked then sellButton:SetDisabled(true) end
                inventoryRow:AddChild(sellButton)
            end
            refs.inventoryRows:AddChild(inventoryRow)

            if inPort and (itemId == "sardine" or itemId == "tuna") and definition then
                saleCount = saleCount + 1
                local saleRow = UI.Panel {
                    width = "100%",
                    minHeight = 36,
                    flexDirection = "row",
                    alignItems = "center",
                    gap = 5,
                }
                saleRow:AddChild(makeLabel(string.format("%s · 槽位 %d", name, itemIndex), 12))
                local price = definition.sellPrice
                local saleButton = makeButton(price and ("出售 ¥" .. tostring(price)) or "售价未定", function()
                    invokeLoop("Sell", itemIndex, itemId, cargoRevision)
                end, "primary", 92)
                if not price or actionsBlocked then saleButton:SetDisabled(true) end
                saleRow:AddChild(saleButton)
                refs.portSales:AddChild(saleRow)
            end

            if elderOpen and definition and definition.canGive then
                giftCount = giftCount + 1
                local giftRow = UI.Panel {
                    width = "100%",
                    minHeight = 38,
                    flexDirection = "row",
                    alignItems = "center",
                    gap = 5,
                }
                giftRow:AddChild(makeLabel(string.format("%02d · %s", itemIndex, name), 12))
                local giftAction = definition.category == "food" and "给予" or "展示"
                local giftButton = makeButton(giftAction, function() invokeLoop("GiveToElder", itemIndex) end, "primary", 64)
                giftButton:SetDisabled(actionsBlocked)
                giftRow:AddChild(giftButton)
                refs.elderGiftRows:AddChild(giftRow)
            end
        end
        if saleCount == 0 then addEmptyMessage(refs.portSales, "没有可出售的鱼。") end
        if giftCount == 0 then addEmptyMessage(refs.elderGiftRows, "没有可给予或展示的物品。") end
    end

    refresh = function()
        if state.destroyed then return end
        local player = loop.player or {}
        local clockState = loop.clock and loop.clock:GetState() or {}
        local phase = clockState.phase == "night" and "夜晚" or "白天"
        local remaining = tonumber(clockState.remaining) or 0
        setText(refs.day, "day", "第 " .. tostring(player.day or 1) .. " 天")
        setText(refs.phase, "phase", string.format("%s · 剩余 %.0f 秒", phase, math.max(0, remaining)))
        setText(refs.stamina, "stamina", string.format("体力：%s/%s", tostring(player.stamina or 0), tostring(player.maxStamina or 0)))
        setText(refs.money, "money", "钱：" .. tostring(player.money or 0))

        local reasons = clockState.pauseReasons or {}
        local pauseText = #reasons > 0 and table.concat(reasons, "、") or "无"
        if clockState.paused and #reasons == 0 then pauseText = "暂停中" end
        setText(refs.pauseReasons, "pauseReasons", "暂停：" .. pauseText)
        setText(refs.save, "save", saveText(loop))

        local message = state.localMessage ~= "" and state.localMessage or userMessage(loop.lastMessage)
        if message == "" then message = "出海采集，返港交易与结算。" end
        setText(refs.message, "message", message)

        local inPort = loop.inPort == true

        local elderPresent = false
        if type(loop.IsElderPresent) == "function" then
            local ok, value = pcall(loop.IsElderPresent, loop)
            elderPresent = ok and value == true
        end
        ---@type HUDElderStatus|nil
        local elderStatus
        if type(loop.GetElderStatus) == "function" then
            local ok, value = pcall(loop.GetElderStatus, loop)
            if ok and type(value) == "table" then elderStatus = value end
        end

        ---@type HUDBarrelState|nil
        local barrelState
        if type(loop.GetBarrelState) == "function" then
            local ok, value = pcall(loop.GetBarrelState, loop)
            if ok and type(value) == "table" then barrelState = value end
        end

        local hasLens, scopeEnabled, scopeApiAvailable = false, false, false
        if type(loop.HasLens) == "function" then
            local ok, value = pcall(loop.HasLens, loop)
            hasLens = ok and value == true
        end
        if type(loop.IsScopeEnabled) == "function" then
            local ok, value = pcall(loop.IsScopeEnabled, loop)
            scopeEnabled = ok and value == true
        end
        scopeApiAvailable = type(loop.HasLens) == "function"
            and type(loop.IsScopeEnabled) == "function" and type(loop.ToggleScope) == "function"

        ---@type HUDStoryDialog|nil
        local storyDialog
        if type(loop.GetStoryDialog) == "function" then
            local ok, value = pcall(loop.GetStoryDialog, loop)
            if ok and type(value) == "table" and value.kind == "paper"
                and type(value.token) == "table" and type(value.text) == "string" then
                storyDialog = value
            end
        end

        ---@type HUDThrowSelection|nil
        local throwSelection
        if type(loop.GetThrowSelection) == "function" then
            local ok, value = pcall(loop.GetThrowSelection, loop)
            if ok and type(value) == "table" then throwSelection = value end
        end

        local busy = loop.busy == true or loop.loading == true or loop.dropInFlight == true
            or throwSelection ~= nil
        local ready = true
        if type(loop.Ready) == "function" then ready = loop:Ready() end
        local bucketActiveForInput = barrelState ~= nil and barrelState.active == true

        ---@type HUDFishingState|nil
        local fishingState
        if type(loop.GetFishingState) == "function" then
            local ok, value = pcall(loop.GetFishingState, loop)
            if ok and type(value) == "table" then fishingState = value end
        end
        local fishingPhase = fishingState and fishingState.state or "idle"
        local fishingSelecting = fishingPhase == "selecting"
        local fishingCleanupPending = fishingPhase == "cleanup_pending"
            or fishingPhase == "rollback_pending" or fishingPhase == "committing"
        local fishingActive = fishingPhase == "casting" or fishingPhase == "landed" or fishingCleanupPending
        local fishingRestricted = fishingSelecting or fishingActive
        local fishingTerminal = fishingPhase == "complete" or fishingPhase == "failed" or fishingPhase == "cancelled"
        local fishingCenter = fishingState and fishingState.center
        local centerX = fishingCenter and fishingCenter.x
        local centerY = fishingCenter and fishingCenter.y
        local fishingStatus
        if fishingSelecting then
            if centerX ~= nil and centerY ~= nil then
                fishingStatus = string.format("网心已设定（%.1f，%.1f），确认后抛网。", centerX, centerY)
            else
                fishingStatus = "请在海面选择网心，再确认抛网。"
            end
        elseif fishingPhase == "casting" then
            fishingStatus = "抛网进行中。"
        elseif fishingPhase == "landed" then
            fishingStatus = "网已落水，正在收网。"
        elseif fishingPhase == "cleanup_pending" then
            fishingStatus = "捕鱼清理尚未完成，可以重试清理。"
        elseif fishingPhase == "rollback_pending" then
            fishingStatus = "捕鱼回滚尚未完成，可以重试清理。"
        elseif fishingPhase == "committing" then
            fishingStatus = "正在提交捕鱼结果，可以重试清理。"
        elseif fishingPhase == "complete" then
            fishingStatus = "本次捕鱼已完成。"
        elseif fishingPhase == "failed" then
            fishingStatus = "本次捕鱼未完成。"
        elseif fishingPhase == "cancelled" then
            fishingStatus = "本次捕鱼已取消。"
        elseif not fishingState then
            fishingStatus = "捕鱼状态暂不可用。"
        else
            fishingStatus = "选择海面网心开始捕鱼。"
        end
        setText(refs.fishingStatus, "fishingStatus", fishingStatus)
        local actionDuration = math.max(0.01, tonumber(fishingState and fishingState.duration) or 4)
        local actionElapsed = math.max(0, tonumber(fishingState and fishingState.elapsed) or 0)
        local progress = fishingPhase == "complete" and 100
            or math.floor(math.min(1, actionElapsed / actionDuration) * 100 + 0.5)
        setText(refs.fishingProgress, "fishingProgress",
            string.format("动作进度：%d%% · %.1f / %.1f 秒", progress, math.min(actionElapsed, actionDuration), actionDuration))
        local resultText = ""
        if fishingTerminal then
            if fishingPhase == "complete" then
                local detail = loop.lastMessage
                resultText = "收网完成。" .. (detail and detail ~= "" and (" " .. userMessage(detail)) or "")
            elseif fishingPhase == "cancelled" then
                resultText = "已取消，未消耗体力。"
            else
                local reason = fishingState and fishingState.reason or loop.lastMessage
                resultText = "未完成：" .. (reason ~= nil and userMessage(reason) or "请稍后重试")
            end
        end
        refs.fishingResult:SetVisible(fishingTerminal)
        setText(refs.fishingResult, "fishingResult", resultText)
        refs.fishingPanel:SetVisible(not inPort or fishingRestricted or fishingTerminal)
        refs.beginFishing:SetVisible(not inPort and not fishingSelecting and not fishingActive)
        refs.beginFishing:SetDisabled(not ready or busy or inPort or loop.inventoryOpen == true
            or loop.elderOpen == true or fishingRestricted)
        refs.confirmFishing:SetVisible(fishingSelecting)
        refs.confirmFishing:SetDisabled(busy or centerX == nil or centerY == nil)
        refs.cancelFishing:SetVisible(fishingRestricted)
        refs.cancelFishing:SetText(fishingCleanupPending and "重试清理" or "取消捕鱼")
        refs.cancelFishing:SetDisabled(false)

        local pendingCatch = false
        if type(loop.HasPendingCatch) == "function" then
            local ok, value = pcall(loop.HasPendingCatch, loop)
            pendingCatch = ok and value == true
        end
        ---@type HUDPendingCatch|nil
        local pendingData
        if pendingCatch and type(loop.GetPendingCatch) == "function" then
            local ok, value = pcall(loop.GetPendingCatch, loop)
            if ok and type(value) == "table" then pendingData = value end
        end
        refs.depart:SetVisible(inPort)
        refs.returnToPort:SetVisible(not inPort)
        refs.endToday:SetVisible(inPort)
        refs.elderToggle:SetVisible(inPort or bucketActiveForInput or loop.elderOpen == true)
        refs.depart:SetDisabled(not ready or busy or fishingRestricted or loop.inventoryOpen == true or loop.elderOpen == true)
        refs.returnToPort:SetDisabled(busy or not ready or fishingRestricted)
        refs.endToday:SetDisabled(busy or not ready or fishingRestricted)
        refs.inventoryToggle:SetDisabled(busy or fishingRestricted or pendingCatch
            or (not ready and loop.inventoryOpen ~= true and not bucketActiveForInput))
        refs.inventoryToggle:SetText(pendingCatch and "船舱（收获待领）" or "背包")
        refs.elderToggle:SetDisabled(busy or fishingRestricted
            or (not ready and not bucketActiveForInput and loop.elderOpen ~= true)
            or (not elderPresent and loop.elderOpen ~= true))
        local showInventory = loop.inventoryOpen == true or pendingCatch
        refs.inventoryPanel:SetVisible(showInventory)
        refs.portPanel:SetVisible(inPort)
        local portAccess, portReason, portDetails = loop:CanAccessPort()
        local portDistance = portDetails and portDetails.distance
        local portRadius = portDetails and portDetails.radius or 10
        local portInfo
        if type(portDistance) == "number" then
            local accessText = portAccess and "范围内，可返港/交易" or "范围外，需≤10米才可返港/交易"
            portInfo = string.format("锚形标记=港口（交易中心）· 距港 %.3f/%.0f米（%s）；同日往返不恢复体力、不补充库存。",
                portDistance, portRadius, accessText)
        else
            portInfo = "锚形标记=港口（交易中心）· 距离暂不可读；返港/交易需距港≤10米。"
            if not portAccess and portReason then portInfo = portInfo .. " " .. userMessage(portReason) end
        end
        setText(refs.portAccessReason, "portAccessReason", portInfo)
        refs.loadSaved:SetVisible(inPort)
        refs.loadSaved:SetText(loop.loadStatus == "error" and "重试读取" or "读取云存档")
        refs.loadSaved:SetDisabled(busy or loop.settlementPending == true or pendingCatch or fishingRestricted)
        refs.newRun:SetDisabled(busy or loop.settlementPending == true or pendingCatch)
        local loadMessages = {
            idle = "云存档仅在每日结算时保存。", loading = "正在读取云存档…",
            empty = "没有云存档，可开始新周目。", loaded = "已恢复每日结算存档。",
            error = "读取云存档失败，当前状态保留；可重试读取。",
        }
        setText(refs.loadStatus, "loadStatus", loadMessages[loop.loadStatus or "idle"] or loadMessages.idle)
        local function updateUpgrade(button, label, price)
            button:SetText(label .. (price and (" · ¥" .. tostring(price)) or " · 已满级/不可升级"))
            button:SetDisabled(not inPort or not ready or busy or fishingRestricted or not price)
        end
        local staminaLevel = loop:GetStaminaLevel()
        updateUpgrade(refs.staminaUpgrade, "升级体力", staminaLevel and Config.upgrades.stamina.prices[staminaLevel])
        updateUpgrade(refs.speedUpgrade, "升级航速", Config.upgrades.boatSpeed.prices[player.boatSpeedLevel])
        updateUpgrade(refs.upgrade, "扩容", Config.upgrades.inventory.prices[player.inventory:GetLevel()])
        for itemId, shopButton in pairs(refs.shopButtons) do
            local definition = assert(Items.GetDefinition(itemId))
            local stock = loop:GetShopStock(itemId)
            local label = definition.name .. " · ¥" .. tostring(definition.buyPrice)
            shopButton:SetText(stock > 0 and label or (definition.name .. " · 售罄"))
            shopButton:SetDisabled(not inPort or not ready or busy or fishingRestricted)
            refs.shopStockLabels[itemId]:SetText(definition.name .. "库存：" .. tostring(stock))
        end
        local elderToggleText = loop.elderOpen == true and "结束对话"
            or (elderPresent and "拜访老人" or "老人不在")
        refs.elderToggle:SetText(elderToggleText)

        refs.barrelPanel:SetVisible(not inPort)
        local barrelGatesAvailable = barrelState ~= nil and barrelState.timingAvailable == true
            and barrelState.interfaceAvailable == true
        local barrelFinished = barrelState ~= nil and (tonumber(barrelState.stage) or 0) >= 3
        local barrelActive = bucketActiveForInput
        local barrelPending = barrelState ~= nil and barrelState.pending == true
        if not barrelGatesAvailable then
            setText(refs.barrelStatus, "barrelStatus", "木桶检查暂未开放。")
            refs.barrelBegin:SetVisible(false)
            refs.barrelCancel:SetVisible(false)
        elseif barrelPending then
            setText(refs.barrelStatus, "barrelStatus", "木桶补给等待领取，请先处理待领取奖励。")
            refs.barrelBegin:SetVisible(false)
            refs.barrelCancel:SetVisible(false)
        elseif barrelFinished then
            setText(refs.barrelStatus, "barrelStatus", "木桶调查已完成。")
            refs.barrelBegin:SetVisible(false)
            refs.barrelCancel:SetVisible(false)
        elseif barrelActive then
            local seconds = math.max(0, tonumber(barrelState.remaining) or 0)
            setText(refs.barrelStatus, "barrelStatus", string.format(
                "木桶检查进行中，剩余 %.1f 秒；打开背包或对话会暂停计时，可以取消。", seconds))
            refs.barrelBegin:SetVisible(false)
            refs.barrelCancel:SetVisible(true)
            refs.barrelCancel:SetDisabled(false)
        else
            setText(refs.barrelStatus, "barrelStatus", "发现海岸边的木桶。")
            refs.barrelBegin:SetVisible(true)
            refs.barrelCancel:SetVisible(false)
            refs.barrelBegin:SetDisabled(busy or fishingRestricted or not ready or pendingCatch)
        end

        if not hasLens then
            setText(refs.scopeStatus, "scopeStatus", "尚未获得透镜；无法查看或切换望远镜功能。")
            refs.scopeToggle:SetText("透镜未获得")
            refs.scopeToggle:SetDisabled(true)
        elseif not scopeApiAvailable or loop.scopeSyncError == "scope_interface_unavailable" then
            setText(refs.scopeStatus, "scopeStatus", "望远镜功能接口暂不可用。")
            refs.scopeToggle:SetText("功能暂不可用")
            refs.scopeToggle:SetDisabled(true)
        elseif loop.scopeSyncError then
            setText(refs.scopeStatus, "scopeStatus", "望远镜状态同步失败，请重试关闭。")
            refs.scopeToggle:SetText("重试关闭望远镜")
            refs.scopeToggle:SetDisabled(busy or fishingRestricted)
        else
            setText(refs.scopeStatus, "scopeStatus", scopeEnabled and "望远镜设置：开启。" or "望远镜设置：关闭。")
            refs.scopeToggle:SetText(scopeEnabled and "关闭望远镜" or "开启望远镜")
            refs.scopeToggle:SetDisabled(busy or fishingRestricted)
        end

        refs.throwSelectionPanel:SetVisible(throwSelection ~= nil)
        if throwSelection then
            setText(refs.throwSelectionText, "throwSelectionText",
                "已选择" .. itemName(throwSelection.itemId) .. "，请点击 12 米内海面投掷；也可以取消。")
            refs.throwSelectionCancel:SetDisabled(false)
        end

        local items = copyItems(loop)
        local capacity = player.inventory and player.inventory:GetCapacity() or 0
        setText(refs.inventoryCount, "inventoryCount", string.format("%d / %d 格", #items, capacity))
        local itemNames = {}
        local shownCount = math.min(#items, 4)
        for index = 1, shownCount do itemNames[index] = itemName(items[index]) end
        local contentsText = #items == 0 and "空" or table.concat(itemNames, "、")
        if #items > shownCount then contentsText = contentsText .. " 等 " .. tostring(#items - shownCount) .. " 件" end
        setText(refs.inventorySummary, "inventorySummary",
            string.format("背包 %d / %d 格：%s", #items, capacity, contentsText))
        ---@type string[]
        local signatureParts = { tostring(loop:GetCargoRevision()), tostring(capacity), tostring(inPort), tostring(loop.elderOpen == true) }
        for _, itemId in ipairs(items) do signatureParts[#signatureParts + 1] = itemId end
        signatureParts[#signatureParts + 1] = tostring(busy or fishingRestricted)
        signatureParts[#signatureParts + 1] = tostring(elderPresent)
        local signature = table.concat(signatureParts, "|")
        if signature ~= state.inventorySignature then
            state.inventorySignature = signature
            state.selectedItemIndex = nil
            rebuildItemRows(items, inPort, loop.elderOpen == true and elderPresent, busy or fishingRestricted)
        end
        local selectedItem = state.selectedItemIndex and items[state.selectedItemIndex]
        local selectedDefinition = selectedItem and Items.GetDefinition(selectedItem)
        local itemUseAvailable = selectedDefinition ~= nil and selectedDefinition.canEat == true
            and selectedDefinition.heal > 0
        refs.itemMenu:SetVisible(showInventory and selectedItem ~= nil)
        if selectedItem then
            setText(refs.itemMenuTitle, "itemMenuTitle", string.format("%02d · %s", state.selectedItemIndex, itemName(selectedItem)))
        end
        refs.itemUse:SetVisible(selectedDefinition ~= nil)
        refs.itemGive:SetVisible(selectedDefinition ~= nil and selectedDefinition.canGive == true)
        refs.itemThrow:SetVisible(selectedDefinition ~= nil and selectedDefinition.category ~= "treasure")
        refs.itemUse:SetDisabled(busy or fishingRestricted or not itemUseAvailable)
        refs.itemGive:SetText(selectedDefinition and selectedDefinition.category == "food" and "给予" or "展示")
        refs.itemGive:SetDisabled(busy or fishingRestricted or not elderPresent)
        refs.itemDrop:SetVisible(selectedDefinition ~= nil and selectedDefinition.category ~= "treasure")
        refs.itemDrop:SetDisabled(busy or fishingRestricted or selectedDefinition == nil or selectedDefinition.category == "treasure")
        refs.itemThrow:SetDisabled(busy or fishingRestricted or inPort or not ready
            or selectedDefinition == nil or selectedDefinition.category == "treasure")
        refs.itemMenuBack:SetDisabled(false)
        local useUnavailable = selectedDefinition ~= nil and not itemUseAvailable
        refs.itemUseReason:SetVisible(useUnavailable)
        setText(refs.itemUseReason, "itemUseReason", useUnavailable and userMessage("item_has_no_use") or "")

        local pendingIds = pendingData and pendingData.itemIds or {}
        local requiredSlots = pendingData and pendingData.requiredSlots
        local availableSlots = capacity - #items
        if availableSlots < 0 then availableSlots = 0 end
        local pendingNames = {}
        for _, itemId in ipairs(pendingIds) do
            pendingNames[#pendingNames + 1] = itemName(itemId)
        end
        local pendingSummary = #pendingNames > 0 and table.concat(pendingNames, "、") or "渔获"
        local pendingText
        if requiredSlots == nil or requiredSlots < 0 then
            pendingText = pendingSummary .. " 等待接收；暂时无法读取所需空间。"
        elseif availableSlots >= requiredSlots then
            pendingText = string.format("%s 等待接收；需要 %d 格，目前有 %d 个空位，可以领取。", pendingSummary, requiredSlots, availableSlots)
        else
            pendingText = string.format("%s 等待接收；需要 %d 格，目前有 %d 个空位，请腾出 %d 格。", pendingSummary,
                requiredSlots, availableSlots, requiredSlots - availableSlots)
        end
        refs.pendingCatchPanel:SetVisible(pendingCatch)
        setText(refs.pendingCatchText, "pendingCatchText", pendingText)
        refs.pendingCatchClaim:SetVisible(pendingCatch)
        refs.pendingCatchClaim:SetDisabled(not ready or busy or fishingRestricted
            or requiredSlots == nil or requiredSlots < 0 or availableSlots < requiredSlots)

        local showEntry = loop.entryPending == true
        local showForced = not showEntry and not pendingCatch and loop.forcedReturnPending == true
        local showSettlement = not showEntry and not pendingCatch and not showForced and loop.settlementPending == true
        local showStory = not pendingCatch and not showForced and not showSettlement and storyDialog ~= nil
        local showElder = not showForced and not showSettlement and not showStory
            and loop.elderOpen == true and elderPresent
        refs.overlay:SetVisible(showEntry or showForced or showSettlement or showStory or showElder)
        local overlayTitle = showEntry and "云存档" or showForced and "夜晚返港"
            or (showSettlement and "每日结算" or (showStory and "纸条" or (showElder and "拜访老人" or "")))
        setText(refs.modalTitle, "modalTitle", overlayTitle)
        refs.entryBody:SetVisible(showEntry)
        if showEntry then
            local initialStatus = loop.initialSaveStatus or "idle"
            local initialSaving = initialStatus == "saving"
            local initialError = initialStatus == "error"
            local entryMessage = initialSaving and "正在保存新周目初始状态；成功后会立即开始游戏。"
                or initialError and "新周目初始存档失败；可重试，或不保存继续。旧云档仍保留。"
                or (loadMessages[loop.loadStatus or "idle"] or loadMessages.idle)
            setText(refs.entryText, "entryText", entryMessage)
            refs.entryLoad:SetVisible(initialStatus == "idle")
            refs.entryNew:SetVisible(initialStatus == "idle")
            refs.entryRetrySave:SetVisible(initialError)
            refs.entryContinue:SetVisible(initialSaving or initialError)
            refs.entryLoad:SetDisabled(busy or loop.initialSaveBusy == true)
            refs.entryNew:SetDisabled(busy or loop.initialSaveBusy == true)
            refs.entryRetrySave:SetDisabled(loop.initialSaveBusy == true)
            refs.entryContinue:SetText(initialSaving and "不等待保存，继续" or "不保存继续")
            refs.entryContinue:SetDisabled(false)
        end
        refs.forcedBody:SetVisible(showForced)
        refs.settlementBody:SetVisible(showSettlement)
        refs.storyBody:SetVisible(showStory)
        refs.elderBody:SetVisible(showElder)

        if showSettlement then
            local confirmed = loop.settlementApplied == true
            local text = loop.dayPreparationError and "本次保存选择已记录，但新日海洋准备失败；请重试准备，不会重复加天或保存。"
                or confirmed and (busy and "今日已结算，正在自动保存…"
                or "保存失败，可重试保存或明确放弃本次保存进入下一天。旧存档仍保留，退出后当天未保存进度可能丢失。")
                or "结束今日并进入下一天？确认后会自动保存。"
            setText(refs.settlementText, "settlementText", text)
            -- ConfirmSettlement 在存档失败时可重试已应用的同一结算。
            local settlementButton = refs.settlementConfirm
            settlementButton:SetText(loop.dayPreparationError and "重试准备" or confirmed and "重试保存" or "确认结算")
            settlementButton:SetDisabled(busy)
            refs.settlementSkip:SetVisible(confirmed
                and (loop.saveStatus == "saving" or loop.saveStatus == "error"))
            refs.settlementSkip:SetText(loop.saveStatus == "saving" and "不等待保存，进入下一天"
                or "放弃本次保存，进入下一天")
            refs.settlementSkip:SetDisabled(loop.loading == true)
        end
        if showForced then
            local forcedButton = refs.forcedConfirm
            forcedButton:SetDisabled(busy)
        end
        if showElder then
            local feedback = state.localMessage
            if feedback == "" then
                feedback = userMessage(loop.lastMessage)
                if feedback == "" or not string.find(feedback, "老人", 1, true) then
                    feedback = "食物可给予老人；鱼和鱼饵可向老人展示。"
                end
            end
            setText(refs.elderMessage, "elderMessage", feedback)
        end
        if loop.elderOpen == true then
            local elderProgressText = "老人进展暂不可用。"
            if elderStatus then
                local day = tonumber(player.day) or 1
                if day <= 3 then
                    elderProgressText = string.format("已给予老人苹果：%d/3", tonumber(elderStatus.applesGiven) or 0)
                else
                    local decisions = {
                        pending = "待第4天判定",
                        saved = "老人获救",
                        dead = "老人已离世",
                    }
                    elderProgressText = decisions[elderStatus.decision] or "老人状态暂不可用。"
                end
            end
            setText(refs.elderStatus, "elderStatus", elderProgressText)
            if not scopeApiAvailable then
                setText(refs.elderLensStatus, "elderLensStatus", "透镜状态接口暂不可用。")
                refs.elderLensGive:SetDisabled(true)
            elseif hasLens then
                setText(refs.elderLensStatus, "elderLensStatus", "透镜仍保留在宝物栏，可向老人展示。")
                refs.elderLensGive:SetDisabled(busy or not elderPresent)
            else
                setText(refs.elderLensStatus, "elderLensStatus", "尚未获得透镜。")
                refs.elderLensGive:SetDisabled(true)
            end
            refs.elderLensGive:SetVisible(true)
        end
        if showStory and storyDialog then
            setText(refs.storyText, "storyText", storyDialog.text)
            -- 文本和两个可见状态先完成，再通知 Loop 这张纸条已展示。
            refs.overlay:SetVisible(true)
            refs.storyBody:SetVisible(true)
            if state.storyShownToken ~= storyDialog.token then
                if type(loop.NotifyStoryShown) == "function" then
                    local ok, accepted, reason = pcall(loop.NotifyStoryShown, loop, storyDialog.token)
                    if ok and accepted ~= false then
                        state.storyShownToken = storyDialog.token
                    else
                        state.localMessage = "纸条状态未能更新：" .. userMessage(ok and reason or accepted)
                    end
                else
                    state.localMessage = "纸条状态记录接口暂不可用。"
                end
            end
        elseif not storyDialog then
            state.storyShownToken = nil
        end
        if refs.debugFishing then refs.debugFishing:SetDisabled(busy or inPort or not ready or fishingRestricted) end
        if refs.debugSalvage then refs.debugSalvage:SetDisabled(busy or inPort or not ready or fishingRestricted) end
    end

    local function destroy()
        if state.destroyed then return end
        state.destroyed = true
        if parent and type(parent.RemoveChild) == "function" then
            pcall(parent.RemoveChild, parent, root)
        end
        root:Destroy()
    end
    local handle = {
        root = root,
        Refresh = function() refresh() end,
        Destroy = destroy,
    }

    if parent then
        if type(parent.AddChild) ~= "function" then error("HUD parent must support AddChild", 2) end
        parent:AddChild(root)
    end
    refresh()
    return handle
end

return HUD
