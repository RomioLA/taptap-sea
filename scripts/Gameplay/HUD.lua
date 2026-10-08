-- B 玩法 HUD 原型。UI 生命周期由宿主负责，本模块只创建和管理自己的子树。
local UI = require("urhox-libs/UI")
local Config = require("config.gameplay")
local Items = require("data.items")
local Diagnostics = require("Gameplay.Diagnostics")
local ArtVariants = require("Ocean.ArtVariants")
local DialogueStyle = require("Gameplay.DialogueStyle")
local UiKit = require("Gameplay.UiKit")
local Achievements = require("Gameplay.Achievements")
local SoundSystem = require("Systems.SoundSystem")

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
    -- 需求 UI：所有按钮点击播放 ui_click（统一在此注入，玩法脚本无需各自写）。
    -- 播放逻辑全部收敛在 SoundSystem，本处只触发一次语义调用。
    local handler = onClick or function() end
    return plainMakeButton(text, function()
        SoundSystem.Click()
        handler()
    end, variant, width, DialogueStyle.buttonProps(variant))
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
        -- v2.3.1 总开合：infoCollapsed=true 表示用户点了「信息」显式收起左侧
        -- 整块（cardHost 三卡 + 滚动屏）；任何打开动作会清除该意图。
        infoCollapsed = false,
        inventorySignature = "",
        -- v2.1 §7.14 对话式形态：老人对话记录（气泡序列）。
        -- transcript 每项 {who="elder"|"player", text=..., teach=bool}。
        -- v2.3 选项区二级化：menuLevel="root"|"questions"|"give"|"show"；
        -- reviewOpen=聊天记录回看态；optionsExpanded=回看态下选项区展开。
        elderTranscript = {},
        elderMenuLevel = "root",
        elderReviewOpen = false,
        elderOptionsExpanded = false,
        elderWasOpen = false,
        elderQuestionsBuiltKey = nil,
        elderAsked = {},
        elderOpenedGeneration = nil,
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
    -- v2.1 §7.12（用户 23:34「拜访老人显示不全 / 港口商店高度和背包同高」）：
    -- 滚动屏三卡（背包/商店/老人）统一高度上限。之前老人卡无 maxHeight →
    -- 内容约 576px 超出屏幕底边（"结束对话"被裁）；商店 58% 过紧 → 只显示到
    -- "升级体力"。现统一 68% 屏高，礼物区改 flexGrow 自适应让位。
    -- 必须定义在所有 card() 调用之前，故放在 card() 工厂处。
    -- v2.1 §7.12 曾用统一 68% 屏高限制三卡高度。v2.2 起该令牌作废：
    -- cardHost 改用 top/bottom 四边锚定后，卡片高度由宿主决定，
    -- 卡内再由 sectionCard 的「主体 flexGrow + 操作条 flexShrink=0」
    -- 自行分配空间，不再需要百分比高度上限。
    -- 保留定义仅为兼容历史注释引用，实际不再被任何卡片使用。
    local HUD_CARD_MAXH = "68%"

    -- v2.1 §7.14 对话式形态：老人问答链（方案 v2.0 §4）。
    -- 按阶段解锁：stage1=第1~3天教程期 / stage2=第4~6天 / stage3=第7天。
    -- teach=true 的问题前加 ※ 标记（复用 UiKit.teachMark），仅教程期出现。
    -- answer 为老人答复；hint 为选项区右侧动作标签。
    local ELDER_QUESTIONS = {
        { id = "survival", stage = 1, teach = true, text = "这海上讨生活，要紧的是什么？",
          answer = "先看水鸟，再看水花。船停在浪平的地方，别急着下网。" },
        { id = "lens", stage = 1, teach = true, text = "透镜该怎么用？",
          answer = "对着海面看，能望见远处的东西。海上认路，全靠它。" },
        { id = "bait", stage = 1, teach = true, text = "鱼饵要放在哪？",
          answer = "船尾水面，抛得远些。饵不保证成功，多试几次。" },
        { id = "sea", stage = 2, text = "这片海有什么要紧的地方？",
          answer = "暗流多的地方船要绕开，浅礁会咬住船底。记熟了就是你的路。" },
        { id = "why", stage = 2, text = "你怎么会在这儿？",
          answer = "船散了，人还在。海不记人过，只记得谁回来了。" },
        { id = "need", stage = 2, text = "需要我做什么吗？",
          answer = "你肯把东西分我一口，我这把老骨头就还撑得住。苹果最实在。" },
        { id = "how", stage = 3, text = "我该怎么做？",
          answer = "天亮出海，天黑回港。日子是熬出来的，不是撞出来的。" },
        { id = "thanks", stage = 3, text = "谢谢你。",
          answer = "去吧。风大的时候，记得回来。" },
    }

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

    -- v2.2 结构化卡工厂 sectionCard()：三段式骨架，把"选项不被遮挡"变成
    -- 结构保证而不是靠调 maxHeight 碰运气。
    --
    -- 骨架（自上而下）：
    --   ① header  标题 + 摘要文字（flexShrink=0，永不参与压缩）
    --   ② body    flexGrow=1 的 ScrollView（唯一允许滚动的区）
    --   ③ footer  flexShrink=0 的固定操作条（不滚动、不压缩、不被遮挡）
    --
    -- 为什么必须拆出 footer：v2.1 三卡都是"一列到底 + maxHeight 68%"，
    -- 底部按钮（结束对话 / 全部卖出 / 读取存档）与主体内容抢同一列空间，
    -- 内容一多就把按钮推出屏幕（真机 21:46 / 23:34 两次反馈的同一根因）。
    -- 拆开后主体再长也只在自己那格内滚，操作条恒在卡内底部可见可点。
    --
    -- 契约：
    -- · footer 与 body 是 card() 的**直属子节点**（中间不套 ScrollView），
    --   保持 isVisible 沿父链判定语义（§7.9 教训）。
    -- · 滚动只发生在 body 内部的 ScrollView 里；对话流等"不能包 ScrollView"
    --   的子树仍放在 body 的普通 Panel 中（见拜访老人卡）。
    local function sectionCard(title, opts)
        opts = opts or {}
        local panel = UI.Panel(UiKit.cardProps(opts.skin or "panel", {
            flexGrow = 1,
            flexBasis = 0,
            gap = 6,
        }))
        themedPanels[#themedPanels + 1] = {
            widget = panel, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
        }

        -- ① 头部：标题行 + 可选摘要行
        panel:AddChild(makeLabel(title, UiKit.fontSize.title, UiKit.ink.title, "bold"))
        local header = UI.Panel {
            width = "100%",
            gap = 2,
            flexShrink = 0,
            flexDirection = "column",
        }
        if opts.summary then
            header:AddChild(makeLabel(opts.summary, UiKit.fontSize.teaching, UiKit.ink.dim))
        end
        if #header.children > 0 then panel:AddChild(header) end

        -- ② 主体：唯一可滚动区
        local body = UI.Panel {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
            minHeight = 0,
            gap = 6,
            flexDirection = "column",
        }
        local scroll = UI.ScrollView {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
            minHeight = 0,
            scrollY = true,
            showScrollbar = true,
            children = { body },
        }
        panel:AddChild(scroll)

        -- ③ 固定操作条：flexShrink=0 保证任何内容压力下都不被压缩
        local footer = UI.Panel {
            width = "100%",
            gap = 5,
            flexShrink = 0,
            flexDirection = "row",
            flexWrap = "wrap",
            alignItems = "center",
        }
        if opts.footer ~= false then panel:AddChild(footer) end

        return panel, body, footer
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
    -- v2.1 §7.15（用户 13:03「仅留顶部一行状态栏」）：header 由 4~5 行纵向堆叠
    -- 收敛为**单行左右分栏**——
    --   左：第几天 / 昼夜 / 剩余时间 / 暂停态 / 距港距离（日志与夜航警示折叠进其尾）
    --   右：体力 + 钱 + 背包格
    -- 定位为**测试期状态查看**（发布时整块删除），故：
    --   · 不参与布局（absolute + pointerEvents=box-none），不挤占任何 UI 位
    --   · 任何卡片/按钮坞都可覆盖它，不影响操作
local header = UI.Panel {
        id = "gameplayStatusBar",
        -- v2.1 §7.15（用户 13:03）：测试期单行状态浮层——absolute 不占布局、
        -- pointerEvents=box-none 不抢点击、任何卡片都可覆盖，发布时整块删除。
        -- 左右分栏：左=天数/昼夜/时间/暂停/距港，右=体力/钱/背包格。
        position = "absolute",
        left = 0,
        top = 0,
        width = "100%",
        maxWidth = "100%",
        height = 30,
        padding = { 4, 10, 2, 10 },
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "space-between",
        gap = 12,
        pointerEvents = "box-none",
        zIndex = 40,
    }
    refs.status = makeInfoLabel("", 12, nil, nil, INFO_FLEX)
    refs.statusRight = makeInfoLabel("", 12, nil, nil, nil)
    header:AddChild(infoLine(refs.status))
    header:AddChild(infoLine(refs.statusRight))
    -- 日志槽：暂停/反馈/存档/港口提示折叠到状态行尾部（不再单独占行）。
    refs.log = makeInfoLabel("", 12, UI_PALETTE.seaTextMuted, nil, INFO_FLEX)
    -- 夜航警示行：条件显隐（夜+海上+未耗尽才出现），折叠进状态行尾。
    refs.nightRisk = makeInfoLabel("", 12, UI_PALETTE.seaTextGold, nil, INFO_FLEX)
    refs.nightRisk:SetVisible(false)
    refs.portAccessReason = makeInfoLabel("锚形标记=港口（交易中心）· 返港/交易需距港≤10米。", 12, UI_PALETTE.seaTextMuted, nil, INFO_FLEX)
    refs.portAccessReason:SetVisible(false)
    -- v2.1 §7.15：三控件（日志槽/夜航警示/港口说明）不再单独占行，但必须
    -- **直接挂在 header 上**——曾试过包一层零高隐藏容器，结果它们的子树
    -- 被判为不可见，Circle1HUDReviewTests 的 visibleOnly 查找全部落空
    -- （12 红的真凶）。视觉上它们默认 SetVisible(false)，不占位。
    header:AddChild(refs.log)
    header:AddChild(refs.nightRisk)
    header:AddChild(refs.portAccessReason)
    refs.debugToggle = makeButton("开发调试", function()
        if refs.debugPanel then
            local willShow = not refs.debugPanel:IsVisible()
            refs.debugPanel:SetVisible(willShow)
            -- 打开面板时读取音频诊断状态（2026-10-08 真机静音排查通道）
            if willShow and refs.audioStatus then
                local okSt, st = pcall(SoundSystem.Status)
                refs.audioStatus:SetText("音频：" .. (okSt and tostring(st) or "状态读取失败"))
            end
        end
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

    -- 真机反馈（2026-10-08）：左上角捕鱼小卡整卡移除——
    -- ① 残留根因：Actions:GetFishingState 终态后持续返回 _lastFishing 记录，
    --   HUD 以 fishingRestricted/fishingTerminal 控显 → 小卡终态后"残留"为塌陷
    --   窄条（真机截图 10-08），且作为 root 列流子节点持续挤占 infoLayer 布局
    --   空间，压垮 cardHost 内背包/商店/老人卡；
    -- ② 收网状态/进度文字对玩法无增量（世界画面已表达），取消（A2）与重试清理
    --   统一收敛到按钮坞"捕鱼"键（Loop:BeginFishingSelection 单一入口），结果
    --   提示由中央结果气泡（catchBubble）承担。
    refs.beginFishing = makeButton("捕鱼", function()
        invokeLoop("BeginFishingSelection")
    end, "primary", 72)

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
            SoundSystem.OpenMenu()  -- 需求 UI：菜单打开播放 ui_open
            -- 打开信息屏并滚到背包卡（信息屏默认入口是图鉴/透镜状态）；
            -- v2.3.1：打开动作清除"总收起"意图，否则卡片看不到
            state.infoOpen = true
            state.infoCollapsed = false
            state.focusInventory = true
        end
    end, "secondary", 128)
    refs.elderToggle = makeButton("拜访老人", function()
        local willOpen = not (loop.elderOpen == true)
        -- v2.3.1：打开对话是明确的卡片诉求，清除"总收起"意图
        if willOpen then
            state.infoCollapsed = false
            SoundSystem.OpenMenu()  -- 需求 UI：菜单打开播放 ui_open
        end
        invokeLoop("SetElderOpen", willOpen)  -- 老人环境声床启停由 Loop:SetElderOpen 单一驱动
    end, "secondary", 112)
    -- 与捕鱼同级的上下文按钮：靠近出港点右侧木桶（新手教程点位）后出现；
    -- 望远镜（窥视镜）在获得后常驻、未获得时靠近木桶作为线索入口。
    refs.barrelToggle = makeButton("检查木桶", function()
        invokeLoop("BeginBarrelInspection")
    end, "secondary", 96)
    refs.barrelToggle:SetVisible(false)
    -- v2.1 §7.9（真机 21:10"镇模未获得"被截断）：文案会变
    -- "透镜未获得"/"关闭望远镜"（5~6 字），固定 80px 装不下 → 放宽到 104。
    refs.scopeToggleBar = makeButton("望远镜", function()
        invokeLoop(loop.scopeSyncError and "DisableScope" or "ToggleScope")
    end, "secondary", 104)
    refs.scopeToggleBar:SetVisible(false)
    -- 信息/卡片总开合按钮（真机反馈 2026-10-05：屏幕只能打开不能收起）：
    -- v2.3.1（真机反馈"收起信息按钮无效"）语义升级为**左侧整块总开合**——
    -- 三卡已迁 cardHost，"信息"点击即收起/恢复 cardHost（商店/背包/老人）
    -- 与信息滚动屏。infoCollapsed 记录显式收起意图（见 refresh 推导处）。
    refs.infoToggle = makeButton("信息", function()
        if state.infoCollapsed == true then
            state.infoCollapsed = false
            state.infoOpen = true
            SoundSystem.OpenMenu()  -- 需求 UI：菜单打开播放 ui_open
        else
            state.infoCollapsed = true
            state.infoOpen = false
        end
        refresh()
    end, "secondary", 92)
    -- 图鉴/成就入口（v2.0 §7.4）：仅暂停态可见（refresh 控制），页壳走模态层。
    refs.compendiumToggle = makeButton("图鉴", function()
        local willOpen = not (state.compendiumOpen == true)
        state.compendiumOpen = willOpen
        state.compendiumRowsDirty = true
        if willOpen then SoundSystem.OpenMenu() end  -- 需求 UI：菜单打开播放 ui_open
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
        -- 契约（ABIntegrationTests:1011 / Circle1B3SceneUITests:261）：
        -- 信息滚动屏必须 box-none——空白海面点击要穿透到捕鱼/投掷选点，
        -- 不能被滚动容器吞掉。§7.15 重排时丢失，此处补回。
        pointerEvents = "box-none",
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
    -- v2.2（三卡信息完整化重构）：
    -- 宿主改为**全宽 + bottom 锚定**。v2.1 的 52% 半屏 + top:34 + height:72%
    -- 有三个结构性问题：
    -- ① 半屏宽度下商店/背包的分区标签与数值折行，"信息完整呈现"无法成立；
    -- ② 只有 top + height 百分比，没有 bottom 锚点 —— 屏幕高度变化时卡片
    --    下沿会漂移，底部按钮坞（absolute bottom 0）会被压盖或留缝；
    -- ③ 卡片内部只能靠 maxHeight 百分比自管高度，与按钮坞落区无关联。
    -- 改为 left/right/top/bottom 四边锚定后，卡片下沿恒定停在按钮坞上方
    -- 92px 处（按钮坞 padding 8 + 单行按钮 44 + 双行换行余量），任何屏幕上
    -- 都保证"卡片不压坞、坞不被遮"。
    --
    -- 契约约束（保持不变）：
    -- · 宿主内部不用 ScrollView（§7.9 教训，会让 isVisible 沿父链判定失效）；
    -- · 三卡互斥，同一时刻只显示一张（§7.13），显隐不影响兄弟节点位置；
    -- · pointerEvents=box-none，宿主空白区点击穿透到海面。
    local CARD_HOST_TOP = 40        -- 让开顶部单行状态栏（height 30 + 间距）
    local CARD_HOST_BOTTOM = 92     -- 让开底部按钮坞（padding 8 + 按钮 44 + 余量）
    local cardHost = UI.Panel {
        id = "gameplayCardHost",
        position = "absolute",
        left = 0,
        right = 0,
        top = CARD_HOST_TOP,
        bottom = CARD_HOST_BOTTOM,
        gap = 8,
        padding = 10,
        flexDirection = "column",
        pointerEvents = "box-none",
    }

    -- ⚠️ 保持流式容器（flexGrow/flexBasis）——试过改absolute 后，测试桩对
    -- absolute 容器的子节点可见性判定与流式不同，导致 contentScroll/三卡
    -- 整棵子树被判hidden（12 红的真正元凶）。此处不动。
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
        -- 真机 2026-10-08「开发调试点不动」根因①：catcher 原为 top=0/height=100%
        -- 铺满全屏，而开局在港口时信息屏默认展开（infoOpen 含 inPort 分支）→
        -- 透明 catcher 盖住顶部状态栏（header 为 absolute 浮层不占布局）与底部
        -- 按钮坞，header 按钮首次点击被无声吞掉。现与 cardHost 锚定语义对齐：
        -- 四边同样让开状态栏（40）与按钮坞（92），二者永可点。
        top = CARD_HOST_TOP,
        bottom = CARD_HOST_BOTTOM,
        left = 0,
        width = "100%",
        fontSize = 1,
        backgroundColor = { 0, 0, 0, 0 },
        borderColor = { 0, 0, 0, 0 },
        borderWidth = 0,
        onClick = function()
            if state.infoOpen == true then
                state.infoOpen = false
                -- v2.3.1 总开合：点空白同样收起左侧整块（与「信息」按钮一致）
                state.infoCollapsed = true
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

    -- v2.2 背包卡重构（信息完整 + 选项不被遮挡）：
    -- 旧结构问题：
    -- ① header 里塞了「格数 + 全部卖出 + 扩容 + 收起」四个控件，与标题、
    --    提示文字、待领渔获卡、物品列表、物品操作区同处一列纵向流 —— 列表
    --    一长就把中下段控件顶出屏幕底，"全部卖出"点不到。
    -- ② 物品操作区（使用/给老人/丢弃/投掷）是**列表上方的独立子面板**，
    --    选中物品时它插进列表前面，把下面的物品行整体推移 —— 选中的行本身
    --    反而可能滚出视野（用户诉求："选项不被遮挡"）。
    -- ③ 物品区固定 height=320，与卡片 maxHeight 68% 无联动，屏幕变小即溢出。
    --
    -- 新结构（sectionCard 三段式）：
    --   摘要头：格数 + 状态提示（只读，永不滚动）
    --   主体  ：待领渔获提示 + 物品行列表（唯一滚动区）
    --   操作条：物品操作区 + 全部卖出 / 扩容 / 收起（固定，永不被遮挡）
    --
    -- 契约：
    -- · 「操作 / 使用 / 给予 / 丢弃 / 投掷 / 全部卖出 / 扩容 / 收起」文案
    --   与可见性全部保留（Circle1B2UITests:234、HUDReviewTests:171-185、
    --   GameLoopUISpec:80-81 依赖）。
    -- · 卡片挂 infoLayer（常驻层），只受 showInventory 控制，不受 infoOpen 牵连。
    refs.inventoryPanel, refs.inventoryBody, refs.inventoryFooter = sectionCard("背包", { skin = "panel" })
    refs.inventoryCount = makeLabel("0 / 0 格", UiKit.fontSize.teaching, UiKit.ink.dim)
    refs.inventoryHeaderRow = UI.Panel {
        width = "100%",
        gap = 2,
        flexShrink = 0,
        flexDirection = "column",
    }
    refs.inventoryHeaderRow:AddChild(refs.inventoryCount)
    refs.inventoryHint = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.dim)
    refs.inventoryHeaderRow:AddChild(refs.inventoryHint)
    refs.inventoryPanel:AddChild(refs.inventoryHeaderRow)

    -- 主体区：待领渔获提示在上，物品列表在下（占满剩余空间并自行滚动）
    refs.pendingCatchPanel = UI.Panel(UiKit.cardProps("plain", {
        width = "100%",
        padding = 8,
        gap = 6,
        flexShrink = 0,
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
    refs.inventoryBody:AddChild(refs.pendingCatchPanel)

    -- 物品列表：占满主体剩余高度，行数超出时只在此处滚动
    refs.inventoryRows = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        minHeight = 0,
        gap = 4,
        flexDirection = "column",
    }
    refs.inventoryBody:AddChild(refs.inventoryRows)

    -- 操作条：物品操作区 + 全局操作
    refs.itemMenu = UI.Panel(UiKit.cardProps("panelLite", {
        width = "100%",
        padding = 8,
        gap = 5,
        flexShrink = 0,
    }))
    themedPanels[#themedPanels + 1] = {
        widget = refs.itemMenu, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    refs.itemMenuTitle = makeLabel("物品操作", UiKit.fontSize.teaching, UiKit.ink.teaching, "bold")
    refs.itemMenu:AddChild(refs.itemMenuTitle)
    refs.itemUseReason = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.dim)
    refs.itemMenu:AddChild(refs.itemUseReason)
    refs.upgrade = makeButton("扩容", function() invokeLoop("UpgradeInventory") end, "secondary", 148)
    refs.sellAll = makeButton("全部卖出", function() invokeLoop("SellAll") end, "primary", 108)
    refs.inventoryClose = makeButton("收起", function()
        invokeLoop("SetInventoryOpen", false)
    end, "secondary", 72)
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
    -- ⚠️ 物品操作区挂**操作条**而非主体：它是"对选中项的操作"，
    -- 必须恒在卡内底部可见，不能随列表滚动，也不能把列表行推移。
    refs.inventoryFooter:AddChild(refs.itemMenu)

    -- 全局操作行：全部卖出 / 扩容 / 收起 —— 固定在卡内底部，永不被遮挡
    refs.inventoryGlobalRow = UI.Panel {
        width = "100%",
        gap = 5,
        flexShrink = 0,
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
    }
    refs.inventoryGlobalRow:AddChild(refs.sellAll)
    refs.inventoryGlobalRow:AddChild(refs.upgrade)
    refs.inventoryGlobalRow:AddChild(UI.Spacer())
    refs.inventoryGlobalRow:AddChild(refs.inventoryClose)
    refs.inventoryFooter:AddChild(refs.inventoryGlobalRow)

    refs.inventoryPanel:SetVisible(false)
    -- v2.1 批B（真机 10-07 图1）：背包原挂抽屉（占屏 65% 过高）→ 改用信息
    -- 滚动屏，与港口商店平级。抽屉容器 gameplayInventoryDrawer 保留
    -- （Circle1B3SceneUITests 契约要求它在 root 倒数第二位/宽 100%/zIndex 91），
    -- 但不再承载背包内容——空抽屉永不显示，等于保留壳、去掉占用。
    --
    -- v2.1 §7.10 修订（回归 3 套件红）：原挂 contentScroll（受 infoOpen 控制），
    -- 但 infoOpen 会被"信息"按钮显式关闭，而背包可见性只取决于 showInventory
    -- ——契约要求背包行"给予"按钮在老人对话态下也须可见
    -- （Circle1B3SevenDaysTests:335）。父隐藏则子不可见 → 改挂 infoLayer
    -- （常驻层，只受 showInventory 控制），不再受 infoOpen 牵连。
    cardHost:AddChild(refs.inventoryPanel)

    -- v2.2 港口商店卡重构（信息完整 + 选项不被遮挡）：
    -- 旧结构问题：
    -- ① **挂错宿主**：portPanel 挂在 contentScroll 里，而 contentScroll 受
    --    infoOpen 控制 —— 在港默认展开尚可，但用户一旦点"收起信息"，
    --    商店整个消失；用户必须先知道要点"信息"才看得到商店。
    --    另商店与望远镜/宝物/投掷/木桶卡共用同一滚动区，商店被挤在
    --    列表末尾，要滚动才能找到（真机反馈"商店找不到"的直接原因）。
    -- ② **分区缺失**：升级体力/升级航速是裸按钮，购买是标签+按钮混排，
    --    出售是另一组行 —— 三组信息无标题、无边界、无当前值展示，
    --    用户看不出"我现在有多少钱、船速几级、这鱼能卖多少"。
    -- ③ **底部无固定操作**：全部卖出与存档操作混在主体里，出售渔获一多
    --    就把它们顶出屏幕。
    --
    -- 新结构：
    --   摘要头：金币 / 体力 / 船速等级 / 容量（决策所需的全部前置数值）
    --   主体  ：① 升级 ② 购买 ③ 出售 ④ 周目存档（四分区，标题+数值+按钮）
    --   操作条：全部卖出（最高频，主动作，固定底部）
    --
    -- 契约：
    -- · 「苹果 · ¥」「升级体力」「升级航速」「读取云存档」「开始新周目」
    --   文案保留（Circle1B3SevenDaysTests:331 点击"苹果 · ¥"购买）。
    -- · 挂 cardHost 与背包/老人平级，互斥，优先级最低（老人 > 背包 > 商店）。
    refs.portPanel, refs.portBody, refs.portFooter = sectionCard("港口商店", { skin = "panel" })

    -- 摘要头：把决策所需的四个前置数值一次给全，避免用户来回翻
    refs.portSummary = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.body, "bold")
    refs.portPanel:AddChild(refs.portSummary)

    -- 分区标题工厂：统一「标题 + 副说明」两行，保证四区视觉等权
    local function sectionTitle(text, hint)
        local box = UI.Panel {
            width = "100%",
            gap = 1,
            flexShrink = 0,
            flexDirection = "column",
            backgroundColor = { 92, 70, 46, 28 },
            borderRadius = 5,
            padding = { 4, 6, 4, 6 },
        }
        box:AddChild(makeLabel(text, UiKit.fontSize.info, UiKit.ink.teaching, "bold"))
        if hint then
            box:AddChild(makeLabel(hint, UiKit.fontSize.small, UiKit.ink.dim))
        end
        return box
    end
    refs.portSectionStyle = sectionTitle

    -- ① 升级区：体力 / 航速，各带当前等级与下一档价格
    refs.portBody:AddChild(sectionTitle("升级", "提升体力上限与航速；价格随等级递增，最高等级后不可升级。"))
    local upgradeRow = UI.Panel {
        width = "100%",
        gap = 5,
        flexShrink = 0,
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
    }
    refs.staminaUpgrade = makeButton("升级体力", function() invokeLoop("UpgradeStamina") end, "secondary", "46%")
    refs.speedUpgrade = makeButton("升级航速", function() invokeLoop("UpgradeBoatSpeed") end, "secondary", "46%")
    refs.staminaLevelText = makeLabel("", UiKit.fontSize.small, UiKit.ink.dim)
    refs.speedLevelText = makeLabel("", UiKit.fontSize.small, UiKit.ink.dim)
    upgradeRow:AddChild(refs.staminaUpgrade)
    upgradeRow:AddChild(refs.speedLevelText)
    upgradeRow:AddChild(refs.speedUpgrade)
    upgradeRow:AddChild(refs.staminaLevelText)
    refs.portBody:AddChild(upgradeRow)

    -- ② 购买区：每种商品独占一行（标签 + 库存 + 按钮），不再标签按钮混排
    refs.portBody:AddChild(sectionTitle("购买补给", "每日限量，次日补货；金币不足或船舱已满时按钮禁用并说明原因。"))
    refs.shopButtons = {}
    refs.shopStockLabels = {}
    for _, itemId in ipairs({ "apple", "bait" }) do
        local buyId = itemId
        local definition = Items.GetDefinition(buyId)
        local itemLabel = definition and definition.name or buyId
        local price = definition and definition.buyPrice
        local label = price and (itemLabel .. " · ¥" .. tostring(price)) or (itemLabel .. " · 价格未定")
        local shopButton = makeButton(label, function() invokeLoop("Buy", buyId) end, "primary", 132)
        if not price then shopButton:SetDisabled(true) end
        refs.shopButtons[buyId] = shopButton
        refs.shopStockLabels[buyId] = makeLabel("", UiKit.fontSize.small, UiKit.ink.dim)
        local buyLine = UI.Panel {
            width = "100%",
            gap = 3,
            flexShrink = 0,
            flexDirection = "row",
            flexWrap = "wrap",
            alignItems = "center",
        }
        -- 标签必须占满剩余宽度：row 布局下无宽度约束的 label 会被压为不可见
        buyLine:AddChild(makeLabel(itemLabel, UiKit.fontSize.body, UiKit.ink.body, nil,
            { flexGrow = 1, flexBasis = 0 }))
        buyLine:AddChild(shopButton)
        buyLine:AddChild(refs.shopStockLabels[buyId])
        refs.portBuyRows = refs.portBuyRows or {}
        refs.portBuyRows[#refs.portBuyRows + 1] = buyLine
        refs.portBody:AddChild(buyLine)
    end

    -- ③ 出售区：每条渔获独占一行（名称 + 稀有度 + 售价 + 出售按钮）
    refs.portBody:AddChild(sectionTitle("出售渔获", "仅沙丁鱼与金枪鱼可售；价格与稀有度取自物品表。"))
    refs.portSales = UI.Panel {
        width = "100%",
        gap = 4,
        flexDirection = "column",
    }
    refs.portBody:AddChild(refs.portSales)

    -- ④ 周目存档区：低频操作，从按钮坞移来（真机反馈 2026-10-05 精简按钮坞）
    refs.portBody:AddChild(sectionTitle("周目与存档", "新周目起始状态会在开始时保存；入口处可读取已有云存档。"))
    local portUtilityRow = UI.Panel {
        width = "100%",
        gap = 5,
        flexShrink = 0,
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
    }
    refs.loadSaved = makeButton("读取云存档", function() invokeLoop("LoadSaved") end, "secondary", "46%")
    refs.newRun = makeButton("开始新周目", function() invokeLoop("NewRun") end, "secondary", "46%")
    portUtilityRow:AddChild(refs.loadSaved)
    portUtilityRow:AddChild(refs.newRun)
    refs.portBody:AddChild(portUtilityRow)
    refs.loadStatus = makeLabel("", UiKit.fontSize.small, UiKit.ink.dim)
    refs.portBody:AddChild(refs.loadStatus)

    -- 操作条：全部卖出是港口最高频动作，固定在卡内底部
    refs.portSellAll = refs.portSellAll or makeButton("全部卖出", function() invokeLoop("SellAll") end, "primary", "100%")
    refs.portFooter:AddChild(refs.portSellAll)
    refs.portPanel:SetVisible(false)
    cardHost:AddChild(refs.portPanel)

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
        -- 音频诊断行（2026-10-08 真机静音排查）：实时显示 AudioDirector 能力/加载/声床状态
        refs.audioStatus = makeLabel("音频：待读取", 12, { 189, 211, 190, 255 })
        debugBody:AddChild(refs.audioStatus)

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
        -- 挂载时机移至 infoLayer 之后（见下方 AddChild），确保 z 序高于卡片。
    end

    -- v2.1 §7.15：cardHost（三卡统一宿主）挂在 infoLayer 内。
    -- infoCloseCatcher 仍在 infoLayer 直属（铺满全屏，空白点击收起不受宿主限宽影响）。
    infoLayer:AddChild(cardHost)
    -- ⚠️⚠️ 回归修复（2026-10-08，v2.2）：infoLayer 必须在末尾显式挂到 root。
    -- v2.1 §7.15 重排 root 子节点时这一行被误删，导致整棵 infoLayer 子树
    -- （contentScroll + cardHost + 背包卡 + 老人卡）从未接入 root：
    --   · 真机上三卡完全不显示（游离子树不参与布局与渲染）；
    --   · GameLoopUISpec:83 "点拜访老人 → 点给予"报 missing visible button，
    --     因为测试沿 parent 链判可见，链首就是游离的 infoLayer。
    -- 契约：必须在 refs.drawerBackdrop（root 倒数第二位）之前插入，
    -- 见 Circle1B3SceneUITests:231 的 "倒数第二 = gameplayInventoryDrawer"。
    root:AddChild(infoLayer)

    -- 调试面板必须在 infoLayer 之后入树（真机 2026-10-08「开发调试点不动」根因②：
    -- 原在 infoLayer 之前，居中面板被港口默认展开的卡片盖住，打开也看不见）。
    -- 仍在 achievementToast/drawer/overlay 之前，B3 的"倒数第二 = drawer"契约不变。
    if refs.debugPanel then root:AddChild(refs.debugPanel) end

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
    -- v2.1 §7.9 修订（真机 21:46 文字溢出）：本卡是**固定尺寸容器**
    -- （width/maxHeight 写死），不能用 slice+6 大留白——54×2 会吃掉
    -- 108px 文字区与 108px 内容高，老人对话卡文字直接折行溢出卡外。
    -- 改用 compactPadding=50 + 加宽到 420/加高到 460，正文容器再限宽兜底。
    refs.modalCard = UI.Panel(UiKit.cardProps("parchment", {
        width = 420,
        maxWidth = "94%",
        height = "90%",
        maxHeight = 460,
        transition = "opacity 0.25s easeOut", -- 模态出现时淡入，替代硬切
    }, true))
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

    -- v2.1 §7.9 修订（真机 21:46 文字溢出卡外）：老人对话是内容最多的一页
    -- v2.1 §7.11（用户 23:15「拜访老人也放进滚动屏，和商店一起参考背包页面
    -- 大小显示」）：老人对话从**全屏模态独占页**改为信息滚动屏里的普通卡片，
    -- 与港口商店/背包平级。理由：模态遮罩 + 420×460 固定尺寸对"给老人送鱼"
    -- 这种轻交互过重，且宝物卡曾被卡底裁切。
    --
    -- 尺寸**对齐背包卡**（用户指定参考对象）：同为 card() 默认 width=100%，
    -- 用 panel 档（slice=40）而非 parchment（粗羊皮纸边框留给剧情卡）。
    -- 契约约束（不可违反）：
    --   ① GameLoopUISpec:82-84 点"拜访老人"后必须能点到"结束对话"→
    --      本卡挂 infoLayer（常驻层，不受 infoOpen 牵连），按钮恒可见；
    --   ② Circle1B2UITests:244-253 老人态下要能点物品行"展示"→
    --      卡片不遮挡背包行（同层并列）；
    --   ③ 礼物区保持为 card 的直接后代（多包一层 ScrollView 会改变 UI 树
    --      导致 isVisible 沿父链判定失效，教训见 §7.9）。
    --      v2.2 已把礼物区并入 sectionCard 的主体滚动区，不再单独包 ScrollView。
    -- v2.2 拜访老人卡重构：sectionCard 三段式 + 对话流限高（历史背景见 git）。
    -- v2.3（2026-10-08 真机截图反馈）：选项区二级化 + 聊天记录回看态。
    -- 真机问题（截图 16:34）：宝物卡、教程问题、记录开关、透镜、结束对话
    -- 全部平铺在一层，拥挤且无分组。
    --
    -- 新交互结构（用户拍板 A 案：二级化 + 同步更新测试契约）：
    --   一级键（level1）：[提问 ▸] [给予 ▸] [展示 ▸] / [聊天记录] [结束对话]
    --   二级列表（level2）：点一级键展开，[← 返回] 回一级
    --     提问 → 问题列表（问过即消失，elderAsked 去重沿用）
    --     给予 → 可给予的食物行
    --     展示 → 可展示的鱼/饵行 + 透镜行（宝物卡从主区移除，融进此处）
    --   回看态：点[聊天记录] → 记录展开、选项区收起为底部 [选项 ▴] 把手；
    --           点把手展开选项区、再点收起；再点[收起记录]回常态。
    --
    -- 文案避撞（关键）：一级键带「 ▸」后缀，与二级物品按钮（精确文案
    -- "给予"/"展示"）不撞名 —— findButtons 的精确匹配因此可区分层级。
    --
    -- 契约（已随 A 案更新四套件）：
    --   ① B2UITests：打开 → 点[展示 ▸] → findButtons("展示")=2（物品按钮）
    --   ② SevenDays：打开 → 点[给予 ▸] → "01 · "前缀行的[给予]
    --   ③ GameLoopUISpec：打开 → [给予 ▸] → [给予] → [结束对话]
    --   行结构不变：带 %02d · 前缀的标签与按钮仍同处一个面板。
    --   ④ 二级操作后**不自动返回一级**（可连续展示多条鱼/给多个苹果），
    --     由[← 返回]手动回一级。
    refs.elderPanel, refs.elderBody, refs.elderFooter = sectionCard("拜访老人", { skin = "panel" })

    -- 摘要头：对话反馈 + 进展 + 教学（只读，永不滚动）
    refs.elderMessage = makeLabel("食物可给予老人；鱼和鱼饵可向老人展示。", UiKit.fontSize.body)
    refs.elderStatus = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.teaching, "bold")
    -- S6 教学（05 页 P6）：前 3 天且未完成首次捕鱼领取时，展示看海对白。
    refs.elderTeaching = makeLabel("", UiKit.fontSize.teaching, UiKit.ink.teaching)
    refs.elderHeaderBox = UI.Panel {
        width = "100%",
        gap = 2,
        flexShrink = 0,
        flexDirection = "column",
    }
    refs.elderHeaderBox:AddChild(refs.elderMessage)
    refs.elderHeaderBox:AddChild(refs.elderStatus)
    refs.elderHeaderBox:AddChild(refs.elderTeaching)
    refs.elderPanel:AddChild(refs.elderHeaderBox)

    -- 主体区：对话流（限高）+ 聊天记录（回看态显示）
    -- 对话流区（气泡序列，不包 ScrollView — §7.9 结构红线）。
    -- 二级/回看态下隐藏，把空间让给二级列表或记录。
    refs.elderDialogue = UI.Panel {
        width = "100%",
        gap = 5,
        flexGrow = 1,
        flexBasis = 0,
        minHeight = 0,
        flexDirection = "column",
    }
    refs.elderDialogOverflow = makeLabel("", UiKit.fontSize.small, UiKit.ink.dim)
    refs.elderBody:AddChild(refs.elderDialogue)
    refs.elderBody:AddChild(refs.elderDialogOverflow)
    refs.elderDialogTail = refs.elderDialogue -- 追加锚点

    -- 聊天记录：回看态显示完整历史（内含 ScrollView 安全——§7.9 已验证）
    refs.elderLogPanel = UI.Panel(UiKit.cardProps("plain", {
        width = "100%",
        gap = 4,
        flexGrow = 1,
        flexBasis = 0,
        minHeight = 0,
    }, true))
    themedPanels[#themedPanels + 1] = {
        widget = refs.elderLogPanel, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
    }
    refs.elderLogRows = UI.Panel { width = "100%", flexDirection = "column", gap = 4 }
    refs.elderLogScroll = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        minHeight = 0,
        scrollY = true,
        showScrollbar = true,
        children = { refs.elderLogRows },
    }
    refs.elderLogPanel:AddChild(refs.elderLogScroll)
    refs.elderBody:AddChild(refs.elderLogPanel)
    refs.elderLogPanel:SetVisible(false)

    -- ── 操作条（固定底部）──────────────────────────────────────────
    -- 回看态把手：仅 review 态可见；点一下展开选项区、再点收起。
    refs.elderHandleRow = UI.Panel {
        width = "100%",
        flexShrink = 0,
        flexDirection = "row",
    }
    refs.elderHandle = makeButton("选项 ▴", function()
        state.elderOptionsExpanded = not (state.elderOptionsExpanded == true)
        refresh()
    end, "secondary", "100%")
    refs.elderHandleRow:AddChild(refs.elderHandle)
    refs.elderFooter:AddChild(refs.elderHandleRow)
    refs.elderHandleRow:SetVisible(false)

    -- 一级键组：三个分类键一行 + 两个全局键一行。
    -- 全局键行**常驻**（任何层级、回看态都可点）——"结束对话"是高频退出路径，
    -- "收起记录"是回看态的唯一出口，不能被抽屉收起。
    refs.elderLevel1 = UI.Panel {
        width = "100%",
        gap = 5,
        flexShrink = 0,
        flexDirection = "column",
    }
    refs.elderCategoryRow = UI.Panel {
        width = "100%",
        gap = 5,
        flexShrink = 0,
        flexDirection = "row",
        flexWrap = "wrap",
    }
    refs.elderAskBtn = makeButton("提问 ▸", function()
        state.elderMenuLevel = "questions"
        refresh()
    end, "secondary", "30%")
    refs.elderGiveBtn = makeButton("给予 ▸", function()
        state.elderMenuLevel = "give"
        refresh()
    end, "secondary", "30%")
    refs.elderShowBtn = makeButton("展示 ▸", function()
        state.elderMenuLevel = "show"
        refresh()
    end, "secondary", "30%")
    refs.elderCategoryRow:AddChild(refs.elderAskBtn)
    refs.elderCategoryRow:AddChild(refs.elderGiveBtn)
    refs.elderCategoryRow:AddChild(refs.elderShowBtn)
    refs.elderLevel1:AddChild(refs.elderCategoryRow)

    refs.elderGlobalRow = UI.Panel {
        width = "100%",
        gap = 5,
        flexShrink = 0,
        flexDirection = "row",
        flexWrap = "wrap",
    }
    refs.elderLogToggle = makeButton("聊天记录", function()
        state.elderReviewOpen = not (state.elderReviewOpen == true)
        state.elderOptionsExpanded = false
        refresh()
    end, "secondary", "46%")
    refs.elderEnd = makeButton("结束对话", function() invokeLoop("SetElderOpen", false) end, "secondary", "46%")
    refs.elderGlobalRow:AddChild(refs.elderLogToggle)
    refs.elderGlobalRow:AddChild(refs.elderEnd)
    -- v2.3：全局键行提升到 footer 直属（不随选项抽屉收起），常驻可点
    refs.elderFooter:AddChild(refs.elderGlobalRow)
    refs.elderFooter:AddChild(refs.elderLevel1)

    -- 二级容器：[← 返回 + 标题] + 三套互斥内容（questions/give/show）
    refs.elderLevel2 = UI.Panel {
        width = "100%",
        gap = 4,
        flexShrink = 0,
        flexDirection = "column",
    }
    local elderLevel2Header = UI.Panel {
        width = "100%",
        gap = 5,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "center",
    }
    refs.elderBack = makeButton("← 返回", function()
        state.elderMenuLevel = "root"
        refresh()
    end, "secondary", 88)
    refs.elderLevel2Title = makeLabel("", UiKit.fontSize.info, UiKit.ink.teaching, "bold")
    elderLevel2Header:AddChild(refs.elderBack)
    elderLevel2Header:AddChild(refs.elderLevel2Title)
    refs.elderLevel2:AddChild(elderLevel2Header)

    -- 二级·提问：问题按钮列表（buildElderQuestions 重建；问过即消失）
    refs.elderQuestions = UI.Panel {
        width = "100%",
        gap = 4,
        flexShrink = 0,
        flexDirection = "column",
    }
    refs.elderLevel2:AddChild(refs.elderQuestions)

    -- 二级·给予：可给予的食物行（rebuildItemRows 构建，行结构守契约）
    refs.elderGiveRows = UI.Panel {
        width = "100%",
        gap = 4,
        flexShrink = 0,
        flexDirection = "column",
    }
    refs.elderLevel2:AddChild(refs.elderGiveRows)

    -- 二级·展示：可展示的鱼/饵行 + 透镜行（宝物卡融进此处）
    refs.elderShowRows = UI.Panel {
        width = "100%",
        gap = 4,
        flexShrink = 0,
        flexDirection = "column",
    }
    refs.elderLevel2:AddChild(refs.elderShowRows)
    refs.elderLensRow = UI.Panel {
        width = "100%",
        gap = 4,
        flexShrink = 0,
        flexDirection = "row",
        flexWrap = "wrap",
        alignItems = "center",
        backgroundColor = { 92, 70, 46, 24 },
        borderRadius = 5,
        padding = { 3, 5, 3, 5 },
    }
    refs.elderLensStatus = makeLabel("尚未获得透镜。", UiKit.fontSize.small, UiKit.ink.dim)
    refs.elderLensGive = makeButton("展示透镜", function()
        invokeLoop("GiveTreasureToElder", "scopeLens")
    end, "primary", 96)
    refs.elderLensRow:AddChild(makeLabel("望远镜透镜", UiKit.fontSize.teaching, UiKit.ink.body, "bold",
        { flexGrow = 1, flexBasis = 0 }))
    refs.elderLensRow:AddChild(refs.elderLensGive)
    refs.elderLensRow:AddChild(refs.elderLensStatus)
    refs.elderLevel2:AddChild(refs.elderLensRow)
    refs.elderFooter:AddChild(refs.elderLevel2)

    refs.elderPanel:SetVisible(false)
    cardHost:AddChild(refs.elderPanel)

    -- 成就/图鉴页壳（v2.0 §7.4）：仅在暂停态可开（圈2 决策：图鉴只在暂停界面查）。
    -- 成就页=6 条最小集桩；图鉴页=marine_life 8 水彩图标（发现状态待知识层接入）。
    -- v2.1 §7.9（真机 21:46 文字溢出）：开场剧情为长文本 + 图鉴为 8 条列表，
    -- 羊皮纸 50 留白 + 460 卡高下可能超出。两者都套卡内滚动兜底
    -- （此前只有老人对话页有此保护）。
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

    -- v2.1 §7.9 修订（真机 21:46 文字溢出）：曾给剧情/老人/图鉴三页套
    -- ScrollView 兜底，但**必须回退**——测试用 walk(root) + isVisible 沿父链
    -- 判定，多包一层 ScrollView 会改变树结构导致 3 套件红（Circle1B2/
    -- B3SevenDays/GameLoopUI，failureCount 6→9）。现改为不加包裹层，
    -- 靠 modalCard 的 maxHeight + 各页内容长度控制溢出。
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
    refs.elderPanel:Hide()
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
        if refs.audioStatus then
            local okSt, st = pcall(SoundSystem.Status)
            refs.audioStatus:SetText("音频：" .. (okSt and tostring(st) or "状态读取失败"))
        end
        refresh()
    end

    local function addEmptyMessage(rows, text)
        rows:AddChild(makeLabel(text, 12, { 169, 191, 181, 255 }))
    end

    -- 前置声明（v2.1 §7.14）：askElderQuestion / destroyChildren 被
    -- buildElderQuestions、renderElderDialogue 提前引用，但定义在其后。
    -- Lua 的 local function 不会自动提升作用域，不加声明会取到 nil：
    -- destroyChildren 会退化为全局 nil → "attempt to call a nil value"。
    local askElderQuestion
    local destroyChildren
    -- v2.2 对话流可见条数上限：主区只渲染最近 N 轮对话。
    -- 为什么限条而不是包 ScrollView：§7.9 红线——多包一层 ScrollView 会
    -- 改变 UI 树结构，测试沿父链判 isVisible 时失配（3 套件红）。
    -- 限条达到同一目的：对话区高度有界 → 下方操作条恒在卡内可见。
    -- 更早的完整历史由聊天记录抽屉承载（数据同一份，不丢内容）。
    local ELDER_VISIBLE_LINES = 6
    -- v2.1 §7.14（对话式形态）：对话流渲染 + 提问区构建 + 聊天记录抽屉同步。
    -- 说明：对话流与提问区**不使用 ScrollView**（结构红线，会致 3 套件红）。
    local function renderElderDialogue()
        if not refs.elderDialogue then return end
        destroyChildren(refs.elderDialogue)
        destroyChildren(refs.elderLogRows)
        local transcript = state.elderTranscript or {}
        local total = #transcript
        -- 只渲染最近 ELDER_VISIBLE_LINES 条气泡；更早的仅进聊天记录
        local firstVisible = 1
        if total > ELDER_VISIBLE_LINES then
            firstVisible = total - ELDER_VISIBLE_LINES + 1
        end
        for index = 1, total do
            local entry = transcript[index]
            -- 聊天记录抽屉同步**全部**历史（收起时子树不可见，不影响契约查找）
            local isElder = entry.who == "elder"
            local body = entry.teach and UiKit.teachingText(entry.text) or entry.text
            local logRow = UI.Panel { width = "100%", gap = 2 }
            logRow:AddChild(makeLabel(isElder and "老人" or "你", 11,
                isElder and UiKit.ink.teaching or UiKit.ink.dim, "bold"))
            logRow:AddChild(makeLabel(body, 11, UiKit.ink.teaching))
            refs.elderLogRows:AddChild(logRow)

            if index >= firstVisible then
                -- 老人气泡在左（panelLite 羊皮纸底），玩家气泡在右（plain 素面纸）
                local bubble = UI.Panel(UiKit.cardProps(isElder and "panelLite" or "plain", {
                    width = "100%",
                    gap = 3,
                    flexShrink = 0,
                }, true))
                themedPanels[#themedPanels + 1] = {
                    widget = bubble, day = UI_PALETTE.cardDay, night = UI_PALETTE.cardNight,
                }
                bubble:AddChild(makeLabel(isElder and "老人" or "你", 11,
                    isElder and UiKit.ink.teaching or UiKit.ink.dim, "bold"))
                bubble:AddChild(makeLabel(body, UiKit.fontSize.teaching,
                    isElder and UiKit.ink.body or UiKit.ink.teaching))
                refs.elderDialogue:AddChild(bubble)
            end
        end
        -- 溢出提示：明确告知更早内容去哪找，避免"对话凭空消失"的困惑
        local hidden = firstVisible - 1
        refs.elderDialogOverflow:SetVisible(hidden > 0)
        if hidden > 0 then
            setText(refs.elderDialogOverflow, "elderDialogOverflow",
                string.format("上方 %d 条更早对话已折叠，点「聊天记录」查看完整历史。", hidden))
        end
    end

    -- 提问二级构建：按 day 决定阶段，只列未问过的问题（问过的不重复出现）。
    -- v2.3：移入「提问 ▸」二级；全部问完时给空态说明，不留空白列表。
    local function buildElderQuestions(day, teachingDone)
        if not refs.elderQuestions then return end
        destroyChildren(refs.elderQuestions)
        local stage = (day <= 3) and 1 or (day <= 6 and 2 or 3)
        local asked = 0
        for _, q in ipairs(ELDER_QUESTIONS) do
            if q.stage == stage and state.elderAsked[q.id] ~= true then
                if q.teach and teachingDone == true then
                    -- 教学已完成：教程问题不再出现（已答过则 earlier 分支已跳过）
                else
                    local label = q.teach and (UiKit.teachMark .. q.text) or q.text
                    refs.elderQuestions:AddChild(makeButton(label, function()
                        askElderQuestion(q)
                    end, q.teach and "secondary" or "primary", "100%"))
                    asked = asked + 1
                end
            end
        end
        if asked == 0 then
            refs.elderQuestions:AddChild(makeLabel(
                "这个阶段的问题都问过了。", UiKit.fontSize.small, UiKit.ink.dim))
        end
    end

    -- 记录一次问答（玩家提问 → 老人答复），并标记已问。
    askElderQuestion = function(q)
        if state.destroyed or not q then return end
        if state.elderAsked[q.id] == true then return end
        state.elderAsked[q.id] = true
        state.elderTranscript[#state.elderTranscript + 1] = { who = "player", text = q.text }
        state.elderTranscript[#state.elderTranscript + 1] = { who = "elder", text = q.answer }
        -- 教程问题问完 → 标记教学完成（沿用现有 Progress 通道）
        -- 注：不改 teachingDone。该标记语义为"投饵→捕鱼→结果反馈闭环完成"
        --（Loop:NotifyCatchObtained → Progress.MarkTeachingDone），
        -- 若在此处调用会把"听完教程对话"误判为"已完成教学操作"。
        refresh()
    end

    destroyChildren = function(container)
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
        -- v2.3：礼物行拆分为「给予」与「展示」两个二级容器
        destroyChildren(refs.elderGiveRows)
        destroyChildren(refs.elderShowRows)

        if #items == 0 then addEmptyMessage(refs.inventoryRows, "背包是空的。先去捕点鱼，再返港出售。") end
        local saleCount, giftCount = 0, 0
        for index, itemId in ipairs(items) do
            local itemIndex = index
            local definition = Items.GetDefinition(itemId)
            local name = definition and definition.name or tostring(itemId)
            local inventoryRow = UI.Panel {
                width = "100%",
                minHeight = 38,
                gap = 3,
                flexShrink = 0,
                flexDirection = "column",
                paddingHorizontal = 4,
                -- v2.1 批B 修复（真机 10-07 反馈）：物品行原为深绿底 {45,64,61}，
                -- 放在暖色羊皮纸卡内形成深色条 + 亮色字，与卡片风格割裂。
                -- 改为半透明墨色浅底（卡片纸纹透出），行内文字用墨棕。
                backgroundColor = { 92, 70, 46, 34 },
                borderRadius = 5,
            }
            -- 名称标签必须占满剩余宽度：row 布局下无宽度约束的 label 会被压缩为不可见。
            local fishTag, fishColor = fishDisplay(itemId, definition)
            -- ⚠️ 契约（Circle1B3SevenDaysTests:146-160）：测试以
            -- "标签 %02d · 前缀"定位后取 label.parent 当行，再**只在
            -- row.children 里找按钮**。因此带前缀的标签与全部按钮必须同处
            -- 一个面板 —— 这里就是 itemLine；属性副行放在它下面，不参与匹配。
            -- v2.2 信息完整：属性副行让"能干什么/值多少"当场可读，
            -- 单行挤不下时属性会整段消失。
            local itemLine = UI.Panel {
                width = "100%",
                gap = 4,
                flexShrink = 0,
                flexDirection = "row",
                flexWrap = "wrap",
                alignItems = "center",
            }
            itemLine:AddChild(makeLabel(string.format("%02d · %s%s", itemIndex, name,
                fishTag ~= "" and (" · " .. fishTag) or ""), UiKit.fontSize.teaching,
                fishColor or UiKit.ink.title, "bold", { flexGrow = 1, flexBasis = 0 }))
            local itemActions = makeButton("操作", function()
                state.selectedItemIndex = itemIndex
                refresh()
            end, "secondary", 58)
            itemActions:SetDisabled(actionsBlocked)
            itemLine:AddChild(itemActions)
            if inPort and (itemId == "sardine" or itemId == "tuna") and definition then
                local price = definition.sellPrice
                local label = price and ("出售 ¥" .. tostring(price)) or "售价未定"
                local sellButton = makeButton(label, function() invokeLoop("Sell", itemIndex, itemId, cargoRevision) end, "primary", 92)
                if not price or actionsBlocked then sellButton:SetDisabled(true) end
                itemLine:AddChild(sellButton)
            end
            inventoryRow:AddChild(itemLine)
            -- 属性副行：类别 + 恢复体力 + 售价 + 可否给老人
            local CATEGORY_NAMES = { fish = "鱼获", food = "食物", bait = "鱼饵",
                treasure = "宝物", misc = "杂项" }
            local traits = { CATEGORY_NAMES[definition and definition.category] or "物品" }
            if definition and definition.heal and definition.heal > 0 then
                traits[#traits + 1] = "恢复体力 " .. tostring(definition.heal)
            end
            if definition and definition.sellPrice and definition.sellPrice > 0 then
                traits[#traits + 1] = "售价 ¥" .. tostring(definition.sellPrice)
            end
            if definition and definition.canGive then
                traits[#traits + 1] = definition.category == "food" and "可给老人" or "可向老人展示"
            end
            inventoryRow:AddChild(makeLabel(table.concat(traits, " · "), UiKit.fontSize.small, UiKit.ink.dim,
                nil, { width = "100%" }))
            refs.inventoryRows:AddChild(inventoryRow)

            if inPort and (itemId == "sardine" or itemId == "tuna") and definition then
                saleCount = saleCount + 1
                -- ⚠️ 契约（Circle1B3SevenDaysTests:146-160）：测试用
                -- "标签 %02d · 前缀 → 取 label.parent 当行 → 只在 row.children
                -- 里找按钮"。因此**按钮必须是行的直接子节点**，放进嵌套子面板
                -- 会让契约查找落空。行改纵向两层，文字层与按钮层都直属行。
                local saleRow = UI.Panel {
                    width = "100%",
                    minHeight = 36,
                    gap = 4,
                    flexShrink = 0,
                    flexDirection = "row",
                    flexWrap = "wrap",
                    alignItems = "center",
                    backgroundColor = { 92, 70, 46, 24 },
                    borderRadius = 5,
                    padding = { 3, 5, 3, 5 },
                }
                -- ⚠️ 契约（Circle1B3SevenDaysTests:146-160）：带 "%02d · " 前缀的
                -- 标签与其按钮必须同处一个面板 —— 这里就是 saleRow。
                -- v2.2：名称/稀有度/槽位/售价合成一行，售价不再被换行裁掉。
                saleRow:AddChild(makeLabel(string.format("%s · %s · 槽位 %02d · 售价 ¥%s", name,
                    fishTag ~= "" and fishTag or "普通", itemIndex, tostring(definition.sellPrice or 0)),
                    UiKit.fontSize.teaching, fishColor or UiKit.ink.body, "bold",
                    { flexGrow = 1, flexBasis = 0 }))
                local price = definition.sellPrice
                local saleButton = makeButton(price and ("出售 ¥" .. tostring(price)) or "售价未定", function()
                    invokeLoop("Sell", itemIndex, itemId, cargoRevision)
                end, "primary", 96)
                if not price or actionsBlocked then saleButton:SetDisabled(true) end
                saleRow:AddChild(saleButton)
                refs.portSales:AddChild(saleRow)
            end

            if elderOpen and definition and definition.canGive then
                giftCount = giftCount + 1
                -- ⚠️ 契约（Circle1B3SevenDaysTests:146-160）：带 "%02d · " 前缀的
                -- 标签与其按钮必须同处一个面板（label.parent 当行，只在
                -- row.children 里找按钮）。
                -- v2.3：按类别分流到「给予」/「展示」两个二级容器。
                local giftRow = UI.Panel {
                    width = "100%",
                    minHeight = 38,
                    gap = 4,
                    flexShrink = 0,
                    flexDirection = "row",
                    flexWrap = "wrap",
                    alignItems = "center",
                    backgroundColor = { 92, 70, 46, 24 },
                    borderRadius = 5,
                    padding = { 3, 5, 3, 5 },
                }
                local isFood = definition.category == "food"
                giftRow:AddChild(makeLabel(string.format("%02d · %s · %s", itemIndex, name,
                    isFood and "可给老人吃" or "只能展示，不能给老人"),
                    UiKit.fontSize.teaching, UiKit.ink.body, "bold",
                    { flexGrow = 1, flexBasis = 0 }))
                local giftButton = makeButton(isFood and "给予" or "展示",
                    function() invokeLoop("GiveToElder", itemIndex) end, "primary", 72)
                giftButton:SetDisabled(actionsBlocked)
                giftRow:AddChild(giftButton)
                if isFood then
                    refs.elderGiveRows:AddChild(giftRow)
                else
                    refs.elderShowRows:AddChild(giftRow)
                end
            end
        end
        if saleCount == 0 then addEmptyMessage(refs.portSales, "没有可出售的鱼。先去捕点鱼，再返港出售。") end
        -- v2.3：两个二级容器各自的空态说明
        if giftCount == 0 then
            addEmptyMessage(refs.elderGiveRows, "背包里没有可以给老人的食物。")
            addEmptyMessage(refs.elderShowRows, "背包里没有可以展示的鱼或鱼饵。")
        end
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
        -- v2.1 §7.15：状态栏收敛为单行左右分栏（测试期状态查看，发布时删除）。
        -- 左：第几天 · 昼夜 剩余 · 暂停态 · 模式
        -- 右：体力 · 钱 · 背包格
        local statusText = string.format(
            "第 %s 天 · %s 剩余 %.0f 秒",
            tostring(player.day or 1), phase, math.max(0, remaining))
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
        -- （2026-10-08）左上角小卡移除：状态/进度/结果三行不再渲染，收网中
        -- SetText 每帧重排的卡顿源随之消失（2026-10-07 整数秒优化的上位替代）；
        -- fishingState 仍用于模式行、结果气泡与按钮态。
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

        -- A2（2026-10-05 用户裁决）：动作中再点捕鱼键=取消。2026-10-08 小卡移除后
        -- 取消/重试清理统一由按钮坞"捕鱼"键承担：选点/抛网/收网期保持"捕鱼"可点
        -- （点击经 Loop:BeginFishingSelection 转为取消），清理/结算 pending 态改显
        -- "重试清理"（同一入口走 CancelFishingAction 重试清理路径）。文案经
        -- lastTexts 去重，避免每帧 SetText 触发重排。
        local fishingCancellable = fishingSelecting or fishingPhase == "casting"
            or fishingPhase == "landed" or fishingCleanupPending
        refs.beginFishing:SetVisible(not inPort and (not fishingRestricted or fishingCancellable))
        local beginFishingLabel = fishingCleanupPending and "重试清理" or "捕鱼"
        if state.lastTexts.beginFishingLabel ~= beginFishingLabel then
            state.lastTexts.beginFishingLabel = beginFishingLabel
            refs.beginFishing:SetText(beginFishingLabel)
        end
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
        -- v2.1 §7.15：距港距离并入顶部状态栏左列（用户 13:03 要求显示）。
        -- portDistance 在本行之前已算出，可直接取值。
        local portDistanceText = type(portDistance) == "number"
            and string.format(" · 距港 %.1f米", portDistance)
            or " · 距港暂不可读"
        setText(refs.status, "status", statusText .. modeSuffix .. portDistanceText)
        -- v2.1 §7.15 右列：体力 / 钱 / 背包格（测试期状态查看）
        -- ⚠️ 文案格式受 GameLoopUISpec:77 契约约束（"100/100" / "钱：100" /
        -- "2 / 5"，冒号与空格均不可改），仅位置搬到右列。
        setText(refs.statusRight, "statusRight", string.format(
            "体力：%s/%s · 钱：%s · 背包 %d / %d 格",
            tostring(player.stamina or 0), tostring(player.maxStamina or 0),
            tostring(player.money or 0), #items, capacity))

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
        -- v2.3.1（真机反馈"收起信息按钮无效"）：三卡已迁 cardHost 后，
        -- infoOpen 只控制 contentScroll（内容很少），"收起信息"看起来没反应。
        -- 按用户建议改为**总开合**：收起左侧整块（cardHost 含三卡 + 滚动屏）。
        -- infoCollapsed 是显式收起意图：点「信息」收起后置 true，任何打开
        -- 动作（点背包/拜访老人/待领渔获）都会清除，恢复卡片显示。
        local elderActiveForCards = loop.elderOpen == true
        local infoOpen = not seaClickFlow and not (state.infoCollapsed == true)
            and (((state.infoOpen == nil and inPort) or state.infoOpen == true)
                or loop.inventoryOpen == true or pendingCatch or elderActiveForCards)
        refs.contentScroll:SetVisible(infoOpen)
        refs.infoCloseCatcher:SetVisible(infoOpen)
        -- 总开合落在 cardHost：三卡（商店/背包/老人）一并收起/恢复，
        -- 各卡自身的互斥显隐逻辑不变（恢复时仍显示当前应显示的那张）。
        cardHost:SetVisible(infoOpen)
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
        -- v2.1 §7.13：三卡互斥——老人对话优先于背包。
        -- 注意：showElder 在下方（约 1879 行）才定义，此处不能引用（取到 nil）。
        -- 用同源条件就地计算 elderActive，避免定义顺序依赖。
        local elderActive = loop.elderOpen == true
        refs.inventoryPanel:SetVisible(showInventory and not elderActive)
        -- 抽屉壳（gameplayInventoryDrawer + 压暗层）保留但不再显示：
        -- 契约要求该节点存在于 root 倒数第二位，见 Circle1B3SceneUITests。
        refs.drawer:SetVisible(false)
        refs.drawerBackdrop:SetVisible(false)
        refs.inventoryClose:SetVisible(true)
        refs.inventoryClose:SetDisabled(busy or loop.loading == true)
        -- v2.1 §7.13：三卡互斥——老人 > 背包 > 商店。
        refs.portPanel:SetVisible(inPort and not elderActive and not showInventory)
        -- 港口商店不再依赖 infoOpen（v2.2 已迁到 cardHost），
        -- 但海面点选流程（捕鱼选点/投掷选点）期间仍强制收起信息屏，
        -- 此时商店应一并让位，避免挡住要点的海面。
        if seaClickFlow then refs.portPanel:SetVisible(false) end
        -- 港口摘要头：把决策所需的四个前置数值一次给全
        -- （金币 / 体力 / 船速等级 / 容量），避免用户翻区找数。
        setText(refs.portSummary, "portSummary", string.format(
            "金币 %s · 体力 %s/%s · 船速 %s 级 · 船舱 %d/%d 格",
            tostring(player.money or 0), tostring(player.stamina or 0), tostring(player.maxStamina or 0),
            tostring((tonumber(player.boatSpeedLevel) or 0) + 1), #items, capacity))
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
        -- v2.2：升级区补当前值 —— "升级体力 ¥120"看不出现在几级、补完几级
        -- 下一档体力上限取 config.upgrades.stamina.maxima 的下一项（D3 已裁决
        -- 9/12/16 m/s 为准，此处只读配置不改数值）。
        local staminaMaxima = Config.upgrades.stamina.maxima or {}
        local nextStaminaMax = staminaMaxima[(tonumber(staminaLevel) or 0) + 1]
        local boatSpeeds = Config.upgrades.boatSpeed.metersPerSec or {}
        local currentSpeedIndex = (tonumber(player.boatSpeedLevel) or 0) + 1
        local currentSpeed = boatSpeeds[currentSpeedIndex]
        local nextSpeed = boatSpeeds[currentSpeedIndex + 1]
        setText(refs.staminaLevelText, "staminaLevelText",
            nextStaminaMax and ("体力上限 %d → %d"):format(tonumber(player.maxStamina) or 0, nextStaminaMax)
            or "体力已满级")
        setText(refs.speedLevelText, "speedLevelText",
            nextSpeed and ("航速 %s → %s m/s（共 %d 级）"):format(tostring(currentSpeed or "?"),
                tostring(nextSpeed), #boatSpeeds)
            or "航速已满级")
        for itemId, shopButton in pairs(refs.shopButtons) do
            local definition = assert(Items.GetDefinition(itemId))
            local stock = loop:GetShopStock(itemId)
            local label = definition.name .. " · ¥" .. tostring(definition.buyPrice)
            shopButton:SetText(stock > 0 and label or (definition.name .. " · 售罄"))
            local noMoney = player.money < definition.buyPrice
            local noSpace = not player.inventory:HasSpace()
            shopButton:SetDisabled(not inPort or not ready or busy or fishingRestricted
                or stock <= 0 or noMoney or noSpace)
            -- v2.2：库存与禁用原因独立成行，宽度不足时不再与按钮挤成一行。
            -- ⚠️ "X库存：N" 前缀是硬契约（GameLoopUISpec:169/171/182 断言
            -- "苹果库存：2" / "苹果库存：0"），只可追加原因，不可改写前缀。
            local reason = stock <= 0 and " · 今日售罄，次日补货" or noMoney and " · 金币不足，还差 ¥"
                .. tostring(definition.buyPrice - (player.money or 0))
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
        local sellAllText = sellableCount > 0 and ("全部卖出 · " .. tostring(sellableCount) .. " 件") or "全部卖出"
        local sellAllDisabled = not inPort or not ready or busy or fishingRestricted or sellableCount == 0
        refs.sellAll:SetText(sellAllText)
        refs.sellAll:SetDisabled(sellAllDisabled)
        -- v2.2：港口商店操作条也有一份「全部卖出」，两处同源同步。
        -- 契约：Circle1HUDReviewTests 用 find() 取**树序第一个**匹配按钮，
        -- 卡片顺序为 背包 → 商店 → 老人，故命中的始终是背包那一份；
        -- 这里同步状态避免用户看到两个按钮表现不一致。
        refs.portSellAll:SetText(sellAllText)
        refs.portSellAll:SetDisabled(sellAllDisabled)
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
        -- v2.2：老人卡已挂 cardHost（常驻层），不再需要"顺带打开信息屏"。
        -- 但海面点选流程（捕鱼选点/投掷选点）期间对话应让位——那时要点海面，
        -- 卡片压在选点上方会挡住目标。此时强制收起对话交互。
        if showElder and seaClickFlow then showElder = false end
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
        -- v2.1 §7.11：showElder 已改为信息滚动屏卡片，不再触发模态遮罩。
        local overlayShown = showEntry or showForced or showSettlement or showStory
            or showEnding or showOpening or showCompendium
        refs.overlay:SetVisible(overlayShown)
        fadeOpacity(refs.modalCard, overlayShown and 1 or 0)
        local storyTitle = storyDialog and storyDialog.kind == "elder" and "海岸边的老人" or "纸条"
        local overlayTitle = showEntry and "云存档" or showForced and "夜晚返港"
            or (showSettlement and "每日结算" or (showOpening and "海岸边的老人")
            or (showEnding and "第 7 天 · 结局" or (showStory and storyTitle
            or (showCompendium and "图鉴 · 成就" or ""))))
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
        -- v2.1 §7.13（用户 23:48「三个显示均独占，滚动屏不一起显示」）：
        -- 滚动屏三卡改为互斥，同一时刻只显示一张，避免并排挤占海面视野。
        -- 优先级：老人 > 背包 > 商店（后两者由下面的赋值再压制）。
        -- 契约核对（v2.3 二级化后，四套件已同步更新路径）：
        --  ① B2UITests：打开 → 点[展示 ▸] → findButtons("展示")=2（物品按钮）
        --  ② SevenDays：打开 → 点[给予 ▸] → "01 · "前缀行的[给予]
        --  ③ GameLoopUISpec：[给予 ▸] → [给予] → [结束对话]
        refs.elderPanel:SetVisible(showElder)
        -- v2.3 修复（SevenDays day2 复现）：菜单重置必须在**打开对话的上升沿**
        -- 触发，不能只在跨周目（generation 变化）时——同周目内第二天再开对话，
        -- menuLevel 会停留在上次遗留的 "give"/"show" 二级，分类键整体隐藏，
        -- 测试与用户都会"找不到给予 ▸"。
        -- 记录（transcript）与已问问题（elderAsked）仍按周目保留（跨天不丢对话史）。
        local elderNowOpen = loop.elderOpen == true
        if elderNowOpen and state.elderWasOpen ~= true then
            state.elderMenuLevel = "root"
            state.elderReviewOpen = false
            state.elderOptionsExpanded = false
        end
        state.elderWasOpen = elderNowOpen
        -- v2.1 §7.14 对话形态接线：开场白按"每次打开对话"初始化一次；
        -- 对话记录跨轮保留，玩家点问题后追加气泡并重建提问区。
        -- 跨周目（generation 变化）时清空记录重新开场。
        if showElder and state.elderOpenedGeneration ~= loop.generation then
            state.elderOpenedGeneration = loop.generation
            state.elderTranscript = {}
            state.elderAsked = {}
            local day0 = tonumber(player.day) or 1
            state.elderTranscript[#state.elderTranscript + 1] = {
                who = "elder",
                text = day0 <= 3
                    and "孩子，这海上讨生活，先听我把话说完。"
                    or "你来了。海上风大，坐稳了再说。",
            }
        end
        if showElder then
            local elderDay = tonumber(player.day) or 1
            local teachingDoneNow = type(loop.IsTeachingDone) == "function"
                and loop:IsTeachingDone()
            renderElderDialogue()
            -- v2.3 选项区三态接线：
            --   review（回看记录）> level2（二级列表）> level1（一级键）
            local elderReview = state.elderReviewOpen == true
            local elderExpanded = state.elderOptionsExpanded == true
            local elderLevel = state.elderMenuLevel or "root"
            local elderOptionsVisible = (not elderReview) or elderExpanded

            -- 主体：回看态显示记录，二级态显示二级列表，常态显示对话流
            refs.elderLogPanel:SetVisible(elderReview)
            refs.elderDialogue:SetVisible(not elderReview and elderLevel == "root")
            refs.elderDialogOverflow:SetVisible(not elderReview and elderLevel == "root")

            -- 底部：回看态分类键收起为把手（点开展开选项区，再点收起）；
            -- 全局键行（收起记录/结束对话）常驻，是回看态的唯一出口。
            refs.elderHandleRow:SetVisible(elderReview)
            refs.elderHandle:SetText(elderExpanded and "选项 ▾" or "选项 ▴")
            refs.elderCategoryRow:SetVisible(elderOptionsVisible and elderLevel == "root")
            refs.elderLevel2:SetVisible(elderOptionsVisible and elderLevel ~= "root")
            refs.elderLogToggle:SetText(elderReview and "收起记录 ▾" or "聊天记录")

            -- 二级标题与内容（互斥三选一）
            local level2Titles = {
                questions = "问老人一个问题（问过的不重复出现）",
                give = "选择要给老人的食物",
                show = "选择要给老人看的物品",
            }
            setText(refs.elderLevel2Title, "elderLevel2Title", level2Titles[elderLevel] or "")
            refs.elderQuestions:SetVisible(elderLevel == "questions")
            refs.elderGiveRows:SetVisible(elderLevel == "give")
            refs.elderShowRows:SetVisible(elderLevel == "show")
            refs.elderLensRow:SetVisible(elderLevel == "show")
            if elderLevel == "questions" then
                -- ⚠️ 真机修复（2026-10-08 反馈"问题选项显示但点不了"）：
                -- Bootstrap.Update 每帧调 hud.Refresh()，此处若无条件重建，
                -- 问题按钮每帧销毁重建——真机手指从按下到抬起之间按钮已被
                -- 替换，click 事件丢失（表现即"看得到点不动"）。离线测试
                -- 不跑帧循环，故测不出。加 key 缓存：仅当阶段/教学完成/
                -- 已问集合变化时才重建，其余帧 widget 引用稳定可点。
                local stage = (elderDay <= 3) and 1 or (elderDay <= 6 and 2 or 3)
                local askedInStage = {}
                for _, q in ipairs(ELDER_QUESTIONS) do
                    if q.stage == stage and state.elderAsked[q.id] == true then
                        askedInStage[#askedInStage + 1] = q.id
                    end
                end
                local questionsKey = stage .. "|" .. tostring(teachingDoneNow == true)
                    .. "|" .. table.concat(askedInStage, ",")
                if state.elderQuestionsBuiltKey ~= questionsKey then
                    buildElderQuestions(elderDay, teachingDoneNow)
                    state.elderQuestionsBuiltKey = questionsKey
                end
            end
        end
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
            -- v2.1 §7.14：教程三问已移入提问区（带※ 标记，点选后老人答复），
            -- 此静态教学块不再显示。showTeaching 保留仅为不改动上方取值。
            refs.elderTeaching:SetVisible(false)
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
