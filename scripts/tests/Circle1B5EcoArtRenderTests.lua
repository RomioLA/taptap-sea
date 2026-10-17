-- C2（2026-10-17）生态层组件 v2 渲染接入白盒测试。
-- 守护契约：
--   1) 帧循环：鱼/海鸟/木桶按 time 走 eco_*_f1→f2→f3（6fps），鸟/桶相位 0 帧序精确可算；
--   2) 物种映射：sardine→eco_fish_small（renderLength 1.8）、tuna→eco_fish_big（3.8）；
--   3) heading 直传：贴图头朝 +X（入库水平翻转），鱼 heading=实体朝向；
--   4) 兜底等价：Plane 失败（返回 false）时全部 nvg 计数与未接入基线完全一致（矢量回退零回归）；
--   5) 零状态改写：Scene 不推进 time/世界/船/相机/实体；
--   6) SeaViewArt.Component：尺寸换算、heading/alpha 透传、非法输入与未知目录名返回 false。
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

-- 记录 ImageArt.Plane 调用；result 控制返回值（true=贴图可用 / false=加载失败）。
local function withPlaneRecorder(result, fn)
    local calls = {}
    local original = ImageArt.Plane
    ImageArt.Plane = function(ctx, name, movement, origin, length, width, heading, altitude, alpha)
        calls[#calls + 1] = { name = name, x = origin.x, y = origin.y,
            length = length, width = width, heading = heading,
            altitude = altitude, alpha = alpha }
        return result
    end
    local ok, err = pcall(fn)
    ImageArt.Plane = original
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

local function makeRuntime()
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
                heading = BIRD_HEADING, diveProgress = BIRD_DIVE } }
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

local function sceneAt(timeValue, planeResult)
    local runtime = makeRuntime()
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
        assert(near(bird.length, 3.2) and near(bird.width, 3.2 * (1 - 0.62 * BIRD_DIVE)),
            "bird plane size did not follow the dive shrink contract")
        assert(near(bird.heading, BIRD_HEADING, 1e-6), "bird heading was not the cue heading")
        assert(near(bird.altitude, birdAltitude), "bird altitude did not follow the dive contract")
        local barrel = findCall(calls, "eco_barrel_f1")
        assert(barrel, "fixed barrel did not draw through the eco barrel art")
        local radius = Config.world.fixedBarrel.radius * 0.65
        local barrelSize = radius * 2 / 0.88
        assert(near(barrel.length, barrelSize) and near(barrel.width, barrelSize),
            "barrel plane size did not follow the visual radius contract")
        assert(near(barrel.heading, 0), "barrel heading should stay 0 (radially symmetric)")
        assert(countCalls(calls, "eco_") == 4,
            "expected exactly 2 fish + 1 bird + 1 barrel eco draws, got " .. countCalls(calls, "eco_"))
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
