-- 船镜头（STEP-6 修正）：正交视高 45m 的固定视口双向换算。
-- 世界原点 = 船初始位置的锚点（boatX = Config.boat.initialX 时的锚点），不随船移动。
-- 缺陷背景：此前 EntityDraw / 点击换算都以"当前锚点"为原点，船一动锚点平移，
-- 所有 World 实体被整体带着走（表现=鱼群跟着船跑，2026-10-02 预览验收发现）。
-- 船的世界偏移 = (boatX - initialX) × 可视宽度（米）——demo 的船是屏幕比例制，
-- 米制速度要等 M0 接入真实船世界坐标；届时只需替换 BoatWorldX 的实现，
-- WorldToScreen / ScreenToWorld 两个消费方不动。
local Config = require("Ocean.Config")

local Camera = {}

local ANCHOR_Y_RATIO = 0.60 -- 船锚点纵向比例（与 Main 旧换算一致）

function Camera.PixelsPerMeter(logicalH)
    return logicalH / Config.world.viewHeight
end

-- 可视宽度（米）：正交视高 × 宽高比（16:9 约 80m）
function Camera.ViewWidthMeters(logicalW, logicalH)
    return Config.world.viewHeight * (logicalW / logicalH)
end

-- 船的世界 x 偏移（米，相对世界原点=船初始位置）
function Camera.BoatWorldX(state, logicalW, logicalH)
    local boatX = state and state.boatX or Config.boat.initialX
    return (boatX - Config.boat.initialX) * Camera.ViewWidthMeters(logicalW, logicalH)
end

-- 世界（米）→ 逻辑屏幕（px）。返回 sx, sy。
function Camera.WorldToScreen(logicalW, logicalH, state, wx, wy)
    local ppm = Camera.PixelsPerMeter(logicalH)
    local anchorX = logicalW * (state and state.boatX or Config.boat.initialX)
    local anchorY = logicalH * ANCHOR_Y_RATIO
    local boatX = Camera.BoatWorldX(state, logicalW, logicalH)
    return anchorX + (wx - boatX) * ppm, anchorY - wy * ppm
end

-- 逻辑屏幕（px）→ 世界（米）。返回 wx, wy。
function Camera.ScreenToWorld(logicalW, logicalH, state, sx, sy)
    local ppm = Camera.PixelsPerMeter(logicalH)
    local anchorX = logicalW * (state and state.boatX or Config.boat.initialX)
    local anchorY = logicalH * ANCHOR_Y_RATIO
    local boatX = Camera.BoatWorldX(state, logicalW, logicalH)
    return (sx - anchorX) / ppm + boatX, -(sy - anchorY) / ppm
end

return Camera
