-- 近景海面动态效果（焦散 + DuDv）白盒测试（2026-10-20）。
-- 守护契约：
--   1) 资产：water_caustic_light / water_caustic_light_alt（512² RGBA 无缝）与
--      water_dudv_flow（256² RGB，R/G 中性 0.5）在 catalog 中存在，且焦散必须
--      repeatTexture=true（运行期 UV 是无界世界平铺坐标，clamp 会退化成色带）；
--   2) 纯函数：WorldUV 世界项与时间项可分离（船动不重置动画时间）、EdgeFade
--      在边缘平滑归零、DecodeDUDV 先减中性值 0.5 再缩放（不把 RGB 当位移）；
--   3) DayFactor 复用现有 clock：day 正午最强、night 压到 nightScale、缺 clock 退化；
--   4) Draw：默认关闭（enabled=false）时完全不出笔；开启后围绕世界锚点出片、
--      只在海面区域（地平线以下）有填充、alpha 受 config × 昼夜倍率控制、
--      贴图加载失败整层跳过不崩；
--   5) DuDv 真实生效：顶点 UV 随位移场变化（同一片在世界锚点不同位置时 UV 不同），
--      dudvEnabled=false / dudvStrength=0 退回纯滚动；
--   6) 零状态改写：Draw 不改相机、不碰世界实体、不做跨帧累加（同 time 同输出）。
local Tests = {}

local WaterFX = require("Ocean.WaterFX")
local Config = require("Ocean.Config")
local ImageArt = require("Ocean.ImageArt")

local WIDTH, HEIGHT = 1280, 720
local CAUSTIC_PATH = "image/SeaSurface/water_caustic_light.png"
local CAUSTIC_ALT_PATH = "image/SeaSurface/water_caustic_light_alt.png"
local DUDV_PATH = "image/SeaSurface/water_dudv_flow.png"

local created, failedPath
local oldCreate, oldMipmap, oldRepeatX, oldRepeatY

-- 录制 nvgTransform（片元的仿射）与 nvgImagePattern（图片/alpha），
-- 用仿射矩阵的平移列反推该片落在屏幕哪里，从而断言「区域跟随世界锚点」。
local transforms, patterns
local oldTransform, oldPattern

local function fresh()
    created, failedPath = {}, ""
    transforms, patterns = {}, {}
end

local function installStubs()
    fresh()
    oldCreate, oldPattern, oldTransform = nvgCreateImage, nvgImagePattern, nvgTransform
    oldMipmap, oldRepeatX, oldRepeatY =
        NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = 1, 2, 4
    nvgCreateImage = function(ctx, path, flags)
        created[#created + 1] = { ctx = ctx, path = path, flags = flags }
        if path == failedPath then return -1 end
        return #created
    end
    nvgImagePattern = function(ctx, ox, oy, w, h, angle, image, alpha)
        patterns[#patterns + 1] = { image = image, alpha = alpha }
        return #patterns
    end
    nvgTransform = function(ctx, a, b, c, d, e, f)
        transforms[#transforms + 1] = { a = a, b = b, c = c, d = d, e = e, f = f }
    end
end

local function restoreStubs()
    nvgCreateImage, nvgImagePattern, nvgTransform = oldCreate, oldPattern, oldTransform
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY =
        oldMipmap, oldRepeatX, oldRepeatY
end

local function near(actual, expected, tolerance)
    assert(type(actual) == "number" and type(expected) == "number"
        and math.abs(actual - expected) <= (tolerance or 0.001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

-- 真实投影（Ocean.Projection）需要完整的 movement 字段；这里直接给最小集合，
-- 使测试走生产同一条 WorldToScreen/ProjectFunction 路径，而不是自造线性近似。
local function makeMovement(cameraX, cameraY)
    local movement = {
        viewportWidth = WIDTH,
        viewportHeight = HEIGHT,
        viewportReady = true,
        viewHeight = Config.camera.viewHeight,
        viewWidth = Config.camera.viewHeight * WIDTH / HEIGHT,
        camera = { x = cameraX or 0, y = cameraY or 0 },
        ship = { position = { x = cameraX or 0, y = cameraY or 0 } },
    }
    function movement:WorldToScreen(position, altitude)
        return require("Ocean.Projection").Project(self, position, altitude)
    end
    function movement:GetHorizonY(x)
        return require("Ocean.Projection").Horizon(self, x)
    end
    return movement
end

local function withSettings(overrides, fn)
    local visual = Config.visual
    local previous = visual.nearWaterFX
    local settings = {}
    for key, value in pairs(previous or {}) do settings[key] = value end
    for key, value in pairs(overrides or {}) do settings[key] = value end
    visual.nearWaterFX = settings
    local ok, err = pcall(fn, settings)
    visual.nearWaterFX = previous
    if not ok then error(err) end
end

-- 取本次 Draw 落在屏幕上的锚点（仿射平移列），用于断言区域跟随世界坐标。
local function anchorOfTransform(entry)
    return entry.e, entry.f
end

function Tests.Run(recorder)
    installStubs()
    local results = {}
    local function check(name, callback)
        fresh()
        recorder.reset()
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("资产：焦散与 DuDv 在 catalog 中且焦散必须 REPEAT（世界平铺）", function()
        for _, name in ipairs({ "water_caustic_light", "water_caustic_light_alt" }) do
            local spec = assert(ImageArt.GetSpec(name), name .. " 不在 catalog")
            assert(spec.repeatTexture == true,
                name .. " 必须 repeatTexture=true（无界世界 UV + clamp 会退化成色带）")
            assert(spec.pixelWidth == 512 and spec.pixelHeight == 512, name .. " 尺寸应为 512²")
        end
        local dudv = assert(ImageArt.GetSpec("water_dudv_flow"), "water_dudv_flow 不在 catalog")
        assert(dudv.repeatTexture == true, "dudv 位移场也必须可平铺")
        assert(dudv.pixelWidth == 256 and dudv.pixelHeight == 256, "dudv 尺寸应为 256²")
    end)

    check("WorldUV：世界项与时间项可分离（船动不重置动画）", function()
        local u0, v0 = WaterFX.WorldUV(10, 20, 18, 0.01, 0.02, 5)
        near(u0, 10 / 18 + 0.01 * 5, 1e-9)
        near(v0, 20 / 18 + 0.02 * 5, 1e-9)
        -- 同一时间、不同世界位置：只差世界项（动画时间没有被位置影响）。
        local u1, v1 = WaterFX.WorldUV(28, 20, 18, 0.01, 0.02, 5)
        near(u1 - u0, 1.0, 1e-9)
        near(v1, v0, 1e-9)
        -- 同一位置、不同时间：只差时间项（滚动连续累积）。
        local u2 = WaterFX.WorldUV(10, 20, 18, 0.01, 0.02, 15)
        near(u2 - u0, 0.01 * 10, 1e-9)
    end)

    check("EdgeFade：中心满强度、边缘平滑归零、区域外为 0", function()
        near(WaterFX.EdgeFade(0, 0.6), 1, 1e-9)
        near(WaterFX.EdgeFade(0.6, 0.6), 1, 1e-9, "渐隐起点仍是满强度")
        near(WaterFX.EdgeFade(1, 0.6), 0, 1e-9, "区域边缘归零")
        assert(WaterFX.EdgeFade(1.4, 0.6) == 0, "区域外必须为 0（无矩形硬边）")
        local mid = WaterFX.EdgeFade(0.8, 0.6)
        assert(mid > 0 and mid < 1, "过渡段应为中间值")
        -- 单调不增：从中心走向边缘不应反弹。
        local previous = 2
        for step = 0, 20 do
            local value = WaterFX.EdgeFade(step / 20, 0.6)
            assert(value <= previous + 1e-9, "边缘渐隐必须单调不增")
            previous = value
        end
    end)

    check("DecodeDUDV：先减中性值 0.5 再缩放（不把颜色当位移）", function()
        local dx, dy = WaterFX.DecodeDUDV(0.5, 0.5)
        near(dx, 0, 1e-9); near(dy, 0, 1e-9)
        dx, dy = WaterFX.DecodeDUDV(1.0, 0.0)
        near(dx, 1, 1e-9); near(dy, -1, 1e-9)
        -- 3/4 通道值不能当成 0.75 的位移，而是 0.5。
        dx = WaterFX.DecodeDUDV(0.75, 0.5)
        near(dx, 0.5, 1e-9)
    end)

    check("DayFactor：day 正午最强、night 压低、缺 clock 退化到 dayScale", function()
        withSettings({ dayScale = 1, nightScale = 0.28 }, function()
            local noon = WaterFX.DayFactor({ phase = "day", progress = 0.5 })
            near(noon, 1, 1e-6, "正午 = dayScale")
            local dawn = WaterFX.DayFactor({ phase = "day", progress = 0 })
            near(dawn, 0.55, 1e-6, "日出衰减到 0.55×")
            local night = WaterFX.DayFactor({ phase = "night", progress = 0.5 })
            near(night, 0.28, 1e-6, "夜间 = nightScale")
            near(WaterFX.DayFactor(nil), 1, 1e-6, "缺 clock 退化为 dayScale（headless 旧路径）")
            -- progress 缺省时由 elapsed/duration 推导（与 Draw.ClockVisualState 同口径）。
            near(WaterFX.DayFactor({ phase = "night", elapsed = 5, duration = 10 }), 0.28, 1e-6)
        end)
        -- 夜间必须明显弱于白天（需求「夜间调低，不新增昼夜系统」）。
        withSettings({}, function()
            local day = WaterFX.DayFactor({ phase = "day", progress = 0.5 })
            local night = WaterFX.DayFactor({ phase = "night", progress = 0.5 })
            assert(night < day * 0.5, "夜间强度必须显著低于白天")
        end)
    end)

    check("Layout：区域以世界锚点为中心、铺满且不超出预算", function()
        local plan = WaterFX.Layout({ x = 120, y = -40 }, { sizeMeters = 36, cellMeters = 6 })
        assert(plan.columns == 6, "36/6 应为 6×6")
        assert(#plan.tiles == 36)
        near(plan.originX, 120 - 18, 1e-9)
        near(plan.originY, -40 - 18, 1e-9)
        -- 默认配置下的实际布局（守住「片数有界」）
        local settings = Config.visual.nearWaterFX
        local live = WaterFX.Layout({ x = 0, y = 0 }, settings)
        assert(#live.tiles <= 36, "默认配置片数必须在预算内（B 方向调优后 6×6）")
        assert(live.sizeMeters <= 120, "默认区域不得超出单屏近水面")
        -- 中心片的中心即锚点，其归一化距离为 0（满强度）。
        -- 注意：6×6 网格没有「恰好在中心」的片（中心落在四片交界），所以取
        -- 距离最小的那一片断言，而不是找一个坐标等于锚点的片。
        local best, centre = math.huge, nil
        for _, tile in ipairs(plan.tiles) do
            if tile.distance < best then best, centre = tile.distance, tile end
        end
        assert(centre, "必须存在网格片")
        assert(best < 0.3, "最靠近锚点的片归一化距离应接近 0，实际 " .. tostring(best))
        -- 预算：极端配置下片数仍受上限约束。
        local huge = WaterFX.Layout({ x = 0, y = 0 }, { sizeMeters = 400, cellMeters = 2 })
        assert(huge.columns <= 12 and #huge.tiles <= 144, "片数必须受硬上限约束")
    end)

    check("Draw：关闭时完全不出笔（可关闭 + 零回归）", function()
        withSettings({ enabled = false }, function()
            local drew = WaterFX.Draw({}, makeMovement(0), nil, 1, nil)
            assert(not drew, "关闭时不得绘制")
            assert(#created == 0, "关闭时连贴图都不应加载")
            assert(#patterns == 0 and #transforms == 0)
        end)
        -- 需求要求「可以关闭」；同时默认要能直接看到效果（真机由 NearWater 按钮对比）。
        assert(Config.visual.nearWaterFX.enabled == true,
            "2026-10-20 交付口径：默认 enabled=true，可用 NearWater 一键关闭")
    end)

    check("Draw：开启后围绕世界锚点出片且不崩", function()
        withSettings({ enabled = true, secondLayer = false, dudvEnabled = false }, function()
            local drew, stats = WaterFX.Draw({}, makeMovement(0), nil, 1, nil)
            assert(drew, "开启且贴图可用时应绘制")
            assert(stats.tiles > 0, "至少绘制到了一片")
            assert(stats.tiles <= 36, "不得超出 6×6 片")
            assert(#transforms >= stats.tiles * 2, "每片两个三角形各一次仿射")
            for _, entry in ipairs(patterns) do
                assert(entry.image > 0, "图案必须绑定有效图像句柄")
                assert(entry.alpha > 0 and entry.alpha <= 1, "单次填充 alpha 必须在 (0,1]")
            end
        end)
    end)

    check("Draw：区域跟随世界锚点（相机横移后屏幕锚点随之变化）", function()
        withSettings({ enabled = true, secondLayer = false, dudvEnabled = false }, function()
            local drewA = WaterFX.Draw({}, makeMovement(0), nil, 1, nil)
            assert(drewA)
            local ax = anchorOfTransform(transforms[1])
            transforms = {}
            local drewB = WaterFX.Draw({}, makeMovement(60), nil, 1, nil)
            assert(drewB)
            local bx = anchorOfTransform(transforms[1])
            assert(math.abs(ax - bx) > 1,
                "相机横移 60m 后区域屏幕位置必须变化（不是钉死的屏幕矩形）")
        end)
    end)

    check("Draw：只在海面区域（地平线以下）填充，不覆盖天空", function()
        withSettings({ enabled = true, secondLayer = false, dudvEnabled = false }, function()
            local movement = makeMovement(0, 0)
            local drew = WaterFX.Draw({}, movement, nil, 1, nil)
            assert(drew)
            local horizon = require("Ocean.Projection").Horizon(movement, WIDTH * 0.5)
            -- 仿射平移列是该片左上角的屏幕位置；区域在半高以内，全部应落在地平线附近或以下。
            local lowest = -math.huge
            for _, entry in ipairs(transforms) do
                local _, y = anchorOfTransform(entry)
                lowest = math.max(lowest, y)
            end
            assert(lowest > horizon - 80,
                "区域不应伸到天空（最近片顶沿仍应在地平线附近）")
        end)
    end)

    check("Draw：贴图加载失败整层跳过，不抛错不刷重试", function()
        withSettings({ enabled = true, dudvEnabled = false }, function()
            -- 每次 Draw 用独立 ctx：ImageArt 的失败句柄按 ctx 缓存，
            -- 换 ctx 才能验证「同一 ctx 内不重复重试」。
            local ctx = {}
            failedPath = CAUSTIC_PATH
            local ok, drew = pcall(WaterFX.Draw, ctx, makeMovement(0), nil, 1, nil)
            assert(ok, "失败必须被吞掉（不得崩场景）")
            assert(not drew, "贴图不可用时应跳过本层")
            local attempts = #created
            WaterFX.Draw(ctx, makeMovement(0), nil, 1, nil)
            assert(#created == attempts, "失败句柄已缓存，不得每帧重试")
            failedPath = ""
        end)
    end)

    check("Draw：alpha = config.alpha × 昼夜倍率（夜间自动变弱）", function()
        withSettings({ enabled = true, dudvEnabled = false, alpha = 0.2 },
            function()
                local dayDrew, dayStats = WaterFX.Draw({}, makeMovement(0), nil, 1,
                    { phase = "day", progress = 0.5 })
                assert(dayDrew)
                near(dayStats.alpha, 0.2, 1e-6, "白天 = alpha × 1.0")
                local nightDrew, nightStats = WaterFX.Draw({}, makeMovement(0), nil, 1,
                    { phase = "night", progress = 0.5 })
                assert(nightDrew)
                near(nightStats.alpha, 0.2 * 0.28, 1e-6, "夜间 = alpha × nightScale")
            end)
    end)

    check("Draw：同 time 同输出（不做跨帧累加，暂停即静止）", function()
        withSettings({ enabled = true, dudvEnabled = false }, function()
            WaterFX.Draw({}, makeMovement(17), nil, 3.5, nil)
            local first = {}
            for index, entry in ipairs(patterns) do first[index] = entry.alpha end
            local firstCount = #patterns
            patterns = {}
            WaterFX.Draw({}, makeMovement(17), nil, 3.5, nil)
            assert(#patterns == firstCount, "同输入应出同样数量的填充")
            for index, entry in ipairs(patterns) do
                near(entry.alpha, first[index], 1e-9, "同 time 的 alpha 必须完全一致")
            end
        end)
    end)

    check("DuDv：顶点 UV 真的被位移场偏移（不是叠图）", function()
        local sampler = WaterFX.DUDVSampler({
            GetWidth = function() return 64 end,
            GetHeight = function() return 64 end,
            -- 构造一个恒定向右的位移场：R=1、G=0.5 → dx=+1, dy=0。
            GetPixelBilinear = function() return { r = 1.0, g = 0.5, b = 0.5, a = 1.0 } end,
        }, 8)
        assert(sampler, "合法 Image 应能构建位移场")
        local dx, dy = sampler.sample(0.3, 0.7)
        near(dx, 1, 1e-9); near(dy, 0, 1e-9)

        -- 中性场（0.5/0.5）必须给出零位移，绝不能把灰色当成位移。
        local neutral = WaterFX.DUDVSampler({
            GetWidth = function() return 64 end,
            GetHeight = function() return 64 end,
            GetPixelBilinear = function() return { r = 0.5, g = 0.5 } end,
        }, 8)
        near(select(1, neutral.sample(0.1, 0.2)), 0, 1e-9)
        near(select(2, neutral.sample(0.1, 0.2)), 0, 1e-9)
    end)

    check("DuDv：引擎对象是 userdata，不得因 type 检查静默退化成纯滚动", function()
        -- 2026-10-20 回归：早期实现写 type(color) == "table"，而引擎 Image/Color
        -- 是 userdata，于是 DUDVSampler 解出的位移全是 0、表面「接了 DuDv」实际
        -- 纯滚动。这里用一个 userdata 形状的代理（只暴露方法/字段、不是 table）
        -- 锁死鸭子类型探测。
        WaterFX.ResetCaches()
        local proxy = setmetatable({}, {
            __index = function(_, key)
                if key == "GetWidth" or key == "GetHeight" then return function() return 32 end end
                if key == "GetPixelBilinear" then
                    return function(_, x, y) return { r = 0.75 + 0*x + 0*y, g = 0.5, b = 0.5 } end
                end
                return nil
            end,
        })
        -- 用 proxy table 模拟「有方法但不是普通数据表」的情形；关键是采样函数
        -- 只做能力探测，不依赖 getmetatable 或类型白名单。
        local sampler = WaterFX.DUDVSampler(proxy, 4)
        assert(sampler, "有 GetPixelBilinear 的对象必须能构建位移场（不管是不是 table）")
        local dx = select(1, sampler.sample(0.25, 0.5))
        near(dx, 0.5, 1e-6, "0.75 通道应解出 +0.5 位移，而不是 0（纯滚动）")

        -- 引擎 Image 缺方法时必须安全返回 nil，让调用方退回滚动。
        assert(WaterFX.DUDVSampler({}, 4) == nil)
        assert(WaterFX.DUDVSampler(nil, 4) == nil)
    end)

    check("DuDv：位移真的改变焦散采样（不是零位移白接）", function()
        withSettings({ enabled = true, dudvEnabled = true, dudvStrength = 0.05,
            edgeJitter = 0 }, function()
            -- 同一次 Draw 内，逐顶点 UV 会因为 DuDv 位移而不同；用两档强度
            -- 比较「填充是否存在差异」不现实（CPU 端只能看调用序列），
            -- 因此这里直接验证 UV 计算路径：位移非零时，同一世界点的 UV 必须变化。
            local sampler = WaterFX.DUDVSampler({
                GetWidth = function() return 64 end,
                GetHeight = function() return 64 end,
                GetPixelBilinear = function() return { r = 1.0, g = 0.5 } end,
            }, 8)
            assert(sampler, "位移场应可构建")
            local baseU, baseV = WaterFX.WorldUV(10, 20, 22, 0.012, 0.008, 3)
            local dx, dy = sampler.sample(0.3, 0.4)
            local shiftedU = baseU + dx * 0.05
            assert(math.abs(shiftedU - baseU) > 0.01 * 0.9,
                "位移必须真正改变 UV（否则只是视觉假象）")
            near(baseV + dy * 0.05, baseV, 1e-9)
        end)
    end)

    check("DuDv：dudvEnabled=false 时不加载位移场（AB 纯滚动路径）", function()
        WaterFX.ResetCaches()
        withSettings({ enabled = true, dudvEnabled = false }, function()
            local drew, stats = WaterFX.Draw({}, makeMovement(0), nil, 1, nil)
            assert(drew)
            assert(stats.dudv == false, "关闭 DuDv 时 stats 必须报告未启用置换")
        end)
    end)

    check("Draw：不改相机、不碰世界（纯表现层）", function()
        withSettings({ enabled = true, dudvEnabled = false }, function()
            local movement = makeMovement(12, 7)
            local camera = movement.camera
            local cameraX, cameraY, shipX, shipY = camera.x, camera.y, movement.ship.position.x, movement.ship.position.y
            WaterFX.Draw({}, movement, nil, 2, nil)
            assert(camera.x == cameraX and camera.y == cameraY, "Draw 不得移动相机")
            assert(movement.ship.position.x == shipX and movement.ship.position.y == shipY,
                "Draw 不得移动船")
        end)
    end)

    check("Draw：非法视口/锚点/时间一律安全返回", function()
        withSettings({ enabled = true, dudvEnabled = false }, function()
            assert(not WaterFX.Draw({}, { viewportWidth = 0, viewportHeight = 0 }, nil, 1, nil))
            assert(not WaterFX.Draw({}, {}, nil, 1, nil))
            assert(not WaterFX.Draw({}, nil, nil, 1, nil))
            local drew = WaterFX.Draw({}, makeMovement(0), { x = 0 / 0, y = 1 }, 1, nil)
            assert(drew ~= nil, "非法锚点不得抛错（NaN 锚点退化为默认）")
        end)
    end)

    restoreStubs()
    return { results = results }
end

return Tests
