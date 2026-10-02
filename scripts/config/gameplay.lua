-- V1 游戏循环配置。所有可调参数集中在此处。
-- V1_IMPLEMENTATION_VALUE：用户确认的当前实现值；平衡目标另见设计契约。
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
        dailyStock = { apple = 2, bait = 2 },
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
    },
}


