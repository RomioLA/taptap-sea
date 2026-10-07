-- UI 套件单一令牌源（UI 套件重设计 v2.1 批A，2026-10-07）。
-- 合并 DialogueStyle（对白/教学/按钮皮肤）与 HUDPresentation 内嵌
-- FALLBACK_PALETTE（HUD 色板/尺寸）为唯一样式源：全局调样式只改本表。
-- 色板走向（拍板决策）：卡片层向水彩暖色收敛；海面信息层保持冷色可读性。
-- 纯数据模块：不依赖引擎，测试桩可直接加载。
local UiKit = {
    -- 字号层级：title=剧情/模态标题（17）；body=正文（14）；button=按钮（13）；
    -- info=信息层（13）；teaching=教学/引导行（12）；small=辅助小字（12）。
    fontSize = { title = 17, body = 14, button = 13, info = 13, teaching = 12, small = 12 },

    -- 对白/教学文字（深底用，兼容 DialogueStyle.color 旧引用）：
    -- body=暖米白正文，teaching=教学金，dim=辅助弱化。
    color = {
        body = { 255, 236, 207, 255 },
        teaching = { 237, 213, 159, 255 },
        dim = { 180, 207, 216, 255 },
    },

    -- HUD 色板（兼容原 FALLBACK_PALETTE 全部键；卡片三键已暖色收敛）。
    palette = {
        -- 海面/氛围层（保持深海蓝绿，信息层文字对比不受影响）。
        seaDeep = { 12, 68, 124, 242 },
        seaNight = { 4, 32, 62, 248 },
        seaMid = { 24, 95, 165, 235 },
        backdrop = { 4, 20, 40, 150 },
        -- 动作/反馈色（不变）。
        actionPrimary = { 15, 110, 86, 255 },
        actionPressed = { 8, 80, 65, 255 },
        coinBright = { 250, 199, 117, 255 },
        coinDeep = { 133, 79, 11, 255 },
        warnCoral = { 216, 90, 48, 255 },
        -- 文字：textMuted/textGold 现为**卡内墨色**（鱼获行标签在卡片内，
        -- 键名受 Circle1HUDReviewTests 契约保护不可改；色值即卡内色）。
        -- 海面信息层（零底板叠海面）必须用 seaTextMuted/seaTextGold 冷色。
        textOnDark = { 230, 241, 251, 255 },
        textMuted = { 92, 70, 46, 255 },       -- == ink.body 卡内正文墨棕
        textGold = { 146, 96, 38, 255 },       -- == ink.teaching 卡内深金棕
        seaTextMuted = { 159, 225, 203, 255 }, -- #9FE1CB 海面信息层注释（冷色）
        seaTextGold = { 250, 213, 130, 255 },  -- #FAD582 海面信息层警示金（冷色）
        -- 卡片层：暖色收敛（v2.1）。卡片已换水彩纸底板，底板图昼夜不变，
        -- 白天衬色全透明（= 原纸色），夜间叠冷蓝墨压暗（= 同一张纸变深），
        -- 由 themer 注册表逐通道插值过渡。改这两个值即改全站卡片昼夜氛围。
        cardDay = { 255, 255, 255, 0 },
        cardNight = { 12, 20, 34, 165 },
        border = { 150, 122, 86, 180 },
        -- 兜底/禁用/信息描边（不变）。
        disabledBg = { 96, 116, 138, 210 },
        disabledText = { 190, 204, 216, 220 },
        infoStroke = { 10, 28, 46, 225 },
        infoShadow = { 6, 16, 28, 150 },
    },

    -- 卡内墨棕文字系（浅色水彩纸上使用；换底板时只调本表）。
    -- body/teaching 与 palette.inkBody/inkGold 同值——后者是给
    -- "config 驱动取色"路径（config.ui.fishDisplay[].paletteKey）用的，
    -- 契约要求行色 == Config.ui.palette[paletteKey]；两处必须同步改。
    ink = {
        title = { 74, 54, 32, 255 },
        body = { 92, 70, 46, 255 },        -- == palette.inkBody
        teaching = { 146, 96, 38, 255 },   -- == palette.inkGold
        dim = { 128, 104, 76, 255 },
    },

    -- 尺寸令牌（兼容原 UI_SIZE；config.ui.size 可逐键覆盖）。
    size = { touchMajor = 88, touchMinor = 64, touchGap = 12, buttonMinHeight = 44, radiusCard = 10 },

    -- 教学行统一前缀：一眼可辨"这是教学不是剧情"（圈2 决策 A6 配套）。
    teachMark = "※ ",

    -- 批3b 按钮水彩底板（v2.0 §7.2/§7.5 D5）：button_states 药丸底板三态，
    -- sliced 九宫格拉伸（源图约 789×191，四边 40px 圆头）；浅底深棕字。
    button = {
        slice = { 40, 40, 40, 40 },
        textColor = { 74, 54, 32, 255 },
        primary = {
            normal = "image/WatercolorUI/button_states/006_447-631.png",  -- pill_gold
            pressed = "image/WatercolorUI/button_states/002_446-137.png", -- pill_cream
        },
        secondary = {
            normal = "image/WatercolorUI/button_states/002_446-137.png",  -- pill_cream
            pressed = "image/WatercolorUI/button_states/004_444-384.png", -- pill_gray
            disabled = "image/WatercolorUI/button_states/004_444-384.png",
        },
    },

    -- 旧对白卡纯色参数（兼容 DialogueStyle.card 旧引用；新代码用 cardProps）。
    card = { backgroundColor = { 45, 64, 61, 220 }, borderRadius = 8, padding = 10 },
}

-- 卡片水彩底板皮肤（批B）：ui_panels 切片（tests/slice_ui_panels.py 产物），
-- sliced 九宫格拉伸；slice 取值需大于各面板的绘画边宽。
--   panel     = 圆角茶棕卡（通用：背包/港口/木桶/投掷/捕鱼/调试）
--   parchment = 羊皮纸粗边框（剧情卡：模态对白/结局/强制返港）
--   plain     = 素面纸卡（轻量浮层：成就 toast/捕鱼结果气泡/渔获待领）
local CARD_SKINS = {
    panel = {
        image = "image/WatercolorUI/ui_panels/002_865-190.png",
        slice = 40,
        padding = 10,
    },
    parchment = {
        image = "image/WatercolorUI/ui_panels/001_297-191.png",
        slice = 48,
        padding = 14,
    },
    plain = {
        image = "image/WatercolorUI/ui_panels/004_865-577.png",
        slice = 28,
        padding = 8,
    },
}

-- 卡片 Panel props 生成（背景图 + 昼夜衬色兜底 + 纵向布局默认值）。
-- extra：调用方覆盖/追加布局属性（id/width/position 等），后到者胜。
function UiKit.cardProps(kind, extra)
    local skin = CARD_SKINS[kind] or CARD_SKINS.panel
    local props = {
        backgroundImage = skin.image,
        backgroundFit = "sliced",
        backgroundSlice = { skin.slice, skin.slice, skin.slice, skin.slice },
        backgroundColor = UiKit.palette.cardDay,
        padding = skin.padding,
        gap = 7,
        flexDirection = "column",
        borderWidth = 0,
        borderRadius = UiKit.size.radiusCard or 10,
        transition = "backgroundColor 0.8s easeInOut",
    }
    if extra then
        for key, value in pairs(extra) do props[key] = value end
    end
    return props
end

-- 语义文字色访问器：卡内文字随皮肤走，避免调用方散写 RGBA。
-- day：浅纸上的墨棕；night：夜间压暗后仍需足够对比，浅一档。
UiKit.inkNight = {
    title = { 226, 214, 196, 255 },
    body = { 208, 196, 178, 255 },
    teaching = { 236, 196, 122, 255 },
    dim = { 172, 162, 148, 255 },
}

--- 取一组文字色（按昼夜阶段）。
-- kind: "ink"（卡内墨色，默认）| "color"（对白浅色，历史遗留深底界面）
-- phase: "day"（默认）| "night"
function UiKit.text(kind, role, phase)
    local day = (kind == "color") and UiKit.color or UiKit.ink
    if phase == "night" then return UiKit.inkNight[role] or day[role] or UiKit.inkNight.body end
    return day[role] or UiKit.ink.body
end

-- 按钮皮肤 props 生成；无皮肤定义时返回 nil（调用方回退默认样式）。
-- 兼容 DialogueStyle.buttonProps 旧签名（primary/secondary/其他→secondary）。
function UiKit.buttonProps(variant)
    local skin = UiKit.button and (UiKit.button[variant] or UiKit.button.secondary)
    if not skin then return nil end
    return {
        textColor = UiKit.button.textColor,
        backgroundFit = "sliced",
        backgroundSlice = UiKit.button.slice,
        backgroundImage = skin.normal,
        pressedBackgroundImage = skin.pressed,
        disabledBackgroundImage = skin.disabled,
    }
end

-- 教学行统一前缀处理；多行文本每行都加前缀。
function UiKit.teachingText(text)
    if type(text) ~= "string" or text == "" then return text end
    local marked = text:gsub("([^\n]+)", UiKit.teachMark .. "%1")
    return marked
end

return UiKit
