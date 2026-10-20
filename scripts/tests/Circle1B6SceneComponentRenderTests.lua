-- C2（2026-10-17）主场景组件渲染接入白盒测试（OceanComponents 世界放置）。
-- 2026-10-18 真机验收：礁石/海岸 oblique 组件撤出独立海面投放（原平铺在开阔海面呈
-- 漂浮贴图块，白边/与世界实体速率脱节），改作既有岛屿底图（island_01←海岸 /
-- island_02←礁石，由 Circle1B5ComponentPlacementTests 的 ISLAND_BASE_TEXTURES 契约
-- 守护）。本套件改以夹具清单守护投放机制本身（回填 Config.world.fixedComponents 即可
-- 复用），生产口径断言礁石/海岸零投放。守护契约：
--   1) 生产零投放：Config.world.fixedComponents 为空，World:Init 后 scenery 为沉船一件
--      + 六座矢量变体岛（fixedIslands，2026-10-18 新增，kind="scenery" 非阻挡）；
--      夹具清单下 World:Init 仍以 kind="scenery" 正确注册地表组件（机制不退化）；
--      冻结契约不受影响：fixedObjects 仍为双岛、kind=="fixed" 仍为 2 岛+宝藏+木桶；
--   2) 地表贴图：夹具 reef/coast 经 SeaViewArt.Component 走 Plane（catalog 名 +
--      ContentPlaneSize 内容比尺寸 + 世界锚点 + 海平面 zero altitude），与 island 同口径；
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
local Content = require("data.content")

local WIDTH, HEIGHT = 1280, 720
-- 2026-10-18：礁石/海岸撤出生产投放后仅存于夹具；夹具位复用原生产坐标
-- （曾满足 isPositionFree 的开阔水域，礁石 (16,20) 出港即见、海岸 (60,40) 居中）。
local REEF_POSITION = { x = 16, y = 20 }
local COAST_POSITION = { x = 60, y = 40 }
local COMPONENT_FIXTURES = {
    { entityType = "reef", contentId = "reef_rocks_v1",
        position = { x = REEF_POSITION.x, y = REEF_POSITION.y }, radius = 6, blocking = false },
    { entityType = "coast", contentId = "coast_base_v3",
        position = { x = COAST_POSITION.x, y = COAST_POSITION.y }, radius = 14, blocking = false },
}
local WRECK = Config.world.fixedWrecks[1]
local WRECK_NEAR = { x = WRECK.position.x, y = WRECK.position.y - 5 }

local function near(a, b, tolerance)
    return type(a) == "number" and type(b) == "number"
        and math.abs(a - b) <= (tolerance or 0.001)
end

-- 以夹具清单临时回填 Config.world.fixedComponents（World:Init 构造时读取），
-- 结束后恢复生产口径（空清单）。pcall 保护：断言失败也恢复，避免污染同进程套件。
local function withComponentFixtures(fn)
    local saved = Config.world.fixedComponents
    Config.world.fixedComponents = COMPONENT_FIXTURES
    local ok, err = pcall(fn)
    Config.world.fixedComponents = saved
    assert(ok, tostring(err))
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

-- 按名称+世界锚点定位：island_02 底图与礁石夹具同名（reef_rocks_v1），远岛底图调用
-- 会混入同名单（2026-10-18 实测：119m 外岛底图仍过 LOD 上屏），必须锚点区分。
local function findCallAt(calls, name, x, y)
    for _, call in ipairs(calls) do
        if call.name == name and near(call.x, x) and near(call.y, y) then return call end
    end
    return nil
end

local function countCallsAt(calls, name, x, y)
    local count = 0
    for _, call in ipairs(calls) do
        if call.name == name and near(call.x, x) and near(call.y, y) then count = count + 1 end
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
        -- 生产口径（2026-10-18 真机验收）：礁石/海岸零投放，scenery 为沉船 + 六座矢量变体岛。
        assert(#Config.world.fixedComponents == 0,
            "reef/coast must no longer float as surface components (moved to island bases)")
        local production = makeRuntime({ x = 0, y = 0 })
        local productionScenery = 0
        for _, entity in ipairs(production.world.entities) do
            if entity.kind == "scenery" then productionScenery = productionScenery + 1 end
        end
        assert(productionScenery == #Config.world.fixedWrecks + #Config.world.fixedIslands,
            "production scenery must be the wreck + variant islands, got " .. productionScenery)
        -- 机制口径：夹具清单下注册链路不退化（回填条目即复用）。
        withComponentFixtures(function()
            local runtime = makeRuntime({ x = 0, y = 0 })
            local world = runtime.world
            local registered = world.fixedContentEntities
            for _, entry in ipairs(COMPONENT_FIXTURES) do
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
            -- V2.8：固定海上内容增加 11 个节点；fixed 计数 = Content.fixed + 木桶。
            assert(fixedKind == #Content.fixed + 1,
                "fixed-kind entities must equal authored content plus the barrel, got " .. fixedKind)
            assert(sceneryKind == #COMPONENT_FIXTURES + #Config.world.fixedWrecks + #Config.world.fixedIslands,
                "scenery-kind entities must match the fixture + wreck + variant island placement lists")
        end)
    end)

    check("surface_components_draw_through_component_entry", function()
        withComponentFixtures(function()
            for _, entry in ipairs(COMPONENT_FIXTURES) do
                local runtime = makeRuntime(entry.position)
                local expectedLength, expectedWidth = ImageArt.ContentPlaneSize(entry.contentId, entry.radius * 2)
                assert(expectedLength and expectedWidth, "catalog content size unavailable for " .. entry.contentId)
                local calls = sceneCalls(runtime, true)
                local call = findCallAt(calls, entry.contentId, entry.position.x, entry.position.y)
                assert(call, entry.contentId .. " did not draw through the component entry at its anchor")
                assert(near(call.length, expectedLength) and near(call.width, expectedWidth),
                    entry.contentId .. " size did not follow the catalog content ratio")
                assert(near(call.heading, 0) and near(call.altitude, 0),
                    entry.contentId .. " must lie flat on the sea plane")
            end
        end)
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
        withComponentFixtures(function()
            local runtime = makeRuntime(REEF_POSITION)
            -- 同型同 kind 但未登记进 fixedContentEntities：身份守卫必须拦下（防幽灵组件）
            runtime.world:spawn({ entityType = "reef", kind = "scenery", layer = "surface",
                contentId = "reef_rocks_v1", position = { x = REEF_POSITION.x + 2, y = REEF_POSITION.y + 2 },
                radius = 6, blocking = false })
            local calls = sceneCalls(runtime, true)
            -- 锚点区分：island_02 底图同名（reef_rocks_v1）但锚在 (-80,90)，不得计入。
            assert(countCallsAt(calls, "reef_rocks_v1", REEF_POSITION.x, REEF_POSITION.y) == 1,
                "only the registered reef may draw through the component entry, got "
                    .. countCallsAt(calls, "reef_rocks_v1", REEF_POSITION.x, REEF_POSITION.y))
            assert(countCallsAt(calls, "reef_rocks_v1", REEF_POSITION.x + 2, REEF_POSITION.y + 2) == 0,
                "the unregistered ghost reef must not draw through the component entry")
        end)
    end)

    check("vector_fallback_renders_when_component_art_unavailable", function()
        -- 真实 headless 路径（不接管 Plane，图片加载必败）：逐点移除对照，证明礁石/海岸/
        -- 沉船的矢量兜底剪影确有绘制。每点只移除当点组件，其余放置保持原样。
        withComponentFixtures(function()
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
    end)

    check("scenery_plane_failure_keeps_vector_fallback_identical", function()
        withComponentFixtures(function()
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
