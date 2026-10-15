-- 图片目录与接入层契约：不创建世界、不改变实体或玩法。
local Tests = {}

function Tests.Run()
    local Art = require("Ocean.ImageArt")
    local ArtVariants = require("Ocean.ArtVariants")
    local results = {}
    local function check(name, callback)
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end
    local oldCreate, oldDelete = nvgCreateImage, nvgDeleteImage
    local oldMipmap, oldRepeatX, oldRepeatY = NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY
    local oldPlane = Art.Plane
    local variantsWereEnabled = ArtVariants.IsEnabled()
    ArtVariants.SetEnabled(true) -- 本套件锁定变体开启契约；结束前还原
    local created, deleted, failedPath = {}, {}, ""
    local a, b, c = {}, {}, {}
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = 1, 2, 4
    nvgCreateImage = function(ctx, path, flags)
        created[#created + 1] = { ctx = ctx, path = path, flags = flags }
        if path == failedPath then return -1 end
        return #created
    end
    nvgDeleteImage = function(ctx, image) deleted[#deleted + 1] = { ctx = ctx, image = image } end

    check("目录规格只返回副本且未知名称无效", function()
        local spec = assert(Art.GetSpec("sardine"))
        assert(spec.path == "image/OceanReady/sardine.png" and spec.anchorX == 0.5 and spec.anchorY == 0.5)
        spec.path = "错误路径"
        assert(Art.GetSpec("sardine").path == "image/OceanReady/sardine.png")
        assert(Art.GetSpec("missing") == nil and not Art.LoadImage(a, "missing"))
        -- 2026-10-16 用户裁决：船贴图替换效果不好，还原无贴图矢量形态；
        -- boat/boat_story 目录项与素材文件同步移除，此处锁定移除契约。
        assert(Art.GetSpec("boat") == nil and Art.GetSpec("boat_story") == nil,
            "船目录项应已移除")
        assert(#created == 0)
    end)
    check("正式启动加载五张原图与全部 story 变体且重复调用幂等", function()
        -- 2026-10-15 修复前此处锁定 #created==6（story 变体无加载路径的 bug 契约）；
        -- 现在 ArtVariants 开启时 Load 必须连带预载 4 个 story 目标
        -- （boat_story 于 2026-10-16 随船贴图移除）。
        Art.Load(a)
        Art.Load(a)
        assert(#created == 9)
        for _, name in ipairs({ "island", "barrel", "gull", "ripple", "waterpaper" }) do
            assert(Art.IsLoaded(a, name))
        end
        for _, name in ipairs(ArtVariants.StoryTargets()) do
            assert(Art.GetSpec(name), name .. " 必须在 catalog 中存在")
            assert(Art.IsLoaded(a, name), name .. " 必须随变体开启预载")
        end
        assert(not Art.IsLoaded(a, "reef") and not Art.IsLoaded(a, "sardine"))
        for _, entry in ipairs(created) do
            assert(entry.flags == (entry.path:find("waterpaper", 1, true) and 7 or 1))
        end
    end)
    check("story 变体目标清单与 catalog 一一对应", function()
        local targets = ArtVariants.StoryTargets()
        assert(#targets == 4, "story 目标应为 4 个，实际 " .. #targets)
        local seen = {}
        for _, name in ipairs(targets) do
            assert(not seen[name], name .. " 重复")
            seen[name] = true
            assert(Art.GetSpec(name) and not Art.GetSpec(name).preload,
                name .. " 应存在且保持 preload=false")
        end
        seen["island_story"], seen["barrel_story"] = true, true
        seen["gull_story"], seen["waterpaper_story"] = true, true
    end)
    check("变体漏载时 WaterPaper 按需加载一次后仍尊重地平线缺失", function()
        -- 修复前：waterpaper_story 永不加载，WaterPaper 直接返回 false，
        -- 海面纸纹层整体消失（Fill 0/f 的组成部分）。
        assert(not Art.IsLoaded(c, "waterpaper_story"))
        assert(not Art.WaterPaper(c, {}, 640, 360))
        assert(#created == 10 and Art.IsLoaded(c, "waterpaper_story"))
        Art.Release(c)
        assert(#deleted == 1 and not Art.IsLoaded(c, "waterpaper_story"))
    end)
    check("新增候选显式加载且不影响另一上下文", function()
        assert(Art.LoadImage(a, "reef") and Art.LoadImage(a, "reef"))
        assert(#created == 11 and Art.IsLoaded(a, "reef") and not Art.IsLoaded(b, "reef"))
        assert(Art.LoadImage(b, "shrub"))
        Art.Load(b)
        assert(#created == 21 and Art.IsLoaded(b, "island"))
    end)
    check("失败只尝试一次并保留矢量回退", function()
        failedPath = Art.GetSpec("driftwood").path
        assert(not Art.LoadImage(a, "driftwood") and not Art.LoadImage(a, "driftwood"))
        assert(#created == 22 and not Art.IsLoaded(a, "driftwood"))
        assert(not Art.Sprite(a, "driftwood", {}, { x = 0, y = 0 }, 2, 0))
        failedPath = ""
    end)
    check("主体尺寸自动补偿留边且保持鱼体比例", function()
        assert(Art.LoadImage(a, "sardine"))
        local called = {}
        Art.Plane = function(ctx, name, movement, origin, length, width, heading, altitude, alpha, roll)
            called = { ctx = ctx, name = name, origin = origin, length = length, width = width,
                heading = heading, altitude = altitude, alpha = alpha, roll = roll }
            return true
        end
        local position = { x = 1, y = 2 }
        assert(Art.Sprite(a, "sardine", {}, position, 1.5, math.pi / 2, 0.2, 0.7))
        local spec = Art.GetSpec("sardine")
        assert(math.abs(called.length - 1.5 * spec.pixelWidth / spec.contentWidth) < 1e-9)
        assert(math.abs(called.width - 1.5 * spec.pixelHeight / spec.contentWidth) < 1e-9)
        assert(called.origin == position and called.heading == math.pi / 2 and called.alpha == 0.7)
        assert(position.x == 1 and position.y == 2)
        assert(Art.Sprite(a, "sardine", {}, position, 1.5, 0, 0, 1, 0.4, 0.1))
        assert(math.abs(called.width - 0.4 * spec.pixelHeight / spec.contentHeight) < 1e-9 and called.roll == 0.1)
        Art.Plane = oldPlane
    end)
    check("无效尺寸和未加载图不提交绘制", function()
        assert(not Art.Sprite(a, "sardine", {}, { x = 0, y = 0 }, 0, 0))
        assert(not Art.Sprite(a, "sardine", {}, { x = 0, y = 0 }, 1, 0, 0, 1, -1))
        assert(not Art.Sprite(a, "shrub", {}, { x = 0, y = 0 }, 1, 0))
    end)
    check("停止释放仅当前上下文的成功句柄且幂等", function()
        Art.Release(a)
        Art.Release(a)
        -- 计数含 test 4 的 Release(c)（+1）：a=9(启动)+reef+sardine=11，c=1。
        assert(#deleted == 12 and not Art.IsLoaded(a, "island") and Art.IsLoaded(b, "island"))
        Art.Release(b)
        assert(#deleted == 22 and not Art.IsLoaded(b, "shrub"))
    end)
    check("停止后可重新加载候选与默认集", function()
        assert(Art.LoadImage(a, "driftwood"))
        Art.Load(a)
        assert(Art.IsLoaded(a, "driftwood") and Art.IsLoaded(a, "island"))
        Art.Release(a)
        assert(#deleted == 32)
    end)
    Art.Plane = oldPlane
    Art.Release(a)
    Art.Release(b)
    nvgCreateImage, nvgDeleteImage = oldCreate, oldDelete
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = oldMipmap, oldRepeatX, oldRepeatY
    ArtVariants.SetEnabled(variantsWereEnabled)
    return { results = results }
end

return Tests
