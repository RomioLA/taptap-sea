-- B 玩法 HUD 原型。UI 生命周期由宿主负责，本模块只创建和管理自己的子树。
local UI = require("urhox-libs/UI")
local Config = require("config.gameplay")
local Items = require("data.items")

local HUD = {}

local ERROR_MESSAGES = {
    busy = "当前操作尚未完成",
    day_finished = "今天已经结束",
    port_required = "请先返港",
    close_dialog_first = "请先关闭当前界面",
    inventory_full = "背包已满",
    unknown_item = "未知物品",
    not_enough_money = "钱不够",
    not_enough_stamina = "体力不足",
    cannot_use_item = "现在无法使用该物品",
    cannot_give_item = "老人不收这件物品",
    insufficient_money = "钱不够",
    not_for_sale = "该物品不出售",
    shop_sold_out = "今日已售罄，明天补货",
    invalid_item = "物品已不存在或无法使用",
    sea_required = "请先出海",
    elder_dialog_required = "请先打开老人对话",
    drop_receiver_unavailable = "附近没有接收地点，物品仍保留在背包里",
    drop_rejected = "没有接收地点接收物品，物品仍保留在背包里",
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
    return ERROR_MESSAGES[text] or text
end

local function saveText(loop)
    if loop.loading then return "读取存档中…" end
    local status = loop.saveStatus
    if status == "idle" or status == nil then return "尚未保存" end
    if status == "saving" then return "正在自动保存…" end
    if status == "saved" then return "已自动保存" end
    if status == "error" then return "自动保存失败，可重试" end
    return "存档状态：" .. tostring(status)
end

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

    local state = {
        destroyed = false,
        localMessage = "",
        inventorySignature = "",
        lastTexts = {},
        seekText = "",
        addItemText = "",
    }
    ---@type table<string, any>
    local refs = {}
    local refresh = function() end
    local invokeLoop = function() end
    local invokeDebug = function() end

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
    root:AddChild(actionBar)

    local contentScroll = UI.ScrollView {
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
        height = 390,
        maxHeight = "92%",
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
    refs.modalCard:AddChild(refs.settlementBody)

    refs.elderBody = UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 8 }
    refs.elderMessage = makeLabel("选择一件可赠送的物品。", 13)
    refs.elderBody:AddChild(refs.elderMessage)
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
    refs.elderBody:AddChild(makeButton("离开老人家", function() invokeLoop("SetElderOpen", false) end, "secondary", 128))
    refs.modalCard:AddChild(refs.elderBody)
    refs.overlay:AddChild(refs.modalCard)
    refs.overlay:Hide()
    refs.forcedBody:Hide()
    refs.settlementBody:Hide()
    refs.elderBody:Hide()
    root:AddChild(refs.overlay)

    invokeLoop = function(methodName, ...)
        if state.destroyed then return end
        local method = loop[methodName]
        if type(method) ~= "function" then
            state.localMessage = "当前玩法暂不支持：" .. methodName
            if refresh then refresh() end
            return
        end
        local ok, result, reason = pcall(method, loop, ...)
        if not ok then
            state.localMessage = "操作失败：" .. tostring(result)
        elseif result == false then
            state.localMessage = "操作未完成：" .. userMessage(reason)
        else
            state.localMessage = ""
        end
        if refresh then refresh() end
    end

    invokeDebug = function(command, argument)
        if state.destroyed or not debugTools then return end
        local ok, result, reason = pcall(debugTools.Execute, debugTools, command, argument)
        if not ok then
            state.localMessage = "调试命令失败：" .. tostring(result)
        elseif result == false then
            state.localMessage = "调试命令失败：" .. userMessage(reason)
        else
            state.localMessage = tostring(reason or "")
        end
        if refs.debugStatus then setText(refs.debugStatus, "debugStatus", state.localMessage) end
        if refresh then refresh() end
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

    local function rebuildItemRows(items, inPort, elderOpen)
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
            if definition and definition.canEat then
                inventoryRow:AddChild(makeButton("使用", function() invokeLoop("UseItem", itemIndex) end, "success", 56))
            end
            if inPort and (itemId == "sardine" or itemId == "tuna") and definition then
                local price = definition.sellPrice
                local label = price and ("出售 ¥" .. tostring(price)) or "售价未定"
                local sellButton = makeButton(label, function() invokeLoop("Sell", itemIndex) end, "primary", 82)
                if not price then sellButton:SetDisabled(true) end
                inventoryRow:AddChild(sellButton)
            end
            inventoryRow:AddChild(makeButton("丢弃", function() invokeLoop("DropItem", itemIndex) end, "danger", 56))
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
                    invokeLoop("Sell", itemIndex)
                end, "primary", 92)
                if not price then saleButton:SetDisabled(true) end
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
                giftRow:AddChild(makeButton("赠送", function() invokeLoop("GiveToElder", itemIndex) end, "primary", 64))
                refs.elderGiftRows:AddChild(giftRow)
            end
        end
        if saleCount == 0 then addEmptyMessage(refs.portSales, "没有可出售的鱼。") end
        if giftCount == 0 then addEmptyMessage(refs.elderGiftRows, "没有老人愿意收下的物品。") end
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

        local busy = loop.busy == true or loop.loading == true or loop.dropInFlight == true
        local ready = true
        if type(loop.Ready) == "function" then ready = loop:Ready() end
        local inPort = loop.inPort == true
        refs.depart:SetVisible(inPort)
        refs.returnToPort:SetVisible(not inPort)
        refs.endToday:SetVisible(inPort)
        refs.elderToggle:SetVisible(inPort)
        refs.depart:SetDisabled(not ready or busy or loop.inventoryOpen == true or loop.elderOpen == true)
        refs.returnToPort:SetDisabled(busy or not ready)
        refs.endToday:SetDisabled(busy or not ready)
        refs.inventoryToggle:SetDisabled(busy or (not ready and loop.inventoryOpen ~= true))
        refs.elderToggle:SetDisabled(busy or not ready)
        refs.inventoryPanel:SetVisible(loop.inventoryOpen == true)
        refs.portPanel:SetVisible(inPort)
        local function updateUpgrade(button, label, price)
            button:SetText(label .. (price and (" · ¥" .. tostring(price)) or " · 已满级/不可升级"))
            button:SetDisabled(not inPort or not ready or busy or not price or player.money < price)
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
            shopButton:SetDisabled(not inPort or not ready or busy or stock <= 0)
            refs.shopStockLabels[itemId]:SetText(definition.name .. "库存：" .. tostring(stock))
        end
        refs.elderToggle:SetText(loop.elderOpen == true and "返回港口" or "拜访老人")

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
        local signatureParts = { tostring(capacity), tostring(inPort), tostring(loop.elderOpen == true) }
        for _, itemId in ipairs(items) do signatureParts[#signatureParts + 1] = itemId end
        local signature = table.concat(signatureParts, "|")
        if signature ~= state.inventorySignature then
            state.inventorySignature = signature
            rebuildItemRows(items, inPort, loop.elderOpen == true)
        end

        local showForced = loop.forcedReturnPending == true
        local showSettlement = not showForced and loop.settlementPending == true
        local showElder = not showForced and not showSettlement and loop.elderOpen == true
        refs.overlay:SetVisible(showForced or showSettlement or showElder)
        refs.forcedBody:SetVisible(showForced)
        refs.settlementBody:SetVisible(showSettlement)
        refs.elderBody:SetVisible(showElder)

        if showSettlement then
            local confirmed = loop.settlementApplied == true
            local text = confirmed and (busy and "今日已结算，正在自动保存…" or "保存失败，可重试同一结算。")
                or "结束今日并进入下一天？确认后会自动保存。"
            setText(refs.settlementText, "settlementText", text)
            -- ConfirmSettlement 在存档失败时可重试已应用的同一结算。
            local settlementButton = refs.settlementConfirm
            settlementButton:SetText(confirmed and "重试保存" or "确认结算")
            settlementButton:SetDisabled(busy)
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
                    feedback = "选择一件可赠送的物品。"
                end
            end
            setText(refs.elderMessage, "elderMessage", feedback)
        end
        if refs.debugFishing then refs.debugFishing:SetDisabled(busy or inPort or not ready) end
        if refs.debugSalvage then refs.debugSalvage:SetDisabled(busy or inPort or not ready) end
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
