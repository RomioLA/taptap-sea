-- C2（2026-10-17）海面组件放置契约白盒测试（OceanComponents 批次：island_01 岛饰）。
-- 2026-10-17 深夜用户仲裁：批准 sign_* 七件作 island_01 固定岛饰（原 D3-A「保持
-- 素材库不放置」经人类裁决解除，跨渠道指令冲突以本裁定为准）。本套件经重建恢复
-- （D3-A 轮次曾被清退），守护契约：
--   1) 防重锚点：shipwreck_v1 全场景至多一次绘制且锚在 fixedWrecks 注册位——水下宝藏
--      (35,45) 与固定沉船 (35,60) 相距 15m，禁止把同一张沉船图再叠到宝藏上（双沉船回归）；
--   2) island_01 固定岛饰：sign_* 七件各恰好放置一次，全部落在 0.89r 陆地圈内、与
--      TREE_LAYOUT 树位保持 ≥1.4m 间距；island_02 零放置（固定装饰作用域不越界）；
--      2026-10-18 起走竖幅公告板投影（Upright）：高度透传+投影模式断言（防回退平铺）；
--   3) 兜底等价：Plane/Upright 恒假时全部 nvg 计数与自然加载失败基线完全一致（矢量回退零回归）；
--   4) 零状态改写：Island/Scene 不推进 time/世界/船/相机/实体；
--   5) Component 入口：shipwreck 尺寸换算与锚点透传（未知名/非法尺寸由生态层测试守护）。
-- 注：reef/coast/wreck 的 scenery 世界放置（Config.world.fixedComponents/fixedWrecks +
-- World:Init kind="scenery" + SeaDraw.drawSurfaceComponent/drawFixedWreck）由
-- Circle1B6SceneComponentRenderTests 守护，与本套件资产作用域互不重叠。
local Tests = {}

local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local SeaViewArt = require("Ocean.SeaViewArt")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")

local WIDTH, HEIGHT = 1280, 720
local BARREL_DISTANCE = 4
local TREASURE_DISPLAY_METERS = 6
local DECOR_MIN_TREE_CLEARANCE = 1.4
-- 镜像 SeaViewArt.TREE_LAYOUT 的归一化树位（契约测试显式复制：布局漂移即失败）。
local TREE_LAYOUT = {
    { x = -0.44, y = 0.12 },
    { x = -0.13, y = -0.34 },
    { x = 0.20, y = 0.27 },
    { x = 0.43, y = -0.08 },
}
-- 镜像 SeaViewArt.ISLAND_01_DECOR（契约测试显式复制：放置漂移即失败）。
local ISLAND_01_DECOR = {
    { name = "sign_chest_v1",     x =  0.02, y =  0.40, size = 1.6 },
    { name = "sign_coins_v1",     x = -0.30, y =  0.34, size = 1.1 },
    { name = "sign_planks_v1",    x =  0.34, y =  0.05, size = 1.8 },
    { name = "sign_rock_v1",      x =  0.12, y = -0.42, size = 1.5 },
    { name = "sign_seaweed_v1",   x =  0.46, y =  0.30, size = 1.2 },
    { name = "sign_palm_v1",      x = -0.38, y = -0.30, size = 2.2 },
    { name = "sign_broadleaf_v1", x = -0.10, y =  0.52, size = 1.8 },
}
local SIGN_COMPONENTS = {
    "sign_chest_v1", "sign_coins_v1", "sign_planks_v1", "sign_rock_v1",
    "sign_seaweed_v1", "sign_palm_v1", "sign_broadleaf_v1",
}

local function fixedObject(contentId)
    for _, entry in ipairs(Config.world.fixedObjects or {}) do
        if entry.contentId == contentId then return entry end
    end
    return nil
end

local ISLAND_01 = assert(fixedObject("island_01"), "island_01 fixed object missing")
local ISLAND_02 = assert(fixedObject("island_02"), "island_02 fixed object missing")
local WRECK = assert(Config.world.fixedWrecks and Config.world.fixedWrecks[1], "fixed wreck missing")
local TREASURE = assert(Config.world.fixedTreasure, "fixed treasure missing")
-- 岛饰观察点：岛体为碰撞圈，出港停泊点取岛外 30m 南侧可航水域（isPositionFree 口径）。
local ISLAND_01_VANTAGE = { x = ISLAND_01.position.x, y = ISLAND_01.position.y - 30 }
local ISLAND_02_VANTAGE = { x = ISLAND_02.position.x, y = ISLAND_02.position.y - 30 }

local function near(a, b, tolerance)
    return type(a) == "number" and type(b) == "number"
        and math.abs(a - b) <= (tolerance or 0.001)
end

-- 记录 ImageArt.Plane / ImageArt.Upright 调用；result 控制返回值（true=贴图可用 / false=加载失败）。
-- 2026-10-18 真机验收：岛饰由平铺（Component→Plane）改竖幅公告板投影（Upright），
-- 录制器须同时覆盖两个入口（Plane 仍服务岛贴图/wreck/reef/coast）。
local function withPlaneRecorder(result, fn)
    local calls = {}
    local originalPlane, originalUpright = ImageArt.Plane, ImageArt.Upright
    ImageArt.Plane = function(ctx, name, movement, origin, length, width, heading, altitude, alpha)
        calls[#calls + 1] = { mode = "plane", name = name, x = origin.x, y = origin.y,
            length = length, width = width, heading = heading,
            altitude = altitude, alpha = alpha }
        return result
    end
    ImageArt.Upright = function(ctx, name, movement, position, worldHeight, alpha)
        calls[#calls + 1] = { mode = "upright", name = name, x = position.x, y = position.y,
            height = worldHeight, alpha = alpha }
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
    assert(runtime.movement:SetViewport(WIDTH, HEIGHT), "offline placement viewport was not applied")
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

local function assertUnchanged(before, after, context)
    assert(after.runtimeTime == before.runtimeTime, context .. " advanced runtime time")
    assert(after.worldTime == before.worldTime, context .. " advanced world time")
    assert(after.shipX == before.shipX and after.shipY == before.shipY, context .. " moved the ship")
    assert(after.cameraX == before.cameraX and after.cameraY == before.cameraY,
        context .. " moved the camera")
    assert(after.entityCount == before.entityCount, context .. " changed world registration")
end

local function islandEntity(entry)
    return {
        contentId = entry.contentId,
        position = { x = entry.position.x, y = entry.position.y },
        radius = entry.radius,
    }
end

local function drawIsland(runtime, entry, planeResult)
    return withPlaneRecorder(planeResult, function()
        SeaViewArt.Island({}, runtime.movement, islandEntity(entry), 0, 0)
    end)
end

local function wreckCallsFrom(departure)
    local runtime = makeRuntime(departure)
    runtime.world.showUnderwater = true
    local calls = withPlaneRecorder(true, function()
        SeaDraw.Scene({}, WIDTH, HEIGHT, runtime)
    end)
    local wreckCalls = {}
    for _, call in ipairs(calls) do
        if call.name == WRECK.contentId then wreckCalls[#wreckCalls + 1] = call end
    end
    return wreckCalls
end

function Tests.Run(recorder)
    local tests = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        tests[#tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("shipwreck_draws_once_anchored_at_registered_position", function()
        -- 防双沉船：从宝藏显示半径内观察，shipwreck_v1 至多一次且不得锚在宝藏位。
        local fromTreasure = wreckCallsFrom({
            x = TREASURE.position.x, y = TREASURE.position.y + TREASURE_DISPLAY_METERS })
        assert(#fromTreasure <= 1,
            "shipwreck must draw at most once per scene, got " .. #fromTreasure)
        for _, call in ipairs(fromTreasure) do
            assert(near(call.x, WRECK.position.x) and near(call.y, WRECK.position.y),
                "shipwreck must anchor at the registered wreck position, never at the treasure")
        end
        -- 沉船附近：必须恰好一次且锚在 fixedWrecks 注册位。
        local fromWreck = wreckCallsFrom({
            x = WRECK.position.x, y = WRECK.position.y - WRECK.radius - 2 })
        assert(#fromWreck == 1,
            "wreck vicinity must draw the shipwreck exactly once, got " .. #fromWreck)
        assert(near(fromWreck[1].x, WRECK.position.x) and near(fromWreck[1].y, WRECK.position.y),
            "shipwreck anchor drifted from the registered wreck position")
    end)

    check("island_01_decor_places_each_sign_once_inside_land_circle", function()
        local runtime = makeRuntime(ISLAND_01_VANTAGE)
        local calls = drawIsland(runtime, ISLAND_01, true)
        local radius = ISLAND_01.radius
        local centerX, centerY = ISLAND_01.position.x, ISLAND_01.position.y
        for _, decor in ipairs(ISLAND_01_DECOR) do
            assert(countCalls(calls, decor.name) == 1,
                decor.name .. " must place exactly once on island_01, got "
                    .. countCalls(calls, decor.name))
            local call = findCall(calls, decor.name)
            local offsetX, offsetY = decor.x * radius, decor.y * radius
            assert(near(call.x, centerX + offsetX) and near(call.y, centerY + offsetY),
                decor.name .. " anchor drifted from the island-normalized layout")
            -- 2026-10-18 真机验收：竖幅公告板投影（原平铺令棕榈/阔叶躺倒、预烘焙斜视
            -- 资产被二次压扁，视觉融入海面）。高度=decor.size 透传（Upright 内容主体
            -- 世界高度口径，画幅由 catalog 内容比内部换算）。
            assert(call.mode == "upright",
                decor.name .. " must draw through the upright billboard projection, got "
                    .. tostring(call.mode))
            assert(near(call.height, decor.size),
                decor.name .. " upright height did not pass through the layout size")
            -- 陆地圈 0.89r 内（与岛体 land 圆同口径）。
            assert(offsetX * offsetX + offsetY * offsetY <= (0.89 * radius) * (0.89 * radius) + 1e-6,
                decor.name .. " must stay inside the 0.89r land circle")
            -- 与四个树位保持 ≥1.4m 间距（r=12 口径实测）。
            for _, tree in ipairs(TREE_LAYOUT) do
                local dx = offsetX - tree.x * radius
                local dy = offsetY - tree.y * radius
                assert(math.sqrt(dx * dx + dy * dy) >= DECOR_MIN_TREE_CLEARANCE - 1e-6,
                    decor.name .. " must keep " .. DECOR_MIN_TREE_CLEARANCE
                        .. "m clearance from every tree layout slot")
            end
        end
        -- 作用域不越界：island_02 与其他岛零放置。
        local other = makeRuntime(ISLAND_02_VANTAGE)
        local otherCalls = drawIsland(other, ISLAND_02, true)
        for _, name in ipairs(SIGN_COMPONENTS) do
            assert(countCalls(otherCalls, name) == 0, name .. " must not decorate island_02")
        end
    end)

    check("decor_plane_failure_keeps_island_counts_identical", function()
        local COUNT_NAMES = { "nvgBeginPath", "nvgMoveTo", "nvgLineTo", "nvgClosePath",
            "nvgFill", "nvgStroke", "nvgCircle", "nvgEllipse" }
        local function islandCounts(mode)
            local runtime = makeRuntime(ISLAND_01_VANTAGE)
            recorder.reset()
            if mode == "natural" then
                -- 不接管 Plane：headless 无 nvgCreateImage，贴图加载自然失败。
                SeaViewArt.Island({}, runtime.movement, islandEntity(ISLAND_01), 0, 0)
            else
                drawIsland(runtime, ISLAND_01, false)
            end
            local counts = {}
            for _, name in ipairs(COUNT_NAMES) do
                counts[name] = recorder.callCount(name)
            end
            return counts
        end
        local natural = islandCounts("natural")
        local forced = islandCounts("forced")
        for _, name in ipairs(COUNT_NAMES) do
            assert(forced[name] == natural[name],
                name .. " drifted when component art failed to load (vector fallback regression)")
        end
    end)

    check("placement_rendering_rewrites_no_world_state", function()
        local runtime = makeRuntime(ISLAND_01_VANTAGE)
        local before = captureState(runtime)
        drawIsland(runtime, ISLAND_01, true)
        assertUnchanged(before, captureState(runtime), "island decor rendering")
        -- Scene 全链路（岛饰 + scenery + 生态层 + 木桶）同样零改写。
        local barrel = runtime.world.fixedBarrel
        local sceneRuntime = makeRuntime({
            x = barrel.position.x + BARREL_DISTANCE, y = barrel.position.y })
        local sceneBefore = captureState(sceneRuntime)
        withPlaneRecorder(true, function()
            SeaDraw.Scene({}, WIDTH, HEIGHT, sceneRuntime)
        end)
        assertUnchanged(sceneBefore, captureState(sceneRuntime), "scene rendering")
    end)

    check("shipwreck_component_entry_passes_catalog_size_and_anchor", function()
        local wreckCalls = wreckCallsFrom({
            x = WRECK.position.x, y = WRECK.position.y - WRECK.radius - 2 })
        local call = wreckCalls[1]
        assert(call, "wreck did not draw through the component entry")
        local expectedLength, expectedWidth = ImageArt.ContentPlaneSize(WRECK.contentId, WRECK.radius * 2)
        assert(expectedLength and expectedWidth, "catalog content size unavailable for the wreck")
        assert(near(call.length, expectedLength) and near(call.width, expectedWidth),
            "wreck size did not follow the catalog content ratio")
        assert(near(call.x, WRECK.position.x) and near(call.y, WRECK.position.y),
            "wreck anchor drifted from the registered position")
        assert(near(call.altitude, 0), "wreck plane must stay on the observation plane")
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
