-- 实体调试绘制（STEP-4 渲染通道）：只读 World 实体并画在海面上，不修改任何状态。
-- 坐标换算与 Main.ScreenPointToWorldMeters 同一模型：正交视高 45m，锚点比例 (boatX, 0.60)。
-- 这是 World 实体的唯一渲染入口；水面信号（涟漪/水花/剪影）后续在本模块扩展。
local Config = require("Ocean.Config")

local EntityDraw = {}

local KIND_COLORS = {
    debug_marker = { 255, 210, 90, 255 },
    fish = { 120, 200, 255, 255 },
    bird = { 255, 255, 255, 255 },
}

---@param ctx NVGContextWrapper
---@param w number 逻辑宽（像素）
---@param h number 逻辑高（像素）
---@param state table Ocean.State（只读 boatX）
---@param world table Game.World
function EntityDraw.Scene(ctx, w, h, state, world)
    if not world then return end
    local pixelsPerMeter = h / Config.world.viewHeight
    local anchorX = w * (state and state.boatX or 0.5)
    local anchorY = h * 0.60
    for _, entity in ipairs(world:GetEntities()) do
        if entity.alive and entity.position then
            local sx = anchorX + entity.position.x * pixelsPerMeter
            local sy = anchorY - entity.position.y * pixelsPerMeter
            local color = KIND_COLORS[entity.kind] or { 200, 200, 200, 255 }
            -- 调试标记：2m 半径外圈 + 4m 十字，全部以米定义、随视高缩放
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

return EntityDraw
