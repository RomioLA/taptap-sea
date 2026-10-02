-- 实体调试绘制（STEP-4 渲染通道）：只读 World 实体并画在海面上，不修改任何状态。
-- 坐标换算统一走 Ocean.Camera（STEP-6 修正）：世界原点钉在船初始位置锚点，
-- 不随船移动——修复"实体跟着船跑"（旧实现以当前锚点为原点，船动=全体平移）。
-- 这是 World 实体的唯一渲染入口；水面信号（涟漪/水花/剪影）后续在本模块扩展。
local Camera = require("Ocean.Camera")

local EntityDraw = {}

local KIND_COLORS = {
    debug_marker = { 255, 210, 90, 255 },
    fish = { 120, 200, 255, 255 },
    bird = { 255, 255, 255, 255 },
}

-- STEP-6 鱼种配色（sardine 银蓝 / tuna 深蓝，仅表现层，不改 AI）
local FISH_COLORS = {
    sardine = { 126, 183, 212, 235 },
    tuna = { 46, 82, 110, 255 },
}

-- 鱼体：身体椭圆 + 尾鳍三角，约 1.1m 体长，按朝向旋转（世界 y 向上，屏幕 y 向下故取负）
local function DrawFish(ctx, sx, sy, ppm, heading, color)
    nvgSave(ctx)
    nvgTranslate(ctx, sx, sy)
    nvgRotate(ctx, -(heading or 0))
    nvgBeginPath(ctx)
    nvgEllipse(ctx, 0, 0, 0.55 * ppm, 0.22 * ppm)
    nvgFillColor(ctx, nvgRGBA(color[1], color[2], color[3], color[4] or 255))
    nvgFill(ctx)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, -0.45 * ppm, 0)
    nvgLineTo(ctx, -0.85 * ppm, -0.20 * ppm)
    nvgLineTo(ctx, -0.85 * ppm, 0.20 * ppm)
    nvgClosePath(ctx)
    nvgFill(ctx)
    nvgRestore(ctx)
end

---@param ctx NVGContextWrapper
---@param w number 逻辑宽（像素）
---@param h number 逻辑高（像素）
---@param state table Ocean.State（只读 boatX）
---@param world table Game.World
function EntityDraw.Scene(ctx, w, h, state, world)
    if not world then return end
    local pixelsPerMeter = Camera.PixelsPerMeter(h)
    for _, entity in ipairs(world:GetEntities()) do
        if entity.alive and entity.position then
            local sx, sy = Camera.WorldToScreen(w, h, state, entity.position.x, entity.position.y)
            if entity.kind == "fish" then
                -- STEP-6 鱼体渲染；Wander 无水面信号（不画涟漪）
                local color = FISH_COLORS[entity.fishKey] or KIND_COLORS.fish
                DrawFish(ctx, sx, sy, pixelsPerMeter, entity.heading, color)
            else
                -- 调试标记：2m 半径外圈 + 4m 十字，全部以米定义、随视高缩放
                local color = KIND_COLORS[entity.kind] or { 200, 200, 200, 255 }
                nvgBeginPath(ctx)
                nvgEllipse(ctx, sx, sy, 2 * pixelsPerMeter, 2 * pixelsPerMeter)
                nvgStrokeColor(ctx, nvgRGBA(color[1], color[2], color[3], color[4] or 255))
                nvgStrokeWidth(ctx, 2)
                nvgStroke(ctx)
                nvgBeginPath(ctx)
                nvgMoveTo(ctx, sx - 4 * pixelsPerMeter, sy)
                nvgLineTo(ctx, sx + 4 * pixelsPerMeter, sy)
                nvgMoveTo(ctx, sx, sy - 4 * pixelsPerMeter)
                nvgLineTo(ctx, sx, sy + 4 * pixelsPerMeter)
                nvgStrokeWidth(ctx, 1)
                nvgStroke(ctx)
            end
        end
    end
end

return EntityDraw
