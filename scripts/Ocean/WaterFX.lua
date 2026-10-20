-- 近景海面动态效果（焦散 + DuDv UV 置换）：纯表现层，只读世界状态，不改玩法。
--
-- 技术路线（AB）：Lua + NanoVG + 图片纹理，不新增 GPU Shader。
-- 焦散贴图（water_caustic_light）按「世界平面网格分片 + 逐顶点仿射」贴到海面上，
-- 与 ImageArt.Plane / ImageArt.triangle 同一投影口径：所有锚点都是世界米制坐标，
-- 经 Ocean.Projection 投影，因此区域随船移动、随深度压缩，不是屏幕空间矩形。
--
-- 关于 DuDv（重要，不做视觉花招）：
--   NanoVG 的图片填充是固定的仿射采样，没有暴露可编程采样器，**无法**让 GPU 用
--   第二张纹理去偏移第一张纹理的 UV。所以这里不做「把 DuDv 当普通图叠上去」的
--   假置换，而是把 DuDv 用在当前接口真正能生效的地方——**逐顶点 UV 位移**：
--     1) 位移场从 Image 资源一次性解码成网格（R/G 中值 0.5，先减中值再缩放）；
--     2) 区域网格的每个顶点按它的世界位置采样 DuDv，得到 (dx, dy)；
--     3) 顶点 UV = 世界平铺 UV + (dx, dy) × strength；
--     4) 片内用两个三角形做仿射映射；相邻片共享顶点 UV → 沿公共边线性插值
--        完全一致，所以位移连续、没有接缝；焦散纹样被局部拉扯、扭曲。
--   这是真正的「用 DuDv 数据计算采样偏移并重新采样」，分辨率等于网格顶点数
--   （默认 7×7 顶点/区域）而不是逐像素；dudvStrength=0 即退回纯滚动。
--
-- 更新模型（与 SeaSurfaceEffects 一致）：所有动画值都由 voyage time 采样，
-- 不做累加、不持有跨帧可变状态；暂停时 time 冻结，效果自然静止，船移动也不会
-- 重置动画时间。

local Config = require("Ocean.Config")
local ImageArt = require("Ocean.ImageArt")
local Projection = require("Ocean.Projection")

local WaterFX = {}

local MAX_TILES_PER_SIDE = 12
-- 低于该屏幕尺寸的片直接跳过（亚像素）。
local MIN_TILE_PIXELS = 2
-- DuDv 解码网格分辨率（顶点数/边）：低频位移场足够，且只解码一次。
local DUDV_RESOLUTION = 16

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function numberOr(value, fallback)
    return finite(value) and value or fallback
end

--- 取近景海面效果配置（缺配置时返回空表，取值在下方各自收敛到默认值）。
---@return table
function WaterFX.Settings()
    local visual = Config.visual or {}
    return type(visual.nearWaterFX) == "table" and visual.nearWaterFX or {}
end

--- 效果是否启用。关闭后 Surface 完全跳过本模块，原有海面表现一字不变。
---@param settings table?
---@return boolean
function WaterFX.Enabled(settings)
    settings = settings or WaterFX.Settings()
    return settings.enabled == true
end

-- 昼夜强度：复用项目唯一的昼夜来源 clock（phase + progress），不新建时钟。
-- day：日出/日落两端自然衰减、正午最强；night：整体压到 nightScale。
---@param clock table?
---@param settings table?
---@return number multiplier 强度倍率
function WaterFX.DayFactor(clock, settings)
    settings = settings or WaterFX.Settings()
    local dayScale = clamp(numberOr(settings.dayScale, 1.0), 0, 2)
    local nightScale = clamp(numberOr(settings.nightScale, 0.28), 0, 1)
    if type(clock) ~= "table" then return dayScale end
    local phase = clock.phase
    local progress = clock.progress
    if not finite(progress) then
        local duration = clock.duration
        if not finite(duration) or duration <= 0 then
            duration = phase == "day" and clock.daySec or clock.nightSec
        end
        if finite(clock.elapsed) and finite(duration) and duration > 0 then
            progress = clock.elapsed / duration
        else
            progress = 0
        end
    end
    progress = clamp(numberOr(progress, 0), 0, 1)
    if phase == "day" then
        local arc = math.sin(math.pi * progress)
        return dayScale * (0.55 + 0.45 * arc)
    elseif phase == "night" then
        return nightScale
    end
    return dayScale
end

-- 纹理 UV：世界坐标 → 归一化纹理坐标。
-- 世界项让纹样钉在世界平面上（船动时水纹不跟着船漂）；时间项单独叠加，
-- 因此滚动动画与船位置完全解耦，船移动不会重置动画时间。
---@param worldX number
---@param worldY number
---@param tileMeters number
---@param scrollX number 归一化纹理单位/秒
---@param scrollY number
---@param time number
---@return number u, number v
function WaterFX.WorldUV(worldX, worldY, tileMeters, scrollX, scrollY, time)
    tileMeters = math.max(0.01, numberOr(tileMeters, 16))
    local u = numberOr(worldX, 0) / tileMeters + numberOr(scrollX, 0) * numberOr(time, 0)
    local v = numberOr(worldY, 0) / tileMeters + numberOr(scrollY, 0) * numberOr(time, 0)
    return u, v
end

--- 区域边缘渐隐（径向 smoothstep）：0=中心，1=边缘，>1 区域外。
---@param normalisedDistance number
---@param feather number 0..1 渐隐起始比例
---@return number 0..1
function WaterFX.EdgeFade(normalisedDistance, feather)
    feather = clamp(numberOr(feather, 0.6), 0.01, 0.99)
    local t = clamp((numberOr(normalisedDistance, 1) - feather) / (1 - feather), 0, 1)
    return 1 - t * t * (3 - 2 * t)
end

-- DuDv 解码：R/G 的中性值是 0.5（字节 128），必须先减中性值再放大。
-- 不能把 RGB 颜色直接当位移向量使用（那是常见的假置换）。
---@param r number 0..1
---@param g number 0..1
---@return number dx, number dy 范围约 -1..1
function WaterFX.DecodeDUDV(r, g)
    return (numberOr(r, 0.5) - 0.5) * 2, (numberOr(g, 0.5) - 0.5) * 2
end

-- DuDv 位移场：把 Image 资源一次性解码成 N×N 的双线性网格采样器。
-- 逐帧只做区间索引，不再回到像素级取色。
---@param image Image?
---@param resolution integer?
---@return table?
function WaterFX.DUDVSampler(image, resolution)
    -- 注意：引擎里的 Image、Color 是 userdata（lupa/tolua++ 绑定），不是 Lua table。
    -- 这里一律用鸭子类型探测（有方法/有字段即认），否则引擎下会静默返回 nil
    -- 使 DuDv 退化成纯滚动（曾在离线预览里复现过）。
    if image == nil or type(image.GetPixelBilinear) ~= "function" then return nil end
    local okWidth, width = pcall(image.GetWidth, image)
    if not okWidth or not finite(width) or width <= 0 then return nil end
    local okHeight, height = pcall(image.GetHeight, image)
    if not okHeight or not finite(height) or height <= 0 then return nil end
    resolution = math.max(2, math.floor(numberOr(resolution, DUDV_RESOLUTION)))
    local size = resolution + 1
    local field = {}
    for row = 0, resolution do
        for column = 0, resolution do
            local px = column / resolution * (width - 1)
            local py = row / resolution * (height - 1)
            local okColor, color = pcall(image.GetPixelBilinear, image, px, py)
            local dx, dy = 0, 0
            if okColor and color ~= nil and finite(color.r) and finite(color.g) then
                dx, dy = WaterFX.DecodeDUDV(color.r, color.g)
            end
            field[row * size + column + 1] = { dx = dx, dy = dy }
        end
    end
    return {
        resolution = resolution,
        width = width,
        height = height,
        ---@param u number
        ---@param v number
        ---@return number dx, number dy
        sample = function(u, v)
            local x = (numberOr(u, 0) % 1 + 1) % 1
            local y = (numberOr(v, 0) % 1 + 1) % 1
            local column = math.min(resolution - 1, math.floor(x * resolution))
            local row = math.min(resolution - 1, math.floor(y * resolution))
            local fx = x * resolution - column
            local fy = y * resolution - row
            local a = field[row * size + column + 1]
            local b = field[row * size + column + 2]
            local c = field[(row + 1) * size + column + 1]
            local d = field[(row + 1) * size + column + 2]
            if not (a and b and c and d) then return 0, 0 end
            local dx = (a.dx * (1 - fx) + b.dx * fx) * (1 - fy)
                + (c.dx * (1 - fx) + d.dx * fx) * fy
            local dy = (a.dy * (1 - fx) + b.dy * fx) * (1 - fy)
                + (c.dy * (1 - fx) + d.dy * fx) * fy
            return dx, dy
        end,
    }
end

-- 已解码的位移场缓存（按资源名）。加载/解码失败缓存 false，不再每帧重试。
local samplerCache = {}

--- 取（必要时加载并解码一次）DuDv 位移场。运行环境缺 Image/cache 时返回 nil，
--- 调用方自动退回纯滚动——不影响焦散本体。
---@param settings table
---@return table?
function WaterFX.ResolveSampler(settings)
    settings = settings or WaterFX.Settings()
    if settings.dudvEnabled == false then return nil end
    local name = settings.dudvName or "water_dudv_flow"
    local spec = ImageArt.GetSpec(name)
    if not spec then return nil end
    local cached = samplerCache[name]
    if cached ~= nil then return cached or nil end
    if cache == nil or type(cache.GetResource) ~= "function" then
        samplerCache[name] = false
        return nil
    end
    local ok, image = pcall(cache.GetResource, cache, "Image", spec.path)
    if not ok or image == nil or type(image.GetPixelBilinear) ~= "function" then
        samplerCache[name] = false
        print("[WaterFX] dudv unavailable (" .. tostring(spec.path) .. "); scroll-only")
        return nil
    end
    local sampler = WaterFX.DUDVSampler(image, settings.dudvResolution)
    samplerCache[name] = sampler or false
    if sampler then
        print("[WaterFX] dudv decoded " .. tostring(sampler.width) .. "x" .. tostring(sampler.height))
    end
    return sampler
end

--- 清空位移场缓存（测试/场景重建用）。
function WaterFX.ResetCaches()
    samplerCache = {}
end

--- 计算本帧的区域网格（不绘制），便于白盒测试与调试读数。
---@param anchor table 世界锚点
---@param settings table
---@return table plan
function WaterFX.Layout(anchor, settings)
    settings = settings or WaterFX.Settings()
    local sizeMeters = math.max(4, numberOr(settings.sizeMeters, 36))
    local cellMeters = math.max(0.5, numberOr(settings.cellMeters, 6))
    local columns = clamp(math.ceil(sizeMeters / cellMeters), 1, MAX_TILES_PER_SIDE)
    local cellX = sizeMeters / columns
    local cellY = cellX
    local halfSize = sizeMeters * 0.5
    local anchorX = numberOr(anchor and anchor.x, 0)
    local anchorY = numberOr(anchor and anchor.y, 0)
    local originX = anchorX - halfSize
    local originY = anchorY - halfSize
    local tiles = {}
    for row = 0, columns - 1 do
        for column = 0, columns - 1 do
            local x0 = originX + column * cellX
            local y0 = originY + row * cellY
            local centreX = x0 + cellX * 0.5
            local centreY = y0 + cellY * 0.5
            local dx = (centreX - anchorX) / halfSize
            local dy = (centreY - anchorY) / halfSize
            tiles[#tiles + 1] = {
                x0 = x0, y0 = y0,
                x1 = x0 + cellX, y1 = y0 + cellY,
                centreX = centreX, centreY = centreY,
                distance = math.sqrt(dx * dx + dy * dy),
            }
        end
    end
    return {
        columns = columns, rows = columns,
        cellX = cellX, cellY = cellY,
        sizeMeters = sizeMeters, halfSize = halfSize,
        originX = originX, originY = originY,
        tiles = tiles,
    }
end

-- 片元的抖动哈希：让边缘渐隐看起来是「焦散自然变稀」而不是一圈同心色阶。
local function tileHash(tile, seed)
    local value = (tile.centreX * 13.13 + tile.centreY * 7.77 + (seed or 0))
    value = value - math.floor(value)
    return value
end

-- 以三个顶点定仿射（UV → 屏幕），在 UV 空间画三角形再用图片图案填充。
-- 与 ImageArt.triangle 同思路；UV 已含 DuDv 位移，所以纹理确实被按位移场重采样。
---@return boolean
local function drawTriangle(ctx, image, alpha, ax, ay, au, av, bx, by, bu, bv, cx, cy, cu, cv)
    local du1, dv1 = bu - au, bv - av
    local du2, dv2 = cu - au, cv - av
    local det = du1 * dv2 - du2 * dv1
    if math.abs(det) < 1e-12 then return false end
    local m1 = ((bx - ax) * dv2 - (cx - ax) * dv1) / det
    local m2 = ((by - ay) * dv2 - (cy - ay) * dv1) / det
    local m3 = ((cx - ax) * du1 - (bx - ax) * du2) / det
    local m4 = ((cy - ay) * du1 - (by - ay) * du2) / det
    local tx = ax - m1 * au - m3 * av
    local ty = ay - m2 * au - m4 * av
    if math.abs(m1 * m4 - m2 * m3) < 1e-9 then return false end
    nvgSave(ctx)
    nvgTransform(ctx, m1, m2, m3, m4, tx, ty)
    nvgShapeAntiAlias(ctx, 0)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, au, av)
    nvgLineTo(ctx, bu, bv)
    nvgLineTo(ctx, cu, cv)
    nvgClosePath(ctx)
    nvgFillPaint(ctx, nvgImagePattern(ctx, 0, 0, 1, 1, 0, image, alpha))
    nvgFill(ctx)
    nvgRestore(ctx)
    return true
end

-- 一片拆两个三角形：四个角各自的 UV 来自逐顶点 DuDv 位移，
-- 相邻片共享角点 UV，沿公共边线性插值一致 → 无接缝。
-- horizonAt: 可选的「屏幕 x → 水天交界 y」函数。若整片的**最下沿**仍在水天交界线
-- 之上（y 更小），说明这片完全在天空里，直接剔除——焦散绝不能画到云和日月的区域。
local function drawTile(ctx, tile, image, alpha, project, uvOf, width, height, horizonAt)
    local x0, y0 = project(tile.x0, tile.y0, 0)
    if not x0 then return false end
    local x1, y1 = project(tile.x1, tile.y0, 0)
    local x2, y2 = project(tile.x1, tile.y1, 0)
    local x3, y3 = project(tile.x0, tile.y1, 0)
    if not x1 or not x2 or not x3 then return false end

    local minX = math.min(x0, x1, x2, x3)
    local maxX = math.max(x0, x1, x2, x3)
    local minY = math.min(y0, y1, y2, y3)
    local maxY = math.max(y0, y1, y2, y3)
    if maxX < -1 or minX > width + 1 or maxY < -1 or minY > height + 1 then return false end
    if maxX - minX < MIN_TILE_PIXELS and maxY - minY < MIN_TILE_PIXELS then return false end
    if horizonAt then
        -- 地平线是夹取横坐标的正抛物线：区间最大值在端点，跨中心时最小值在中心。
        -- 用区间内的**最低**地平线（= 最大 y 阈值）作保守判定：只要片的最下沿
        -- 高过它，整片就都在天空里。
        local left, right = horizonAt(minX), horizonAt(maxX)
        local ceiling = math.max(left, right)
        if minX <= width * 0.5 and maxX >= width * 0.5 then
            ceiling = math.max(ceiling, horizonAt(width * 0.5))
        end
        if maxY <= ceiling then return false end
    end

    local u0, v0 = uvOf(tile.x0, tile.y0)
    local u1, v1 = uvOf(tile.x1, tile.y0)
    local u2, v2 = uvOf(tile.x1, tile.y1)
    local u3, v3 = uvOf(tile.x0, tile.y1)
    local drew = drawTriangle(ctx, image, alpha,
        x0, y0, u0, v0, x1, y1, u1, v1, x2, y2, u2, v2)
    drew = drawTriangle(ctx, image, alpha,
        x0, y0, u0, v0, x2, y2, u2, v2, x3, y3, u3, v3) or drew
    return drew
end

-- 单层焦散：把区域网格铺一遍。返回实际绘制的片数。
local function drawLayer(ctx, plan, image, project, uvOf, baseAlpha, settings, width, height,
    horizonAt)
    local drew = 0
    local feather = numberOr(settings.feather, 0.62)
    local jitter = clamp(numberOr(settings.edgeJitter, 0.45), 0, 1)
    local seed = numberOr(settings.edgeJitterSeed, 0.17)
    for _, tile in ipairs(plan.tiles) do
        local fade = WaterFX.EdgeFade(tile.distance, feather)
        -- 抖动：边缘处按 hash 降权，把同心色阶打散成自然的稀疏。
        if fade < 0.999 then
            fade = fade * (1 - jitter * tileHash(tile, seed))
        end
        local alpha = baseAlpha * fade
        if alpha > 0.002 and drawTile(ctx, tile, image, alpha, project, uvOf, width, height,
            horizonAt) then
            drew = drew + 1
        end
    end
    return drew
end

--- 绘制近景海面动态效果。
---@param ctx NVGContextWrapper
---@param view table movement（含 viewportWidth/Height 与 camera）
---@param anchor table? 世界锚点；默认取相机（相机已在 Movement 里跟随船，且带平滑滞后）
---@param time number 航行时间（暂停时冻结）
---@param clock table? 昼夜 clock
---@param settings table?
---@return boolean drew, table? stats
function WaterFX.Draw(ctx, view, anchor, time, clock, settings)
    settings = settings or WaterFX.Settings()
    if not WaterFX.Enabled(settings) then return false, nil end
    if type(view) ~= "table" then return false, nil end
    local width, height = view.viewportWidth, view.viewportHeight
    if not finite(width) or not finite(height) or width <= 0 or height <= 0 then
        return false, nil
    end
    time = finite(time) and time or 0
    local dayFactor = WaterFX.DayFactor(clock, settings)
    local baseAlpha = clamp(numberOr(settings.alpha, 0.13), 0, 1) * dayFactor
    if baseAlpha <= 0.002 then return false, nil end

    local image = ImageArt.ImageHandle(ctx, settings.causticName or "water_caustic_light")
    if image <= 0 then return false, nil end

    local project = Projection.ProjectFunction(view)
    if not project then return false, nil end
    -- 水天交界曲线：整片落在天空里的网格直接剔除（焦散不得画到云和日月上）。
    local horizon = Projection.HorizonFunction(view)
    local horizonAt = nil
    if horizon then
        horizonAt = function(x)
            local y = horizon(clamp(x, 0, width))
            if finite(y) then return clamp(y, -height, height) end
            return height * numberOr(Config.camera and Config.camera.horizonY, 0.24)
        end
    end

    local anchorPoint = type(anchor) == "table" and anchor
        or (type(view.camera) == "table" and view.camera) or { x = 0, y = 0 }
    local plan = WaterFX.Layout(anchorPoint, settings)

    local scrollX = numberOr(settings.scrollX, 0.012)
    local scrollY = numberOr(settings.scrollY, 0.008)
    local tileMeters = math.max(1, numberOr(settings.tileMeters, 18))
    local dudvTile = math.max(1, numberOr(settings.dudvTileMeters, 26))
    local dudvStrength = 0
    local sampler = nil
    if settings.dudvEnabled ~= false then
        sampler = WaterFX.ResolveSampler(settings)
        dudvStrength = clamp(numberOr(settings.dudvStrength, 0.008), 0, 0.25)
        if not sampler then dudvStrength = 0 end
    end
    local dudvScrollX = numberOr(settings.dudvScrollX, 0.017)
    local dudvScrollY = numberOr(settings.dudvScrollY, -0.011)

    -- 顶点 UV：世界平铺坐标 + 时间滚动 + DuDv 位移（真正的采样偏移）。
    local function uvOf(worldX, worldY)
        local u, v = WaterFX.WorldUV(worldX, worldY, tileMeters, scrollX, scrollY, time)
        if dudvStrength > 0 then
            local su, sv = WaterFX.WorldUV(worldX, worldY, dudvTile,
                dudvScrollX, dudvScrollY, time)
            local dx, dy = sampler.sample(su, sv)
            u = u + dx * dudvStrength
            v = v + dy * dudvStrength
        end
        return u, v
    end

    local drew = drawLayer(ctx, plan, image, project, uvOf, baseAlpha, settings, width, height,
        horizonAt)

    -- 第二层（可选）：不同方向/速度/尺度，交叉出更自然的网；默认关闭。
    if settings.secondLayer == true and drew > 0 then
        local altImage = ImageArt.ImageHandle(ctx,
            settings.causticAltName or "water_caustic_light_alt")
        if altImage > 0 then
            local altScrollX = numberOr(settings.scrollXAlt, 0.021)
            local altScrollY = numberOr(settings.scrollYAlt, -0.014)
            local altTile = math.max(1, numberOr(settings.tileMetersAlt, tileMeters * 1.37))
            local altAlpha = clamp(numberOr(settings.secondLayerAlpha, 0.6), 0, 1)
            local function altUV(worldX, worldY)
                local u, v = WaterFX.WorldUV(worldX, worldY, altTile,
                    altScrollX, altScrollY, time)
                if dudvStrength > 0 then
                    local su, sv = WaterFX.WorldUV(worldX, worldY, dudvTile,
                        dudvScrollX, dudvScrollY, time)
                    local dx, dy = sampler.sample(su, sv)
                    u = u + dx * dudvStrength * 1.6
                    v = v + dy * dudvStrength * 1.6
                end
                return u, v
            end
            drew = drew + drawLayer(ctx, plan, altImage, project, altUV,
                baseAlpha * altAlpha, settings, width, height, horizonAt)
        end
    end

    if drew <= 0 then return false, nil end
    return true, {
        tiles = drew,
        columns = plan.columns,
        alpha = baseAlpha,
        dudv = dudvStrength > 0,
        dayFactor = dayFactor,
    }
end

return WaterFX
