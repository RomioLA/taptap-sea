-- 海洋场景配置：所有位置以屏幕比例表达，横竖屏使用同一套层次。
local Config = {
    title = "海风小岛",
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
