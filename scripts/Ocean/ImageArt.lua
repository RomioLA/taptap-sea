-- 平面 PNG 的只读投影适配：复用现有世界投影/裁剪，不持有实体或更新游戏。
local Projection = require("Ocean.Projection")
local Geometry = require("Ocean.ProjectedGeometry")
local Config = require("Ocean.Config")
local Art = {}
local contexts = setmetatable({}, { __mode = "k" })
local catalog = require("GeneratedData.OceanImageCatalog")

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

-- 库内候选按需显式加载，不随场景启动批量占用纹理或自动生成对象。
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
    local handle = nvgCreateImage(ctx, spec.path, flags) or -1
    images[name] = handle
    if handle > 0 then
        print("[OceanArt] loaded " .. name .. " path=" .. spec.path)
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
local function triangle(ctx, movement, image, a, b, c, alpha, frame)
    -- 先在世界平面裁剪，再为裁剪顶点恢复 UV。不能用曲线中点配原端点
    -- 仿射矩阵，否则跨地平线的片会把岸线采样成透明留白。
    local clipped = Geometry.ClipPolygon(movement, { a, b, c })
    if #clipped < 3 then return false end
    local dx1, dy1, dx2, dy2 = b.x - a.x, b.y - a.y, c.x - a.x, c.y - a.y
    local worldDet = dx1 * dy2 - dx2 * dy1
    if math.abs(worldDet) < 1e-12 then return false end
    local projected = {}
    for _, point in ipairs(clipped) do
        local dx, dy = point.x - a.x, point.y - a.y
        local s, t = (dx * dy2 - dy * dx2) / worldDet, (dx1 * dy - dy1 * dx) / worldDet
        local x, y = frame.project(point.x, point.y, point.altitude)
        if not x then return false end
        projected[#projected + 1] = { x = x, y = y,
            u = a.u + (b.u - a.u) * s + (c.u - a.u) * t,
            v = a.v + (b.v - a.v) * s + (c.v - a.v) * t }
    end
    for index = 2, #projected - 1 do
        local p, q, r = projected[1], projected[index], projected[index + 1]
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
    local images = contexts[ctx]
    local image = images and images[name] or 0
    if image <= 0 then return false end
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
    local columns = math.max(2, math.min(8, math.ceil(length / 3)))
    local rows = math.max(2, math.min(8, math.ceil(width / 3)))
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
    local images = contexts[ctx]
    local image = images and images.waterpaper or 0
    if image <= 0 then return false end
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
