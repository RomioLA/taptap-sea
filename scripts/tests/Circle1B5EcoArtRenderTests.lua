-- C2（2026-10-17）生态层组件 v2 渲染接入白盒测试。
-- 守护契约：
--   1) 帧循环：鱼/海鸟/木桶按 time 走 eco_*_f1→f2→f3（6fps），鸟/桶相位 0 帧序精确可算；
--   2) 物种映射：sardine→eco_fish_small（renderLength 1.8）、tuna→eco_fish_big（3.8）；
--   3) heading 直传：贴图头朝 +X（入库水平翻转），鱼 heading=实体朝向；
--   4) 兜底等价：Plane/Upright 失败（返回 false）时全部 nvg 计数与未接入基线完全一致（矢量回退零回归）；
--   5) 零状态改写：Scene 不推进 time/世界/船/相机/实体；
--   6) SeaViewArt.Component：尺寸换算、heading/alpha 透传、非法输入与未知目录名返回 false。
-- 2026-10-18 真机验收：木桶由平铺（Plane）改竖幅公告板投影（Upright）——预烘焙斜视
-- 资产平铺在世界平面会被引擎斜投影二次压扁；鱼保持平铺口径不变。
-- 2026-10-19 真机验收：海鸟同样由平铺改立牌（用户红框「海鸟自带平铺效果」）——eco_bird_f*
-- 是水彩侧视素材，平铺呈漂浮贴图块；改后按内容主体宽度（1.8m 翼展，对齐旧平铺的实际
-- 可见翼展）+ 底沿悬停高度绘制，朝向由屏幕水平镜像表达（±15° 死区防抖）。鱼/木桶口径不变。
local Tests = {}

local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local SeaViewArt = require("Ocean.SeaViewArt")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")

local WIDTH, HEIGHT = 1280, 720
local BARREL_DISTANCE = 4
local FISH_SARDINE_ROTATION = 0.3
local FISH_TUNA_ROTATION = -0.8
local BIRD_HEADING, BIRD_DIVE = 0.4, 0.2

local function near(a, b, tolerance)
    return type(a) == "number" and type(b) == "number"
        and math.abs(a - b) <= (tolerance or 0.001)
end

-- 记录 ImageArt.Plane / ImageArt.Upright 调用；result 控制返回值（true=贴图可用 / false=加载失败）。
-- 2026-10-18 真机验收：木桶由平铺（Plane）改竖幅公告板投影（Upright），录制器须同时
-- 覆盖两个入口，否则桶绘制不被记录（生态帧循环/尺寸契约会静默失守）。
-- 2026-10-19 真机验收：海鸟同样由平铺改立牌，且首次使用 Upright 的 worldWidth /
-- altitude / flipX 三个可选参数，故桩一并录制（老调用点仍逐字等价）。
local function withPlaneRecorder(result, fn)
    local calls = {}
    local originalPlane, originalUpright = ImageArt.Plane, ImageArt.Upright
    ImageArt.Plane = function(ctx, name, movement, origin, length, width, heading, altitude, alpha)
        calls[#calls + 1] = { mode = "plane", name = name, x = origin.x, y = origin.y,
            length = length, width = width, heading = heading,
            altitude = altitude, alpha = alpha }
        return result
    end
    ImageArt.Upright = function(ctx, name, movement, position, worldHeight, alpha,
        worldWidth, altitude, flipX)
        calls[#calls + 1] = { mode = "upright", name = name, x = position.x, y = position.y,
            height = worldHeight, alpha = alpha,
            worldWidth = worldWidth, altitude = altitude, flipX = flipX }
        return result
    end
    local ok, err = pcall(fn)
    ImageArt.Plane, ImageArt.Upright = originalPlane, originalUpright
    if not ok then error(err) end
    return calls
end

local function findCall(calls, name)
    for _, call in ipairs(calls) do
        if call.name == name then return call end
    end
    return nil
end

local function countCalls(calls, prefix)
    local count = 0
    for _, call in ipairs(calls) do
        if string.sub(call.name, 1, #prefix) == prefix then count = count + 1 end
    end
    return count
end

local function makeRuntime(headingOverride)
    local fixed = Config.world.fixedBarrel.position
    local runtime = Runtime.New({
        departure = { x = fixed.x + BARREL_DISTANCE, y = fixed.y },
        initializeRegions = false,
    })
    assert(runtime.movement:SetViewport(WIDTH, HEIGHT), "offline eco viewport was not applied")
    runtime.world.showUnderwater = true
    local sardine = runtime.world:spawn({
        entityType = "fish", kind = "fish", layer = "underwater", species = "sardine",
        position = { x = runtime.ship.position.x + 3, y = runtime.ship.position.y + 2 },
        radius = FishData.sardine.radius, rotation = FISH_SARDINE_ROTATION,
    })
    local tuna = runtime.world:spawn({
        entityType = "fish", kind = "fish", layer = "underwater", species = "tuna",
        position = { x = runtime.ship.position.x + 6, y = runtime.ship.position.y + 3 },
        radius = FishData.tuna.radius, rotation = FISH_TUNA_ROTATION,
    })
    local bird = { x = runtime.ship.position.x + 8, y = runtime.ship.position.y + 6 }
    runtime.surfaceSignals = {
        GetSplashes = function() return {} end,
        GetBirds = function()
            return { { position = { x = bird.x, y = bird.y },
                heading = headingOverride or BIRD_HEADING, diveProgress = BIRD_DIVE } }
        end,
    }
    return runtime, sardine, tuna, bird
end

local function captureState(runtime)
    return {
        runtimeTime = runtime.time,
        worldTime = runtime.world.time,
        shipX = runtime.ship.position.x,
        shipY = runtime.ship.position.y,
        cameraX = runtime.movement.camera.x,
        cameraY = runtime.movement.camera.y,
        entityCount = #runtime.world.entities,
    }
end

local function sceneAt(timeValue, planeResult, headingOverride)
    local runtime = makeRuntime(headingOverride)
    runtime.time = timeValue
    local before = captureState(runtime)
    local calls = withPlaneRecorder(planeResult, function()
        SeaDraw.Scene({}, WIDTH, HEIGHT, runtime)
    end)
    local after = captureState(runtime)
    assert(after.runtimeTime == before.runtimeTime, "eco rendering advanced runtime time")
    assert(after.worldTime == before.worldTime, "eco rendering advanced world time")
    assert(after.shipX == before.shipX and after.shipY == before.shipY, "eco rendering moved the ship")
    assert(after.cameraX == before.cameraX and after.cameraY == before.cameraY,
        "eco rendering moved the camera")
    assert(after.entityCount == before.entityCount, "eco rendering changed world registration")
    return calls
end

function Tests.Run(recorder)
    local tests = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        tests[#tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("eco_frames_cycle_f1_f2_f3_over_time", function()
        -- 鸟/桶相位 0：t=0/0.2/0.4 对应 floor(t*6)%3 = 0/1/2 → f1/f2/f3
        local atZero = sceneAt(0, true)
        local atMid = sceneAt(0.2, true)
        local atLate = sceneAt(0.4, true)
        assert(findCall(atZero, "eco_bird_f1"), "bird frame f1 missing at t=0")
        assert(findCall(atMid, "eco_bird_f2"), "bird frame f2 missing at t=0.2")
        assert(findCall(atLate, "eco_bird_f3"), "bird frame f3 missing at t=0.4")
        assert(findCall(atZero, "eco_barrel_f1"), "barrel frame f1 missing at t=0")
        assert(findCall(atMid, "eco_barrel_f2"), "barrel frame f2 missing at t=0.2")
        assert(findCall(atLate, "eco_barrel_f3"), "barrel frame f3 missing at t=0.4")
        -- 鱼按实体 id 相位错相：同一物种在三个时刻应遍历三个不同帧
        for _, prefix in ipairs({ "eco_fish_small", "eco_fish_big" }) do
            local seen = {}
            for _, calls in ipairs({ atZero, atMid, atLate }) do
                for _, call in ipairs(calls) do
                    if string.sub(call.name, 1, #prefix) == prefix then
                        seen[call.name] = true
                    end
                end
            end
            local distinct = 0
            for _ in pairs(seen) do distinct = distinct + 1 end
            assert(distinct == 3, prefix .. " did not cycle through three frames (got " .. distinct .. ")")
        end
    end)

    check("eco_species_mapping_length_and_heading_passthrough", function()
        local calls = sceneAt(0, true)
        local sardine = findCall(calls, "eco_fish_small_f1")
            or findCall(calls, "eco_fish_small_f2") or findCall(calls, "eco_fish_small_f3")
        assert(sardine, "sardine did not draw through the eco fish art")
        assert(near(sardine.length, FishData.sardine.renderLength)
            and near(sardine.width, FishData.sardine.renderLength),
            "sardine plane size did not follow renderLength")
        assert(near(sardine.heading, FISH_SARDINE_ROTATION, 1e-6),
            "sardine heading was not the entity heading (head-left flip contract)")
        assert(near(sardine.altitude, 0), "sardine plane altitude should stay on the sea plane")
        local tuna = findCall(calls, "eco_fish_big_f1")
            or findCall(calls, "eco_fish_big_f2") or findCall(calls, "eco_fish_big_f3")
        assert(tuna, "tuna did not draw through the eco fish art")
        assert(near(tuna.length, FishData.tuna.renderLength)
            and near(tuna.width, FishData.tuna.renderLength),
            "tuna plane size did not follow renderLength")
        assert(near(tuna.heading, FISH_TUNA_ROTATION, 1e-6), "tuna heading was not the entity heading")
        local bird = findCall(calls, "eco_bird_f1")
        assert(bird, "bird did not draw through the eco bird art")
        local birdAltitude = Config.visual.projection.birdAltitude * (1 - BIRD_DIVE)
        -- 2026-10-19 真机验收：海鸟由平铺（Plane）改竖幅公告板投影（Upright）——
        -- 与木桶同一病根（预烘焙水彩素材被斜投影二次压扁成「漂浮贴图块」）。
        assert(bird.mode == "upright",
            "bird must draw through the upright billboard projection, got " .. tostring(bird.mode))
        assert(bird.worldWidth ~= nil,
            "bird upright must size by content width, not the old plane canvas length")
        assert(bird.height == nil,
            "bird upright must not pass a world height (width takes precedence)")
        assert(near(bird.worldWidth, 1.8 * (1 - 0.62 * BIRD_DIVE)),
            "bird upright width did not follow the dive shrink contract")
        assert(near(bird.altitude, birdAltitude), "bird upright altitude did not follow the dive contract")
        -- 朝向：素材头朝 +X，heading=0.4（朝世界 +X）不镜像。
        assert(bird.flipX == false, "bird heading +X must not mirror the billboard")
        local barrel = findCall(calls, "eco_barrel_f1")
        assert(barrel, "fixed barrel did not draw through the eco barrel art")
        -- 2026-10-18 真机验收：平铺被斜投影二次压扁 → 竖幅公告板投影立起。
        assert(barrel.mode == "upright",
            "barrel must draw through the upright billboard projection, got " .. tostring(barrel.mode))
        local radius = Config.world.fixedBarrel.radius * 0.65
        assert(near(barrel.height, radius * 2),
            "barrel upright height did not follow the visual radius contract")
        assert(countCalls(calls, "eco_") == 4,
            "expected exactly 2 fish + 1 bird + 1 barrel eco draws, got " .. countCalls(calls, "eco_"))
    end)

    check("bird_upright_mirrors_only_outside_the_heading_deadzone", function()
        -- 公告板恒面向相机，朝向只由屏幕水平镜像表达。素材头朝 +X：朝世界 +X 不镜像，
        -- 朝世界 -X 镜像；正前/正后飞（cos≈0）落在死区内不翻转，避免每帧抖动。
        local cases = {
            { heading = 0.0, flip = false, label = "due +X" },
            { heading = math.pi, flip = true, label = "due -X" },
            { heading = math.pi / 2, flip = false, label = "due +Y (deadzone)" },
            { heading = -math.pi / 2, flip = false, label = "due -Y (deadzone)" },
        }
        for _, case in ipairs(cases) do
            local calls = sceneAt(0, true, case.heading)
            local bird = findCall(calls, "eco_bird_f1")
            assert(bird, "bird billboard missing for " .. case.label)
            assert(bird.mode == "upright", "bird must stay on the billboard path for " .. case.label)
            assert(bird.flipX == case.flip,
                "bird billboard flip mismatch for " .. case.label
                    .. " (heading=" .. tostring(case.heading) .. ", flipX=" .. tostring(bird.flipX) .. ")")
        end
    end)

    check("upright_sizes_by_content_ratio_and_mirrors_in_place", function()
        -- 直测 ImageArt.Upright 的三个新参数（海鸟立牌依赖）：桩只验参数透传不够，
        -- 这里走真实投影代码，用 nvgRect/nvgScale 录制实际提交的几何。
        -- 契约：①按 worldWidth 定内容宽、另一边按 catalog 内容比推导（等比不变形）；
        --       ②底沿 altitude 抬高锚点（悬停不站水面）；③flipX 只加镜像变换、
        --       提交矩形本身逐字不变（公告板恒面向相机）。
        local runtime = makeRuntime()
        local movement = runtime.movement
        local spec = assert(ImageArt.GetSpec("eco_bird_f1"), "eco_bird_f1 missing from catalog")
        local anchor = { x = runtime.ship.position.x + 4, y = runtime.ship.position.y + 3 }
        local worldWidth, altitude = 1.8, 1.2

        local captured = {}
        local oldCreate = nvgCreateImage
        local oldRect, oldScale, oldTranslate = nvgRect, nvgScale, nvgTranslate
        local oldPattern, oldAntiAlias = nvgImagePattern, nvgShapeAntiAlias
        nvgCreateImage = function() return 1 end
        nvgImagePattern = nvgImagePattern or function(_, _, _, _, _, _, image, alpha)
            return { image = image, alpha = alpha }
        end
        nvgShapeAntiAlias = nvgShapeAntiAlias or function() end
        nvgRect = function(_, x, y, w, h) captured.rect = { x = x, y = y, w = w, h = h } end
        nvgScale = function(_, sx, sy)
            captured.scales = captured.scales or {}
            captured.scales[#captured.scales + 1] = { sx = sx, sy = sy }
        end
        nvgTranslate = function(_, x, y)
            captured.translates = captured.translates or {}
            captured.translates[#captured.translates + 1] = { x = x, y = y }
        end

        local ok, err = pcall(function()
            local function draw(flipX)
                captured.rect, captured.scales, captured.translates = nil, nil, nil
                assert(ImageArt.Upright({}, "eco_bird_f1", movement, anchor, nil, 1,
                    worldWidth, altitude, flipX), "Upright refused a valid width-sized billboard")
                assert(captured.rect, "Upright committed no rectangle")
                return captured.rect, captured.scales, captured.translates
            end

            local plainRect, plainScales = draw(false)
            -- 内容宽 = worldWidth；内容高按 catalog 内容比反推，故画布高宽比恒等比。
            local scale = select(3, movement:WorldToScreen(anchor, altitude))
            assert(type(scale) == "number" and scale > 0, "anchor did not project")
            local contentWidth = plainRect.w * spec.contentWidth / spec.pixelWidth
            local contentHeight = plainRect.h * spec.contentHeight / spec.pixelHeight
            assert(math.abs(contentWidth - worldWidth * scale) < 1e-6,
                "content width did not follow worldWidth (got " .. tostring(contentWidth) .. ")")
            assert(math.abs(contentHeight - worldWidth * scale
                * spec.contentHeight / spec.contentWidth) < 1e-6,
                "content height was not derived from the catalog content ratio")
            -- 底沿坐锚点：内容在画布内垂直居中，故内容底 = 画布顶 + (画布高+内容高)/2。
            local anchorY = select(2, movement:WorldToScreen(anchor, altitude))
            local contentBottom = plainRect.y + (plainRect.h + contentHeight) * 0.5
            assert(math.abs(contentBottom - anchorY) < 1e-6,
                "billboard bottom edge did not land on the elevated anchor")
            -- altitude 生效：锚点抬到 birdAltitude 后，屏上锚点高于同位置 altitude=0 的投影。
            local groundY = select(2, movement:WorldToScreen(anchor, 0))
            assert(anchorY < groundY - 1e-6,
                "elevated anchor did not project above the sea plane")
            assert(plainScales == nil, "an unmirrored billboard must not push a scale transform")

            local flippedRect, flippedScales = draw(true)
            assert(flippedScales and #flippedScales == 1
                and flippedScales[1].sx == -1 and flippedScales[1].sy == 1,
                "flipX must add exactly one horizontal mirror transform")
            assert(flippedRect.x == plainRect.x and flippedRect.y == plainRect.y
                and flippedRect.w == plainRect.w and flippedRect.h == plainRect.h,
                "flipX must not move or resize the billboard (camera-facing billboard)")
        end)
        ImageArt.Release({})
        nvgCreateImage = oldCreate
        nvgRect, nvgScale, nvgTranslate = oldRect, oldScale, oldTranslate
        nvgImagePattern, nvgShapeAntiAlias = oldPattern, oldAntiAlias
        if not ok then error(err) end

        -- 尺寸口径守卫：宽度与高度都非法时必须拒绝（否则静默画出零尺寸公告板）。
        local rejected = makeRuntime()
        assert(not ImageArt.Upright({}, "eco_bird_f1", rejected.movement, anchor, nil, 1, nil, 0, false),
            "Upright must reject a billboard with neither a usable width nor height")
        assert(not ImageArt.Upright({}, "eco_bird_f1", rejected.movement, anchor, 0, 1, nil, 0, false),
            "Upright must reject a non-positive height")
    end)

    check("eco_plane_failure_keeps_vector_fallback_identical", function()
        recorder.reset()
        local baseline = sceneAt(0, nil) -- nil=不接管，走真实加载失败路径（headless 无 nvgCreateImage）
        local baselineCounts = {}
        for _, name in ipairs({ "nvgEllipse", "nvgCircle", "nvgFill", "nvgBeginPath" }) do
            baselineCounts[name] = recorder.callCount(name)
        end
        recorder.reset()
        local forced = sceneAt(0, false)
        -- Plane 被接管为恒 false：调用会发生（贴图尝试），但全部落矢量回退。
        -- 真正的契约是 nvg 计数与未接管基线一致（零回归），见下方逐项比对。
        for _, name in ipairs({ "nvgEllipse", "nvgCircle", "nvgFill", "nvgBeginPath" }) do
            assert(recorder.callCount(name) == baselineCounts[name],
                name .. " count drifted when eco art failed to load (vector fallback regression)")
        end
    end)

    check("component_entry_scales_by_catalog_content_ratio", function()
        local runtime = makeRuntime()
        local size = 6
        local expectedLength, expectedWidth = ImageArt.ContentPlaneSize("reef_rocks_v1", size)
        assert(expectedLength and expectedWidth, "catalog content size unavailable for reef_rocks_v1")
        local calls = withPlaneRecorder(true, function()
            local ok = SeaViewArt.Component({}, "reef_rocks_v1", runtime.movement,
                { x = 1, y = 2 }, size, 0.5, 0.8)
            assert(ok, "Component returned false with a working plane")
        end)
        assert(#calls == 1, "Component did not issue exactly one plane draw")
        assert(calls[1].name == "reef_rocks_v1", "Component passed the wrong catalog name")
        assert(near(calls[1].x, 1) and near(calls[1].y, 2), "Component moved the world anchor")
        assert(near(calls[1].length, expectedLength) and near(calls[1].width, expectedWidth),
            "Component size did not follow the catalog content ratio")
        assert(near(calls[1].heading, 0.5, 1e-6), "Component did not pass heading through")
        assert(near(calls[1].alpha, 0.8, 1e-6), "Component did not pass alpha through")
        local rejected = withPlaneRecorder(true, function()
            assert(not SeaViewArt.Component({}, "no_such_component", runtime.movement,
                { x = 0, y = 0 }, size), "unknown catalog name should return false")
            assert(not SeaViewArt.Component({}, "reef_rocks_v1", runtime.movement,
                { x = 0, y = 0 }, 0), "non-positive size should return false")
            assert(not SeaViewArt.Component({}, "reef_rocks_v1", runtime.movement,
                { x = 0 }, size), "incomplete anchor should return false")
            assert(not SeaViewArt.Component({}, "reef_rocks_v1", runtime.movement,
                nil, size), "missing anchor should return false")
        end)
        assert(#rejected == 0, "rejected Component calls should not reach the plane")
    end)

    check("component_entry_reports_false_when_art_unavailable", function()
        local runtime = makeRuntime()
        -- headless 无图片加载：Component 必须返回 false 让调用方走矢量兜底
        local ok = SeaViewArt.Component({}, "reef_rocks_v1", runtime.movement,
            { x = 0, y = 0 }, 6, 0, 1)
        assert(not ok, "Component should report false when the image cannot load")
    end)

    local passed = true
    for _, test in ipairs(tests) do
        if not test.passed then passed = false end
    end
    return {
        status = passed and "PASS" or "FAIL",
        tests = tests,
        metrics = {
            ecoAssets = 12,
            frameFps = 6,
            speciesMapping = "sardine->eco_fish_small, tuna->eco_fish_big",
            fallback = "plane-false == unpatched vector baseline",
        },
    }
end

return Tests
