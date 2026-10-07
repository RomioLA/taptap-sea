-- V1 游戏循环配置。所有可调参数集中在此处。
-- V1_IMPLEMENTATION_VALUE：用户确认的当前实现值；平衡目标另见设计契约。
local ItemRows = require("GeneratedData.Items")
local dailyStock = {}
for _, row in ipairs(ItemRows) do
    if row.shopStockPerDay ~= nil then
        dailyStock[row.id] = row.shopStockPerDay
    end
end
return {
    initial = {
        maxStamina = 100,
        stamina = 100,
        money = 100,
        day = 1,
        items = { "apple", "bait" },
    },
    stamina = {
        fishingCost = 40,
        salvageCost = 40,
        sailingCost = 0,
        eventOperationCost = 40,
    },
    -- 圈1共同协议已确认：约0.5秒落网、完整动作4秒；不是临时测试值。
    fishing = { landingSec = 0.5, durationSec = 4 },
    -- 用户确认木桶检查耗时4秒；进度使用昼夜游戏时钟，界面打开时随时钟暂停。
    barrel = { cost = 40, durationSec = 4, firstReward = { "apple", "bait" } },
    clock = {
        daySec = 120,
        nightSec = 60,
        graceSec = 30,
        penaltyPerSec = 1,
        forcedStaminaRatio = 0.5,
        -- T1（2026-10-06）：每轮 7 天；第 7 天结算即结局，不进入第 8 天。
        maxDay = 7,
    },
    inventory = {
        capacities = { 5, 10, 15, 20 },
    },
    shop = {
        dailyStock = dailyStock,
    },
    upgrades = {
        stamina = { maxima = { 100, 160, 200 }, prices = { 400, 600 } },
        inventory = { prices = { 300, 600, 900 } },
        boatSpeed = { metersPerSec = { 9.0, 12.0, 16.0 }, prices = { 350, 750 } },
    },
    drop = {
        lifetimeSec = 20,
    },
    location = {
        recognitionDistance = 20,
    },
    debug = {
        timeScales = { 1, 5, 20 },
        staminaStep = 20,
        moneyStep = 100,
    },
    persistence = {
        key = "sea_game_loop_v1",
        schemaVersion = 1,
        localFilename = "sea_loop_save.json",
    },
    -- 玩家界面设计方案 v1.0（2026-10-04）：海洋主题 token，HUD 表现层唯一取色来源。
    ui = {
        -- 圈1鱼获识别标签，仅用于展示，不改变捕获概率/价格或存档结构。
        -- 键名 textMuted/textGold 是 B 侧测试契约（Circle1HUDReviewTests 断言
        -- 行色 == palette[paletteKey]），键名不可改；v2.1 批B 把这两个键的
        -- **色值**改为墨棕（卡片已换水彩浅纸底，冷色不可读）。
        -- 海面信息层改用下方 seaTextMuted/seaTextGold 冷色，二者互不影响。
        fishDisplay = {
            sardine = { rarity = "普通", paletteKey = "textMuted" },
            tuna = { rarity = "稀有", paletteKey = "textGold" },
        },
        themeTransition = "backgroundColor 0.8s easeInOut",
        palette = {
            seaDeep = { 12, 68, 124, 242 },         -- #0C447C 操作坞/白天面板
            seaNight = { 4, 32, 62, 248 },          -- #04203E 夜间面板（更深，与海面明度反向）
            seaMid = { 24, 95, 165, 235 },          -- #185FA5 状态条
            actionPrimary = { 15, 110, 86, 255 },   -- #0F6E56 主行动青
            actionPressed = { 8, 80, 65, 255 },     -- #085041 按压态
            coinBright = { 250, 199, 117, 255 },    -- #FAC775 金币高亮
            coinDeep = { 133, 79, 11, 255 },        -- #854F0B 金币深色（浅底上用）
            warnCoral = { 216, 90, 48, 255 },       -- #D85A30 警示珊瑚
            textOnDark = { 230, 241, 251, 255 },    -- #E6F1FB 深面板正文
            -- 卡内墨色（v2.1 批B）：水彩浅纸底板上的文字，暖墨体系。
            -- textMuted/textGold 现为卡内色（鱼获行标签在卡片内，键名受测试契约保护）。
            textMuted = { 92, 70, 46, 255 },        -- #5C462E 卡内正文墨棕
            textGold = { 146, 96, 38, 255 },        -- #926026 卡内稀有/强调深金棕
            -- 海面信息层专用冷色（零底板叠在海面上，需冷色对比；勿用于卡内）。
            seaTextMuted = { 159, 225, 203, 255 },  -- #9FE1CB 信息层注释
            seaTextGold = { 250, 213, 130, 255 },   -- #FAD582 信息层警示金
            -- v2.1 批B：卡片层向水彩暖色收敛（Gameplay.UiKit.palette 同值）。
            -- 卡片已换水彩纸底板（image/WatercolorUI/ui_panels/），底板图本身
            -- 昼夜不变，夜间由 cardNight 衬色叠加压暗实现"同一张纸变深"。
            cardDay = { 255, 255, 255, 0 },         -- 白天全透明 = 原纸色
            cardNight = { 12, 20, 34, 165 },        -- 夜间冷蓝墨压暗
            border = { 150, 122, 86, 180 },         -- #967A56 暖棕描边（纸边同源）
            backdrop = { 4, 20, 40, 150 },          -- 抽屉背后压暗层
            disabledBg = { 96, 116, 138, 210 },     -- 禁用底（深面板系）
            disabledText = { 190, 204, 216, 220 },  -- 禁用文字
            infoStroke = { 10, 28, 46, 225 },       -- #0A1C2E 信息层文字描边（零底板可读）
            infoShadow = { 6, 16, 28, 150 },        -- 信息层文字投影
        },
        size = {
            touchMajor = 88,       -- 主操作按钮热区
            touchMinor = 64,       -- 次级圆钮视觉尺寸
            touchGap = 12,         -- 可点元素最小间距
            buttonMinHeight = 44,  -- 通用按钮最小触控高度
            radiusCard = 10,
            drawerHeightPct = "65%",
        },
    },
}


