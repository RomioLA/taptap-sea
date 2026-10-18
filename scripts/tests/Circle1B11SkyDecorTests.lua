-- 日月云贴图（SkyDecor）接入白盒测试（2026-10-19 读海美术接入）。
-- 守护契约：
--   1) catalog 规格：四图（sky_sun/sky_moon/sky_cloud_dark/sky_cloud_light）
--      preload=false（首帧懒加载）、repeatTexture=false（单件精灵不循环）、尺寸契约；
--   2) Art.ScreenSprite：懒加载一次且仅 MIPMAPS（无循环标志）、imagePattern 参数口径
--      （ox/oy=左上角、cell=目标宽高、angle=0、alpha 透传）、宽高比推导、save/restore
--      配平、不使用 scissor、失败一次即缓存不重试、未知名/非法宽度返回 false；
--   3) Draw.Background 接入：day=太阳+日云、night=月亮+夜云、无相位=太阳+日云
--      （headless 旧观感）、day 末段日夜云交叉淡入、夜间不加载日云；
--   4) 兜底零回归：贴图加载失败回退矢量（nvgEllipse/nvgBezierTo 仍被调用）、
--      skyDecor.enabled=false 整层回退矢量、alpha 经 config 透传。
local Tests = {}

local Draw = require("Ocean.Draw")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")

local WIDTH, HEIGHT = 1280, 720
local DECOR_PATH = "image/SkyDecor/"

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

local function near(actual, expected, tolerance)
    assert(type(actual) == "number" and type(expected) == "number"
        and math.abs(actual - expected) <= (tolerance or 0.001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

local function decorPatterns()
    local found = {}
    for _, pattern in ipairs(patterns) do
        local path = pathOf(pattern.image)
        if path:sub(1, #DECOR_PATH) == DECOR_PATH then
            found[#found + 1] = { path = path, pattern = pattern }
        end
    end
    return found
end

local function pathsOfDecor()
    local list = {}
    for _, entry in ipairs(decorPatterns()) do list[#list + 1] = entry.path end
    return list
end

function Tests.Run(recorder)
    installStubs()
    local results = {}
    local function check(name, callback)
        fresh()
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("catalog 规格：四图 preload=false、repeatTexture=false、尺寸契约", function()
        local expected = {
            sky_sun = { path = DECOR_PATH .. "sky_sun.png", w = 512, h = 511 },
            sky_moon = { path = DECOR_PATH .. "sky_moon.png", w = 512, h = 512 },
            sky_cloud_dark = { path = DECOR_PATH .. "sky_cloud_dark.png", w = 512, h = 234 },
            sky_cloud_light = { path = DECOR_PATH .. "sky_cloud_light.png", w = 512, h = 224 },
        }
        for name, spec in pairs(expected) do
            local entry = assert(ImageArt.GetSpec(name), name .. " 缺 catalog 条目")
            assert(entry.path == spec.path, name .. " 路径不符：" .. entry.path)
            assert(entry.preload == false, name .. " 应懒加载（首个 Backdrop 帧按需加载一次）")
            assert(entry.repeatTexture == false, name .. " 单件精灵不应带循环标志")
            assert(entry.pixelWidth == spec.w and entry.pixelHeight == spec.h,
                name .. " 尺寸不符契约")
        end
    end)

    check("Art.ScreenSprite：懒加载一次且仅 MIPMAPS，重复调用不重复创建", function()
        local ctx = {}
        assert(ImageArt.ScreenSprite(ctx, "sky_sun", 100, 50, 64))
        assert(#created == 1, "首次绘制应触发一次按需加载")
        assert(created[1].path == DECOR_PATH .. "sky_sun.png")
        assert(created[1].flags == 1, "单件精灵只应带 MIPMAPS（无 REPEATX/REPEATY）")
        assert(ImageArt.ScreenSprite(ctx, "sky_sun", 100, 50, 64))
        assert(#created == 1, "同上下文同图只应加载一次")
    end)

    check("Art.ScreenSprite：imagePattern 参数口径（居中/宽高比/alpha 透传）", function()
        local ctx = {}
        assert(ImageArt.ScreenSprite(ctx, "sky_cloud_light", 300, 120, 120, 0.6))
        assert(#patterns == 1)
        local first = patterns[1]
        near(first.ox, 300 - 60, 1e-9, "ox=左边界（中心 - 宽/2）")
        near(first.oy, 120 - 120 * 224 / 512 / 2, 1e-9, "oy=上边界（中心 - 高/2）")
        near(first.w, 120, 1e-9)
        near(first.h, 120 * 224 / 512, 1e-9, "高度按源图宽高比推导")
        near(first.angle, 0, 1e-9)
        near(first.alpha, 0.6, 1e-9)
        patterns = {}
        assert(ImageArt.ScreenSprite(ctx, "sky_cloud_light", 300, 120, 120))
        near(patterns[1].alpha, 1, 1e-9, "alpha 缺省应不透明")
    end)

    check("Art.ScreenSprite：save/restore 配平且不使用 scissor", function()
        local ctx = {}
        recorder.reset()
        assert(ImageArt.ScreenSprite(ctx, "sky_moon", 100, 50, 64))
        assert(recorder.callCount("nvgSave") == 1 and recorder.callCount("nvgRestore") == 1)
        assert(recorder.callCount("nvgScissor") == 0, "屏幕空间精灵不得用 scissor 裁剪")
    end)

    check("Art.ScreenSprite：失败一次即缓存；未知名/非法宽度返回 false", function()
        local failCtx = {}
        failedPath = DECOR_PATH .. "sky_sun.png"
        assert(not ImageArt.ScreenSprite(failCtx, "sky_sun", 10, 10, 32))
        assert(#created == 1, "失败应只尝试一次")
        assert(not ImageArt.ScreenSprite(failCtx, "sky_sun", 10, 10, 32))
        assert(#created == 1, "失败句柄 -1 已缓存，不得每帧重试")
        failedPath = ""
        assert(not ImageArt.ScreenSprite({}, "sky_missing", 10, 10, 32), "未知名应返回 false")
        assert(not ImageArt.ScreenSprite({}, "sky_sun", 10, 10, 0), "非正宽度应返回 false")
        assert(not ImageArt.ScreenSprite({}, "sky_sun", 10, 10, -8), "负宽度应返回 false")
    end)

    check("Background 接入：day 画太阳+日云，不加载月亮与夜云", function()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "day", progress = 0.5 })
        local list = pathsOfDecor()
        assert(#list == 3, "day 应为 1 太阳 + 2 日云，实际 " .. #list)
        assert(list[1] == DECOR_PATH .. "sky_sun.png", "首绘为太阳贴图")
        assert(list[2] == DECOR_PATH .. "sky_cloud_light.png")
        assert(list[3] == DECOR_PATH .. "sky_cloud_light.png")
    end)

    check("Background 接入：night 画月亮+夜云，不加载太阳与日云", function()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "night", progress = 0.5 })
        local list = pathsOfDecor()
        assert(#list == 3, "night 应为 1 月亮 + 2 夜云，实际 " .. #list)
        assert(list[1] == DECOR_PATH .. "sky_moon.png")
        assert(list[2] == DECOR_PATH .. "sky_cloud_dark.png")
        assert(list[3] == DECOR_PATH .. "sky_cloud_dark.png")
    end)

    check("Background 接入：无相位（headless 旧观感）= 太阳+日云", function()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0)
        local list = pathsOfDecor()
        assert(#list == 3, "无 clock 应为 1 太阳 + 2 日云，实际 " .. #list)
        assert(list[1] == DECOR_PATH .. "sky_sun.png")
        assert(list[2] == DECOR_PATH .. "sky_cloud_light.png")
    end)

    check("Background 接入：day 末段日夜云交叉淡入（两态云并存）", function()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "day", progress = 0.9 })
        local list = pathsOfDecor()
        assert(#list == 5, "day 0.9 应为太阳 + 日云×2 + 夜云×2，实际 " .. #list)
        local found = {}
        for _, path in ipairs(list) do found[path] = (found[path] or 0) + 1 end
        assert(found[DECOR_PATH .. "sky_cloud_light.png"] == 2, "日云仍在（淡出中）")
        assert(found[DECOR_PATH .. "sky_cloud_dark.png"] == 2, "夜云已叠加（淡入中）")
    end)

    check("Background 接入：太阳/月亮贴图宽度按核心盘比例反推", function()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "day", progress = 0.5 })
        local sunRadius = math.min(WIDTH * 0.055, HEIGHT * 0.065)
        local sun = decorPatterns()[1].pattern
        near(sun.w, 2 * sunRadius / 0.72, 1e-9, "太阳核心盘与原矢量同径（比例 0.72）")
        fresh()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "night", progress = 0.5 })
        local moon = decorPatterns()[1].pattern
        near(moon.w, 2 * sunRadius * 0.78 / 0.80, 1e-9, "月亮核心盘与原矢量同径（比例 0.80）")
    end)

    check("兜底零回归：贴图加载失败回退矢量日/月/云", function()
        failedPath = DECOR_PATH .. "sky_sun.png"
        recorder.reset()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "day", progress = 0.5 })
        assert(recorder.callCount("nvgEllipse") >= 3, "太阳贴图失败应回退矢量圆盘")
        for _, entry in ipairs(pathsOfDecor()) do
            assert(entry ~= DECOR_PATH .. "sky_sun.png", "失败后不得再绘制太阳贴图")
        end
        failedPath = ""
        fresh()
        recorder.reset()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "night", progress = 0.5 })
        failedPath = DECOR_PATH .. "sky_cloud_dark.png"
        recorder.reset()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "night", progress = 0.5 })
        assert(recorder.callCount("nvgBezierTo") >= 2, "云贴图失败应回退矢量贝塞尔云")
        failedPath = ""
    end)

    check("兜底零回归：skyDecor.enabled=false 整层回退矢量", function()
        local oldEnabled = Config.visual.skyDecor.enabled
        Config.visual.skyDecor.enabled = false
        fresh()
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "day", progress = 0.5 })
        assert(#decorPatterns() == 0, "关闭后不应绘制任何日月云贴图")
        Config.visual.skyDecor.enabled = oldEnabled
    end)

    check("Background 接入：alpha 经 config 透传", function()
        local oldAlpha = Config.visual.skyDecor.alpha
        Config.visual.skyDecor.alpha = 0.8
        Draw.SceneBackdrop({}, WIDTH, HEIGHT, 0, false, { phase = "day", progress = 0.5 })
        for _, entry in ipairs(decorPatterns()) do
            near(entry.pattern.alpha, 0.8, 1e-9, "贴图 alpha = config.alpha")
        end
        Config.visual.skyDecor.alpha = oldAlpha
    end)

    restoreStubs()
    return { results = results }
end

return Tests