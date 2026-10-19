-- 2026-10-20 用户裁定「波纹改回程序 crests 但想参考贴图样式」白盒测试。
-- 以 sea_ripple_overlay 水彩波纹贴图的笔触特征为参照，守护程序 crest marks 的
-- 贴图样式契约（全部经 Config.visual.crest 参数化，缺配置即退回历史单笔口径）：
--   1) 默认口径：seaRipple.enabled=false，Surface 进入程序 crest marks 段并出笔；
--   2) 两端渐细 taper：同笔拆出 root/tip 两段线宽（tip = root × taperTip）；
--   3) 水彩晕染 halo：存在更宽更淡的同色笔画（halo alpha < 主体 alpha）；
--   4) 伴生小笔 companion：companionChance 控制有无，宽度与 alpha 均低于主体；
--   5) 色相抖动：crest.color 与 crest.altColor 两档都出现在同屏笔画中；
--   6) 密度呼吸 skipRatio：比例越大笔画越少（贴图式疏朗，非满屏等密）；
--   7) 关闭口径零回归：样式参数全关即退回历史「整行一笔」宽度集合与纸白色；
--   8) 零状态改写：Surface 不改相机、不触碰 crest 配置。
local Tests = {}

local SeaViewArt = require("Ocean.SeaViewArt")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")

local WIDTH, HEIGHT = 640, 360

-- 最小可投影 movement：只提供 crest 段所需字段（视口/相机/世界→屏幕/世界带）。
-- 纵向按 0.15 压缩（模拟斜投影纵深压缩），保证各层行都落在地平线以下可见区。
local function makeMovement(cameraX, cameraY, minY, maxY)
    local scale = HEIGHT / Config.camera.viewHeight
    local movement = {
        viewportWidth = WIDTH,
        viewportHeight = HEIGHT,
        camera = { x = cameraX or 0, y = cameraY or 0 },
    }
    function movement:WorldToScreen(position, altitude)
        local x = WIDTH * 0.5 + (position.x - movement.camera.x) * scale
        local y = HEIGHT * Config.camera.anchorY
            - (position.y - movement.camera.y) * scale * 0.15
            - (altitude or 0) * scale
        return x, y, scale
    end
    function movement:GetHorizonY()
        return HEIGHT * Config.camera.horizonY
    end
    function movement:GetViewBounds(margin)
        margin = margin or 0
        return { minY = (minY or -20) - margin, maxY = (maxY or 120) + margin }
    end
    return movement
end

-- 笔画录制：包裹 nvgStroke/Color/Width 记录每次描边的（线宽, 颜色, alpha）。
local strokes, beziers = {}, 0
local oldStroke, oldStrokeColor, oldStrokeWidth
local oldCreateImage, oldImagePattern
local oldMipmap, oldRepeatX, oldRepeatY
local oldBezier
local pendingColor, pendingWidth

local function installStubs()
    strokes, beziers = {}, 0
    pendingColor, pendingWidth = nil, nil
    oldBezier = nvgBezierTo
    -- 贝塞尔段数=实际笔画几何量（stroke 次数是批次量，跳过格位只减段数不减批次）。
    nvgBezierTo = function(ctx, c1x, c1y, c2x, c2y, x, y)
        beziers = beziers + 1
        return oldBezier(ctx, c1x, c1y, c2x, c2y, x, y)
    end
    oldStroke, oldStrokeColor, oldStrokeWidth = nvgStroke, nvgStrokeColor, nvgStrokeWidth
    oldCreateImage, oldImagePattern = nvgCreateImage, nvgImagePattern
    -- 海面底图/纸纹层走 ImageArt 加载路径，需要贴图标志常量（NVGCapture 不提供）。
    oldMipmap, oldRepeatX, oldRepeatY =
        NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = 1, 2, 4
    nvgCreateImage = function() return 1 end
    nvgImagePattern = function() return nil end
    nvgStrokeColor = function(ctx, color) pendingColor = color end
    nvgStrokeWidth = function(ctx, width) pendingWidth = width end
    nvgStroke = function(ctx)
        strokes[#strokes + 1] = { width = pendingWidth, color = pendingColor }
    end
end

local function restoreStubs()
    nvgBezierTo = oldBezier
    nvgStroke, nvgStrokeColor, nvgStrokeWidth = oldStroke, oldStrokeColor, oldStrokeWidth
    nvgCreateImage, nvgImagePattern = oldCreateImage, oldImagePattern
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY =
        oldMipmap, oldRepeatX, oldRepeatY
end

local function near(actual, expected, tolerance)
    assert(type(actual) == "number" and type(expected) == "number"
        and math.abs(actual - expected) <= (tolerance or 0.001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

local function hasWidth(target, tolerance)
    for _, stroke in ipairs(strokes) do
        if stroke.width and math.abs(stroke.width - target) <= (tolerance or 1e-6) then
            return true
        end
    end
    return false
end

-- 期望线宽：由配置与本套件的 scale 推导（与 drawSurfaceRow 同口径，含 ×0.86）。
local function expectedWidths()
    local scale = HEIGHT / Config.camera.viewHeight
    local surface = Config.visual.surface or {}
    local crest = Config.visual.crest or {}
    local nearBase = math.max(1.05, math.min(3.2, scale * (surface.nearStrokeWidthMeters or 0.12)))
    local farBase = math.max(0.55, math.min(1.15, scale * (surface.farStrokeWidthMeters or 0.055)))
    local tip = crest.taperTip or 1
    return {
        nearRoot = nearBase * 0.86,
        nearHalo = nearBase * (crest.haloWidth or 1) * 0.86,
        nearTip = nearBase * tip * 0.86,
        nearCompanion = nearBase * 0.72 * 0.86,
        farRoot = farBase * 0.86,
        farTip = farBase * tip * 0.86,
    }
end

local function drawCrests(movement)
    SeaViewArt.Surface({}, movement, 1.5)
end

function Tests.Run(recorder)
    installStubs()
    local results = {}
    local function check(name, callback)
        strokes, beziers = {}, 0
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("默认口径：seaRipple.enabled=false 且 Surface 进入程序 crest 段并出笔", function()
        assert(Config.visual.seaRipple.enabled == false,
            "2026-10-20 裁定：波纹层默认关闭，海面细节回到程序 crest marks")
        local movement = makeMovement()
        local entered = 0
        local probe = movement.GetViewBounds
        movement.GetViewBounds = function(m, margin)
            entered = entered + 1
            return probe(m, margin)
        end
        drawCrests(movement)
        assert(entered == 1, "波纹层关闭后应进入程序 crest marks 段")
        assert(#strokes > 2, "应画出 crest 笔画（含地平线线）")
    end)

    check("两端渐细：同笔拆出 root/tip 两段，tip 线宽 = base × taperTip", function()
        local widths = expectedWidths()
        drawCrests(makeMovement())
        assert(hasWidth(widths.nearRoot), "应存在 body 线宽（近景层）")
        assert(hasWidth(widths.nearTip), "应存在 taper 尾段线宽（近景层）")
        assert(hasWidth(widths.farTip), "远景层同样应用 taper")
        assert(widths.nearTip < widths.nearRoot, "尾段必须比主体更细（贴图笔触两端渐细）")
    end)

    check("水彩晕染：halo 更宽且更淡（alpha 低于主体）", function()
        local widths = expectedWidths()
        drawCrests(makeMovement())
        assert(hasWidth(widths.nearHalo), "应存在 halo 柔边线宽")
        local haloAlpha, bodyAlpha
        for _, stroke in ipairs(strokes) do
            if stroke.color and stroke.color.a then
                if stroke.width and math.abs(stroke.width - widths.nearHalo) <= 1e-6 then
                    haloAlpha = stroke.color.a
                elseif stroke.width and math.abs(stroke.width - widths.nearRoot) <= 1e-6 then
                    bodyAlpha = bodyAlpha or stroke.color.a
                end
            end
        end
        assert(haloAlpha and bodyAlpha, "应取到 halo 与主体笔画的 alpha")
        assert(haloAlpha < bodyAlpha, "halo 必须比主体更淡（水彩渗色边）")
        assert(widths.nearHalo > widths.nearRoot, "halo 必须比主体更宽")
    end)

    check("伴生小笔：companionChance 控制有无，且更细更淡", function()
        local widths = expectedWidths()
        drawCrests(makeMovement())
        assert(hasWidth(widths.nearCompanion), "companionChance>0 应出现伴生小笔线宽")
        local crest = Config.visual.crest
        local oldChance = crest.companionChance
        crest.companionChance = 0
        strokes = {}
        drawCrests(makeMovement())
        crest.companionChance = oldChance
        assert(not hasWidth(widths.nearCompanion), "companionChance=0 不得出现伴生小笔")
    end)

    check("色相抖动：配了 crest.altColor 才分出冷调变体（默认单色省批次）", function()
        local crest = Config.visual.crest
        -- 默认不配 altColor：主色单档即可，配了才按格哈希分两档（可选旋钮）。
        crest.altColor = { 233, 243, 223 }
        local function hasColor(rgb)
            for _, stroke in ipairs(strokes) do
                if stroke.color and stroke.color.r == rgb[1] and stroke.color.g == rgb[2]
                    and stroke.color.b == rgb[3] then
                    return true
                end
            end
            return false
        end
        drawCrests(makeMovement())
        assert(hasColor(crest.color), "应出现白沫主色（贴图取色）")
        assert(hasColor(crest.altColor), "配了 altColor 应出现冷调变体")
        crest.altColor = nil
        strokes = {}
        drawCrests(makeMovement())
        local distinctColors = {}
        for _, stroke in ipairs(strokes) do
            if stroke.color then
                distinctColors[tostring(stroke.color.r) .. "," .. tostring(stroke.color.g)] = true
            end
        end
        local count = 0
        for _ in pairs(distinctColors) do count = count + 1 end
        assert(count <= 2, "未配 altColor 时应合并为单一笔画色（省 stroke 批次）")
    end)

    check("密度呼吸：skipRatio 越大笔画越少（贴图式疏朗）", function()
        local crest = Config.visual.crest
        local oldSkip = crest.skipRatio
        crest.skipRatio = 0
        drawCrests(makeMovement())
        local dense = beziers
        crest.skipRatio = 0.6
        strokes, beziers = {}, 0
        drawCrests(makeMovement())
        local sparse = beziers
        crest.skipRatio = oldSkip
        assert(dense > 0 and sparse > 0, "两种密度都应出笔")
        assert(sparse < dense, string.format("skipRatio 0.6 段数(%d) 应少于 0(%d)", sparse, dense))
    end)

    check("关闭口径零回归：样式全关退回历史「整行一笔」宽度集合与纸白色", function()
        local crest = Config.visual.crest
        local old = {
            skipRatio = crest.skipRatio, lengthJitter = crest.lengthJitter,
            skewMax = crest.skewMax, taperAt = crest.taperAt, taperTip = crest.taperTip,
            haloWidth = crest.haloWidth, haloAlpha = crest.haloAlpha,
            companionChance = crest.companionChance, companionScale = crest.companionScale,
            color = crest.color, altColor = crest.altColor,
        }
        crest.skipRatio, crest.lengthJitter, crest.taperAt = 0, 0, 0
        crest.haloAlpha, crest.companionChance = 0, 0
        crest.color, crest.altColor = nil, nil
        drawCrests(makeMovement())
        local widths = expectedWidths()
        for _, stroke in ipairs(strokes) do
            local isHorizon = math.abs(stroke.width - 1.15) <= 1e-6
            local isLegacy = math.abs(stroke.width - widths.nearRoot) <= 1e-6
                or math.abs(stroke.width - widths.farRoot) <= 1e-6
            assert(isHorizon or isLegacy,
                "关闭样式后只剩历史单一线宽，实际出现 " .. tostring(stroke.width))
            if not isHorizon then
                assert(stroke.color.r == 233 and stroke.color.g == 243 and stroke.color.b == 223,
                    "缺 crest.color 时应沿用历史纸白色 PAPER_WAVE")
            end
        end
        for key, value in pairs(old) do crest[key] = value end
    end)

    check("零状态改写：Surface 不改写相机与 crest 配置", function()
        local crest = Config.visual.crest
        local before = { crest.skipRatio, crest.taperAt, crest.haloAlpha, crest.companionChance }
        local movement = makeMovement(12, 4)
        drawCrests(movement)
        assert(movement.camera.x == 12 and movement.camera.y == 4, "不得改写相机")
        assert(crest.skipRatio == before[1] and crest.taperAt == before[2]
            and crest.haloAlpha == before[3] and crest.companionChance == before[4],
            "绘制不得改写 crest 配置")
    end)

    check("配置缺省零回归：Config.visual.crest=nil 时不报错且笔画照旧", function()
        local visual = Config.visual
        local saved = visual.crest
        visual.crest = nil
        local ok, err = pcall(function() drawCrests(makeMovement()) end)
        visual.crest = saved
        assert(ok, "缺 crest 配置不得报错：" .. tostring(err))
        assert(#strokes > 2, "缺 crest 配置仍应照常出笔")
    end)

    restoreStubs()
    return { results = results }
end

return Tests
