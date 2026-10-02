-- 海洋场景配置：所有位置以屏幕比例表达，横竖屏使用同一套层次。
local Config = {
    title = "海风小岛",
    -- 米制世界常量（STEP-3 坐标基座）：所有距离/速度统一米，来源=第一版参数表。
    world = {
        unit = 1,          -- 1 world unit = 1m（参数表「世界单位」）
        viewHeight = 45,   -- 正交可视高度 45m；16:9 约 80m 宽（参数表「船镜头」）
        worldSize = 1800,  -- 1800×1800m = 最大船速 10m/s × 180s（参数表「地图/世界结构」）
    },
    boatSpeedLevels = { 6, 8, 10 }, -- m/s（参数表「船移动」；M0 接入真实船逻辑时消费）
    -- STEP-5 昼夜时钟（参数表「GameClock」「夜晚处罚」「昼夜视觉」）
    clock = {
        dayLength = 120,         -- 白天 120s
        nightLength = 60,        -- 夜晚 60s；耗尽自动结束当天（「夜晚强制返港」）
        nightGraceSeconds = 30,  -- 夜晚前 30s 安全，之后每晚 1 秒减 1 体力（M1 消费）
        nightOverlayAlpha = 190, -- 夜间遮罩透明度，190/255≈75% 黑蓝
    },
    debug = {
        spawnTestEntity = true, -- STEP-4 渲染通道验证：生成 1 个调试实体；FishSystem 落地后关闭
        sardineCount = 8,       -- STEP-6 初始沙丁鱼数（正式区域密度 20/4 属 M2 区域生成）
    },
    -- STEP-6 鱼群 Wander（键名用 fishSystem：脚手架的 fish=装饰鱼群数组仍被 Draw 消费，
    -- 同名会被表构造器覆盖——19:57 预览崩溃根因，勿改回）
    fishSystem = {
        wanderRetargetMin = 2, -- 每 2~4s 换方向（参数表「Wander」）
        wanderRetargetMax = 4,
        worldMargin = 30,      -- 距世界边缘 30m 内目标朝向回指中心（1800m 地图内不贴边）
    },
    layers = {
        birds = 0.21,
        waves = 0.32,
        fish = 0.44,
        boat = 0.61,
        island = 0.83,
    },
    boat = {
        initialX = 0.5,
        minX = 0.18,
        maxX = 0.82,
        speed = 0.24,
        buttonStep = 0.12,
    },
    birds = {
        { x = 0.39, phase = 0, scale = 1 },
        { x = 0.62, phase = 1.8, scale = 0.82 },
    },
    fish = {
        { x = 0.38, phase = 0, direction = 1, color = { 255, 165, 112, 255 } },
        { x = 0.65, phase = 2.4, direction = -1, color = { 176, 238, 218, 255 } },
    },
}

return Config
