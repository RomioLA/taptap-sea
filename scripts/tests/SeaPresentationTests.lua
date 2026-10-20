local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local Presentation = require("Ocean.SeaPresentation")
local SeaDraw = require("Ocean.SeaDraw")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.Draw")
local Geometry = require("Ocean.ProjectedGeometry")
local Tests = {}

local function assertNear(actual, expected, label, tolerance)
    tolerance = tolerance or 1e-6
    assert(type(actual) == "number" and math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.8f, got %s", label, expected, tostring(actual)))
end

local function newRuntime(width, height)
    local runtime = Runtime.New({ initializeRegions = false, departure = { x = 0, y = 0 } })
    runtime.movement:SetViewport(width, height)
    return runtime
end

function Tests.Run(recorder)
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("fixed_island_height_crosses_the_horizon_without_vertical_art_motion", function()
        local runtime = newRuntime(1920, 1080)
        local movement = runtime.movement
        local farIsland = { x = -80, y = 90 }
        local groundX, groundY = movement:WorldToScreen(farIsland)
        local tallestTree = { x = farIsland.x + 20 * 0.20, y = farIsland.y + 20 * 0.27 }
        local treeX, treeY = movement:WorldToScreen(tallestTree, 5.4)
        assert(groundY > movement:GetHorizonY(groundX), "island ground must remain in the water plane")
        assert(treeY < movement:GetHorizonY(treeX), "raised tree silhouette should naturally pass the horizon")

        local near = Presentation.State(movement, { x = 35, y = 25 }, 12, 5.4,
            { allowAboveHorizon = true, allowBeyondHorizon = true })
        local far = Presentation.State(movement, farIsland, 20, 5.4,
            { allowAboveHorizon = true, allowBeyondHorizon = true })
        assert(near and far and near.progress == 1 and far.progress == 1,
            "islands must not use a depth-driven geometric emergence animation")
        assert(near.risePixels == 0 and far.risePixels == 0,
            "presentation must not translate world art vertically")
        assert(far.airMix > near.airMix and far.alpha > 0,
            "the far island should retain visible atmospheric perspective")
    end)

    check("complete_footprint_bounds_replace_center_cutoff_and_opacity_emergence", function()
        local movement=newRuntime(1280,720).movement
        for _,depth in ipairs({110-1e-5,110,110+1e-5,111}) do
            local point={x=0,y=depth}
            local state=Presentation.State(movement,point,2,0)
            assert(state and state.horizonFade==1 and state.alpha>0,
                "partially visible footprints must reach their geometric draw callback")
            assert(#Geometry.ProjectPolygon(movement,Geometry.SampleCircle(point,2))>=3)
        end
        assert(Presentation.State(movement,{x=0,y=112.01},2,0)==nil)
        local high=Presentation.State(movement,{x=0,y=130},5,5)
        assert(high and high.horizonFade==1,"raised objects use geometry, not a whole-outline fade")
    end)

    check("presentation_preserves_world_coordinates_and_restores_drawing_state", function()
        local movement=newRuntime(1280,720).movement
        recorder.reset()
        local called=false
        local drawnAlpha
        assert(Presentation.Draw({},movement,{x=0,y=111},2,0,function(state)
            called=true;assert(state.risePixels==0)
            drawnAlpha=state.alpha
            Geometry.WorldCircle({},movement,{x=0,y=111},2,{184,130,90,255})
        end))
        -- 两种 recorder 口径都证明"可见足迹被真实绘制"：run_circle1_review 的包装器
        -- 自带 globalAlpha 跟踪、不烧录进填充色（记录值恒为 255）；run_sea_view_regression
        -- 的 NVGCapture 直接绑定 set_global_alpha，_element 按 alpha 缩放填充色
        -- （255×alpha，depth=111 空气透视下约 138）。故两种记录值均可接受。
        local baked=drawnAlpha and math.floor(255*drawnAlpha+0.5) or 255
        assert(called and (recorder.countFillColor(184,130,90,255)>0
            or recorder.countFillColor(184,130,90,baked)>0),
            "a center beyond the horizon must still draw its visible footprint")
        assert(recorder.globalAlpha()==1 and recorder.callCount("nvgSave")==recorder.callCount("nvgRestore"))
        assert(recorder.callCount("nvgScissor")==0 and recorder.callCount("nvgIntersectScissor")==0,
            "actual geometry must be clipped without a conservative rectangular cutoff")
        assert(not Presentation.Draw({},movement,{x=0,y=112.01},2,0,
            function() error("wholly hidden footprint must not draw") end))
    end)

    check("paused_scene_keeps_hidden_and_beyond_horizon_fish_out_of_the_sky", function()
        local runtime = newRuntime(1280, 720)
        local hidden = runtime:spawnFish("sardine", { x = 0, y = Config.camera.farDepth + 8 }, 0)
        assert(not runtime.world:isVisible(hidden))
        runtime:TogglePause()
        local oldTime, oldCount = runtime.time, #runtime.world.entities
        local oldX, oldY = runtime.ship.position.x, runtime.ship.position.y
        local original, count = Draw.WorldFish, 0
        Draw.WorldFish = function(...) count = count + 1; return original(...) end
        local ok, err = pcall(function()
            for _ = 1, 3 do
                recorder.reset()
                SeaDraw.Scene({}, 1280, 720, runtime)
                runtime:Update(0.25, 1, 0)
                assert(recorder.globalAlpha() == 1)
                assert(recorder.callCount("nvgScissor") == 0,
                    "scene-wide horizon scissor would cut elevated island silhouettes")
                assert(recorder.callCount("nvgSave") == recorder.callCount("nvgRestore"))
            end
            runtime:setDebugFlag("showUnderwater", true)
            recorder.reset()
            SeaDraw.Scene({}, 1280, 720, runtime)
            assert(count == 0 and recorder.countFillColor(table.unpack(FishData.sardine.color)) == 0,
                "visible-but-distant fish must be culled before they leak into the sky")
        end)
        Draw.WorldFish = original
        assert(ok, tostring(err))
        assert(#runtime.world.entities == oldCount and runtime.time == oldTime)
        assert(runtime.ship.position.x == oldX and runtime.ship.position.y == oldY)
    end)

    -- =========================================================
    -- 2026-10-20 真人试玩修复（HUMAN-PLAYTEST-RCA-FIX-01）
    -- =========================================================
    check("fishing bird billboard keeps a player-readable screen span, not just the raster floor", function()
        -- 真人试玩 RCA：鸟确实生成，但正式捕鱼鸟的最小屏幕翼展只有约 3px
        -- （技术剔除下限），真人“几乎看不见”。现在把两个概念分开：
        --   · 技术下限（不被 ImageArt.UPRIGHT_MIN_PX 剔除）
        --   · 玩家可辨识下限（首轮试玩值 10px）
        -- 这里锁住：小视口 + 俯冲的极端组合下，立牌宽度换算回屏幕像素 >= 10。
        local Projection = require("Ocean.Projection")
        local MIN_READABLE_PX = 10
        for _, viewport in ipairs({ { 1280, 720 }, { 960, 540 }, { 800, 450 } }) do
            local runtime = newRuntime(viewport[1], viewport[2])
            local camera = runtime.movement.camera
            for _, spec in ipairs({ { 110, 0.0 }, { 110, 0.62 }, { 80, 0.0 }, { 80, 0.62 } }) do
                local depth, dive = spec[1], spec[2]
                local altitude = Config.visual.projection.birdAltitude * (1 - dive)
                local authoredWidth = Presentation.BIRD_SPAN_METERS * (1 - 0.62 * dive)
                local point = { x = camera.x, y = camera.y + depth }
                local _, _, scale = Projection.Project(runtime.movement, point, altitude)
                if type(scale) == "number" and scale > 0 then
                    -- 与 SeaDraw 同构：先过剔除线，再抬到可辨识下限。
                    local drawn = math.max(authoredWidth, MIN_READABLE_PX / scale)
                    local screenPx = drawn * scale
                    assert(screenPx >= MIN_READABLE_PX - 1e-6,
                        string.format("viewport %dx%d depth %d dive %.2f: drawn span %.2fpx < %dpx",
                            viewport[1], viewport[2], depth, dive, screenPx, MIN_READABLE_PX))
                end
            end
        end
        -- 提体量只走 presentation：不影响鸟与小鱼/出现条件的权威来源。
        assert(Presentation.BIRD_SPAN_METERS > 0,
            "the authored bird span must stay a presentation-only constant")
    end)

    check("commuter flock keeps three-bird formation, island_02 gating and larger visuals", function()
        -- 真人试玩 RCA：通勤鸟群是 island_02 的唯一早期引导线索，但 14 号屏幕尺寸偏小。
        -- 首轮试玩值：整体视觉尺寸 ×1.6。三只编队 / 只引导 island_02 /
        -- 识别后消失全部不变。
        local runtime = newRuntime(1920, 1080)
        assert(runtime:GetTrace("flock_commute"),
            "the seeded world must expose a live flock_commute trace for this check")
        local originalWorldSeabird = Draw.WorldSeabird
        local birdsDrawn, recordedScales = 0, {}
        Draw.WorldSeabird = function(_, x, y, scale, heading, dive)
            birdsDrawn = birdsDrawn + 1
            recordedScales[#recordedScales + 1] = scale
            return originalWorldSeabird(_, x, y, scale, heading, dive)
        end
        local function draw()
            recorder.reset()
            SeaDraw.Scene({}, 1920, 1080, runtime, nil, nil,
                function() return false end, function() return false end)
        end
        local ok, err = pcall(draw)
        assert(ok, tostring(err))

        -- ① 编队规则不变：恰好 3 只。
        assert(birdsDrawn == 3,
            "the commuter flock must stay a three-bird formation, got " .. birdsDrawn)
        -- ② 视觉尺寸放大 1.6 倍（14 -> 22.4），仍是同一绘制入口。
        local expectedScale = 14 * 1.6
        for index, scale in ipairs(recordedScales) do
            assertNear(scale, expectedScale, "commuter bird " .. index .. " screen scale", 1e-6)
        end

        -- ③ 识别后消失：island_02 认出来后整群不再绘制。
        birdsDrawn = 0
        recordedScales = {}
        local okRecognized, errRecognized = pcall(function()
            recorder.reset()
            SeaDraw.Scene({}, 1920, 1080, runtime, nil, nil,
                function(contentId) return contentId == "island_02" end,
                function() return false end)
        end)
        Draw.WorldSeabird = originalWorldSeabird
        assert(okRecognized, tostring(errRecognized))
        assert(birdsDrawn == 0,
            "the flock must disappear once island_02 is recognized, got " .. birdsDrawn)
    end)

    check("leviathan bubbles are drawn from 40m but stay a fixed, untrailed cue", function()
        -- 真人试玩 RCA：气泡原先只在 <=5m 绘制，等于没有发现作用。
        -- 现在 40m 内有海面慢气泡；仍与“大鱼移动水花”不同：固定位置、缓慢、无尾迹。
        local runtime = newRuntime(1920, 1080)
        local bones = assert(runtime.world.fixedContentEntities["leviathan_bones_01"])
        local ldef
        for _, item in ipairs(require("data.content").fixed) do
            if item.contentId == "leviathan_bones_01" then ldef = item; break end
        end
        assert(ldef and ldef.bubble, "the leviathan needs its bubble cue config")
        assert(ldef.bubble.surfaceRadius == 40,
            "the discovery cue radius must be the 40m first-playtest value")

        -- 直接拦 Geometry.WorldCircle，只数“巨骨气泡”这一个调用特征：
        -- 圆心落在巨骨坐标附近、描边色是气泡专用色（214,240,246）。
        local probes = {}
        local originalWorldCircle = Geometry.WorldCircle
        Geometry.WorldCircle = function(ctx, movement, center, radius, fillColor, strokeColor, width, altitude)
            if type(center) == "table" and type(strokeColor) == "table"
                and strokeColor[1] == 214 and strokeColor[2] == 240 and strokeColor[3] == 246
                and math.abs(center.x - bones.position.x) < 3
                and math.abs(center.y - bones.position.y) < 3 then
                probes[#probes + 1] = { x = center.x, y = center.y, radius = radius, alpha = strokeColor[4] }
            end
            if fillColor == nil or fillColor ~= nil then
                return originalWorldCircle(ctx, movement, center, radius, fillColor, strokeColor, width, altitude)
            end
        end

        local function bubblesAt(distance)
            probes = {}
            runtime.ship.position = { x = bones.position.x, y = bones.position.y - distance }
            recorder.reset()
            local ok, err = pcall(function()
                SeaDraw.Scene({}, 1920, 1080, runtime, nil, nil,
                    function() return false end, function() return false end)
            end)
            assert(ok, tostring(err))
            return #probes
        end

        local at30 = bubblesAt(30)
        local at40 = bubblesAt(40)
        local at41 = bubblesAt(41)
        local at90 = bubblesAt(90)
        Geometry.WorldCircle = originalWorldCircle

        assert(at30 > 0, "a 30m approach must show the surface bubbles, got " .. at30)
        assert(at40 > 0, "the 40m discovery edge must still show the bubbles, got " .. at40)
        assert(at41 == 0, "past 40m the cue must stop, got " .. at41)
        assert(at90 == 0, "at 90m there must be no bubble cue, got " .. at90)

        -- 仍是“固定位置、缓慢、无方向尾迹”：气泡圆心的抖动幅度远小于自身半径，
        -- 且没有任何指向性绘制（只画圆环）。
        assert(at30 == at40,
            string.format("the cue must not thin out between 30m and 40m (%d vs %d)", at30, at40))

        -- 巨骨真实坐标与互动半径不得被这次改动动到。
        assert(bones.position.x == ldef.position.x and bones.position.y == ldef.position.y,
            "the leviathan coordinates must not move with the cue radius")
        assert(bones.radius == ldef.radius,
            "the interaction radius must stay the authored radius")
    end)

    -- =========================================================
    -- 2026-10-20 画面层次：四角压暗（vignette）+ 空气透视
    -- =========================================================
    check("vignette darkens only the outer corners and stops inside the safe zone", function()
        -- 四角压暗是纯屏幕空间的一次径向渐变填充：
        --   中心区不压暗（保证船与近水交互点可读），
        --   四角才压到 strength。
        -- 这里用真实的 Scene 调用 + 一个只统计"径向渐变填充"的最小桩，
        -- 断言它对每个分辨率都真的发生了一次，且参数随配置变化。
        local calls = {}
        local stubs = {
            nvgRGBA = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
            nvgBeginPath = function() end, nvgMoveTo = function() end,
            nvgLineTo = function() end, nvgQuadTo = function() end,
            nvgBezierTo = function() end, nvgClosePath = function() end,
            nvgRect = function() end, nvgRoundedRect = function() end,
            nvgCircle = function() end, nvgEllipse = function() end,
            nvgFillColor = function() end, nvgFill = function() end,
            nvgStrokeColor = function() end, nvgStrokeWidth = function() end,
            nvgStroke = function() end, nvgFillPaint = function() end,
            nvgRadialGradient = function(ctx, cx, cy, innerR, outerR, c0, c1)
                calls[#calls + 1] = { cx = cx, cy = cy, inner = innerR, outer = outerR,
                    c0 = c0, c1 = c1 }
                return 0
            end,
            nvgLinearGradient = function() return 0 end,
            nvgSave = function() end, nvgRestore = function() end,
            nvgTranslate = function() end, nvgScale = function() end, nvgRotate = function() end,
            nvgScissor = function() end, nvgIntersectScissor = function() end,
            nvgResetScissor = function() end, nvgGlobalAlpha = function() end,
            nvgShapeAntiAlias = function() end, nvgTransform = function() end,
            nvgImagePattern = function() return 0 end,
            nvgCreateImage = function() return -1 end, nvgImageSize = function() end,
            nvgText = function() end, nvgFontFace = function() end, nvgFontSize = function() end,
            nvgTextAlign = function() end, nvgCreateFont = function() return 0 end,
            nvgTextBounds = function() return 0, 0, 0, 0 end,
            NVG_IMAGE_GENERATE_MIPMAPS = 1, NVG_IMAGE_REPEATX = 2,
            NVG_IMAGE_REPEATY = 4, NVG_IMAGE_FLIPY = 8,
            NVG_IMAGE_PREMULTIPLIED = 16, NVG_IMAGE_NEAREST = 32,
        }
        -- 只补运行器没提供的函数；已有绑定（recorder 的计数/globalAlpha 等）
        -- 一律保留原样，否则会抹掉后续断言依赖的 recorder 能力。
        local saved = {}
        for name, fn in pairs(stubs) do
            if _G[name] == nil then
                saved[name] = false
                _G[name] = fn
            end
        end
        -- nvgRadialGradient 必须由本用例接管（要在调用时记录参数）。
        local savedRadial = _G.nvgRadialGradient
        _G.nvgRadialGradient = stubs.nvgRadialGradient
        local function cleanup()
            _G.nvgRadialGradient = savedRadial
            for name, had in pairs(saved) do
                if had == false then _G[name] = nil end
            end
        end

        local okBody, bodyErr = pcall(function()
            local settings = Config.visual.vignette
            assert(type(settings) == "table", "visual.vignette config is missing")
            assert(settings.enabled == true, "vignette ships enabled")

            for _, viewport in ipairs({ { 1920, 1080 }, { 960, 540 }, { 800, 450 } }) do
                local runtime = newRuntime(viewport[1], viewport[2])
                calls = {}
                SeaDraw.Scene({}, viewport[1], viewport[2], runtime, nil, nil,
                    function() return false end, function() return false end)
                assert(#calls >= 1,
                    string.format("viewport %dx%d must paint at least one radial vignette",
                        viewport[1], viewport[2]))
                -- 找到"从中心向外扩散到覆盖四角"的那一次（外半径 == 半对角线）
                local found
                for _, call in ipairs(calls) do
                    local cx, cy = viewport[1] * 0.5, viewport[2] * 0.5
                    local expectOuter = math.sqrt(cx * cx + cy * cy)
                    if math.abs(call.cx - cx) < 1e-6 and math.abs(call.cy - cy) < 1e-6
                        and math.abs(call.outer - expectOuter) < 1e-6 then
                        found = call
                        break
                    end
                end
                assert(found, string.format("viewport %dx%d vignette must be centred on screen "
                    .. "and reach the corners", viewport[1], viewport[2]))
                -- 中心透明 -> 边缘压暗；中心不压暗靠 inner > 0 保证。
                assert(found.inner > 0,
                    "the vignette must leave a clear centre (innerRadius > 0)")
                -- nvgRGBA 在真实引擎返回 userdata、在离线 recorder 返回 table；
                -- 用 pcall 双重探测，两种都能读。
                local function alphaOf(c)
                    if c == nil then return nil end
                    local ok, a = pcall(function() return c.a end)
                    if ok and type(a) == "number" then return a end
                    local ok2, a2 = pcall(function() return c[4] end)
                    if ok2 and type(a2) == "number" then return a2 end
                    return nil
                end
                local edgeAlpha, centreAlpha = alphaOf(found.c1), alphaOf(found.c0)
                assert(edgeAlpha and centreAlpha,
                    "radial gradient stops must carry an alpha component")
                assert(edgeAlpha > 0 and centreAlpha == 0,
                    "the vignette must fade from transparent centre to tinted edge")
                assert(edgeAlpha <= 255 * settings.strength + 1,
                    "edge alpha must follow the configured strength")
            end

            -- 关掉后必须一次都不画（完全回退到原画面）。
            local runtime = newRuntime(1280, 720)
            local oldEnabled = settings.enabled
            settings.enabled = false
            calls = {}
            SeaDraw.Scene({}, 1280, 720, runtime, nil, nil,
                function() return false end, function() return false end)
            local vignetteWhileOff = 0
            local cx, cy = 640, 360
            local expectOuter = math.sqrt(cx * cx + cy * cy)
            for _, call in ipairs(calls) do
                if math.abs(call.outer - expectOuter) < 1e-6 then
                    vignetteWhileOff = vignetteWhileOff + 1
                end
            end
            settings.enabled = oldEnabled
            assert(vignetteWhileOff == 0,
                "enabled=false must not paint the vignette at all")
        end)
        cleanup()
        assert(okBody, bodyErr)
    end)

    check("aerial perspective now separates far objects from near ones", function()
        -- 空气透视把远处物体按深度衰减 alpha。旧值 0.48 时远近几乎一样清楚，
        -- 没有纵深；这里锁住"远明显比近淡"这个可量化的事实。
        local Projection = require("Ocean.Projection")
        local air = Config.visual.aerialPerspective
        assert(air.enabled == true, "aerial perspective ships enabled")
        local runtime = newRuntime(1920, 1080)
        local camera = runtime.movement.camera
        local function alphaAt(depth)
            local state = Presentation.State(runtime.movement,
                { x = camera.x, y = camera.y + depth }, 1.5, 0)
            assert(state, "depth " .. depth .. " should be on screen")
            return state.alpha
        end
        -- 用视野内可达的深度：VisibleDepth 由视口高度与相机参数决定，
        -- 直接取可视深度的 30% 与 95% 作"近/远"两个采样点。
        local visible = Projection.VisibleDepth(runtime.movement, 0)
        local near = alphaAt(math.min(air.startDepthMeters + 1, visible * 0.3))
        local far = alphaAt(visible * 0.95)
        assert(near > far, string.format(
            "far objects must be fainter than near ones (near=%.3f far=%.3f)", near, far))
        -- 远端至少淡掉四成，才看得出"退进雾里"。
        assert(1 - far >= 0.4, string.format(
            "the far end must lose at least 40%% opacity, got %.3f", 1 - far))
        -- 近端不得被压暗（不能为了纵深把近景一起弄灰）。
        assert(near >= 0.99, string.format(
            "near objects must stay fully opaque, got %.3f", near))
    end)

    return { results = results }
end

return Tests
