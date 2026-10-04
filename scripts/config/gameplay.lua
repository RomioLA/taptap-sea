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
        boatSpeed = { metersPerSec = { 6.0, 8.0, 10.0 }, prices = { 350, 750 } },
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
}


