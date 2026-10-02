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

-- STEP-9 体型（倍率，表现层）：金枪鱼约为沙丁鱼两倍体长
local FISH_SCALE = {
    sardine = 1.0,
    tuna = 1.9,
}

-- STEP-9 Chase 白色尾迹线（R1 第二段）：世界坐标点列连线 + 实时末端
local function DrawChaseTrail(ctx, w, h, state, entity, ppm)
    local trail = entity.trail
    if not trail or #trail < 2 then return end
    nvgBeginPath(ctx)
    for i, p in ipairs(trail) do
        local px, py = Camera.WorldToScreen(w, h, state, p.x, p.y)
        if i == 1 then nvgMoveTo(ctx, px, py) else nvgLineTo(ctx, px, py) end
    end
    local tx, ty = Camera.WorldToScreen(w, h, state, entity.position.x, entity.position.y)
    nvgLineTo(ctx, tx, ty)
    nvgStrokeColor(ctx, nvgRGBA(240, 252, 250, 120))
    nvgStrokeWidth(ctx, 2.5)
    nvgStroke(ctx)
end

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

-- STEP-7 信号渲染（R1 信号链第一段）：
-- Attracted=聚集涟漪 / Flee 出水前=T1 上浮剪影 / 出水后=白色水花 / Wander=无信号

-- T1 上浮剪影：深色鱼影随深度渐显、微放大（depth 0 水下 → 1 水面）；
-- 外圈淡白提示环随深度增强（上浮是读海信号，需在海面上醒目可见）
local function DrawSilhouette(ctx, sx, sy, ppm, heading, depth)
    nvgSave(ctx)
    nvgTranslate(ctx, sx, sy)
    nvgRotate(ctx, -(heading or 0))
    local s = 1 + 0.2 * depth
    nvgBeginPath(ctx)
    nvgEllipse(ctx, 0, 0, 0.55 * ppm * s, 0.22 * ppm * s)
    nvgFillColor(ctx, nvgRGBA(14, 34, 52, math.floor(160 + 95 * depth)))
    nvgFill(ctx)
    nvgRestore(ctx)
    local ring = math.floor(40 + 110 * depth)
    if ring > 8 then
        nvgBeginPath(ctx)
        nvgEllipse(ctx, sx, sy, 1.5 * ppm, 1.0 * ppm)
        nvgStrokeColor(ctx, nvgRGBA(235, 250, 248, ring))
        nvgStrokeWidth(ctx, 1.6)
        nvgStroke(ctx)
    end
end

-- 聚集涟漪：3 道相位错开的扩散环（phase 由 FishSystem 的 rippleTimer 推进）
local function DrawRippleRings(ctx, sx, sy, ppm, phase)
    for i = 0, 2 do
        local p = (phase * 0.9 + i / 3) % 1
        local alpha = math.floor((1 - p) * 150)
        if alpha > 4 then
            nvgBeginPath(ctx)
            nvgEllipse(ctx, sx, sy, (0.6 + p * 2.6) * ppm, (0.35 + p * 1.6) * ppm)
            nvgStrokeColor(ctx, nvgRGBA(210, 245, 230, alpha))
            nvgStrokeWidth(ctx, 1.5)
            nvgStroke(ctx)
        end
    end
end

-- 出水水花：白色扩散环（splashTimer 0.6→0 线性衰减）
local function DrawSplash(ctx, sx, sy, ppm, splashTimer)
    local p = 1 - splashTimer / 0.6
    local alpha = math.floor((1 - p) * 230)
    nvgBeginPath(ctx)
    nvgEllipse(ctx, sx, sy, (0.5 + p * 3.2) * ppm, (0.3 + p * 2.0) * ppm)
    nvgStrokeColor(ctx, nvgRGBA(240, 252, 250, alpha))
    nvgStrokeWidth(ctx, 2.5)
    nvgStroke(ctx)
end

-- STEP-10 海鸟（俯视）：身体 + 后掠双翼，按朝向旋转
local function DrawSeabird(ctx, sx, sy, ppm, heading)
    nvgSave(ctx)
    nvgTranslate(ctx, sx, sy)
    nvgRotate(ctx, -(heading or 0))
    local s = ppm * 0.9
    -- 后掠双翼
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, 0.1 * s, 0)
    nvgLineTo(ctx, -0.55 * s, -0.50 * s)
    nvgLineTo(ctx, -0.15 * s, -0.10 * s)
    nvgClosePath(ctx)
    nvgMoveTo(ctx, 0.1 * s, 0)
    nvgLineTo(ctx, -0.55 * s, 0.50 * s)
    nvgLineTo(ctx, -0.15 * s, 0.10 * s)
    nvgClosePath(ctx)
    nvgFillColor(ctx, nvgRGBA(250, 250, 240, 235))
    nvgFill(ctx)
    -- 身体 + 头部
    nvgBeginPath(ctx)
    nvgEllipse(ctx, 0, 0, 0.55 * s, 0.15 * s)
    nvgFillColor(ctx, nvgRGBA(255, 255, 248, 245))
    nvgFill(ctx)
    nvgBeginPath(ctx)
    nvgEllipse(ctx, 0.5 * s, 0, 0.12 * s, 0.10 * s)
    nvgFillColor(ctx, nvgRGBA(235, 190, 130, 255)) -- 喙
    nvgFill(ctx)
    nvgRestore(ctx)
end

-- STEP-10 读海信号：Dive/Circle 时目标处的白色聚焦圈（玩家据此读出海面下有动静）
local function DrawBirdFocusRing(ctx, sx, sy, ppm)
    nvgBeginPath(ctx)
    nvgEllipse(ctx, sx, sy, 2.6 * ppm, 1.7 * ppm)
    nvgStrokeColor(ctx, nvgRGBA(240, 252, 250, 95))
    nvgStrokeWidth(ctx, 1.8)
    nvgStroke(ctx)
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
                -- STEP-7/9 按 FSM 状态渲染信号；Wander 仍无水面信号
                local stateName = entity.fsm and entity.fsm.current or "Wander"
                if stateName == "Flee" and (entity.riseTimer or 0) > 0 then
                    -- T1 上浮阶段：只画剪影（鱼体仍在水面下）
                    DrawSilhouette(ctx, sx, sy, pixelsPerMeter, entity.heading, entity.depth or 0)
                else
                    -- 捕食水花（Tuna 捕获瞬间）与 Flee 出水水花共用表现
                    if (entity.splashTimer or 0) > 0 then
                        DrawSplash(ctx, sx, sy, pixelsPerMeter, entity.splashTimer)
                    end
                    if stateName == "Chase" then
                        DrawChaseTrail(ctx, w, h, state, entity, pixelsPerMeter)
                    end
                    if stateName == "Attracted" then
                        DrawRippleRings(ctx, sx, sy, pixelsPerMeter, entity.rippleTimer or 0)
                    end
                    local color = FISH_COLORS[entity.fishKey] or KIND_COLORS.fish
                    local bodyScale = FISH_SCALE[entity.fishKey] or 1.0
                    DrawFish(ctx, sx, sy, pixelsPerMeter * bodyScale, entity.heading, color)
                end
            elseif entity.kind == "bait" then
                -- STEP-7 调试诱饵：橙色饵球 + 淡环
                nvgBeginPath(ctx)
                nvgEllipse(ctx, sx, sy, 0.7 * pixelsPerMeter, 0.7 * pixelsPerMeter)
                nvgFillColor(ctx, nvgRGBA(235, 150, 80, 235))
                nvgFill(ctx)
                nvgBeginPath(ctx)
                nvgEllipse(ctx, sx, sy, 1.6 * pixelsPerMeter, 1.6 * pixelsPerMeter)
                nvgStrokeColor(ctx, nvgRGBA(235, 170, 100, 90))
                nvgStrokeWidth(ctx, 1.5)
                nvgStroke(ctx)
            elseif entity.kind == "predator" then
                -- STEP-7 调试捕食者（Tuna Chase 替身）：深灰大鱼影
                nvgBeginPath(ctx)
                nvgEllipse(ctx, sx, sy, 2.2 * pixelsPerMeter, 0.9 * pixelsPerMeter)
                nvgFillColor(ctx, nvgRGBA(35, 45, 55, 220))
                nvgFill(ctx)
            elseif entity.kind == "bird" then
                -- STEP-10 海鸟：Dive/Circle 时在目标处画聚焦圈（读海信号）
                local stateName = entity.fsm and entity.fsm.current or "Cruise"
                if (stateName == "Dive" or stateName == "Circle")
                    and entity.target and entity.target.alive then
                    local tx, ty = Camera.WorldToScreen(w, h, state,
                        entity.target.position.x, entity.target.position.y)
                    DrawBirdFocusRing(ctx, tx, ty, pixelsPerMeter)
                end
                DrawSeabird(ctx, sx, sy, pixelsPerMeter, entity.heading)
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
