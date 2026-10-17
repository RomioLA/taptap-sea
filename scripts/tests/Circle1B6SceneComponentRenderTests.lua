-- C2（2026-10-17）主场景组件渲染接入白盒测试（OceanComponents 世界放置）。
-- 守护契约：
--   1) 放置注册：World:Init 以 kind="scenery" 注册 reef/coast（地表）与 wreck（水下），
--      contentId 进 fixedContentEntities，实体类型/位置/半径/层级/blocking 与 Config 一致；
--      冻结契约不受影响：fixedObjects 仍为双岛、kind=="fixed" 仍为 2 岛+宝藏+木桶；
--   2) 地表贴图：reef/coast 经 SeaViewArt.Component 走 Plane（catalog 名 + ContentPlaneSize
--      内容比尺寸 + 世界锚点 + 海平面 zero altitude），与 island/生态层同口径；
--   3) 水下门控：wreck 仅在可见（showUnderwater/scope）时绘制，scope 关闭时零绘制；
--   4) 身份守卫：未登记进 fixedContentEntities 的同型实体不得绘制（防幽灵组件）；
--   5) 兜底绘制：真实 headless 路径（Plane 加载必败）下逐点移除对照，证明礁石/海岸/沉船
--      矢量兜底剪影确有绘制；
--   6) 兜底等价：Plane 恒 false 时 nvg 计数与真实加载失败基线一致（矢量兜底零回归）；
--   7) 零状态改写：Scene 不推进 time/世界/船/相机/实体。
local Tests = {}

local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local SeaViewArt = require("Ocean.SeaViewArt")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")

local WIDTH, HEIGHT = 1280, 720
local REEF_POSITION = { x = Config.world.fixedComponents[1].position.x,
    y = Config.world.fixedComponents[1].position.y }
local COAST_POSITION = { x = Config.world.fixedComponents[2].position.x,
    y = Config.world.fixedComponents[2].position.y }
local WRECK = Config.world.fixedWrecks[1]
local WRECK_NEAR = { x = WRECK.position.x, y = WRECK.position.y - 5 }

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

local function countCalls(calls, name)
    local count = 0
    for _, call in ipairs(calls) do
        if call.name == name then count = count + 1 end
    end
    return count
end

local function makeRuntime(departure)
    local runtime = Runtime.New({
        departure = { x = departure.x, y = departure.y },
        initializeRegions = false,
    })
    assert(runtime.movement:SetViewport(WIDTH, HEIGHT), "offline component viewport was not applied")
    return runtime
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

local function sceneCalls(runtime, planeResult)
    local before = captureState(runtime)
    local calls = withPlaneRecorder(planeResult, function()
        SeaDraw.Scene({}, WIDTH, HEIGHT, runtime)
    end)
    local after = captureState(runtime)
    assert(after.runtimeTime == before.runtimeTime, "component rendering advanced runtime time")
    assert(after.worldTime == before.worldTime, "component rendering advanced world time")
    assert(after.shipX == before.shipX and after.shipY == before.shipY, "component rendering moved the ship")
    assert(after.cameraX == before.cameraX and after.cameraY == before.cameraY,
        "component rendering moved the camera")
    assert(after.entityCount == before.entityCount, "component rendering changed world registration")
    return calls
end

function Tests.Run(recorder)
    local tests = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        tests[#tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("scenery_entities_registered_at_world_init", function()
        local runtime = makeRuntime({ x = 0, y = 0 })
        local world = runtime.world
        local registered = world.fixedContentEntities
        for _, entry in ipairs(Config.world.fixedComponents) do
            local entity = assert(registered[entry.contentId], "missing scenery " .. entry.contentId)
            assert(entity.kind == "scenery", entry.contentId .. " must register as scenery kind")
            assert(entity.entityType == entry.entityType, entry.contentId .. " entityType mismatch")
            assert(entity.layer == "surface", entry.contentId .. " must stay on the surface layer")
            assert(not entity.blocking, entry.contentId .. " must not block navigation")
            assert(near(entity.position.x, entry.position.x) and near(entity.position.y, entry.position.y),
                entry.contentId .. " position mismatch")
            assert(near(entity.radius, entry.radius), entry.contentId .. " radius mismatch")
            assert(world:get(entity.id) == entity, entry.contentId .. " must be a live world entity")
        end
        for _, entry in ipairs(Config.world.fixedWrecks) do
            local entity = assert(registered[entry.contentId], "missing wreck " .. entry.contentId)
            assert(entity.kind == "scenery", entry.contentId .. " must register as scenery kind")
            assert(entity.entityType == entry.entityType, entry.contentId .. " entityType mismatch")
            assert(entity.layer == "underwater", entry.contentId .. " must stay underwater")
            assert(not entity.blocking, entry.contentId .. " must not block navigation")
            assert(near(entity.position.x, entry.position.x) and near(entity.position.y, entry.position.y),
                entry.contentId .. " position mismatch")
            assert(near(entity.radius, entry.radius), entry.contentId .. " radius mismatch")
            assert(world:get(entity.id) == entity, entry.contentId .. " must be a live world entity")
        end
        -- 冻结契约：fixedObjects 仍是双岛，kind=="fixed" 集合（2 岛+宝藏+木桶）未被 scenery 稀释
        assert(#Config.world.fixedObjects == 2, "the original fixed-object set should remain unchanged")
        local fixedKind, sceneryKind = 0, 0
        for _, entity in ipairs(world.entities) do
            if entity.kind == "fixed" then fixedKind = fixedKind + 1 end
            if entity.kind == "scenery" then sceneryKind = sceneryKind + 1 end
        end
        assert(fixedKind == 4, "fixed-kind entities must stay 2 islands + treasure + barrel, got " .. fixedKind)
        assert(sceneryKind == #Config.world.fixedComponents + #Config.world.fixedWrecks,
            "scenery-kind entities must match the component + wreck placement lists")
    end)

    check("surface_components_draw_through_component_entry", function()
        for _, entry in ipairs(Config.world.fixedComponents) do
            local runtime = makeRuntime(entry.position)
            local expectedLength, expectedWidth = ImageArt.ContentPlaneSize(entry.contentId, entry.radius * 2)
            assert(expectedLength and expectedWidth, "catalog content size unavailable for " .. entry.contentId)
            local calls = sceneCalls(runtime, true)
            local call = findCall(calls, entry.contentId)
            assert(call, entry.contentId .. " did not draw through the component entry")
            assert(near(call.x, entry.position.x) and near(call.y, entry.position.y),
                entry.contentId .. " moved the world anchor")
            assert(near(call.length, expectedLength) and near(call.width, expectedWidth),
                entry.contentId .. " size did not follow the catalog content ratio")
            assert(near(call.heading, 0) and near(call.altitude, 0),
                entry.contentId .. " must lie flat on the sea plane")
        end
    end)

    check("wreck_draws_only_when_visible", function()
        local visible = makeRuntime(WRECK_NEAR)
        visible.world.showUnderwater = true
        local calls = sceneCalls(visible, true)
        local call = findCall(calls, WRECK.contentId)
        assert(call, "wreck did not draw while underwater display is on")
        local expectedLength, expectedWidth = ImageArt.ContentPlaneSize(WRECK.contentId, WRECK.radius * 2)
        assert(near(call.length, expectedLength) and near(call.width, expectedWidth),
            "wreck size did not follow the catalog content ratio")
        assert(near(call.x, WRECK.position.x) and near(call.y, WRECK.position.y),
            "wreck moved the world anchor")
        assert(near(call.altitude, 0), "wreck plane must stay on the observation plane")

        local hidden = makeRuntime(WRECK_NEAR)
        local hiddenCalls = sceneCalls(hidden, true)
        assert(not findCall(hiddenCalls, WRECK.contentId),
            "wreck must stay hidden while the scope is closed")
    end)

    check("unregistered_scenery_entity_draws_nothing", function()
        local runtime = makeRuntime(REEF_POSITION)
        -- 同型同 kind 但未登记进 fixedContentEntities：身份守卫必须拦下（防幽灵组件）
        runtime.world:spawn({ entityType = "reef", kind = "scenery", layer = "surface",
            contentId = "reef_rocks_v1", position = { x = REEF_POSITION.x + 2, y = REEF_POSITION.y + 2 },
            radius = 6, blocking = false })
        local calls = sceneCalls(runtime, true)
        assert(countCalls(calls, "reef_rocks_v1") == 1,
            "only the registered reef may draw through the component entry, got "
                .. countCalls(calls, "reef_rocks_v1"))
    end)

    check("vector_fallback_renders_when_component_art_unavailable", function()
        -- 真实 headless 路径（不接管 Plane，图片加载必败）：逐点移除对照，证明礁石/海岸/
        -- 沉船的矢量兜底剪影确有绘制。每点只移除当点组件，其余放置保持原样。
        local spots = {
            { list = "fixedComponents", index = 1, departure = REEF_POSITION, underwater = false },
            { list = "fixedComponents", index = 2, departure = COAST_POSITION, underwater = false },
            { list = "fixedWrecks", index = 1, departure = WRECK_NEAR, underwater = true },
        }
        for _, spot in ipairs(spots) do
            local function fillCount()
                local runtime = makeRuntime(spot.departure)
                runtime.world.showUnderwater = spot.underwater
                recorder.reset()
                SeaDraw.Scene({}, WIDTH, HEIGHT, runtime)
                return recorder.callCount("nvgFill")
            end
            local withArt = fillCount()
            local saved = Config.world[spot.list]
            local reduced = {}
            for index, entry in ipairs(saved) do
                if index ~= spot.index then reduced[#reduced + 1] = entry end
            end
            Config.world[spot.list] = reduced
            local ok, err = pcall(function()
                local withoutArt = fillCount()
                assert(withArt > withoutArt,
                    spot.list .. "[" .. spot.index .. "] vector fallback added no fills")
            end)
            Config.world[spot.list] = saved
            assert(ok, tostring(err))
        end
    end)

    check("scenery_plane_failure_keeps_vector_fallback_identical", function()
        local function sceneFillCounts(planeResult)
            local runtime = makeRuntime(REEF_POSITION)
            runtime.world.showUnderwater = true
            sceneCalls(runtime, planeResult)
        end
        recorder.reset()
        sceneFillCounts(nil) -- nil=恒 false 的贴图路径（headless 无 nvgCreateImage）
        local baselineCounts = {}
        for _, name in ipairs({ "nvgEllipse", "nvgCircle", "nvgFill", "nvgBeginPath" }) do
            baselineCounts[name] = recorder.callCount(name)
        end
        recorder.reset()
        sceneFillCounts(false)
        for _, name in ipairs({ "nvgEllipse", "nvgCircle", "nvgFill", "nvgBeginPath" }) do
            assert(recorder.callCount(name) == baselineCounts[name],
                name .. " count drifted when component art failed to load (vector fallback regression)")
        end
    end)

    local passed = true
    for _, test in ipairs(tests) do
        if not test.passed then passed = false end
    end
    return {
        status = passed and "PASS" or "FAIL",
        tests = tests,
        passed = passed,
    }
end

return Tests
