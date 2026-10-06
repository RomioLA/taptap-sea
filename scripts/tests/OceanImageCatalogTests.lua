-- 图片目录与接入层契约：不创建世界、不改变实体或玩法。
local Tests = {}

function Tests.Run()
    local Art = require("Ocean.ImageArt")
    local results = {}
    local function check(name, callback)
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end
    local oldCreate, oldDelete = nvgCreateImage, nvgDeleteImage
    local oldMipmap, oldRepeatX, oldRepeatY = NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY
    local oldPlane = Art.Plane
    local created, deleted, failedPath = {}, {}, ""
    local startupNames = { "boat", "island", "barrel", "gull", "ripple", "waterpaper", "gull_dive", "splash" }
    local startupCount = #startupNames
    local a, b = {}, {}
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
        assert(#created == 0)
    end)
    check("正式启动只加载已接入世界素材且重复调用幂等", function()
        Art.Load(a)
        Art.Load(a)
        assert(#created == startupCount)
        for _, name in ipairs(startupNames) do
            assert(Art.IsLoaded(a, name))
        end
        assert(not Art.IsLoaded(a, "reef") and not Art.IsLoaded(a, "sardine"))
        for _, entry in ipairs(created) do
            assert(entry.flags == (entry.path:find("waterpaper", 1, true) and 7 or 1))
        end
    end)
    check("新增候选显式加载且不影响另一上下文", function()
        assert(Art.LoadImage(a, "reef") and Art.LoadImage(a, "reef"))
        assert(#created == startupCount + 1 and Art.IsLoaded(a, "reef") and not Art.IsLoaded(b, "reef"))
        assert(Art.LoadImage(b, "shrub"))
        Art.Load(b)
        assert(#created == startupCount * 2 + 2 and Art.IsLoaded(b, "boat"))
    end)
    check("失败只尝试一次并保留矢量回退", function()
        failedPath = Art.GetSpec("driftwood").path
        assert(not Art.LoadImage(a, "driftwood") and not Art.LoadImage(a, "driftwood"))
        assert(#created == startupCount * 2 + 3 and not Art.IsLoaded(a, "driftwood"))
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
        assert(#deleted == startupCount + 2 and not Art.IsLoaded(a, "boat") and Art.IsLoaded(b, "boat"))
        Art.Release(b)
        assert(#deleted == startupCount * 2 + 3 and not Art.IsLoaded(b, "shrub"))
    end)
    check("停止后可重新加载候选与默认集", function()
        assert(Art.LoadImage(a, "driftwood"))
        Art.Load(a)
        assert(Art.IsLoaded(a, "driftwood") and Art.IsLoaded(a, "boat"))
        Art.Release(a)
        assert(#deleted == startupCount * 3 + 4)
    end)
    Art.Plane = oldPlane
    Art.Release(a)
    Art.Release(b)
    nvgCreateImage, nvgDeleteImage = oldCreate, oldDelete
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = oldMipmap, oldRepeatX, oldRepeatY
    return { results = results }
end

return Tests
