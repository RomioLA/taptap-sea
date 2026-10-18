-- 天空图（Sky）渲染接入白盒测试（2026-10-18 读海美术接入，方案 B：零 scissor）。
-- 守护契约：
--   1) SkyFrame 相位选择（纯函数，委托 SeaSurfaceFrame 改写键名 sky_day/sky_dusk）：
--      day/night 各 progress、无 clock、progress 由 elapsed/duration 推导与越界钳制；
--      夜间基图恒为 sky_day（无 sky_night 键，夜罩负责压暗）；
--   2) ImageArt.Sky：懒加载一次且 REPEATX|REPEATY|MIPMAPS、imagePattern 参数口径
--      （ox=scrollX/oy=0/视口 cell/angle=0/alpha 透传）、满幅无地平线裁剪、save/restore
--      配平且不使用 scissor、失败一次即缓存不再重试、未知名返回 false；
--   3) SeaViewArt.Sky 接入：三参旧调用只画 base；day 末段交叉淡入 dusk；night 前 10%
--      淡回昼天图、其后昼天图过罩；滚动偏移随 camera.x（scroll=false 静止）；
--      alpha 经 config 透传（base=layerAlpha、over=layerAlpha×blend）；enabled=false
--      跳过整层；零状态改写；
--   4) catalog 规格：天空两图（preload=false/repeatTexture=true/1920×1080）。
local Tests = {}

local SeaViewArt = require("Ocean.SeaViewArt")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")

local WIDTH, HEIGHT = 1280, 720
local SKY_DAY_PATH = "image/Sky/sky_day.png"
local SKY_DUSK_PATH = "image/Sky/sky_dusk.png"

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

-- 最小可投影 movement：只提供 SeaViewArt.Sky 所需字段（视口/相机）。
local function makeMovement(cameraX)
    return {
        viewportWidth = WIDTH,
        viewportHeight = HEIGHT,
        camera = { x = cameraX or 0, y = 0 },
        GetHorizonY = function() return HEIGHT * 0.24 end,
    }
end

function Tests.Run(recorder)
    installStubs()
    local results = {}
    local function check(name, callback)
        fresh()
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("SkyFrame 相位：无 clock 与非法相位退化为昼天图独显", function()
        for _, clock in ipairs({ nil, {}, { phase = "dusk" }, { phase = 42 } }) do
            local frame = SeaViewArt.SkyFrame(clock)
            assert(frame.base == "sky_day" and frame.over == nil and frame.blend == 0,
                "无有效相位时必须退化为昼天图独显")
        end
    end)

    check("SkyFrame 相位：day 末段 smoothstep 交叉淡入黄昏天图", function()
        local function dayFrame(progress)
            return SeaViewArt.SkyFrame({ phase = "day", progress = progress })
        end
        assert(dayFrame(0).over == nil and dayFrame(0).blend == 0)
        assert(dayFrame(0.5).over == nil and dayFrame(0.79).over == nil)
        near(dayFrame(0.8).blend, 0, 1e-9)
        local mid = dayFrame(0.9)
        assert(mid.over == "sky_dusk", "day 0.9 应交叉淡入黄昏天图")
        near(mid.blend, 0.5, 1e-9)
        local late = dayFrame(1.0)
        assert(late.over == "sky_dusk")
        near(late.blend, 1, 1e-9)
        near(dayFrame(1.7).blend, 1, 1e-9)
        near(dayFrame(-0.5).blend, 0, 1e-9)
    end)

    check("SkyFrame 相位：night 前 10% 淡回昼天图，其余昼天图过夜罩；无 sky_night 键", function()
        local function nightFrame(progress)
            return SeaViewArt.SkyFrame({ phase = "night", progress = progress })
        end
        local start = nightFrame(0)
        assert(start.base == "sky_day" and start.over == "sky_dusk",
            "入夜瞬间应延续黄昏天图，避免夜罩叠加跳变")
        near(start.blend, 1, 1e-9)
        local mid = nightFrame(0.05)
        assert(mid.over == "sky_dusk")
        near(mid.blend, 0.5, 1e-9)
        assert(nightFrame(0.1).over == nil and nightFrame(0.1).blend == 0)
        assert(nightFrame(0.5).over == nil and nightFrame(0.99).over == nil)
        for _, progress in ipairs({ 0, 0.05, 0.1, 0.5, 1 }) do
            assert(nightFrame(progress).base == "sky_day",
                "方案 A：夜间基图恒为昼天图（夜罩负责压暗），无 sky_night 键")
        end
    end)

    check("SkyFrame 相位：progress 缺省时由 elapsed/duration 推导", function()
        local day = SeaViewArt.SkyFrame({ phase = "day", elapsed = 54, duration = 120 })
        assert(day.over == nil, "0.45 未到 duskFrom 应无交叉淡入")
        local night = SeaViewArt.SkyFrame({ phase = "night", elapsed = 3, nightSec = 60 })
        assert(night.over == "sky_dusk", "0.05 处于 nightFade 段")
        near(night.blend, 0.5, 1e-9)
    end)

    check("Art.Sky：懒加载一次且带 REPEATX|REPEATY|MIPMAPS，重复调用不重复创建", function()
        local ctx = {}
        assert(ImageArt.Sky(ctx, "sky_day", WIDTH, HEIGHT))
        assert(#created == 1, "首次绘制应触发一次按需加载")
        assert(created[1].path == SKY_DAY_PATH)
        assert(created[1].flags == 7, "REPEATX|REPEATY|MIPMAPS 横拼标志")
        assert(ImageArt.Sky(ctx, "sky_day", WIDTH, HEIGHT))
        assert(#created == 1, "同上下文同图只应加载一次")
    end)

    check("Art.Sky：imagePattern 参数口径（scrollX/视口 cell/alpha 透传）", function()
        local ctx = {}
        assert(ImageArt.Sky(ctx, "sky_day", WIDTH, HEIGHT, 0.6, -320))
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
        assert(ImageArt.Sky(ctx, "sky_day", WIDTH, HEIGHT))
        near(patterns[1].ox, 0, 1e-9, "scrollX 缺省应静止满幅")
        near(patterns[1].alpha, 1, 1e-9, "alpha 缺省应不透明")
    end)

    check("Art.Sky：save/restore 配平且不使用 scissor（满幅材质层）", function()
        local ctx = {}
        recorder.reset()
        assert(ImageArt.Sky(ctx, "sky_day", WIDTH, HEIGHT))
        assert(recorder.callCount("nvgSave") == 1 and recorder.callCount("nvgRestore") == 1)
        assert(recorder.callCount("nvgScissor") == 0, "天空满幅材质层不得用 scissor 裁剪")
    end)

    check("Art.Sky：加载失败一次即缓存；未知名返回 false", function()
        local failCtx = {}
        failedPath = SKY_DAY_PATH
        assert(not ImageArt.Sky(failCtx, "sky_day", WIDTH, HEIGHT))
        assert(#created == 1, "失败应只尝试一次")
        assert(not ImageArt.Sky(failCtx, "sky_day", WIDTH, HEIGHT))
        assert(#created == 1, "失败句柄 -1 已缓存，不得每帧重试")
        failedPath = ""
        assert(not ImageArt.Sky({}, "sky_missing", WIDTH, HEIGHT),
            "未知目录名应直接返回 false")
    end)

    check("SeaViewArt.Sky 接入：三参旧调用（无 clock）画 base 天图", function()
        local ctx = {}
        SeaViewArt.Sky(ctx, makeMovement(0), WIDTH, HEIGHT, 1.5)
        assert(#patterns == 1, "无 clock 应只画 base 天图")
        assert(pathOf(patterns[1].image) == SKY_DAY_PATH)
        near(patterns[1].alpha, 1, 1e-9)
    end)

    check("SeaViewArt.Sky 接入：day 0.9 交叉淡入 dusk 天图（base=1，over alpha=0.5）", function()
        local ctx = {}
        SeaViewArt.Sky(ctx, makeMovement(0), WIDTH, HEIGHT, 1.5, { phase = "day", progress = 0.9 })
        assert(#patterns == 2)
        assert(pathOf(patterns[1].image) == SKY_DAY_PATH)
        assert(pathOf(patterns[2].image) == SKY_DUSK_PATH)
        near(patterns[1].alpha, 1, 1e-9, "base 满幅")
        near(patterns[2].alpha, 0.5, 1e-9, "over alpha = layerAlpha × blend")
    end)

    check("SeaViewArt.Sky 接入：night 前 10% 淡回昼天图、其后昼天图过罩、无 sky_night 加载", function()
        local ctx = {}
        SeaViewArt.Sky(ctx, makeMovement(0), WIDTH, HEIGHT, 1.5, { phase = "night", progress = 0.05 })
        assert(#patterns == 2)
        assert(pathOf(patterns[2].image) == SKY_DUSK_PATH)
        near(patterns[2].alpha, 0.5, 1e-9)
        patterns = {}
        SeaViewArt.Sky(ctx, makeMovement(0), WIDTH, HEIGHT, 1.5, { phase = "night", progress = 0.5 })
        assert(#patterns == 1, "nightFade 之后应只画昼天图（夜罩压暗）")
        assert(pathOf(patterns[1].image) == SKY_DAY_PATH)
        for _, entry in ipairs(created) do
            assert(entry.path ~= "image/Sky/sky_night.png", "夜图不得进入自动映射/自动加载")
        end
    end)

    check("SeaViewArt.Sky 接入：滚动偏移随 camera.x，scroll=false 静止，alpha 经 config 透传", function()
        local ctx = {}
        local base = HEIGHT / Config.camera.viewHeight
        local oldScroll = Config.visual.skyLayer.scroll
        Config.visual.skyLayer.scroll = true
        SeaViewArt.Sky(ctx, makeMovement(100), WIDTH, HEIGHT, 1.5)
        near(patterns[1].ox, -((100 * base * Config.visual.skyLayer.scrollScale) % WIDTH), 1e-9,
            "视差横滚：1 世界米 = base 屏距 × scrollScale")
        Config.visual.skyLayer.scroll = false
        patterns = {}
        SeaViewArt.Sky(ctx, makeMovement(100), WIDTH, HEIGHT, 1.5)
        near(patterns[1].ox, 0, 1e-9,
            "scroll=false 天空固定（不跟随船移动，与用户'随镜头横滚'默认口径区分）")
        Config.visual.skyLayer.scroll = oldScroll
        local oldAlpha = Config.visual.skyLayer.alpha
        Config.visual.skyLayer.alpha = 0.8
        patterns = {}
        SeaViewArt.Sky(ctx, makeMovement(0), WIDTH, HEIGHT, 1.5, { phase = "day", progress = 0.9 })
        near(patterns[1].alpha, 0.8, 1e-9, "base alpha = config.alpha")
        near(patterns[2].alpha, 0.4, 1e-9, "over alpha = config.alpha × blend")
        Config.visual.skyLayer.alpha = oldAlpha
    end)

    check("SeaViewArt.Sky 接入：enabled=false 跳过整层（回退程序渐变）", function()
        local oldEnabled = Config.visual.skyLayer.enabled
        Config.visual.skyLayer.enabled = false
        patterns = {}
        SeaViewArt.Sky({}, makeMovement(0), WIDTH, HEIGHT, 1.5)
        assert(#patterns == 0, "关闭天空层应完全不绘制")
        Config.visual.skyLayer.enabled = oldEnabled
    end)

    check("SeaViewArt.Sky 接入：零状态改写（不触碰相机）", function()
        local movement = makeMovement(0)
        SeaViewArt.Sky({}, movement, WIDTH, HEIGHT, 1.5)
        assert(movement.camera.x == 0 and movement.camera.y == 0,
            "Sky 不得改写相机状态")
    end)

    check("catalog 规格：天空两图 1920×1080、preload=false、repeatTexture=true", function()
        local day = assert(ImageArt.GetSpec("sky_day"))
        assert(day.preload == false, "天空懒加载（首个 Backdrop 帧按需加载一次）")
        assert(day.repeatTexture == true, "横向无缝循环标志")
        assert(day.pixelWidth == 1920 and day.pixelHeight == 1080)
        assert(day.path == SKY_DAY_PATH)
        local dusk = assert(ImageArt.GetSpec("sky_dusk"))
        assert(dusk.preload == false and dusk.repeatTexture == true)
        assert(dusk.pixelWidth == 1920 and dusk.pixelHeight == 1080)
        assert(dusk.path == SKY_DUSK_PATH)
    end)

    restoreStubs()
    return { results = results }
end

return Tests
