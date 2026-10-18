-- 平面 PNG 的只读投影适配：复用现有世界投影/裁剪，不持有实体或更新游戏。
local Projection = require("Ocean.Projection")
local Geometry = require("Ocean.ProjectedGeometry")
local Config = require("Ocean.Config")
local Art = {}
local contexts = setmetatable({}, { __mode = "k" })
local catalog = require("GeneratedData.OceanImageCatalog")
local ArtVariants = require("Ocean.ArtVariants")

-- 绘制 LOD（P1，2026-10-06）：按四角投影后的屏幕包围盒选细分档位。
-- 旧实现固定 ceil(length/3) 细分（上限 8×8=128 三角片、每片一次独立 nvgFill），
-- 移动端扇出过大。现在：≥256px 用 4×4、≥64px 用 2×2、更小用单四边形、
-- <2px 直接剔除；岛屿跨地平线，最低保持 2×2 防岸线仿射畸变。
local LOD_TINY_PX, LOD_SMALL_PX, LOD_MID_PX = 2, 64, 256
-- 岛屿类图片：最低细分档 2×2（远景单四边形会压平岸线曲率）。
local MIN_GRID_2 = { island = true, island_story = true }
-- 竖幅公告板（Art.Upright）最小绘制高度：更小的直接在像素级以下剔除。
local UPRIGHT_MIN_PX = 2

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- P0：nvgFill 计数（SeaDebug 性能行读数）。无条件累计，读取即清零。
local fillCounter = 0
function Art.FillsSnapshotAndReset()
    local count = fillCounter
    fillCounter = 0
    return count
end

-- 只返回规格副本，调用者不能改写共享目录或运行时图片句柄。
function Art.GetSpec(name)
    local spec = catalog[name]
    if not spec then return nil end
    return { path = spec.path, pixelWidth = spec.pixelWidth, pixelHeight = spec.pixelHeight,
        contentWidth = spec.contentWidth, contentHeight = spec.contentHeight,
        anchorX = spec.anchorX, anchorY = spec.anchorY,
        preload = spec.preload, repeatTexture = spec.repeatTexture,
        completeIsland = spec.completeIsland }
end

-- 库内候选显式加载：preload=true 基础图与（ArtVariants 开启时）story 变体
-- 随场景启动装入；其余候选保持按需，由 Plane/WaterPaper 首次使用时触发。
---@param ctx NVGContextWrapper
---@param name string
function Art.LoadImage(ctx, name)
    local spec = catalog[name]
    if not spec or type(nvgCreateImage) ~= "function" then return false end
    local images = contexts[ctx]
    if not images then
        images = {}
        contexts[ctx] = images
    end
    if images[name] ~= nil then return images[name] > 0 end
    local flags = spec.repeatTexture
        and (NVG_IMAGE_REPEATX | NVG_IMAGE_REPEATY | NVG_IMAGE_GENERATE_MIPMAPS)
        or NVG_IMAGE_GENERATE_MIPMAPS
    -- 卡顿排查埋点（2026-10-15）：story 变体默认随场景启动预载（见 Art.Load），
    -- 运行中切换 StoryArt 触发的按需加载仍会在此打出单帧尖峰；loadMs 直接量化。
    local loadStartMs = (type(os) == "table" and type(os.clock) == "function") and os.clock() * 1000 or nil
    local handle = nvgCreateImage(ctx, spec.path, flags) or -1
    images[name] = handle
    if handle > 0 then
        local loadMs = loadStartMs and ((os.clock() * 1000) - loadStartMs) or nil
        print("[OceanArt] loaded " .. name .. " path=" .. spec.path
            .. (loadMs and (" loadMs=" .. string.format("%.1f", loadMs)) or ""))
    else
        print("[OceanArt] load failed " .. spec.path .. "; retaining vector fallback")
    end
    return handle > 0
end

---@param ctx NVGContextWrapper
function Art.Load(ctx)
    for name, spec in pairs(catalog) do
        if spec.preload then Art.LoadImage(ctx, name) end
    end
    -- 2026-10-15 修复（卡顿排查根因）：story 变体 preload=false 且自批1接入
    -- （59c1f9b）起没有任何加载路径——Art.Load 只载 preload=true 的基础图，
    -- Plane/Sprite/WaterPaper 解析到 story 名后 images[name] 恒为 nil；
    -- ArtVariants 默认开启，导致全量静默走矢量回退（SeaDebug 读数 Fill 0/f，
    -- Draw 111ms 的主因之一）。变体开启时随场景启动预载，把同步解码+上传的
    -- 成本移到加载期，避免首帧绘制尖峰。
    if ArtVariants.IsEnabled() then
        for _, storyName in ipairs(ArtVariants.StoryTargets()) do
            if catalog[storyName] then Art.LoadImage(ctx, storyName) end
        end
    end
end

---@param ctx NVGContextWrapper
function Art.Release(ctx)
    local images = contexts[ctx]
    if not images then return end
    for _, handle in pairs(images) do
        if handle > 0 then nvgDeleteImage(ctx, handle) end
    end
    contexts[ctx] = nil
end

function Art.IsLoaded(ctx, name)
    local images = contexts[ctx]
    return images ~= nil and (images[name] or 0) > 0
end

-- 每个三角片用三个实际投影点计算 UV→屏幕仿射矩阵。
-- 大岛分片，小船分片；不能整张斜视图片做屏幕旋转，也不修改摄像机。
-- projected 走模块级 scratch 复用（同帧同步消费，无跨帧别名），削减每帧 GC 压力。
local projectedScratch = {}
local function triangle(ctx, movement, image, a, b, c, alpha, frame)
    -- 先在世界平面裁剪，再为裁剪顶点恢复 UV。不能用曲线中点配原端点
    -- 仿射矩阵，否则跨地平线的片会把岸线采样成透明留白。
    local clipped = Geometry.ClipPolygon(movement, { a, b, c })
    if #clipped < 3 then return false end
    local dx1, dy1, dx2, dy2 = b.x - a.x, b.y - a.y, c.x - a.x, c.y - a.y
    local worldDet = dx1 * dy2 - dx2 * dy1
    if math.abs(worldDet) < 1e-12 then return false end
    local projectedCount = 0
    for _, point in ipairs(clipped) do
        local dx, dy = point.x - a.x, point.y - a.y
        local s, t = (dx * dy2 - dy * dx2) / worldDet, (dx1 * dy - dy1 * dx) / worldDet
        local x, y = frame.project(point.x, point.y, point.altitude)
        if not x then return false end
        projectedCount = projectedCount + 1
        local entry = projectedScratch[projectedCount]
        if not entry then entry = {}; projectedScratch[projectedCount] = entry end
        entry.x, entry.y = x, y
        entry.u = a.u + (b.u - a.u) * s + (c.u - a.u) * t
        entry.v = a.v + (b.v - a.v) * s + (c.v - a.v) * t
    end
    for index = 2, projectedCount - 1 do
        local p, q, r = projectedScratch[1], projectedScratch[index], projectedScratch[index + 1]
        local du1, dv1, du2, dv2 = q.u - p.u, q.v - p.v, r.u - p.u, r.v - p.v
        local uvDet = du1 * dv2 - du2 * dv1
        if math.abs(uvDet) > 1e-12 then
            local m1 = ((q.x - p.x) * dv2 - (r.x - p.x) * dv1) / uvDet
            local m2 = ((q.y - p.y) * dv2 - (r.y - p.y) * dv1) / uvDet
            local m3 = ((r.x - p.x) * du1 - (q.x - p.x) * du2) / uvDet
            local m4 = ((r.y - p.y) * du1 - (q.y - p.y) * du2) / uvDet
            local tx, ty = p.x - m1 * p.u - m3 * p.v, p.y - m2 * p.u - m4 * p.v
            local det = m1 * m4 - m2 * m3
            if math.abs(det) > 1e-7 then
                local screen = { p, q, r }
                if a.altitude == 0 and b.altitude == 0 and c.altitude == 0 then
                    screen = Geometry.ClipScreenPolygon(movement, screen, 1)
                end
                if #screen >= 3 then
                    nvgSave(ctx)
                    nvgTransform(ctx, m1, m2, m3, m4, tx, ty)
                    nvgShapeAntiAlias(ctx, 0)
                    nvgBeginPath(ctx)
                    for pointIndex, point in ipairs(screen) do
                        local dx, dy = point.x - tx, point.y - ty
                        local u, v = (m4 * dx - m3 * dy) / det, (-m2 * dx + m1 * dy) / det
                        if pointIndex == 1 then nvgMoveTo(ctx, u, v) else nvgLineTo(ctx, u, v) end
                    end
                    nvgClosePath(ctx)
                    nvgFillPaint(ctx, nvgImagePattern(ctx, 0, 0, 1, 1, 0, image, alpha))
                    fillCounter = fillCounter + 1
                    nvgFill(ctx)
                    nvgRestore(ctx)
                end
            end
        end
    end
    return true
end

---@param ctx NVGContextWrapper
---@param name string
---@param movement table
---@param origin table
---@param length number 图片横轴对应的米制长度。
---@param width number 图片纵轴对应的米制宽度。
---@param heading number 世界弧度，0 朝 +X。
---@param altitude number?
---@param alpha number?
---@param roll number?
function Art.Plane(ctx, name, movement, origin, length, width, heading, altitude, alpha, roll)
    name = ArtVariants.Resolve(name)
    local images = contexts[ctx]
    local image = images and images[name] or 0
    if image <= 0 then
        -- 按需加载（2026-10-15 修复）：覆盖 SeaDebug 运行中切换 StoryArt 的场景；
        -- 启动预载漏项（如变体当时关闭）也在此兜底。加载失败时 -1 已缓存，
        -- 不会每帧重试，保持矢量回退语义。
        Art.LoadImage(ctx, name)
        images = contexts[ctx]
        image = images and images[name] or 0
        if image <= 0 then return false end
    end
    local cosine, sine = math.cos(heading or 0), math.sin(heading or 0)
    local rollSin = math.sin(roll or 0)
    local function vertex(u, v)
        local along, across = (u - 0.5) * length, (0.5 - v) * width
        return { x = origin.x + cosine * along - sine * across,
            y = origin.y + sine * along + cosine * across,
            altitude = (altitude or 0) + across * rollSin, u = u, v = v }
    end
    local corners = { vertex(0, 0), vertex(1, 0), vertex(1, 1), vertex(0, 1) }
    if not Geometry.WorldBoundsVisible(movement, corners) then return true end
    local frame = { project = Projection.ProjectFunction(movement), horizon = Projection.HorizonFunction(movement) }
    if not frame.project then return true end
    -- LOD 选档：四角投影求屏幕包围盒，取代旧的固定 length/3 细分。
    local minX, minY, maxX, maxY
    for index = 1, 4 do
        local corner = corners[index]
        local x, y = frame.project(corner.x, corner.y, corner.altitude)
        if not x then return true end
        if not minX or x < minX then minX = x end
        if not maxX or x > maxX then maxX = x end
        if not minY or y < minY then minY = y end
        if not maxY or y > maxY then maxY = y end
    end
    local extent = math.max(maxX - minX, maxY - minY)
    if extent < LOD_TINY_PX then return true end
    local minGrid = MIN_GRID_2[name] and 2 or 1
    local columns, rows
    if extent < LOD_SMALL_PX then
        columns, rows = minGrid, minGrid
    elseif extent < LOD_MID_PX then
        columns, rows = math.max(minGrid, 2), math.max(minGrid, 2)
    else
        columns, rows = 4, 4
    end
    for row = 1, rows do
        for column = 1, columns do
            local u0, u1 = (column - 1) / columns, column / columns
            local v0, v1 = (row - 1) / rows, row / rows
            local a, b, c, d = vertex(u0, v0), vertex(u1, v0), vertex(u1, v1), vertex(u0, v1)
            triangle(ctx, movement, image, a, b, c, alpha or 1, frame)
            triangle(ctx, movement, image, a, c, d, alpha or 1, frame)
        end
    end
    return true
end

-- 内容主体世界尺寸 → 画幅（UV 0-1）世界尺寸。缩放口径按 catalog 实测内容比逐素材
-- 计算，替代历史硬编码 0.88（那只对旧版 island/boat 的 900/1024 成立；story 版
-- island 是 730/1024=0.713，旧口径令岛贴图只画到世界半径的 0.80）。
-- 调用方拿返回值走 Plane（保留其懒加载与岛屿 LOD 契约）；目录缺失返回 nil。
---@param name string
---@param contentLength number 内容主体沿 u 的世界长度（米）。
---@param contentWidth number? 内容主体沿 v 的世界宽度（米）；省略保持源图主体比例。
---@return number?, number?
function Art.ContentPlaneSize(name, contentLength, contentWidth)
    local spec = catalog[ArtVariants.Resolve(name)]
    if not spec or not spec.contentWidth or spec.contentWidth <= 0
        or not spec.contentHeight or spec.contentHeight <= 0 then return nil end
    if type(contentLength) ~= "number" or contentLength <= 0 then return nil end
    local width = contentWidth or contentLength * spec.contentHeight / spec.contentWidth
    if type(width) ~= "number" or width <= 0 then return nil end
    return contentLength * spec.pixelWidth / spec.contentWidth,
        width * spec.pixelHeight / spec.contentHeight
end

-- 竖幅公告板（2026-10-16，方案 A：正视图素材的投影模式修正）。
-- 树/沙丘等正视图贴图不再平铺在世界平面（会被斜投影压扁剪切、丢失矢量版的立体高度），
-- 改绘为相机朝向的竖面：底沿落在世界锚点、高度=世界米制、宽度按源图内容宽高比推导。
-- 本投影下世界 altitude 直接映射为屏幕向上（×该深度 scale），竖幅与真三维竖面投影等价
-- （屏幕矩形画法沿用 MIF 归档 Art.Layer，锚点/scale 取自 Projection.ProjectFunction）。
-- 内容主体居中假设（内容中心≈画布中心，误差≤2%）：若未来素材内容偏心，
-- 需在 catalog 增加 contentX/contentY 偏移字段后再扩展（同 MIF 归档约定）。
-- 不做朝向旋转：树/沙丘不需要；若需按 heading 旋转再扩展。
---@param ctx NVGContextWrapper
---@param name string
---@param movement table
---@param position table 世界锚点（内容主体底沿中心）
---@param worldHeight number 内容主体高度（米）
---@param alpha number?
function Art.Upright(ctx, name, movement, position, worldHeight, alpha)
    name = ArtVariants.Resolve(name)
    local spec = catalog[name]
    if not spec or type(worldHeight) ~= "number" or worldHeight <= 0
        or not spec.contentWidth or spec.contentWidth <= 0
        or not spec.contentHeight or spec.contentHeight <= 0 then return false end
    -- 懒加载（与 Plane 同口径）：decor 素材 preload=false，首次绘制时加载；
    -- 失败不缓存重试路径之外的状态，返回 false 由调用方走矢量兜底。
    local images = contexts[ctx]
    local image = images and images[name] or 0
    if image <= 0 then
        Art.LoadImage(ctx, name)
        images = contexts[ctx]
        image = images and images[name] or 0
        if image <= 0 then return false end
    end
    if type(position) ~= "table" or not finite(position.x) or not finite(position.y) then return false end
    local project = Projection.ProjectFunction(movement)
    if not project then return false end
    local x, y, scale = project(position.x, position.y, 0)
    if not x or type(scale) ~= "number" or scale <= 0 then return false end
    local screenHeight = worldHeight * scale
    if screenHeight < UPRIGHT_MIN_PX then return true end
    local canvasHeight = screenHeight * spec.pixelHeight / spec.contentHeight
    local canvasWidth = canvasHeight * spec.pixelWidth / spec.pixelHeight
    -- 内容主体底沿落在锚点：画布中心 = 锚点 − 屏高/2（居中假设下内容底=锚点）。
    local boxX = x - canvasWidth * 0.5
    local boxY = y - screenHeight * 0.5 - canvasHeight * 0.5
    nvgSave(ctx)
    nvgBeginPath(ctx)
    nvgRect(ctx, boxX, boxY, canvasWidth, canvasHeight)
    nvgClosePath(ctx)
    nvgFillPaint(ctx, nvgImagePattern(ctx, boxX, boxY, canvasWidth, canvasHeight, 0, image, alpha or 1))
    fillCounter = fillCounter + 1
    nvgFill(ctx)
    nvgRestore(ctx)
    return true
end

-- 按可见主体宽度适配透明留边；默认保持主体比例，尺寸仅用于绘制，不是碰撞范围。
---@param ctx NVGContextWrapper
---@param name string
---@param movement table
---@param origin table
---@param contentLength number 可见主体沿 +X 的长度（米）。
---@param heading number 世界朝向（弧度）。
---@param altitude number?
---@param alpha number?
---@param contentWidth number? 省略时保持源图主体比例。
---@param roll number?
function Art.Sprite(ctx, name, movement, origin, contentLength, heading, altitude, alpha, contentWidth, roll)
    name = ArtVariants.Resolve(name)
    local spec = catalog[name]
    if not spec or not Art.IsLoaded(ctx, name) or contentLength <= 0 then return false end
    local width = contentWidth or contentLength * spec.contentHeight / spec.contentWidth
    if width <= 0 then return false end
    local canvasLength = contentLength * spec.pixelWidth / spec.contentWidth
    local canvasWidth = width * spec.pixelHeight / spec.contentHeight
    return Art.Plane(ctx, name, movement, origin, canvasLength, canvasWidth, heading, altitude, alpha, roll)
end

-- 海面纸纹为画布材质层，只用一条海线遮罩；不作为世界地标或动态波浪。
---@param ctx NVGContextWrapper
function Art.WaterPaper(ctx, movement, width, height)
    local name = ArtVariants.Resolve("waterpaper")
    local images = contexts[ctx]
    local image = images and images[name] or 0
    if image <= 0 then
        -- 按需加载（2026-10-15 修复）：与 Plane 同构，兜底运行中切换与漏项。
        Art.LoadImage(ctx, name)
        images = contexts[ctx]
        image = images and images[name] or 0
        if image <= 0 then return false end
    end
    local horizon = Projection.HorizonFunction(movement)
    if not horizon then return false end
    nvgSave(ctx)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, 0, horizon(0))
    for index = 1, 48 do
        local x = width * index / 48
        nvgLineTo(ctx, x, horizon(x))
    end
    nvgLineTo(ctx, width, height)
    nvgLineTo(ctx, 0, height)
    nvgClosePath(ctx)
    local size = height * 1.5
    nvgFillPaint(ctx, nvgImagePattern(ctx, 0, 0, size, size, 0, image, 0.5))
    fillCounter = fillCounter + 1
    nvgFill(ctx)
    nvgRestore(ctx)
    return true
end

-- 纯海面贴图层（2026-10-17 C2，方案 A）：屏幕空间材质层，与 WaterPaper
-- 同构——只用一条地平线折线遮罩，不作为世界地标或动态波浪。差异点：
-- ①满幅 16:9 贴图（地平线约在其 25% 处，与游戏 horizonY≈0.24 吻合），
--   cell 取视口尺寸使全图恰好铺满可见水域，竖向上沿即裁剪区不会回绕；
-- ②REPEATX 横向无缝循环 + scrollX 偏移实现相机横移视差（近水速率由
--   调用方按 base=height/camera.viewHeight 折算后传入，负向偏移）。
-- 懒加载同 Plane 口径：加载失败返回 false，由调用方走渐变/纸纹兜底；
-- 失败句柄 -1 已缓存，不会每帧重试。scrollX 缺省 0（静止满幅）。
---@param ctx NVGContextWrapper
---@param name string
---@param movement table
---@param width number
---@param height number
---@param alpha number?
---@param scrollX number?
function Art.SeaSurface(ctx, movement, width, height, name, alpha, scrollX)
    name = ArtVariants.Resolve(name)
    local images = contexts[ctx]
    local image = images and images[name] or 0
    if image <= 0 then
        Art.LoadImage(ctx, name)
        images = contexts[ctx]
        image = images and images[name] or 0
        if image <= 0 then return false end
    end
    local horizon = Projection.HorizonFunction(movement)
    if not horizon then return false end
    nvgSave(ctx)
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, 0, horizon(0))
    for index = 1, 48 do
        local x = width * index / 48
        nvgLineTo(ctx, x, horizon(x))
    end
    nvgLineTo(ctx, width, height)
    nvgLineTo(ctx, 0, height)
    nvgClosePath(ctx)
    nvgFillPaint(ctx, nvgImagePattern(ctx, scrollX or 0, 0, width, height, 0, image, alpha or 1))
    fillCounter = fillCounter + 1
    nvgFill(ctx)
    nvgRestore(ctx)
    return true
end

-- 波纹只读现有 voyage time；暂停自然冻结，不生成粒子或寿命表。
function Art.ContactRipple(ctx, movement, position, time, radius)
    local phase = ((time or 0) * 0.48) % 1
    local diameter = (radius or 1) * (2.4 + phase * 0.9)
    return Art.Plane(ctx, "ripple", movement, position, diameter, diameter, 0, 0, (1 - phase) * 0.7)
end

return Art
