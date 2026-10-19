-- C2（2026-10-17）纯海面 v2 贴图渲染接入白盒测试（方案 A：夜罩不动）。
-- 2026-10-18 C3/C4：日间海面底图换用户提供水彩海面（catalog 规格不变）；新增
-- 波纹平铺层（sea_ripple_overlay）替换程序 crest marks。守护契约：
--   1) SeaSurfaceFrame 选择函数（纯函数）：day/night 各 progress、无 clock、
--      progress 由 elapsed/duration 推导与越界钳制；夜图永不进自动映射；
--   2) ImageArt.SeaSurface：懒加载一次且 REPEATX|REPEATY|MIPMAPS、imagePattern
--      参数口径（ox=scrollX/oy=0/视口 cell/angle=0/alpha 透传）、地平线 48 段
--      裁剪路径、失败一次即缓存不再重试、未知名/缺地平线函数返回 false；
--   3) Surface 接入：三参旧调用只画 base；day 末段交叉淡入 dusk；night 前 10%
--      淡回昼图、其后昼图过罩；贴图可用跳过 WaterPaper、失败走 WaterPaper 兜底；
--      滚动偏移随 camera.x 且可关闭；alpha 经 config 透传；零状态改写；
--   4) ImageArt.SeaRipple：懒加载一次且 REPEATX|REPEATY|MIPMAPS、瓦片=catalog
--      像素尺寸×tileScale、alpha 透传/越界钳制、地平线 48 段裁剪、失败缓存、
--      缺地平线函数返回 false；
--   5) Surface 接入：波纹层可用即跳过 crests（GetViewBounds 入口断言），失败/
--      enabled=false 回退 crests；alpha/tileScale 经 config 透传；
--      2026-10-20 裁定：波纹层默认 enabled=false（改回程序 crests 承接海面细节，
--      贴图样式由程序层参考实现），故断言波纹层的检查一律显式开启后再断言，
--      并新增默认口径检查（只画底图 + 进入 crests 段）；
--   6) catalog 规格：海面三图（preload/repeatTexture/昼·黄昏 1728×972 用户水彩
--      纹理 v2、夜 1920×1080）+ 波纹层（preload=true/repeatTexture=true/512×288）。
local Tests = {}

local SeaViewArt = require("Ocean.SeaViewArt")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")

local WIDTH, HEIGHT = 1280, 720
local DAY_PATH = "image/SeaSurface/sea_surface_day.png"
local DUSK_PATH = "image/SeaSurface/sea_surface_dusk.png"
local NIGHT_PATH = "image/SeaSurface/sea_surface_night.png"
local RIPPLE_PATH = "image/SeaSurface/sea_ripple_overlay.png"

local function near(actual, expected, tolerance)
    assert(type(actual) == "number" and type(expected) == "number"
        and math.abs(actual - expected) <= (tolerance or 0.001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

-- 本地 NVG 桩：NVGCapture 不绑定 nvgCreateImage/nvgImagePattern，
-- 由本套件自建并记录加载与图案参数；句柄即 created 序号，便于反查路径。
local created, patterns, failedPath
local oldCreate, oldPattern
local oldMipmap, oldRepeatX, oldRepeatY

local function fresh()
    created, patterns, failedPath = {}, {}, ""
end

local function installStubs()
    fresh()
    oldCreate, oldPattern = nvgCreateImage, nvgImagePattern
    oldMipmap, oldRepeatX, oldRepeatY =
        NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = 1, 2, 4
    nvgCreateImage = function(ctx, path, flags)
        created[#created + 1] = { ctx = ctx, path = path, flags = flags }
        if path == failedPath then return -1 end
        return #created
    end
    nvgImagePattern = function(ctx, ox, oy, w, h, angle, image, alpha)
        patterns[#patterns + 1] = { ox = ox, oy = oy, w = w, h = h,
            angle = angle, image = image, alpha = alpha }
        return #patterns
    end
end

local function restoreStubs()
    nvgCreateImage, nvgImagePattern = oldCreate, oldPattern
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY =
        oldMipmap, oldRepeatX, oldRepeatY
end

local function pathOf(image)
    local entry = created[image]
    return entry and entry.path or ""
end

-- 最小可投影 movement：只提供 SeaViewArt.Surface 贴图层所需字段
--（视口/相机/地平线函数）；不含 GetViewBounds，绘制在浪脊格前返回。
local function makeMovement(cameraX)
    return {
        viewportWidth = WIDTH,
        viewportHeight = HEIGHT,
        camera = { x = cameraX or 0, y = 0 },
        GetHorizonY = function() return HEIGHT * 0.24 end,
    }
end

-- crest 段入口探针 movement：GetViewBounds 计数 + 返回空世界带（零行、不触
-- 投影），用于断言「是否进入程序 crest marks 段」——波纹层绘制成功即跳过。
local function makeBoundsProbeMovement()
    local movement = makeMovement(0)
    movement.viewBoundsCalls = 0
    movement.GetViewBounds = function()
        movement.viewBoundsCalls = movement.viewBoundsCalls + 1
        return { minY = 0, maxY = -1 }
    end
    return movement
end

-- 波纹层默认关闭（2026-10-20 裁定）后，断言波纹层的检查须显式开启再断言，
-- 使断言与 Config 默认值解耦（默认值可再调整而不误伤本套契约）。
local function withRippleEnabled(fn)
    local settings = Config.visual.seaRipple or {}
    local oldEnabled = settings.enabled
    settings.enabled = true
    local ok, err = pcall(fn)
    settings.enabled = oldEnabled
    if not ok then error(err) end
end

local function withWaterPaperCounter(fn)
    local calls = 0
    local original = ImageArt.WaterPaper
    ImageArt.WaterPaper = function() calls = calls + 1; return true end
    local ok, err = pcall(fn)
    ImageArt.WaterPaper = original
    if not ok then error(err) end
    return calls
end

function Tests.Run(recorder)
    installStubs()
    local results = {}
    local function check(name, callback)
        fresh()
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("相位选择：无 clock 与非法相位退化为昼图独显", function()
        for _, clock in ipairs({ nil, {}, { phase = "dusk" }, { phase = 42 } }) do
            local frame = SeaViewArt.SeaSurfaceFrame(clock)
            assert(frame.base == "sea_surface_day" and frame.over == nil and frame.blend == 0,
                "无有效相位时必须退化为昼图独显")
        end
    end)

    check("相位选择：day 末段 smoothstep 交叉淡入黄昏图", function()
        local function dayFrame(progress)
            return SeaViewArt.SeaSurfaceFrame({ phase = "day", progress = progress })
        end
        assert(dayFrame(0).over == nil and dayFrame(0).blend == 0)
        assert(dayFrame(0.5).over == nil and dayFrame(0.79).over == nil)
        near(dayFrame(0.8).blend, 0, 1e-9)
        local mid = dayFrame(0.9)
        assert(mid.over == "sea_surface_dusk", "day 0.9 应交叉淡入黄昏图")
        near(mid.blend, 0.5, 1e-9)
        local late = dayFrame(1.0)
        assert(late.over == "sea_surface_dusk")
        near(late.blend, 1, 1e-9)
        -- 越界 progress 钳制在 [0,1]，不得产生越界 blend。
        near(dayFrame(1.7).blend, 1, 1e-9)
        near(dayFrame(-0.5).blend, 0, 1e-9)
    end)

    check("相位选择：night 前 10% 淡回昼图，其余昼图过夜罩；夜图不进自动映射", function()
        local function nightFrame(progress)
            return SeaViewArt.SeaSurfaceFrame({ phase = "night", progress = progress })
        end
        local start = nightFrame(0)
        assert(start.base == "sea_surface_day" and start.over == "sea_surface_dusk",
            "入夜瞬间应延续黄昏图，避免夜罩叠加跳变")
        near(start.blend, 1, 1e-9)
        local mid = nightFrame(0.05)
        assert(mid.over == "sea_surface_dusk")
        near(mid.blend, 0.5, 1e-9)
        assert(nightFrame(0.1).over == nil and nightFrame(0.1).blend == 0)
        assert(nightFrame(0.5).over == nil and nightFrame(0.99).over == nil)
        for _, progress in ipairs({ 0, 0.05, 0.1, 0.5, 1 }) do
            assert(nightFrame(progress).base == "sea_surface_day",
                "方案 A：夜间基图恒为昼图（夜罩负责压暗），夜图不进自动映射")
        end
    end)

    check("相位选择：progress 缺省时由 elapsed/duration 推导", function()
        local day = SeaViewArt.SeaSurfaceFrame({ phase = "day", elapsed = 54, duration = 120 })
        assert(day.over == nil, "0.45 未到 duskFrom 应无交叉淡入")
        local night = SeaViewArt.SeaSurfaceFrame({ phase = "night", elapsed = 3, nightSec = 60 })
        assert(night.over == "sea_surface_dusk", "0.05 处于 nightFade 段")
        near(night.blend, 0.5, 1e-9)
    end)

    check("SeaSurface：懒加载一次且带 REPEATX|REPEATY|MIPMAPS，重复调用不重复创建", function()
        local ctx = {}
        local movement = makeMovement(0)
        assert(ImageArt.SeaSurface(ctx, movement, WIDTH, HEIGHT, "sea_surface_day"))
        assert(#created == 1, "首次绘制应触发一次按需加载")
        assert(created[1].path == DAY_PATH)
        assert(created[1].flags == 7, "REPEATX|REPEATY|MIPMAPS 横拼标志")
        assert(ImageArt.SeaSurface(ctx, movement, WIDTH, HEIGHT, "sea_surface_day", 0.5))
        assert(#created == 1, "同上下文同图只应加载一次")
    end)

    check("SeaSurface：imagePattern 参数口径（scrollX/视口 cell/alpha 透传）", function()
        local ctx = {}
        assert(ImageArt.SeaSurface(ctx, makeMovement(0), WIDTH, HEIGHT, "sea_surface_day", 0.6, -320))
        assert(#patterns == 1)
        local first = patterns[1]
        near(first.ox, -320, 1e-9)
        near(first.oy, 0, 1e-9)
        near(first.w, WIDTH, 1e-9)
        near(first.h, HEIGHT, 1e-9)
        near(first.angle, 0, 1e-9)
        near(first.alpha, 0.6, 1e-9)
        assert(first.image == 1)
        patterns = {}
        assert(ImageArt.SeaSurface(ctx, makeMovement(0), WIDTH, HEIGHT, "sea_surface_day"))
        near(patterns[1].ox, 0, 1e-9, "scrollX 缺省应静止满幅")
        near(patterns[1].alpha, 1, 1e-9, "alpha 缺省应不透明")
    end)

    check("SeaSurface：地平线 48 段裁剪路径且 save/restore 配平", function()
        local ctx = {}
        assert(ImageArt.SeaSurface(ctx, makeMovement(0), WIDTH, HEIGHT, "sea_surface_day"))
        recorder.reset()
        assert(ImageArt.SeaSurface(ctx, makeMovement(0), WIDTH, HEIGHT, "sea_surface_day"))
        assert(recorder.callCount("nvgMoveTo") == 1, "路径起点一次")
        assert(recorder.callCount("nvgLineTo") == 50, "48 段折线 + 两个底角")
        assert(recorder.callCount("nvgClosePath") == 1)
        assert(recorder.callCount("nvgSave") == 1 and recorder.callCount("nvgRestore") == 1)
        assert(recorder.callCount("nvgFill") == 1)
    end)

    check("SeaSurface：加载失败一次即缓存；未知名与缺地平线函数返回 false", function()
        local failCtx = {}
        failedPath = DAY_PATH
        assert(not ImageArt.SeaSurface(failCtx, makeMovement(0), WIDTH, HEIGHT, "sea_surface_day"))
        assert(#created == 1, "失败应只尝试一次")
        assert(not ImageArt.SeaSurface(failCtx, makeMovement(0), WIDTH, HEIGHT, "sea_surface_day"))
        assert(#created == 1, "失败句柄 -1 已缓存，不得每帧重试")
        failedPath = ""
        assert(not ImageArt.SeaSurface({}, makeMovement(0), WIDTH, HEIGHT, "sea_surface_missing"),
            "未知目录名应直接返回 false")
        assert(not ImageArt.SeaSurface({}, {}, WIDTH, HEIGHT, "sea_surface_day"),
            "缺地平线函数应返回 false（走兜底）")
    end)

    check("Surface 接入：三参旧调用画 base+波纹层且零状态改写", function()
        local ctx = {}
        local movement = makeMovement(0)
        withRippleEnabled(function()
            SeaViewArt.Surface(ctx, movement, 1.5)
        end)
        assert(#patterns == 2, "无 clock 应画 base 与波纹层各一次")
        assert(pathOf(patterns[1].image) == DAY_PATH)
        near(patterns[1].alpha, 1, 1e-9)
        assert(pathOf(patterns[2].image) == RIPPLE_PATH,
            "C4：波纹平铺层叠加于海面底图之上")
        assert(movement.camera.x == 0 and movement.camera.y == 0,
            "Surface 不得改写相机状态")
    end)

    check("Surface 接入：day 0.9 交叉淡入 dusk（over alpha=0.5）+ 波纹层", function()
        local ctx = {}
        withRippleEnabled(function()
            SeaViewArt.Surface(ctx, makeMovement(0), 1.5, { phase = "day", progress = 0.9 })
        end)
        assert(#patterns == 3)
        assert(pathOf(patterns[1].image) == DAY_PATH)
        assert(pathOf(patterns[2].image) == DUSK_PATH)
        assert(pathOf(patterns[3].image) == RIPPLE_PATH)
        near(patterns[1].alpha, 1, 1e-9)
        near(patterns[2].alpha, 0.5, 1e-9)
    end)

    check("Surface 接入：night 前 10% 淡回昼图、其后昼图过罩、夜图不自动加载", function()
        local ctx = {}
        withRippleEnabled(function()
            SeaViewArt.Surface(ctx, makeMovement(0), 1.5, { phase = "night", progress = 0.05 })
        end)
        assert(#patterns == 3)
        assert(pathOf(patterns[2].image) == DUSK_PATH)
        assert(pathOf(patterns[3].image) == RIPPLE_PATH)
        near(patterns[2].alpha, 0.5, 1e-9)
        patterns = {}
        withRippleEnabled(function()
            SeaViewArt.Surface(ctx, makeMovement(0), 1.5, { phase = "night", progress = 0.5 })
        end)
        assert(#patterns == 2, "nightFade 之后应只画昼图+波纹层（夜罩压暗）")
        assert(pathOf(patterns[1].image) == DAY_PATH)
        assert(pathOf(patterns[2].image) == RIPPLE_PATH)
        for _, entry in ipairs(created) do
            assert(entry.path ~= NIGHT_PATH, "夜图不得进入自动映射/自动加载")
        end
    end)

    check("Surface 接入：贴图可用跳过 WaterPaper，贴图失败走纸纹兜底", function()
        local ctx = {}
        local calls = withWaterPaperCounter(function()
            SeaViewArt.Surface(ctx, makeMovement(0), 1.5)
        end)
        assert(calls == 0, "贴图可用时不应再叠纸纹层")
        failedPath = DAY_PATH
        local failCtx = {}
        calls = withWaterPaperCounter(function()
            SeaViewArt.Surface(failCtx, makeMovement(0), 1.5)
        end)
        assert(calls == 1, "贴图加载失败应回退纸纹层（渐变仍在最底层）")
        failedPath = ""
    end)

    check("Surface 接入：滚动偏移随 camera.x，scroll=false 静止，alpha 经 config 透传", function()
        local ctx = {}
        local base = HEIGHT / Config.camera.viewHeight
        local oldScroll = Config.visual.seaSurface.scroll
        Config.visual.seaSurface.scroll = true
        SeaViewArt.Surface(ctx, makeMovement(100), 1.5)
        near(patterns[1].ox, -((100 * base) % WIDTH), 1e-9,
            "近水速率：1 世界米 = base 屏距（与 Projection 同口径）")
        Config.visual.seaSurface.scroll = false
        patterns = {}
        SeaViewArt.Surface(ctx, makeMovement(100), 1.5)
        near(patterns[1].ox, 0, 1e-9,
            "scroll=false 底图固定（2026-10-18 真机验收默认口径：不跟随船移动）")
        Config.visual.seaSurface.scroll = oldScroll
        local oldAlpha = Config.visual.seaSurface.alpha
        Config.visual.seaSurface.alpha = 0.8
        patterns = {}
        SeaViewArt.Surface(ctx, makeMovement(0), 1.5, { phase = "day", progress = 0.9 })
        near(patterns[1].alpha, 0.8, 1e-9)
        near(patterns[2].alpha, 0.4, 1e-9, "over alpha = config.alpha × blend")
        Config.visual.seaSurface.alpha = oldAlpha
    end)

    check("Surface 接入：enabled=false 跳过贴图层走纸纹，波纹层仍叠加", function()
        local oldEnabled = Config.visual.seaSurface.enabled
        Config.visual.seaSurface.enabled = false
        patterns = {}
        local calls = withWaterPaperCounter(function()
            withRippleEnabled(function()
                SeaViewArt.Surface({}, makeMovement(0), 1.5)
            end)
        end)
        assert(calls == 1, "贴图层关闭应回退纸纹层（渐变仍在最底层）")
        assert(#patterns == 1 and pathOf(patterns[1].image) == RIPPLE_PATH,
            "波纹层独立于海面底图：底图关闭仍应叠加")
        Config.visual.seaSurface.enabled = oldEnabled
    end)

    -- crest 段入口断言：波纹层绘制成功即跳过程序 crest marks（GetViewBounds 是
    -- crest 段唯一入口，探针 movement 返回空世界带使零行绘制、不触投影）。
    -- 三种情形显式设定波纹层开关（不再依赖 Config 默认值：默认已改为关闭）：
    -- 缺省=可用（跳过 crests）、failRipple=加载失败、disableRipple=显式关闭。
    local function crestEntered(failRipple, disableRipple)
        local movement = makeBoundsProbeMovement()
        local ctx = {}
        if failRipple then failedPath = RIPPLE_PATH end
        local settings = Config.visual.seaRipple or {}
        local oldEnabled = settings.enabled
        settings.enabled = not disableRipple
        SeaViewArt.Surface(ctx, movement, 1.5)
        failedPath = ""
        settings.enabled = oldEnabled
        return movement.viewBoundsCalls
    end

    check("SeaRipple：懒加载一次且带 REPEATX|REPEATY|MIPMAPS", function()
        local ctx = {}
        assert(ImageArt.SeaRipple(ctx, makeMovement(0), WIDTH, HEIGHT))
        assert(#created == 1, "首次绘制应触发一次按需加载")
        assert(created[1].path == RIPPLE_PATH)
        assert(created[1].flags == 7, "双向平铺+预过滤横拼标志")
        assert(ImageArt.SeaRipple(ctx, makeMovement(0), WIDTH, HEIGHT))
        assert(#created == 1, "同上下文同图只应加载一次")
    end)

    check("SeaRipple：imagePattern 瓦片=catalog 像素×tileScale 且 alpha 透传", function()
        local ctx = {}
        assert(ImageArt.SeaRipple(ctx, makeMovement(0), WIDTH, HEIGHT, 0.5, 2))
        assert(#patterns == 1)
        local first = patterns[1]
        near(first.ox, 0, 1e-9)
        near(first.oy, 0, 1e-9)
        near(first.w, 1024, 1e-9, "瓦片宽=512×tileScale")
        near(first.h, 576, 1e-9, "瓦片高=288×tileScale")
        near(first.angle, 0, 1e-9)
        near(first.alpha, 0.5, 1e-9)
        assert(first.image == 1)
        patterns = {}
        assert(ImageArt.SeaRipple(ctx, makeMovement(0), WIDTH, HEIGHT))
        near(patterns[1].w, 512, 1e-9, "tileScale 缺省=资产原生像素")
        near(patterns[1].alpha, 0.28, 1e-9, "alpha 缺省回退默认值")
    end)

    check("SeaRipple：地平线 48 段裁剪路径且 save/restore 配平", function()
        local ctx = {}
        assert(ImageArt.SeaRipple(ctx, makeMovement(0), WIDTH, HEIGHT))
        recorder.reset()
        assert(ImageArt.SeaRipple(ctx, makeMovement(0), WIDTH, HEIGHT))
        assert(recorder.callCount("nvgMoveTo") == 1, "路径起点一次")
        assert(recorder.callCount("nvgLineTo") == 50, "48 段折线 + 两个底角")
        assert(recorder.callCount("nvgClosePath") == 1)
        assert(recorder.callCount("nvgSave") == 1 and recorder.callCount("nvgRestore") == 1)
        assert(recorder.callCount("nvgFill") == 1)
    end)

    check("SeaRipple：失败一次即缓存；alpha/scale 越界钳制；缺地平线 false", function()
        local failCtx = {}
        failedPath = RIPPLE_PATH
        assert(not ImageArt.SeaRipple(failCtx, makeMovement(0), WIDTH, HEIGHT))
        assert(#created == 1, "失败应只尝试一次")
        assert(not ImageArt.SeaRipple(failCtx, makeMovement(0), WIDTH, HEIGHT))
        assert(#created == 1, "失败句柄已缓存，不得每帧重试")
        failedPath = ""
        patterns = {}
        assert(ImageArt.SeaRipple({}, makeMovement(0), WIDTH, HEIGHT, 5, -2))
        near(patterns[1].alpha, 0.28, 1e-9, "alpha>1 钳制回默认值")
        near(patterns[1].w, 512, 1e-9, "scale<=0 回退 1（原生像素）")
        near(patterns[1].h, 288, 1e-9)
        assert(not ImageArt.SeaRipple({}, {}, WIDTH, HEIGHT),
            "缺地平线函数应返回 false（走 crests 兜底）")
    end)

    check("Surface 接入：波纹层可用即跳过 crests（GetViewBounds 入口断言）", function()
        assert(crestEntered() == 0,
            "波纹平铺层已承接海面细节，不得再画程序 crest marks")
    end)

    check("Surface 接入：波纹加载失败回退 crests", function()
        assert(crestEntered(true) == 1,
            "贴图失败应回退程序 crest marks（贴图优先、失败回退，零回归）")
    end)

    check("Surface 接入：seaRipple.enabled=false 回退 crests", function()
        assert(crestEntered(nil, true) == 1,
            "显式关闭波纹层应回退程序 crest marks 兜底")
    end)

    check("默认口径：seaRipple.enabled=false，海面细节由程序 crests 承接", function()
        local ripple = Config.visual.seaRipple or {}
        assert(ripple.enabled == false,
            "2026-10-20 用户裁定：波纹层默认关闭，波纹改回程序 crest marks")
        local movement = makeBoundsProbeMovement()
        SeaViewArt.Surface({}, movement, 1.5)
        assert(movement.viewBoundsCalls == 1, "默认口径应进入程序 crest marks 段")
        assert(#patterns == 1 and pathOf(patterns[1].image) == DAY_PATH,
            "默认口径只画海面底图，不再叠加波纹平铺层")
    end)

    check("Surface 接入：alpha/tileScale 经 config 透传至波纹层", function()
        local ctx = {}
        local ripple = Config.visual.seaRipple or {}
        local oldAlpha, oldScale = ripple.alpha, ripple.tileScale
        ripple.alpha, ripple.tileScale = 0.5, 2
        patterns = {}
        withRippleEnabled(function()
            SeaViewArt.Surface(ctx, makeMovement(0), 1.5)
        end)
        assert(#patterns == 2, "base + 波纹层")
        assert(pathOf(patterns[2].image) == RIPPLE_PATH)
        near(patterns[2].alpha, 0.5, 1e-9)
        near(patterns[2].w, 1024, 1e-9, "瓦片宽=512×tileScale(2)")
        near(patterns[2].h, 576, 1e-9)
        ripple.alpha, ripple.tileScale = oldAlpha, oldScale
    end)

    check("catalog 四图规格：昼/黄昏 1728×972 + 夜 1920×1080 + 波纹层 512×288", function()
        local day = assert(ImageArt.GetSpec("sea_surface_day"))
        assert(day.preload == true and day.repeatTexture == true)
        assert(day.pixelWidth == 1728 and day.pixelHeight == 972,
            "2026-10-20 换装：昼图=用户水彩海面纹理 v2（1728×972 精确 16:9）")
        local dusk = assert(ImageArt.GetSpec("sea_surface_dusk"))
        assert(dusk.preload == true and dusk.repeatTexture == true)
        assert(dusk.pixelWidth == 1728 and dusk.pixelHeight == 972,
            "2026-10-20 换装：黄昏图=用户水彩海面纹理 v2 黄昏版")
        local night = assert(ImageArt.GetSpec("sea_surface_night"))
        assert(night.preload == false,
            "夜图留 SeaDebug/后续方案：不随场景启动预载")
        assert(night.repeatTexture == true, "夜图保持横拼标志备用")
        assert(night.pixelWidth == 1920 and night.pixelHeight == 1080,
            "夜图沿用锚点链 v2 满幅 1920×1080")
        local ripple = assert(ImageArt.GetSpec("sea_ripple_overlay"))
        assert(ripple.preload == true, "波纹层随场景启动预载，避免首帧尖峰")
        assert(ripple.repeatTexture == true, "双向平铺标志")
        assert(ripple.pixelWidth == 512 and ripple.pixelHeight == 288,
            "瓦片原生像素 512×288")
        assert(ripple.path == RIPPLE_PATH)
    end)

    restoreStubs()
    return { results = results }
end

return Tests
