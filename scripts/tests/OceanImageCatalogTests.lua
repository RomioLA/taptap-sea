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
    -- 基础 preload + W2 海鸥/浪花候选 + 四个 story 目标；船贴图与完整岛屿
    -- 候选保留在素材清单，但不替换主线矢量船和分层岛屿的运行目录项。
    -- 2026-10-20：清单改由 catalog 的 preload 标记 + ArtVariants 的 story 目标
    -- 推导，不再手写名单——否则每加一张预载图（近景焦散 water_caustic_light）
    -- 都要改测试，而测的其实是「Art.Load 是否履行了 catalog 声明」。
    local catalog = require("GeneratedData.OceanImageCatalog")
    local startupNames, seenStartup = {}, {}
    local function addStartup(name)
        if not seenStartup[name] then
            seenStartup[name] = true
            startupNames[#startupNames + 1] = name
        end
    end
    for name, spec in pairs(catalog) do
        if spec.preload then addStartup(name) end
    end
    -- story 变体 preload=false，但 Art.Load 在 ArtVariants 开启时会连带预载。
    for _, name in ipairs(ArtVariants.StoryTargets()) do addStartup(name) end
    table.sort(startupNames)
    local startupCount = #startupNames
    local a, b, c = {}, {}, {}
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = 1, 2, 4
    nvgCreateImage = function(ctx, path, flags)
        -- 记下 path → catalog 名，后续按 catalog 的真实 repeatTexture 判定标志位。
        local name
        for candidate, spec in pairs(require("GeneratedData.OceanImageCatalog")) do
            if spec.path == path then name = candidate; break end
        end
        created[#created + 1] = { ctx = ctx, path = path, flags = flags, name = name }
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
        local island = assert(Art.GetSpec("island"))
        assert(island.path == "image/OceanLoop/island.png" and not island.completeIsland,
            "完整岛候选不得替换分层岛屿运行项")
        assert(#created == 0)
    end)
    check("正式启动加载运行素材与全部 story 变体且重复调用幂等", function()
        Art.Load(a)
        Art.Load(a)
        assert(#created == startupCount)
        for _, name in ipairs(startupNames) do
        -- 2026-10-15 修复前此处锁定 #created==6（story 变体无加载路径的 bug 契约）；
        -- 现在 ArtVariants 开启时 Load 必须连带预载 4 个 story 目标
        -- （boat_story 于 2026-10-16 随船贴图移除）。
            assert(Art.IsLoaded(a, name), name .. " 声明 preload=true 却没有在 Art.Load 装入")
        end
        assert(Art.IsLoaded(a, "sea_surface_day") and Art.IsLoaded(a, "sea_ripple_overlay"),
            "海面底图/波纹层必须启动即载（首帧即需）")
        assert(Art.IsLoaded(a, "water_caustic_light"),
            "近景焦散 preload=true：必须在启动期解码，避免首帧尖峰")
        for _, name in ipairs(ArtVariants.StoryTargets()) do
            assert(Art.GetSpec(name), name .. " 必须在 catalog 中存在")
            assert(Art.IsLoaded(a, name), name .. " 必须随变体开启预载")
        end
        assert(not Art.IsLoaded(a, "reef") and not Art.IsLoaded(a, "sardine"))
        assert(not Art.IsLoaded(a, "sea_surface_night"),
            "夜图 preload=false：不随场景启动加载（SeaDebug/后续方案）")
        for _, entry in ipairs(created) do
            -- 重复纹理（catalog repeatTexture=true）才带 REPEATX|REPEATY|MIPMAPS=7。
            -- 2026-10-20：旧断言只列 waterpaper / sea_surface 两个前缀，
            -- 漏掉了同为 repeatTexture 的 sea_ripple_overlay（波纹平铺层），
            -- 于是把正确的 7 误判成回归。改为按 catalog 的真实标志判定。
            local spec = assert(Art.GetSpec(entry.name or ""), "created image must come from the catalog")
            local expected = spec.repeatTexture and 7 or 1
            assert(entry.flags == expected,
                entry.path .. " flags=" .. tostring(entry.flags) .. " expected=" .. tostring(expected))
        end
    end)
    check("story 变体目标清单与 catalog 一一对应", function()
        local targets = ArtVariants.StoryTargets()
        assert(#targets == 4, "story 目标应为 4 个，实际 " .. #targets)
        local expected = {
            island_story = true, barrel_story = true,
            gull_story = true, waterpaper_story = true,
        }
        local seen = {}
        for _, name in ipairs(targets) do
            assert(expected[name] and not seen[name], name .. " 未预期或重复")
            seen[name] = true
            assert(Art.GetSpec(name) and not Art.GetSpec(name).preload,
                name .. " 应存在且保持 preload=false")
        end
        for name in pairs(expected) do assert(seen[name], name .. " 未进入 story 目标清单") end
    end)
    check("变体漏载时 WaterPaper 按需加载一次后仍尊重地平线缺失", function()
        -- 修复前：waterpaper_story 永不加载，WaterPaper 直接返回 false，
        -- 海面纸纹层整体消失（Fill 0/f 的组成部分）。
        assert(not Art.IsLoaded(c, "waterpaper_story"))
        local createdBefore, deletedBefore = #created, #deleted
        assert(not Art.WaterPaper(c, {}, 640, 360))
        assert(#created == createdBefore + 1 and Art.IsLoaded(c, "waterpaper_story"))
        Art.Release(c)
        assert(#deleted == deletedBefore + 1 and not Art.IsLoaded(c, "waterpaper_story"))
    end)
    check("新增候选显式加载且不影响另一上下文", function()
        local before = #created
        assert(Art.LoadImage(a, "reef") and Art.LoadImage(a, "reef"))
        assert(#created == before + 1 and Art.IsLoaded(a, "reef") and not Art.IsLoaded(b, "reef"))
        assert(Art.LoadImage(b, "shrub"))
        Art.Load(b)
        assert(#created == before + startupCount + 2 and Art.IsLoaded(b, "island"))
    end)
    check("失败只尝试一次并保留矢量回退", function()
        failedPath = Art.GetSpec("driftwood").path
        local before = #created
        assert(not Art.LoadImage(a, "driftwood") and not Art.LoadImage(a, "driftwood"))
        assert(#created == before + 1 and not Art.IsLoaded(a, "driftwood"))
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
        local before = #deleted
        Art.Release(a)
        Art.Release(a)
        assert(#deleted == before + startupCount + 2
            and not Art.IsLoaded(a, "island") and Art.IsLoaded(b, "island"))
        before = #deleted
        Art.Release(b)
        assert(#deleted == before + startupCount + 1 and not Art.IsLoaded(b, "shrub"))
    end)
    check("停止后可重新加载候选与默认集", function()
        assert(Art.LoadImage(a, "driftwood"))
        Art.Load(a)
        assert(Art.IsLoaded(a, "driftwood") and Art.IsLoaded(a, "island"))
        local before = #deleted
        Art.Release(a)
        assert(#deleted == before + startupCount + 1)
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
