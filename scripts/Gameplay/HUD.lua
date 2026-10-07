-- B 玩法 HUD 原型。UI 生命周期由宿主负责，本模块只创建和管理自己的子树。
local UI = require("urhox-libs/UI")
local Config = require("config.gameplay")
local Items = require("data.items")
local Diagnostics = require("Gameplay.Diagnostics")
local ArtVariants = require("Ocean.ArtVariants")
local DialogueStyle = require("Gameplay.DialogueStyle")
local UiKit = require("Gameplay.UiKit")
local Achievements = require("Gameplay.Achievements")

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

local presentation = require("Gameplay.HUDPresentation").Create(UI, Config, Items)
local userMessage = presentation.userMessage
local saveText = presentation.saveText
local copyItems = presentation.copyItems
local itemName = presentation.itemName
local UI_PALETTE = presentation.UI_PALETTE
local UI_SIZE = presentation.UI_SIZE
local makeThemer = presentation.makeThemer
local makeLabel = presentation.makeLabel
local fishDisplay = presentation.fishDisplay
local modeText = presentation.modeText
local makeInfoLabel = presentation.makeInfoLabel
local infoLine = presentation.infoLine
local makeButton = presentation.makeButton
-- 批3b 水彩按钮底板（v2.0 §7.2）：外包一层注入皮肤 props，不改 presentation
-- 的无依赖设计；DialogueStyle 无皮肤定义时 buttonProps 返回 nil，等价原行为。
local plainMakeButton = makeButton
makeButton = function(text, onClick, variant, width)
    return plainMakeButton(text, onClick, variant, width, DialogueStyle.buttonProps(variant))
end
local fadeOpacity = presentation.fadeOpacity
local OPENING_ELDER_TEXT = presentation.OPENING_ELDER_TEXT
local INFO_FLEX = presentation.INFO_FLEX

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
    ---@field openingDismissedGeneration number|nil
    ---@field openingActive boolean
    ---@field openingGeneration number|nil
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
        openingDismissedGeneration = nil,
        openingActive = false,
        openingGeneration = nil,
        -- 图鉴/成就页（v2.0 §7.4）：暂停态才可开；tab="achievements"|"marine"。
        compendiumOpen = false,
        compendiumTab = "achievements",
        compendiumBuiltTab = nil,
        compendiumRowsDirty = false,
        achievementToastUntil = nil,
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

    local themedPanels = {} -- 昼夜主题注册表：{widget=, day=, night=}
    local applyTheme = makeThemer()

    -- v2.1 批B：通用卡工厂换水彩底板（roundcard=圆角茶棕卡）。
    -- 皮肤/文字色全部来自 Gameplay.UiKit 单一令牌源，本函数不再内嵌样式。
    -- 昼夜：底板图不变，靠 themedPanels 的 day/night 衬色压暗
    -- （palette.cardDay/cardNight），makeThemer 逐通道插值 —— 换图后仍保留昼夜氛围。
    -- card() 通用卡工厂。skin 选底板档位（v2.1 批B-D 分级）：
    --   抽屉内面板（背包/港口）用默认 panel（繁复茶棕，信息量大需要框感）；
    --   海面高频操作区传 "panelLite"（素面纸，去掉卷草纹/双线边框）。
    local function card(title, extra, skin)
        local panel = UI.Panel(UiKit.cardProps(skin or "panel", extra))
        themedPanels[#themedPanels + 1] = {
            widget = panel, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
        }
        panel:AddChild(makeLabel(title, UiKit.fontSize.title, UiKit.ink.title, "bold"))
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

    -- v2.0 零遮挡：header 保持 root 首子节点（测试契约 + Scene 左侧注入依赖）。
    -- 真机反馈（2026-10-05）：原 9 行信息堆叠严重，收敛为两层文字——
    -- 第一行状态（天/昼夜/体力/钱/背包），第二行日志（暂停/反馈/存档/港口提示）。
    local header = UI.Panel {
        width = "100%",
        minHeight = 40,
        flexDirection = "column",
        alignItems = "flex-start",
        gap = 2,
    }
    refs.status = makeInfoLabel("", 13, nil, nil, INFO_FLEX)
    header:AddChild(infoLine(refs.status))
    -- 日志槽：log 与 portAccessReason 互斥显示，同一时刻只占一行。
    refs.log = makeInfoLabel("", 12, UI_PALETTE.seaTextMuted, nil, INFO_FLEX)
    header:AddChild(infoLine(refs.log))
    -- 夜航警示行：默认隐藏，仅"夜+海上+未耗尽"出现（B 侧 review 契约的安全提示）。
    refs.nightRisk = makeInfoLabel("", 12, UI_PALETTE.seaTextGold, nil, INFO_FLEX)
    refs.nightRisk:SetVisible(false)
    header:AddChild(infoLine(refs.nightRisk))
    refs.portAccessReason = makeInfoLabel("锚形标记=港口（交易中心）· 返港/交易需距港≤10米。", 12, UI_PALETTE.seaTextMuted, nil, INFO_FLEX)
    refs.portAccessReason:SetVisible(false)
    header:AddChild(infoLine(refs.portAccessReason))
    refs.debugToggle = makeButton("开发调试", function()
        if refs.debugPanel then refs.debugPanel:SetVisible(not refs.debugPanel:IsVisible()) end
    end, "secondary", 92)
    if debugTools and debugTools.enabled == true then header:AddChild(refs.debugToggle) end
    -- 批2 水彩 HUD（2026-10-07）：状态图标条——体力(苹果)/钱(金币堆)/背包(鱼)。
    -- 文本状态行原样保留（B 侧 Circle1HUDReviewTests 契约），图标条是增量层；
    -- 显隐随 ArtVariants（StoryArt 开关）在 refresh 中同步，A/B 一键切换。
    -- 能力探测：测试桩的 UI 门面无 Sprite 字段时跳过整条（离线回归红基线不变）。
    if type(UI.Sprite) == "function" then
        refs.watercolorStrip = UI.Panel {
            id = "watercolorIconStrip",
            width = "auto",
            flexDirection = "row",
            alignItems = "center",
            gap = 12,
            pointerEvents = "box-none",
        }
        refs.watercolorValues = {}
        for _, def in ipairs({
            { key = "wcStamina", frame = "apple" },
            { key = "wcMoney", frame = "coins_pile" },
            { key = "wcBag", frame = "fish" },
        }) do
            local slot = UI.Panel {
                width = "auto", flexDirection = "row", alignItems = "center",
                gap = 4, pointerEvents = "box-none",
            }
            slot:AddChild(UI.Sprite {
                src = "image/WatercolorUI/resource_icons.json",
                frame = def.frame, width = 22, height = 22,
            })
            local valueLabel = makeLabel("", 12)
            slot:AddChild(valueLabel)
            refs.watercolorValues[def.key] = valueLabel
            refs.watercolorStrip:AddChild(slot)
        end
        refs.watercolorStrip:SetVisible(ArtVariants.IsEnabled())
        header:InsertChild(refs.watercolorStrip, 1)
    end
    root:AddChild(header)

    -- 真机反馈（2026-10-05）：捕鱼弹出框过大遮挡中心小船——压成左上角小卡
    -- （宽 ≤216px、行高 ~11px、按钮 32px），面积约为原 1/4，只留必要提示；
    -- 只在抛网/收网/结算过程中出现，入口仍走按钮坞"捕鱼"按钮。
    refs.fishingPanel = UI.Panel(UiKit.cardProps("panelLite", {
        id = "fishingCompactPanel",
        width = "auto",
        maxWidth = 216,
        alignSelf = "flex-start",
        padding = 6,
        gap = 3,
    }))
    themedPanels[#themedPanels + 1] = {
        widget = refs.fishingPanel, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    refs.fishingStatus = makeLabel("选择海面网心开始捕鱼。", UiKit.fontSize.teaching)
    refs.fishingProgress = makeLabel("动作进度：0%", UiKit.fontSize.teaching, UiKit.ink.dim)
    -- T2b：同气泡根因的保险——显式宽度，避免任何父布局变化导致零宽不渲染。
    refs.fishingResult = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.teaching, nil, { width = "100%" })
    refs.fishingPanel:AddChild(refs.fishingStatus)
    refs.fishingPanel:AddChild(refs.fishingProgress)
    refs.fishingPanel:AddChild(refs.fishingResult)
    refs.beginFishing = makeButton("捕鱼", function()
        invokeLoop("BeginFishingSelection")
    end, "primary", 72)
    local fishingButtons = UI.Panel {
        width = "100%",
        flexDirection = "row",
        gap = 5,
    }
    -- Circle1 一键抛网（B 侧交付）：无确认步骤，仅保留取消/重试清理按钮。
    refs.cancelFishing = makeButton("取消捕鱼", function()
        invokeLoop("CancelFishingAction")
    end, "danger", 88)
    fishingButtons:AddChild(refs.cancelFishing)
    refs.fishingPanel:AddChild(fishingButtons)
    root:AddChild(refs.fishingPanel)

    -- 真机反馈（2026-10-05）：按钮坞由三行收敛为单行操作。容器透明 +
    -- box-none——空白区域点击穿透海面，只有按钮本身接收点击；超出屏幕
    -- 宽度时 flexWrap 兜底换行，常态保证一行。
    -- zIndex 低于抽屉(90/91)与模态(100)：抽屉/弹窗打开时自然盖住按钮坞。
    local actionBar = UI.Panel {
        id = "gameplayActionDock",
        position = "absolute",
        right = 0,
        bottom = 0,
        -- v2.1 批B 修复（真机 10-07 图1-3）：绝对定位元素若不设 width，
        -- 百分比宽度基准为 0，导致内层 dock 的 maxWidth="100%" 形同虚设、
        -- 按钮互相压盖并压在岛面上。显式给 left:0 让它撑满屏幕宽度，
        -- 再由 justifyContent=flex-end 靠右对齐，换行仍生效。
        left = 0,
        width = "100%",
        zIndex = 60,
        padding = 8,
        gap = 6,
        flexDirection = "row",
        justifyContent = "flex-end",
        alignItems = "flex-end",
        flexWrap = "wrap",
        pointerEvents = "box-none",
    }
    local dock = UI.Panel {
        id = "gameplayActionDockRow",
        flexDirection = "row",
        -- v2.1 批B：显式允许换行 + 限宽。超宽时按钮折行而非互相压盖
        -- （真机 10-07 图1-3 压盖在岛面上不可读）。justifyContent 保持
        -- flex-end，折行后仍靠右下对齐。
        flexWrap = "wrap",
        gap = 6,
        alignItems = "flex-end",
        justifyContent = "flex-end",
        maxWidth = "100%",
        pointerEvents = "box-none",
    }
    refs.depart = makeButton("出航", function() invokeLoop("Depart") end, "primary", 80)
    refs.returnToPort = makeButton("返港", function() invokeLoop("ReturnToPort") end, "secondary", 80)
    refs.endToday = makeButton("结束今日", function() invokeLoop("EndToday") end, "primary", 98)
    -- 读取云存档/开始新周目移入信息滚动屏（低频港口操作，见 portPanel 段）。
    -- 背包开关（v2.1 批B 真机图1 修复）：背包已迁入信息滚动屏，按钮不再开关
    -- 65% 抽屉，改为"开信息屏 + 标记定位到背包卡"。世界仍照常暂停
    -- （走 loop:SetInventoryOpen，契约 Circle1B2UITests 要求该调用生效）。
    refs.inventoryToggle = makeButton("背包", function()
        local willOpen = not (loop.inventoryOpen == true)
        invokeLoop("SetInventoryOpen", willOpen)
        if willOpen then
            -- 打开信息屏并滚到背包卡（信息屏默认入口是图鉴/透镜状态）
            state.infoOpen = true
            state.focusInventory = true
        end
    end, "secondary", 80)
    refs.elderToggle = makeButton("拜访老人", function()
        invokeLoop("SetElderOpen", not (loop.elderOpen == true))
    end, "secondary", 98)
    -- 与捕鱼同级的上下文按钮：靠近出港点右侧木桶（新手教程点位）后出现；
    -- 望远镜（窥视镜）在获得后常驻、未获得时靠近木桶作为线索入口。
    refs.barrelToggle = makeButton("检查木桶", function()
        invokeLoop("BeginBarrelInspection")
    end, "secondary", 96)
    refs.barrelToggle:SetVisible(false)
    refs.scopeToggleBar = makeButton("望远镜", function()
        invokeLoop(loop.scopeSyncError and "DisableScope" or "ToggleScope")
    end, "secondary", 80)
    refs.scopeToggleBar:SetVisible(false)
    -- 信息滚动屏开合按钮（真机反馈 2026-10-05：屏幕只能打开不能收起）：
    -- 按一下打开、再按一下或点击屏内空白处收起。
    refs.infoToggle = makeButton("信息", function()
        state.infoOpen = not (state.infoOpen == true)
        refresh()
    end, "secondary", 72)
    -- 图鉴/成就入口（v2.0 §7.4）：仅暂停态可见（refresh 控制），页壳走模态层。
    refs.compendiumToggle = makeButton("图鉴", function()
        state.compendiumOpen = not (state.compendiumOpen == true)
        state.compendiumRowsDirty = true
        refresh()
    end, "secondary", 72)
    refs.compendiumToggle:SetVisible(false)
    -- 单行顺序：信息开合 → 情境按钮 → 核心动作（出航/返港/结束今日/捕鱼）。
    -- v2.1 批B 修复（真机 10-07 图1-3）：按钮互相压盖、压在岛面上不可读。
    -- 先试"收进更多浮层"被回归拦下（Circle1B2/B3 断言背包/拜访老人/
    -- 透镜未获得等按钮在 HUD 树中**可见**，折叠即 hidden → 契约不允许）。
    -- 改为：全部按钮保持可见，靠两层约束消除压盖——
    --   ① dock 允许换行（flexWrap）且限制最大宽度，超出自动折行不重叠；
    --   ② D 案把海面操作区底板换成素面纸（panelLite），去掉卷草纹与
    --      双线边框，视觉噪声下降后可读性提升。
    -- 按钮宽度已在 10-05 收敛过一轮（80~98px），此处不再压缩触控尺寸。
    dock:AddChild(refs.infoToggle)
    dock:AddChild(refs.compendiumToggle)
    dock:AddChild(refs.barrelToggle)
    dock:AddChild(refs.scopeToggleBar)
    dock:AddChild(refs.inventoryToggle)
    dock:AddChild(refs.elderToggle)
    dock:AddChild(refs.depart)
    dock:AddChild(refs.returnToPort)
    dock:AddChild(refs.endToday)
    dock:AddChild(refs.beginFishing)
    actionBar:AddChild(dock)
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

    -- 真机反馈（2026-10-05）：信息滚动屏改为开合式——"信息"按钮打开，
    -- 点屏内空白处（或再按按钮）收起。closeCatcher 是铺满信息区的透明按钮，
    -- 垫在 contentScroll 之下：scroll 保持 pointerEvents=box-none（AB 契约），
    -- 空白点击穿透到 catcher 触发收起，面板内按钮不受影响。
    local infoLayer = UI.Panel {
        id = "gameplayInfoLayer",
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        pointerEvents = "box-none",
    }
    refs.infoCloseCatcher = UI.Button {
        id = "infoCloseCatcher",
        text = "",
        position = "absolute",
        top = 0,
        left = 0,
        width = "100%",
        height = "100%",
        fontSize = 1,
        backgroundColor = { 0, 0, 0, 0 },
        borderColor = { 0, 0, 0, 0 },
        borderWidth = 0,
        onClick = function()
            if state.infoOpen == true then
                state.infoOpen = false
                refresh()
            end
        end,
    }
    refs.infoCloseCatcher:SetVisible(false)
    infoLayer:AddChild(refs.infoCloseCatcher)
    refs.contentScroll = contentScroll
    refs.contentScroll:SetVisible(false)
    infoLayer:AddChild(contentScroll)

    -- 背包底部抽屉（设计方案 v1.0）：从底部滑入占屏 65%，背后场景压暗；
    -- 港口商店留在滚动区——抽屉若同时容纳商店会遮挡出航/结算等核心按钮。
    refs.drawerBackdrop = UI.Panel {
        id = "gameplayDrawerBackdrop",
        position = "absolute",
        top = 0,
        left = 0,
        width = "100%",
        height = "100%",
        zIndex = 90,
        backgroundColor = UI_PALETTE.backdrop,
        pointerEvents = "auto",
    }
    refs.drawerBackdrop:Hide()
    -- 抽屉是"容器层"不是"卡片"：保持 seaDeep/seaNight 冷色容器契约
    -- （Circle1HUDReviewTests 断言其昼夜 RGBA 插值走 palette.seaDeep/seaNight），
    -- 卡内子卡（背包/宝物/物品操作）各自换水彩底板，形成"冷容器 + 暖卡片"的层级对比。
    refs.drawer = UI.Panel {
        id = "gameplayInventoryDrawer",
        position = "absolute",
        left = 0,
        bottom = 0,
        width = "100%",
        height = UI_SIZE.drawerHeightPct or "65%",
        zIndex = 91,
        padding = 12,
        gap = 8,
        flexDirection = "column",
        backgroundColor = UI_PALETTE.seaDeep,
        borderColor = UI_PALETTE.border,
        borderWidth = 1,
        borderRadius = 16,
        pointerEvents = "auto",
        transition = "opacity 0.25s easeOut, " .. ((Config.ui or {}).themeTransition or "backgroundColor 0.8s easeInOut"),
    }
    themedPanels[#themedPanels + 1] = { widget = refs.drawer, day = UI_PALETTE.seaDeep, night = UI_PALETTE.seaNight }
    refs.drawer:Hide()
    local drawerGrabber = UI.Panel {
        width = "100%",
        minHeight = 10,
        justifyContent = "center",
        alignItems = "center",
    }
    drawerGrabber:AddChild(UI.Panel {
        width = 44,
        height = 4,
        backgroundColor = UI_PALETTE.border,
        borderRadius = 2,
    })
    refs.drawer:AddChild(drawerGrabber)
    refs.drawerScroll = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        scrollY = true,
        showScrollbar = true,
    }
    local drawerContent = UI.Panel {
        width = "100%",
        gap = 8,
        flexDirection = "column",
    }
    refs.drawerScroll:AddChild(drawerContent)
    refs.drawer:AddChild(refs.drawerScroll)

    -- 真机反馈（2026-10-05）：投掷/木桶提示是"过程提示"，不进可开合的信息滚动屏，
    -- 直接挂在根流（与捕鱼小卡同级），保证进行中流程始终可见。
    -- 屏内不再放重复入口按钮：检查入口走按钮坞"检查木桶"。
    refs.throwSelectionPanel = card("投掷物品")
    refs.throwSelectionText = makeLabel("", UiKit.fontSize.body, UiKit.ink.title, "bold")
    refs.throwSelectionPanel:AddChild(refs.throwSelectionText)
    refs.throwSelectionCancel = makeButton("取消投掷", function()
        invokeLoop("CancelThrowSelection")
    end, "secondary", 94)
    refs.throwSelectionPanel:AddChild(refs.throwSelectionCancel)
    refs.throwSelectionPanel:SetVisible(false)
    root:AddChild(refs.throwSelectionPanel)

    refs.barrelPanel = card("海岸木桶")
    refs.barrelStatus = makeLabel("木桶检查暂未开放。", 13)
    refs.barrelPanel:AddChild(refs.barrelStatus)
    refs.barrelCancel = makeButton("取消检查", function()
        invokeLoop("CancelBarrelInspection")
    end, "secondary", 92)
    refs.barrelPanel:AddChild(refs.barrelCancel)
    refs.barrelPanel:SetVisible(false)
    root:AddChild(refs.barrelPanel)

    -- 望远镜状态行只读（信息滚动屏内）；开关入口收敛为按钮坞"望远镜"单按钮。
    refs.scopePanel = UI.Panel {
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
        gap = 7,
    }
    refs.scopeStatus = makeInfoLabel("尚未获得透镜；无法查看或切换望远镜功能。", 12, UI_PALETTE.seaTextMuted)
    refs.scopePanel:AddChild(refs.scopeStatus)
    content:AddChild(refs.scopePanel)
    -- 宝物是既有player.treasures状态，不占有限格inventory；开关复用既有望远镜入口。
    refs.treasurePanel = card("宝物 · 不占船舱格")
    refs.treasureSummary = makeLabel("尚未获得宝物。", UiKit.fontSize.teaching, UiKit.ink.dim)
    refs.treasurePanel:AddChild(refs.treasureSummary)
    drawerContent:AddChild(refs.treasurePanel)

    refs.inventoryPanel = card("背包")
    refs.inventoryCount = makeLabel("0 / 0 格", UiKit.fontSize.teaching, UiKit.ink.dim)
    refs.upgrade = makeButton("扩容", function() invokeLoop("UpgradeInventory") end, "secondary", 148)
    refs.sellAll = makeButton("全部卖出", function() invokeLoop("SellAll") end, "primary", 108)
    refs.inventoryClose = makeButton("收起", function()
        invokeLoop("SetInventoryOpen", false)
    end, "secondary", 72)
    local inventoryHeader = UI.Panel {
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
        gap = 6,
        children = {
            refs.inventoryCount,
            UI.Spacer(),
            refs.sellAll,
            refs.upgrade,
            refs.inventoryClose,
        },
    }
    refs.inventoryPanel:AddChild(inventoryHeader)
    refs.inventoryHint = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.dim)
    refs.inventoryPanel:AddChild(refs.inventoryHint)
    refs.itemMenu = UI.Panel(UiKit.cardProps("panelLite", {
        width = "100%",
        padding = 8,
        gap = 6,
    }))
    themedPanels[#themedPanels + 1] = {
        widget = refs.itemMenu, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    refs.itemMenuTitle = makeLabel("物品操作", UiKit.fontSize.teaching, UiKit.ink.teaching, "bold")
    refs.itemMenu:AddChild(refs.itemMenuTitle)
    refs.itemUseReason = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.dim)
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
        local itemIndex = state.selectedItemIndex
        if not itemIndex then return end
        -- 打开对话会刷新物品行并清除选择，先保存原槽位；失败时不交付物品。
        invokeLoop("SetElderOpen", true)
        if loop.elderOpen == true then invokeLoop("GiveToElder", itemIndex) end
    end, "primary", 72)
    refs.itemDrop = makeButton("丢弃", function()
        if state.selectedItemIndex then invokeLoop("DropItem", state.selectedItemIndex) end
    end, "danger", 56)
    refs.itemThrow = makeButton("投掷", function()
        local itemIndex = state.selectedItemIndex
        if not itemIndex then return end
        -- 真机反馈（2026-10-05）：背包内点"投掷"直接以船当前位置投放并收起背包，
        -- 不再要求点击海面（抽屉遮罩会挡住海面导致卡死在背包页）。
        invokeLoop("SetInventoryOpen", false)
        invokeLoop("ThrowItemAtShip", itemIndex)
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
    refs.pendingCatchPanel = UI.Panel(UiKit.cardProps("plain", {
        width = "100%",
        padding = 8,
        gap = 6,
    }))
    themedPanels[#themedPanels + 1] = {
        widget = refs.pendingCatchPanel, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    refs.pendingCatchText = makeLabel("有渔获等待接收。", UiKit.fontSize.info, UiKit.ink.title, "bold")
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
        -- v2.1 批B：背包卡迁入信息滚动屏后，物品区高度由 210 放宽到 320，
        -- 一屏能看到更多行；整卡外已有 contentScroll 滚动，不至于撑破信息屏。
        height = 320,
        scrollY = true,
        showScrollbar = true,
        children = { refs.inventoryRows },
    }
    refs.inventoryPanel:AddChild(refs.inventoryScroll)
    refs.inventoryPanel:SetVisible(false)
    -- v2.1 批B（真机 10-07 图1）：背包原挂抽屉（占屏 65% 过高）→ 改挂信息
    -- 滚动屏，与港口商店平级。抽屉容器 gameplayInventoryDrawer 保留
    -- （Circle1B3SceneUITests 契约要求它在 root 倒数第二位/宽 100%/zIndex 91），
    -- 但不再承载背包内容——空抽屉永不显示，等于保留壳、去掉占用。
    content:AddChild(refs.inventoryPanel)

    -- v2.1 批B 修复（真机 10-07 图4）：港口商店内容多，card() 走 width=100%
    -- 无高度约束，内容把卡片撑出抽屉、压到底部按钮坞（苹果·¥30 与
    -- 出航/结束今日 重叠）。按设计方案 v2.1 §7.3 规则一，改为
    -- "卡片有高度上限 + 卡内滚动"，不撑破抽屉、不侵占底坞落区⑤。
    refs.portPanel = card("港口商店", { maxHeight = "58%" })
    -- 内容全部挂进 portBody（滚动容器），portPanel 自身只承担标题+滚动。
    local portBody = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        gap = 6,
        flexDirection = "column",
    }
    local portScroll = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        scrollY = true,
        showScrollbar = true,
        children = { portBody },
    }
    refs.portPanel:AddChild(portScroll)
    -- 低频港口操作（真机反馈 2026-10-05 精简按钮坞）：从按钮坞移入信息屏。
    refs.loadSaved = makeButton("读取云存档", function() invokeLoop("LoadSaved") end, "secondary", 110)
    refs.newRun = makeButton("开始新周目", function() invokeLoop("NewRun") end, "secondary", 110)
    local portUtilityRow = UI.Panel {
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
        gap = 6,
    }
    portUtilityRow:AddChild(refs.loadSaved)
    portUtilityRow:AddChild(refs.newRun)
    portBody:AddChild(portUtilityRow)
    refs.loadStatus = makeLabel("", 12)
    portBody:AddChild(refs.loadStatus)
    portBody:AddChild(makeLabel("新周目起始状态会在开始时保存；入口处可读取已有云存档。", 12))
    refs.staminaUpgrade = makeButton("升级体力", function() invokeLoop("UpgradeStamina") end, "secondary", 180)
    refs.speedUpgrade = makeButton("升级航速", function() invokeLoop("UpgradeBoatSpeed") end, "secondary", 180)
    portBody:AddChild(refs.staminaUpgrade)
    portBody:AddChild(refs.speedUpgrade)
    portBody:AddChild(makeLabel("购买补给", UiKit.fontSize.info, UiKit.ink.teaching, "bold"))
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
    portBody:AddChild(buyRow)
    portBody:AddChild(makeLabel("出售渔获", UiKit.fontSize.info, UiKit.ink.teaching, "bold"))
    refs.portSales = UI.Panel { width = "100%", flexDirection = "column", gap = 4 }
    refs.portSalesScroll = UI.Panel {
        width = "100%",
        children = { refs.portSales },
    }
    portBody:AddChild(refs.portSalesScroll)
    refs.portPanel:SetVisible(false)
    content:AddChild(refs.portPanel)

    if debugTools and debugTools.enabled == true then
        -- v2.1 批B 修复（真机 10-07 图1-3）：调试面板直挂 root，内部多行
    -- flexWrap="wrap" 的按钮行总宽远超屏幕，导致按钮左截断堆叠
    -- （"derwater C" / "eception OA" / "pawn sardine" 溢出面板外）。
    -- 按 §7.3 规则一：面板落区④居中卡，宽 ≤70%，内容超出则卡内滚动。
    refs.debugPanel = card("开发调试", {
        width = "86%",
        maxWidth = 520,
        maxHeight = "72%",
    }, "panelLite")
    -- 内容统一挂 debugBody（卡内滚动容器），面板本身只承担标题 + 滚动。
    local debugBody = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        gap = 7,
        flexDirection = "column",
    }
    local debugScroll = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        scrollY = true,
        showScrollbar = true,
        children = { debugBody },
    }
    refs.debugPanel:AddChild(debugScroll)
        refs.debugPanel:SetVisible(false)
        refs.debugStatus = makeLabel("调试命令仅在开发模式启用", 12, { 189, 211, 190, 255 })
        debugBody:AddChild(refs.debugStatus)

        -- UI 树 dump（UI 定位诊断）：递归可见节点 → 诊断日志逐行输出；
        -- 深色窄条（w≤40 且 h≥40 且带背景）直接摘要在 debugStatus。
        if debugTools.SetUiDumper then
            debugTools:SetUiDumper(function()
                local lines, suspects = {}, {}
                local function dumpWidget(widget, depth, path)
                    if depth > 6 or #lines >= 150 then return end
                    local okLayout, layout = pcall(widget.GetAbsoluteLayout, widget)
                    if not okLayout or type(layout) ~= "table" then return end
                    local props = widget.props or {}
                    if props.visible == false then return end
                    local w, h = layout.w or 0, layout.h or 0
                    if w <= 0 or h <= 0 then return end
                    local id = props.id or "?"
                    local bg = props.backgroundColor
                    local bgText = ""
                    if type(bg) == "table" and (bg[4] or 0) > 0 then
                        bgText = string.format(" bg=%d,%d,%d,%d", bg[1], bg[2], bg[3], bg[4])
                        if w <= 40 and h >= 40 then
                            suspects[#suspects + 1] = string.format(
                                "可疑窄条 %s %dx%d @(%d,%d)%s", id, w, h, layout.x or 0, layout.y or 0, bgText)
                        end
                    end
                    lines[#lines + 1] = string.format("%s%s %s %.0fx%.0f @(%d,%d)%s",
                        string.rep("  ", depth), id, tostring(widget.__class and widget.__class.__name or "W"),
                        w, h, layout.x or 0, layout.y or 0, bgText)
                    for _, child in ipairs(widget.children or {}) do
                        dumpWidget(child, depth + 1, path)
                    end
                end
                dumpWidget(root, 0, "")
                for _, line in ipairs(lines) do
                    Diagnostics.Event("ui_dump", { text = line })
                end
                if #suspects == 0 then
                    return "UI 树 " .. #lines .. " 行已入日志；无深色窄条可疑项"
                end
                return table.concat(suspects, "；") .. "（全树 " .. #lines .. " 行已入日志）"
            end)
        end

        local scaleRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 5 }
        scaleRow:AddChild(makeLabel("时间倍率", 12))
        for _, scale in ipairs(Config.debug.timeScales or {}) do
            local configuredScale = scale
            scaleRow:AddChild(makeButton(tostring(configuredScale) .. "×", function()
                invokeDebug("timeScale", configuredScale)
            end, "secondary", 54))
        end
        debugBody:AddChild(scaleRow)

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
        debugBody:AddChild(staminaRow)

        -- 成就桩试水（v2.0 §7.4）：真机验证 toast 展示/淡出与层级，不碰判定逻辑。
        debugBody:AddChild(makeButton("模拟成就解锁", function()
            Achievements.Unlock("zero_skunk")
            refresh()
        end, "secondary", 140))

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
        debugBody:AddChild(seekRow)

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
        debugBody:AddChild(itemRow)

        -- S0 音频验证桩：试听 UI 点击音与白天声床循环（验收标准见设计方案 §9 S0）。
        local audioRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 5 }
        audioRow:AddChild(makeLabel("音频S0", 12))
        audioRow:AddChild(makeButton("试听点击", function() invokeDebug("audioClick") end, "secondary", 86))
        audioRow:AddChild(makeButton("声床开关", function() invokeDebug("audioAmb") end, "secondary", 86))
        debugBody:AddChild(audioRow)

        -- T3 海岛性能探针：开探针→绕岛航行数秒→读数（每帧均值快照，屏幕通道）。
        local perfRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 5 }
        perfRow:AddChild(makeLabel("性能T3", 12))
        perfRow:AddChild(makeButton("探针开关", function() invokeDebug("perfToggle") end, "secondary", 86))
        perfRow:AddChild(makeButton("性能读数", function() invokeDebug("perfRead") end, "secondary", 86))
        debugBody:AddChild(perfRow)

        -- UI 定位诊断：复现占位现象时点一次，整棵可见树进诊断日志。
        local uiDiagRow = UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 5 }
        uiDiagRow:AddChild(makeLabel("UI诊断", 12))
        uiDiagRow:AddChild(makeButton("UI树dump", function() invokeDebug("uiDump") end, "secondary", 96))
        debugBody:AddChild(uiDiagRow)

        -- 调试面板挂根流（仅开发模式创建）：不随信息滚动屏开合，保证调试按钮常可用。
        root:AddChild(refs.debugPanel)
    end

    root:AddChild(infoLayer)

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
    -- v2.1 批B 剧情档：模态主卡换羊皮纸底板（parchment）。开场剧情/每日结算/
    -- 第7天结局/老人对话/强制返港/图鉴成就 6 个模态页共用此卡。
    refs.modalCard = UI.Panel(UiKit.cardProps("parchment", {
        width = 380,
        maxWidth = "94%",
        height = "90%",
        maxHeight = 430,
        transition = "opacity 0.25s easeOut", -- 模态出现时淡入，替代硬切
    }))
    themedPanels[#themedPanels + 1] = {
        widget = refs.modalCard, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    refs.modalTitle = makeLabel("", UiKit.fontSize.title + 1, UiKit.ink.title, "bold")
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
    refs.forcedText = makeLabel("夜深了，你必须返港。", UiKit.fontSize.title, UiKit.ink.title, "bold")
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

    -- T1（2026-10-06）：第 7 天结局模态；文案占位，正式版按 Q-006 由 B 侧替换。
    refs.endingBody = UI.Panel { width = "100%", flexGrow = 1, gap = 12 }
    refs.endingText = makeLabel("", 14)
    refs.endingBody:AddChild(refs.endingText)
    refs.endingNewRun = makeButton("开始新周目", function() invokeLoop("NewRun") end, "primary", 130)
    refs.endingBody:AddChild(refs.endingNewRun)
    refs.modalCard:AddChild(refs.endingBody)

    refs.elderBody = UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 8 }
    refs.elderMessage = makeLabel("食物可给予老人；鱼和鱼饵可向老人展示。", UiKit.fontSize.body)
    refs.elderBody:AddChild(refs.elderMessage)
    -- S6 教学（05 页 P6）：前 3 天且未完成首次捕鱼领取时，展示两条看海对白。
    -- v2.1 批B：卡内教学行改墨棕 teaching（羊皮纸底），※ 前缀由 UiKit 统一。
    refs.elderTeaching = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.teaching)
    refs.elderBody:AddChild(refs.elderTeaching)
    refs.elderStatus = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.teaching, "bold")
    refs.elderBody:AddChild(refs.elderStatus)
    -- 宝物小卡（卡内卡）：用 plain 素面纸档，padding 更紧。
    refs.elderTreasure = UI.Panel(UiKit.cardProps("plain", { padding = 7, gap = 5 }))
    themedPanels[#themedPanels + 1] = {
        widget = refs.elderTreasure, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    refs.elderTreasure:AddChild(makeLabel("宝物", UiKit.fontSize.teaching, UiKit.ink.teaching, "bold"))
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

    -- 成就/图鉴页壳（v2.0 §7.4）：仅在暂停态可开（圈2 决策：图鉴只在暂停界面查）。
    -- 成就页=6 条最小集桩；图鉴页=marine_life 8 水彩图标（发现状态待知识层接入）。
    refs.compendiumBody = UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 8 }
    local compTabs = UI.Panel { width = "100%", flexDirection = "row", gap = 8 }
    refs.compTabAchievements = makeButton("成就", function()
        if state.compendiumTab ~= "achievements" then
            state.compendiumTab = "achievements"
            state.compendiumRowsDirty = true
            refresh()
        end
    end, "secondary", 84)
    refs.compTabMarine = makeButton("图鉴", function()
        if state.compendiumTab ~= "marine" then
            state.compendiumTab = "marine"
            state.compendiumRowsDirty = true
            refresh()
        end
    end, "secondary", 84)
    compTabs:AddChild(refs.compTabAchievements)
    compTabs:AddChild(refs.compTabMarine)
    refs.compendiumBody:AddChild(compTabs)
    refs.compList = UI.Panel { width = "100%", flexDirection = "column", gap = 6 }
    refs.compendiumBody:AddChild(UI.ScrollView {
        width = "100%", flexGrow = 1, flexBasis = 0, scrollY = true, showScrollbar = true,
        children = { refs.compList },
    })
    refs.compendiumBody:AddChild(makeButton("返回游戏", function()
        state.compendiumOpen = false
        refresh()
    end, "secondary", 130))
    refs.modalCard:AddChild(refs.compendiumBody)

    refs.storyBody = UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 12 }
    refs.storyText = UI.Label {
        id = "storyDialogText",
        text = "",
        fontSize = UiKit.fontSize.body,
        -- v2.1 批B：羊皮纸底板上的正文用墨棕（原浅米白在浅纸上不可读）。
        fontColor = UiKit.ink.body,
        whiteSpace = "normal",
    }
    refs.storyBody:AddChild(refs.storyText)
    refs.storyClose = makeButton("结束对话", function()
        if state.openingActive then
            state.openingDismissedGeneration = state.openingGeneration
            state.openingActive = false
            refresh()
        else
            invokeLoop("CloseStoryDialog")
        end
    end, "primary", 104)
    refs.storyBody:AddChild(refs.storyClose)
    refs.modalCard:AddChild(refs.storyBody)
    refs.overlay:AddChild(refs.modalCard)
    refs.overlay:Hide()
    fadeOpacity(refs.modalCard, 0) -- 隐藏期间保持全透明；显示时由 transition 淡入
    refs.forcedBody:Hide()
    refs.settlementBody:Hide()
    refs.endingBody:Hide()
    refs.elderBody:Hide()
    refs.storyBody:Hide()
    -- 成就解锁 toast（v2.0 §7.4，D6=A：圈1 先行试水）：落区① 顶带右上，
    -- zIndex 30（低于小卡 50/气泡 70/模态 100），出现时不遮按钮坞与模态。
    -- 显示由 refresh 驱动：PollToast 取一条 → 展示 3 秒后淡出。
    refs.achievementToast = UI.Panel(UiKit.cardProps("plain", {
        id = "achievementToast",
        position = "absolute",
        top = 8,
        right = 10,
        width = 252,
        gap = 6,
        flexDirection = "row",
        alignItems = "center",
        zIndex = 30,
        pointerEvents = "box-none",
    }))
    themedPanels[#themedPanels + 1] = {
        widget = refs.achievementToast, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    if type(UI.Sprite) == "function" then
        -- 与水彩图标条同源：resource_icons 图集（宝箱暂代徽章，正式图标待批3b）。
        refs.achievementToast:AddChild(UI.Sprite {
            src = "image/WatercolorUI/resource_icons.json",
            frame = "chest", width = 22, height = 22,
        })
    end
    refs.achievementToastText = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.teaching, "bold")
    refs.achievementToast:AddChild(refs.achievementToastText)
    refs.achievementToast:SetVisible(false)

    -- 捕鱼结果气泡（真机反馈 2026-10-05）：收网后在屏幕中上部弹出结果提示，
    -- 约 5 秒后自动消失；不接收点击（box-none），不遮挡按钮坞。
    refs.catchBubble = UI.Panel {
        id = "catchResultBubble",
        position = "absolute",
        top = 64,
        left = 0,
        width = "100%",
        justifyContent = "center",
        alignItems = "center",
        zIndex = 70,
        pointerEvents = "box-none",
    }
    local catchBubbleCard = UI.Panel(UiKit.cardProps("plain", {
        -- T2b（2026-10-06 真机复检）：宽度必须显式固定。此前卡片随内容收缩且
        -- alignItems=center 使空文本 label 测量宽度为 0；Label 对 multiline
        -- (whiteSpace=normal) 的 SetText 不重算宽度（urhox-libs Label.lua:1241
        -- 提前 return），Render 在 contentW≈0 时提前 return 只画背景——
        -- 即真机"黑胶囊无文字"的根因。
        width = 320,
        maxWidth = 340,
        gap = 4,
        alignItems = "center",
    }))
    themedPanels[#themedPanels + 1] = {
        widget = catchBubbleCard, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    -- T2（2026-10-06）：真机反馈气泡只见边框无文字，嫌疑"bold"字重在该运行环境
    -- 渲染为空；两个结果标签统一降为常规字重（信息无损，排除变量）。
    -- T2b：显式 width 让 multiline label 拿到真实排版宽度（见卡片注释的根因分析）。
    refs.catchBubbleText = makeLabel("", UiKit.fontSize.body, UiKit.ink.body, nil, { width = "100%", textAlign = "center" })
    catchBubbleCard:AddChild(refs.catchBubbleText)
    refs.catchBubble:AddChild(catchBubbleCard)
    refs.catchBubble:SetVisible(false)
    -- 插在信息层之后、抽屉/模态之前：root 末两个子节点必须是
    -- gameplayInventoryDrawer 与全屏 overlay（Circle1B3SceneUITests 契约）。
    -- 成就 toast 在 catchBubble 之前入树，同受该契约保护（§7.3 规则一）。
    root:AddChild(refs.achievementToast)
    root:AddChild(refs.catchBubble)
    root:AddChild(refs.drawerBackdrop)
    root:AddChild(refs.drawer)
    -- overlay 保持 root 最后一个子节点（fitHudToLeftSide 全屏豁免 + 测试契约）。
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

        if #items == 0 then addEmptyMessage(refs.inventoryRows, "背包是空的。先去捕点鱼，再返港出售。") end
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
                -- v2.1 批B 修复（真机 10-07 反馈）：物品行原为深绿底 {45,64,61}，
                -- 放在暖色羊皮纸卡内形成深色条 + 亮色字，与卡片风格割裂。
                -- 改为半透明墨色浅底（卡片纸纹透出），行内文字用墨棕。
                backgroundColor = { 92, 70, 46, 34 },
                borderRadius = 5,
            }
            -- 名称标签必须占满剩余宽度：row 布局下无宽度约束的 label 会被压缩为不可见。
            local fishTag, fishColor = fishDisplay(itemId, definition)
            inventoryRow:AddChild(makeLabel(string.format("%02d · %s%s", itemIndex, name,
                fishTag ~= "" and (" · " .. fishTag) or ""), 12,
                fishColor, nil, { flexGrow = 1, flexBasis = 0 }))
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
                saleRow:AddChild(makeLabel(string.format("%s · %s · 槽位 %d", name, fishTag, itemIndex), 12,
                    fishColor, nil, { flexGrow = 1, flexBasis = 0 }))
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
        if saleCount == 0 then addEmptyMessage(refs.portSales, "没有可出售的鱼。先去捕点鱼，再返港出售。") end
        if giftCount == 0 then addEmptyMessage(refs.elderGiftRows, "没有可给予或展示的物品。") end
    end

    -- 图鉴/成就页行构建（v2.0 §7.4）：开页或切 tab 时重建一次，不在每帧执行。
    local MARINE_NAMES = {
        ray = "鳐鱼", octopus = "章鱼", jellyfish = "水母", turtle = "海龟",
        shark = "鲨鱼", tuna = "金枪鱼", dolphin = "海豚", mackerel = "鲭鱼",
    }
    local function buildCompendiumRows(tab)
        if not refs.compList then return end
        destroyChildren(refs.compList)
        if tab == "marine" then
            for _, frame in ipairs({ "ray", "octopus", "jellyfish", "turtle", "shark", "tuna", "dolphin", "mackerel" }) do
                local row = UI.Panel { width = "100%", flexDirection = "row", alignItems = "center", gap = 8 }
                if type(UI.Sprite) == "function" then
                    row:AddChild(UI.Sprite {
                        src = "image/WatercolorUI/marine_life.json",
                        frame = frame, width = 26, height = 26,
                    })
                end
                local info = UI.Panel { width = "auto", flexDirection = "column", gap = 2 }
                info:AddChild(makeLabel(MARINE_NAMES[frame] or frame, UiKit.fontSize.body, UiKit.ink.body))
                info:AddChild(makeLabel("发现记录待接入（圈2 知识层）", UiKit.fontSize.teaching, UiKit.ink.dim))
                row:AddChild(info)
                refs.compList:AddChild(row)
            end
        else
            for _, def in ipairs(Achievements.Definitions()) do
                local isUnlocked = Achievements.IsUnlocked(def.id)
                local row = UI.Panel { width = "100%", flexDirection = "row", alignItems = "center", gap = 8 }
                if type(UI.Sprite) == "function" then
                    row:AddChild(UI.Sprite {
                        src = "image/WatercolorUI/button_states.json",
                        frame = isUnlocked and "circle_gold" or "circle_gray",
                        width = 26, height = 26,
                    })
                end
                local info = UI.Panel { width = "auto", flexDirection = "column", gap = 2 }
                info:AddChild(makeLabel(
                    def.name .. (isUnlocked and " · 已解锁" or ""),
                    UiKit.fontSize.body,
                    isUnlocked and UiKit.ink.teaching or UiKit.ink.body))
                info:AddChild(makeLabel(def.desc, UiKit.fontSize.teaching, UiKit.ink.dim))
                row:AddChild(info)
                refs.compList:AddChild(row)
            end
        end
    end

    refresh = function()
        if state.destroyed then return end
        local player = loop.player or {}
        local clockState = loop.clock and loop.clock:GetState() or {}
        local phase = clockState.phase == "night" and "夜晚" or "白天"
        -- 阶段变化时设置目标色；卡片/抽屉由引擎backgroundColor过渡连续插值。
        applyTheme(clockState.phase == "night" and "night" or "day", themedPanels)
        local remaining = tonumber(clockState.remaining) or 0

        local inPort = loop.inPort == true
        local items = copyItems(loop)
        local capacity = player.inventory and player.inventory:GetCapacity() or 0

        -- 批2 水彩图标条：显隐随 StoryArt 开关（SeaDebug 面板可切），数值与状态行同源；
        -- setText 走 lastTexts 去重，静态时零开销。
        if refs.watercolorStrip then
            local stripVisible = ArtVariants.IsEnabled()
            if refs.watercolorStrip:IsVisible() ~= stripVisible then
                refs.watercolorStrip:SetVisible(stripVisible)
            end
            if stripVisible then
                setText(refs.watercolorValues.wcStamina, "wcStamina",
                    tostring(player.stamina or 0) .. "/" .. tostring(player.maxStamina or 0))
                setText(refs.watercolorValues.wcMoney, "wcMoney", tostring(player.money or 0))
                setText(refs.watercolorValues.wcBag, "wcBag", #items .. "/" .. tostring(capacity))
            end
        end

        -- 第一行（状态）：天 / 昼夜倒计时 / 体力 / 钱 / 背包 / 模式；暂停态也属于状态，
        -- 直接拼在状态行尾（暂停：port 等），日志行让给事件类信息。
        -- （"模式："并入状态行是 B 侧 Circle1HUDReviewTests 契约：模式跟随真实状态。）
        local reasons = clockState.pauseReasons or {}
        local statusText = string.format(
            "第 %s 天 · %s 剩余 %.0f 秒 · 体力：%s/%s · 钱：%s · 背包 %d / %d 格",
            tostring(player.day or 1), phase, math.max(0, remaining),
            tostring(player.stamina or 0), tostring(player.maxStamina or 0),
            tostring(player.money or 0), #items, capacity)
        if clockState.paused == true or #reasons > 0 then
            statusText = statusText .. " · 暂停："
                .. (#reasons > 0 and table.concat(reasons, "、") or "暂停中")
        end
        -- setText 延后到模式段拼接完成后一次性写入（保持 lastTexts 去重语义）。

        -- 第二行（日志槽）：同一时刻只显示一条——
        -- 存档失败 > 本地即时反馈 > 已自动保存 > lastMessage 提示 > 存档进行中 > 港口提示 > 默认引导。
        -- （本地即时反馈（本次点击的结果）必须高于"已自动保存"：B 侧 SevenDays 契约
        --   要求点击被拒时立即看到解释；而持久 lastMessage 低于 saved，
        --   GameLoopUISpec 契约要求保存完成后"已自动保存"可见。）
        local localMessage = state.localMessage ~= "" and state.localMessage or nil
        local lastMessageText = userMessage(loop.lastMessage)
        local lastMessageEvent = (lastMessageText ~= "" and lastMessageText ~= "出海采集，返港交易与结算。")
            and lastMessageText or nil
        local saveStatus = loop.saveStatus
        local portAccess, portReason, portDetails = loop:CanAccessPort()
        local portDistance = portDetails and portDetails.distance
        local portRadius = portDetails and portDetails.radius or 10
        local portHintActive = (type(portDistance) == "number" and (not portAccess or portDistance <= 30))
            or (type(portDistance) ~= "number" and not portAccess)
        -- 港口提示文本每帧刷新（读数契约：包含实时距离与范围内/外结论）；
        -- 是否占用日志行由 logSlot 决定。
        local portInfo
        if type(portDistance) == "number" then
            local accessText = portAccess and "范围内，可返港/交易" or "范围外，需≤10米才可返港/交易"
            portInfo = string.format("锚形标记=港口（交易中心）· 距港 %.3f/%.0f米（%s）；同日往返不恢复体力、不补充库存。",
                portDistance, portRadius, accessText)
        else
            portInfo = "锚形标记=港口（交易中心）· 距离暂不可读；返港/交易需距港≤10米。"
            if not portAccess and portReason then portInfo = portInfo .. " " .. userMessage(portReason) end
        end
        setText(refs.portAccessReason, "portInfo", portInfo)
        local logSlot = "log"
        local logText
        if saveStatus == "error" then
            logText = saveText(loop)
        elseif localMessage then
            logText = localMessage
        elseif saveStatus == "saved" then
            logText = saveText(loop)
        elseif lastMessageEvent then
            logText = lastMessageEvent
        elseif loop.loading == true or saveStatus == "loading" or saveStatus == "saving" then
            logText = saveText(loop)
        elseif portHintActive then
            logSlot = "port"
        else
            logText = "出海采集，返港交易与结算。"
        end
        refs.log:SetVisible(logSlot ~= "port")
        refs.portAccessReason:SetVisible(logSlot == "port")
        if logSlot ~= "port" then setText(refs.log, "log", logText or "") end

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

        -- 成就桩判定（§7.4，D6=A）：判定条件待 B 侧定稿，当前仅首日透镜试水。
        Achievements.Evaluate({ day = tonumber(player.day) or 1, hasLens = hasLens })
        -- 成就 toast 驱动：3 秒展示后淡出；同屏只一条（§7.3 规则二）。
        local now = os.clock()
        if state.achievementToastUntil and now >= state.achievementToastUntil then
            refs.achievementToast:SetVisible(false)
            state.achievementToastUntil = nil
        end
        if not state.achievementToastUntil then
            local toast = Achievements.PollToast()
            if toast then
                refs.achievementToastText:SetText("成就解锁：" .. toast.name)
                refs.achievementToast:SetVisible(true)
                state.achievementToastUntil = now + 3
            end
        end

        ---@type HUDStoryDialog|nil
        local storyDialog
        if type(loop.GetStoryDialog) == "function" then
            local ok, value = pcall(loop.GetStoryDialog, loop)
            if ok and type(value) == "table"
                and (value.kind == "paper" or value.kind == "elder")
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
        local fishingStatus
        if fishingSelecting then
            fishingStatus = "点击或触摸30米内合法海面，立即抛网；可取消选点。"
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
        -- 真机反馈 2026-10-07：%.1f 秒使文本每帧变化 → SetText 每帧触发 UI 重排，
        -- 收网期间成为卡顿源。改整数秒后文本变化率 ~10Hz→1Hz。
        setText(refs.fishingProgress, "fishingProgress",
            string.format("动作进度：%d%% · %d / %d 秒", progress,
                math.floor(math.min(actionElapsed, actionDuration) + 0.5), math.floor(actionDuration + 0.5)))
        local resultText = ""
        if fishingTerminal then
            if fishingPhase == "complete" then
                -- T2（2026-10-06 真机反馈）：文案按结算结果生成，不再依赖滞后的
                -- lastMessage（旧逻辑在成功时也只显示"收网完成。"且常带过期消息）。
                local outcome = fishingState and fishingState.outcome
                local caughtItemId = fishingState and fishingState.itemId
                if (outcome == "caught" or outcome == "pending_catch") and caughtItemId then
                    local definition = Items.GetDefinition(caughtItemId)
                    local fishName = definition and definition.name or "鱼获"
                    if outcome == "pending_catch" then
                        resultText = "本次捞到 1 条" .. fishName .. "；船舱已满，请整理背包接收鱼获。"
                    else
                        local sellPrice = definition and definition.sellPrice
                        resultText = "本次捞到 1 条" .. fishName
                            .. (sellPrice and sellPrice > 0 and string.format("，返港可卖 %d 币", sellPrice) or "")
                    end
                elseif outcome == "empty" then
                    resultText = "没有捞到。试试停船投饵，等鱼群聚过来再下网。"
                else
                    local detail = loop.lastMessage
                    resultText = "收网完成。" .. (detail and detail ~= "" and (" " .. userMessage(detail)) or "")
                end
            elseif fishingPhase == "cancelled" then
                resultText = "已取消，未消耗体力。"
            else
                local reason = fishingState and fishingState.reason or loop.lastMessage
                resultText = "未完成：" .. (reason ~= nil and userMessage(reason) or "请稍后重试")
            end
        end
        refs.fishingResult:SetVisible(fishingTerminal)
        setText(refs.fishingResult, "fishingResult", resultText)

        -- 收网结果气泡：进入终态时记录文本并展示约 5 秒；离开终态后允许下次收网重弹。
        -- （os.time 缺失的运行时静默禁用气泡，结果仍见捕鱼小卡的结果行。）
        local nowStamp = os and type(os.time) == "function" and os.time() or nil
        if nowStamp then
            if fishingTerminal and resultText ~= "" then
                local bubbleKey = fishingPhase .. "|" .. resultText
                if state.bubbleKey ~= bubbleKey then
                    state.bubbleKey = bubbleKey
                    state.bubbleText = resultText
                    state.bubbleUntil = nowStamp + 5
                end
            elseif not fishingTerminal and state.bubbleKey ~= nil then
                state.bubbleKey = nil
            end
            local bubbleVisible = state.bubbleUntil ~= nil and nowStamp < state.bubbleUntil
            refs.catchBubble:SetVisible(bubbleVisible)
            if bubbleVisible then
                setText(refs.catchBubbleText, "catchBubbleText", state.bubbleText or "")
            end
        end

        -- v2.0 零遮挡：捕鱼面板只在捕鱼过程（选择/收网/清理/结算）中出现；
        -- 待机状态的出海画面只保留左上信息文字与右下按钮坞。
        refs.fishingPanel:SetVisible(fishingRestricted or fishingTerminal)
        -- A2（2026-10-05 用户裁决）：动作中再点捕鱼键=取消——按钮坞"捕鱼"在选点/收网期间
        -- 保持可见可点（点击经 Loop:BeginFishingSelection 转为取消）；清理/结算 pending 态
        -- 仍由捕鱼小卡内的"取消捕鱼/重试清理"按钮承担。
        local fishingCancellable = fishingSelecting or fishingPhase == "casting" or fishingPhase == "landed"
        refs.beginFishing:SetVisible(not inPort and (not fishingRestricted or fishingCancellable))
        refs.beginFishing:SetDisabled((not ready and not fishingCancellable) or busy or inPort
            or loop.inventoryOpen == true or loop.elderOpen == true)
        -- 新手教程点位：靠近出港点右侧木桶（≤操作距离+3m 余量）时出现 检查木桶/望远镜；
        -- 望远镜获得后常驻（设定集：窥视镜=看海面下）。
        local barrelNearForDock, barrelDistanceForDock = false, nil
        if type(loop.GetBarrelAccess) == "function" then
            local okBarrel, nearBarrel, _barrelReason, barrelDetails = pcall(loop.GetBarrelAccess, loop)
            if okBarrel and type(barrelDetails) == "table" and type(barrelDetails.distance) == "number" then
                barrelDistanceForDock = barrelDetails.distance
                barrelNearForDock = nearBarrel == true
                    or barrelDetails.distance <= (barrelDetails.operateDistance or 5) + 3
            end
        end
        local barrelDockEngaged = bucketActiveForInput or (barrelState ~= nil and barrelState.active == true)
        refs.barrelToggle:SetVisible(not inPort and (barrelNearForDock or barrelDockEngaged))
        refs.barrelToggle:SetDisabled(busy or fishingRestricted
            or (not barrelNearForDock and not barrelDockEngaged))
        -- 望远镜单入口（真机反馈 2026-10-05 精简：信息屏内只留状态文字）：
        -- 海上常驻；无透镜时按 B 侧契约显示禁用的"透镜未获得"。
        refs.scopeToggleBar:SetVisible(not inPort)
        refs.scopeToggleBar:SetText(hasLens
            and (scopeEnabled and "关闭望远镜" or "开启望远镜") or "透镜未获得")
        -- A1（2026-10-05 用户裁决）：白名单制——捕鱼动作期间允许透镜开关
        -- （ToggleScope 不暂停世界、不触碰捕获锁定），只禁移动/背包/投放/打捞/交谈/进港。
        refs.scopeToggleBar:SetDisabled(busy
            or not hasLens or not scopeApiAvailable)
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
        -- 模式并入状态行（追加在暂停态之后）：跟随真实状态（B 侧 review 契约）。
        local modeSuffix = " · 模式：" .. modeText(loop, fishingPhase, pendingCatch, throwSelection)
            .. (scopeEnabled and " · 望远镜开启" or "")
        setText(refs.status, "status", statusText .. modeSuffix)

        -- 夜航警示行：条件显隐（夜+海上+未耗尽才出现），常日不占行。
        refs.nightRisk:SetVisible(clockState.phase == "night" and not inPort and not clockState.exhausted)
        local graceRemaining = math.max(0, Config.clock.graceSec - (clockState.elapsed or 0))
        setText(refs.nightRisk, "nightRisk", graceRemaining > 0
            and string.format("夜航：还剩 %.0f 秒安全返港；夜尽将强制返港。", graceRemaining)
            or string.format("晚归处罚中：现在返港次日体力 %.1f/%s；夜尽仅恢复上限的%.0f%%。",
                loop:GetNextDayStamina(false), tostring(player.maxStamina), Config.clock.forcedStaminaRatio * 100))
        setText(refs.treasureSummary, "treasureSummary", hasLens
            and "望远镜透镜 ×1 · 永久保留，不占船舱格，不能出售或丢弃。"
            or "尚未获得宝物；取得的宝物单独保留，不占船舱格。")
        -- 信息滚动屏开合（真机反馈 2026-10-05）：纯派生态，不写用户偏好——
        -- · 需要点击海面的流程（捕鱼选点/投放选点）强制收起（流程结束自动恢复）；
        -- · 用户未操作过（nil）时：在港默认展开（商店/读取可用），出海默认收起；
        -- · 用户显式开/关后跟随其选择。"信息"按钮或屏内空白点击均可开合。
        local seaClickFlow = fishingSelecting or throwSelection ~= nil
        -- v2.1 批B（真机图1 背包改占信息滚动屏）：背包/待领渔获展开时强制
        -- 打开信息屏——背包卡是 contentScroll 的子节点，父隐藏则子不可见。
        -- 单向同步（背包开 → 信息屏开；关背包不自动关信息屏，避免连带关掉
        -- 用户正在看的内容）。"信息"按钮显式关闭后，同一帧会被本条件再打开，
        -- 因此只在背包态为真时接管，收起背包后交还用户控制。
        local infoOpen = not seaClickFlow
            and (((state.infoOpen == nil and inPort) or state.infoOpen == true)
                or loop.inventoryOpen == true or pendingCatch)
        refs.contentScroll:SetVisible(infoOpen)
        refs.infoCloseCatcher:SetVisible(infoOpen)
        refs.infoToggle:SetText(infoOpen and "收起信息" or "信息")
        refs.infoToggle:SetDisabled(busy or loop.loading == true)

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
            or (not ready and not bucketActiveForInput and loop.elderOpen ~= true))
        local showInventory = loop.inventoryOpen == true or pendingCatch
        -- v2.1 批B（真机图1）：背包卡改挂信息滚动屏。显隐只跟随 showInventory
        -- 本身，不再强制 infoOpen —— 因为"待领渔获"路径可能由逻辑直接置
        -- inventoryOpen（不经背包按钮、没开信息屏），此时仍须能看到提示与
        -- "领取渔获"按钮（GameLoopUISpec 契约）。按钮路径会顺带打开信息屏。
        refs.inventoryPanel:SetVisible(showInventory)
        -- 抽屉壳（gameplayInventoryDrawer + 压暗层）保留但不再显示：
        -- 契约要求该节点存在于 root 倒数第二位，见 Circle1B3SceneUITests。
        refs.drawer:SetVisible(false)
        refs.drawerBackdrop:SetVisible(false)
        refs.inventoryClose:SetVisible(true)
        refs.inventoryClose:SetDisabled(busy or loop.loading == true)
        refs.portPanel:SetVisible(inPort)
        -- 港口提示已并入左上角日志槽（见 refresh 开头的 logSlot 逻辑），不再单独占行。
        -- loadSaved/newRun 已移入信息屏（portPanel 段），显隐随 infoOpen。
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
            local noMoney = player.money < definition.buyPrice
            local noSpace = not player.inventory:HasSpace()
            shopButton:SetDisabled(not inPort or not ready or busy or fishingRestricted
                or stock <= 0 or noMoney or noSpace)
            local reason = stock <= 0 and " · 今日售罄，次日补货" or noMoney and " · 金币不足"
                or noSpace and " · 船舱已满，先腾出一格" or ""
            refs.shopStockLabels[itemId]:SetText(definition.name .. "库存：" .. tostring(stock) .. reason)
        end
        local elderToggleText = loop.elderOpen == true and "结束对话"
            or (elderPresent and "拜访老人" or "老人不在")
        refs.elderToggle:SetText(elderToggleText)

        -- UI 精简 v1.1：木桶卡仅在检查过程中出现；入口走按钮坞"检查木桶"
        refs.barrelPanel:SetVisible(not inPort and barrelDockEngaged)
        local barrelGatesAvailable = barrelState ~= nil and barrelState.timingAvailable == true
            and barrelState.interfaceAvailable == true
        local barrelFinished = barrelState ~= nil and (tonumber(barrelState.stage) or 0) >= 3
        local barrelActive = bucketActiveForInput
        local barrelPending = barrelState ~= nil and barrelState.pending == true
        if not barrelGatesAvailable then
            setText(refs.barrelStatus, "barrelStatus", "木桶检查暂未开放。")
            refs.barrelCancel:SetVisible(false)
        elseif barrelPending then
            setText(refs.barrelStatus, "barrelStatus", "木桶补给等待领取，请先处理待领取奖励。")
            refs.barrelCancel:SetVisible(false)
        elseif barrelFinished then
            setText(refs.barrelStatus, "barrelStatus", "木桶调查已完成。")
            refs.barrelCancel:SetVisible(false)
        elseif barrelActive then
            local seconds = math.max(0, tonumber(barrelState.remaining) or 0)
            setText(refs.barrelStatus, "barrelStatus", string.format(
                "木桶检查进行中，剩余 %.1f 秒；打开背包或对话会暂停计时，可以取消。", seconds))
            refs.barrelCancel:SetVisible(true)
            refs.barrelCancel:SetDisabled(false)
        else
            setText(refs.barrelStatus, "barrelStatus", "发现海岸边的木桶；靠近后点按钮坞「检查木桶」。")
            refs.barrelCancel:SetVisible(false)
        end

        -- 望远镜状态行（信息屏内）只读；开关统一走按钮坞"望远镜"。
        if not hasLens then
            setText(refs.scopeStatus, "scopeStatus", "尚未获得透镜；无法查看或切换望远镜功能。")
        elseif not scopeApiAvailable or loop.scopeSyncError == "scope_interface_unavailable" then
            setText(refs.scopeStatus, "scopeStatus", "望远镜功能接口暂不可用。")
        elseif loop.scopeSyncError then
            setText(refs.scopeStatus, "scopeStatus", "望远镜状态同步失败，请重试关闭。")
        else
            setText(refs.scopeStatus, "scopeStatus", scopeEnabled and "望远镜设置：开启。" or "望远镜设置：关闭。")
        end

        -- 注：scopePanel（望远镜条目）保留常驻——测试契约要求无透镜时显示
        -- "透镜未获得"禁用按钮；v2.0 已将其压成一行透明文字+按钮。

        refs.throwSelectionPanel:SetVisible(throwSelection ~= nil)
        if throwSelection then
            setText(refs.throwSelectionText, "throwSelectionText",
                "已选择" .. itemName(throwSelection.itemId) .. "，请点击 12 米内海面投掷；也可以取消。")
            refs.throwSelectionCancel:SetDisabled(false)
        end

        -- items/capacity 已在 refresh 开头计算（状态行复用），此处直接使用。
        setText(refs.inventoryCount, "inventoryCount", string.format("%d / %d 格", #items, capacity))
        -- F2: 全部卖出——在港且背包有可售渔获时启用。
        local sellableCount = 0
        for _, itemId in ipairs(items) do
            local definition = Items.GetDefinition(itemId)
            if definition and definition.category == "fish"
                and definition.sellPrice and definition.sellPrice > 0 then
                sellableCount = sellableCount + 1
            end
        end
        refs.sellAll:SetText(sellableCount > 0 and ("全部卖出 · " .. tostring(sellableCount) .. " 件") or "全部卖出")
        refs.sellAll:SetDisabled(not inPort or not ready or busy or fishingRestricted or sellableCount == 0)
        -- 背包抽屉内的空舱/在途提示（B 侧 review 契约）；位于抽屉内部，不占左上角两行。
        refs.inventoryHint:SetVisible(sellableCount == 0 or not inPort)
        setText(refs.inventoryHint, "inventoryHint", sellableCount == 0
            and "先去捕点鱼：出航后观察海鸟和水花，停船投饵，再点击捕鱼选择海面。"
            or "鱼获已装舱；航行到港口10米内并返港后，可以出售。")
        -- 背包摘要已并入左上角状态行（refs.status），不再单独维护。
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
        refs.itemGive:SetDisabled(busy or fishingRestricted)
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
        -- T1：结局模态在结算保存流程结束后显示（settlementPending 清除后）。
        local showEnding = not showEntry and not pendingCatch and not showForced and not showSettlement
            and loop.endingPending == true
        local showStory = not showEntry and not pendingCatch and not showForced and not showSettlement
            and not showEnding and storyDialog ~= nil
        local showElder = not showForced and not showSettlement and not showEnding
            and loop.elderOpen == true and elderPresent
        -- 开场教学（演出层，见 OPENING_ELDER_TEXT）：模态独占，优先级低于存档/结算弹窗。
        local showOpening = player.day == 1 and inPort == true
            and state.openingDismissedGeneration ~= loop.generation
            and not showEntry and not pendingCatch and not showForced and not showSettlement
            and not showEnding and not showStory and not showElder and loop.inventoryOpen ~= true
        state.openingActive = showOpening
        if showOpening then state.openingGeneration = loop.generation end
        -- 图鉴/成就页（§7.4）：暂停态才可开；任何玩法模态优先；未暂停自动收起。
        local worldPaused = clockState.paused == true or #reasons > 0
        local showCompendium = state.compendiumOpen == true and worldPaused
            and not showEntry and not pendingCatch and not showForced and not showSettlement
            and not showEnding and not showStory and not showElder and not showOpening
        if state.compendiumOpen == true and not showCompendium then
            state.compendiumOpen = false
        end
        local overlayShown = showEntry or showForced or showSettlement or showStory or showElder
            or showEnding or showOpening or showCompendium
        refs.overlay:SetVisible(overlayShown)
        fadeOpacity(refs.modalCard, overlayShown and 1 or 0)
        local storyTitle = storyDialog and storyDialog.kind == "elder" and "海岸边的老人" or "纸条"
        local overlayTitle = showEntry and "云存档" or showForced and "夜晚返港"
            or (showSettlement and "每日结算" or (showOpening and "海岸边的老人")
            or (showEnding and "第 7 天 · 结局" or (showStory and storyTitle
            or (showElder and "拜访老人" or (showCompendium and "图鉴 · 成就" or "")))))
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
        refs.endingBody:SetVisible(showEnding)
        refs.storyBody:SetVisible(showStory or showOpening)
        refs.elderBody:SetVisible(showElder)
        refs.compendiumBody:SetVisible(showCompendium)
        -- 图鉴入口只在暂停态出现（避免海上误触打断操作）；页打开后入口隐藏。
        refs.compendiumToggle:SetVisible(worldPaused and not overlayShown and not pendingCatch)
        if showCompendium then
            local activeTab = state.compendiumTab or "achievements"
            refs.compTabAchievements:SetText(activeTab == "achievements" and "成就 ●" or "成就")
            refs.compTabMarine:SetText(activeTab == "marine" and "图鉴 ●" or "图鉴")
            if state.compendiumBuiltTab ~= activeTab or state.compendiumRowsDirty == true then
                buildCompendiumRows(activeTab)
                state.compendiumBuiltTab = activeTab
                state.compendiumRowsDirty = false
            end
        end

        if showEnding then
            -- [PLACEHOLDER] 结局占位文案；正式版按 Q-006 由 B 侧内容生产替换。
            local endingCopy = loop.endingKind == "changed"
                and "老人活了下来。你们约好，明天继续出海。"
                or "七天过去，风平浪静，无事发生。日子还得继续。"
            setText(refs.endingText, "endingText", endingCopy)
            refs.endingNewRun:SetDisabled(busy)
        end

        if showSettlement then
            local confirmed = loop.settlementApplied == true
            local text = loop.dayPreparationError and "本次保存选择已记录，但新日海洋准备失败；请重试准备，不会重复加天或保存。"
                or confirmed and (busy and "今日已结算，正在自动保存…不等待可继续下一天，但已发出的请求仍可能稍后写入。"
                or "保存失败，可重试或放弃本次保存进入下一天。退出后当天未保存进度可能丢失，已发出的请求仍可能稍后写入。")
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
            -- S6 教学区：Day1~3 且教学未完成（首次领取捕鱼收获）时展示，完成后收起。
            local teachingDone = type(loop.IsTeachingDone) == "function" and loop:IsTeachingDone()
            local day = tonumber(player.day) or 1
            local showTeaching = showElder and teachingDone ~= true and day <= 3
            refs.elderTeaching:SetVisible(showTeaching)
            if showTeaching then
                setText(refs.elderTeaching, "elderTeaching",
                    DialogueStyle.teachingText(
                        "「鸟在那边盘旋，附近应该有小鱼，投点饵试试。」\n"
                        .. "「留意水花留下的方向，那是大鱼经过的痕迹。」\n"
                        .. "船开动会惊散鱼群，停船再投；饵不保证成功，多试几次。"))
            end
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
        if showOpening then
            setText(refs.storyText, "storyText", OPENING_ELDER_TEXT)
        elseif showStory and storyDialog then
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
