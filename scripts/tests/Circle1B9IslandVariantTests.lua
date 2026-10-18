-- 2026-10-18：6 座新岛屿矢量变体放置契约白盒测试（OceanIslands 批次）。
-- 用户指令：「和以上会话的岛屿的同样方法处理这几个岛屿图，并在世界生成这几张图的
-- 矢量图，参考复用现有实体岛屿，矢量绘画根据图中尺寸比例绘制」。落地口径：
-- Config.world.fixedIslands 独立清单 + World:Init kind="scenery" 注册（非阻挡装饰，
-- entityType="island" 复用 SeaViewArt.Island 入口）+ ISLAND_VARIANTS 变体矢量路径
-- （oblique 贴图独立投放已被 10-18 真机验收否决，贴图仅 catalog preload=false 备用）。
-- 守护契约：
--   1) 注册与冻结：6 岛全部以 kind="scenery" 注册且 contentId 防重登记；冻结契约不受
--      影响（fixedObjects 双岛、kind=="fixed" 计数不变、blockingList 不含新岛）；
--   2) 世界内形态=矢量：变体岛绘制时对该岛贴图名零 Plane 调用（oblique 独立投放
--      否决口径），且确有矢量填充（nvgFill>0）；
--   3) 轮廓分量：nvgFill 下界 = outline 多边形数 + land + hills + trees + rocks + pillar
--      （镜像 ISLAND_VARIANTS 数据，布点漂移即红）；
--   4) 礁石群：5 个子多边形各自独立成岸块（无 land），beginPath 下界 10；
--   5) 石碑岛：中央石柱 + 双散石确有绘制（pillar 增量高于裸轮廓）；
--   6) 放置间距：两两岛距 ≥ r_i+r_j+4m，距 island_01/02/barrel ≥ r+r_block+4m；
--   7) 尺寸比例：Config radius 与镜像一致且 ≤ 贴图外接半径×12/512（island_01 口径）；
--   8) 零状态改写：Island 不推进 time/世界/船/相机/实体。
-- 与 Circle1B5ComponentPlacementTests（island_01/02 底图+岛饰）/ B6（scenery 投放
-- 机制）资产作用域互不重叠：本套件守 fixedIslands 清单与 ISLAND_VARIANTS 数据。
local Tests = {}

local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local SeaViewArt = require("Ocean.SeaViewArt")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")

local WIDTH, HEIGHT = 1280, 720
local CLEARANCE = 4 -- 视觉间距裕量（isPositionFree 硬底线之外）
local SCALE = 12.0 / 512.0 -- 贴图 px → 世界米（island_01 口径：512px ↔ 12m）

-- 镜像 SeaViewArt.ISLAND_VARIANTS（契约测试显式复制：布点/半径漂移即失败）。
-- maxRadius=贴图 content_bounds 半对角×SCALE 取整（矢量半径不得溢出贴图整体外接）。
local VARIANT_MIRROR = {
    { contentId = "island_peak_v1", radius = 7, maxRadius = 13,
        outlines = 1, land = 1, hills = 2, trees = 3, rocks = 2, pillar = 0 },
    { contentId = "island_reefcluster_v1", radius = 9, maxRadius = 11,
        outlines = 5, land = 0, hills = 0, trees = 0, rocks = 0, pillar = 0 },
    { contentId = "island_cliff_v1", radius = 9, maxRadius = 14,
        outlines = 1, land = 1, hills = 1, trees = 2, rocks = 1, pillar = 0 },
    { contentId = "island_stele_v1", radius = 4, maxRadius = 13,
        outlines = 1, land = 1, hills = 0, trees = 0, rocks = 2, pillar = 1 },
    { contentId = "island_twinhills_v1", radius = 10, maxRadius = 15,
        outlines = 1, land = 1, hills = 2, trees = 2, rocks = 1, pillar = 0 },
    { contentId = "island_sandbar_v1", radius = 10, maxRadius = 15,
        outlines = 1, land = 1, hills = 0, trees = 3, rocks = 3, pillar = 0 },
}
local VARIANT_TEXTURE_NAMES = {}
for _, variant in ipairs(VARIANT_MIRROR) do
    VARIANT_TEXTURE_NAMES[variant.contentId] = true
end

local function near(a, b, tolerance)
    return type(a) == "number" and type(b) == "number"
        and math.abs(a - b) <= (tolerance or 0.001)
end

local function fixedObject(contentId)
    for _, entry in ipairs(Config.world.fixedObjects or {}) do
        if entry.contentId == contentId then return entry end
    end
    return nil
end

local ISLAND_01 = assert(fixedObject("island_01"), "island_01 fixed object missing")
local ISLAND_02 = assert(fixedObject("island_02"), "island_02 fixed object missing")
local BARREL = assert(Config.world.fixedBarrel, "fixed barrel missing")

local function fixedIsland(contentId)
    for _, entry in ipairs(Config.world.fixedIslands or {}) do
        if entry.contentId == contentId then return entry end
    end
    return nil
end

local function variantByContentId(contentId)
    for _, variant in ipairs(VARIANT_MIRROR) do
        if variant.contentId == contentId then return variant end
    end
    return nil
end

-- 观察点：岛体为非阻挡 scenery，停泊点取岛南 25m 可航水域（避开 blocking 碰撞圈）。
local function vantageOf(entry)
    return { x = entry.position.x, y = entry.position.y - 25 }
end

local function makeRuntime(departure)
    local runtime = Runtime.New({
        departure = { x = departure.x, y = departure.y },
        initializeRegions = false,
    })
    assert(runtime.movement:SetViewport(WIDTH, HEIGHT), "offline placement viewport was not applied")
    return runtime
end

-- 记录 ImageArt.Plane 调用；result 控制返回值（headless 无图，false=加载失败走矢量）。
local function withPlaneRecorder(result, fn)
    local calls = {}
    local originalPlane = ImageArt.Plane
    ImageArt.Plane = function(ctx, name, movement, origin, length, width, heading, altitude, alpha)
        calls[#calls + 1] = { name = name, x = origin.x, y = origin.y,
            length = length, width = width, heading = heading, altitude = altitude }
        return result
    end
    local ok, err = pcall(fn)
    ImageArt.Plane = originalPlane
    if not ok then error(err) end
    return calls
end

local function countCalls(calls, name)
    local count = 0
    for _, call in ipairs(calls) do
        if call.name == name then count = count + 1 end
    end
    return count
end

local function islandEntity(entry)
    return {
        contentId = entry.contentId,
        position = { x = entry.position.x, y = entry.position.y },
        radius = entry.radius,
    }
end

-- 变体岛矢量绘制（贴图恒失败）：返回 Plane 调用表；nvg 计数经 recorder 读取。
local function drawVariantIsland(entry)
    local runtime = makeRuntime(vantageOf(entry))
    return withPlaneRecorder(false, function()
        SeaViewArt.Island({}, runtime.movement, islandEntity(entry), 0, 0)
    end)
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

local function distance(a, b)
    return math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
end

function Tests.Run(recorder)
    local tests = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        tests[#tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("fixed_islands_registered_at_world_init", function()
        local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
        local world = runtime.world
        local sceneryCount = 0
        for _, entity in ipairs(world.entities) do
            if entity.contentId and VARIANT_TEXTURE_NAMES[entity.contentId] then
                assert(entity.kind == "scenery",
                    entity.contentId .. " must register as scenery, got " .. tostring(entity.kind))
                assert(entity.entityType == "island",
                    entity.contentId .. " must reuse the island entity type")
                assert(entity.layer == "surface", entity.contentId .. " must be a surface entity")
                assert(entity.blocking == false, entity.contentId .. " must not block navigation")
                assert(world.fixedContentEntities[entity.contentId] == entity,
                    entity.contentId .. " must register into fixedContentEntities")
                sceneryCount = sceneryCount + 1
            end
        end
        assert(sceneryCount == 6, "all six variant islands must register, got " .. sceneryCount)
        -- 冻结契约复核：双岛集 / fixed 计数 / blockingList 均不因本批扩张。
        assert(#Config.world.fixedObjects == 2, "the frozen fixed-object set must stay at two")
        local fixedKind = 0
        for _, entity in ipairs(world.entities) do
            if entity.kind == "fixed" then fixedKind = fixedKind + 1 end
        end
        assert(fixedKind == 4, "kind==fixed count drifted: " .. fixedKind)
        for _, entity in ipairs(world.blockingList) do
            assert(not VARIANT_TEXTURE_NAMES[entity.contentId or ""],
                "variant islands must never enter the blocking list")
        end
    end)

    check("variant_islands_draw_vector_without_texture", function()
        -- oblique 贴图独立投放已被真机验收否决：变体岛世界内形态=矢量，
        -- 绘制时对该岛贴图名零 Plane 调用，且确有矢量填充。
        for _, variant in ipairs(VARIANT_MIRROR) do
            local entry = assert(fixedIsland(variant.contentId), variant.contentId .. " missing")
            recorder.reset()
            local calls = drawVariantIsland(entry)
            assert(countCalls(calls, variant.contentId) == 0,
                variant.contentId .. " must not draw through the texture plane (vector only)")
            assert(recorder.callCount("nvgFill") > 0,
                variant.contentId .. " vector outline added no fills")
        end
    end)

    check("variant_fill_counts_match_outline_data", function()
        for _, variant in ipairs(VARIANT_MIRROR) do
            local entry = assert(fixedIsland(variant.contentId), variant.contentId .. " missing")
            recorder.reset()
            drawVariantIsland(entry)
            local expectedFills = variant.outlines + variant.land + variant.hills
                + variant.trees + variant.rocks + variant.pillar
            assert(recorder.callCount("nvgFill") >= expectedFills,
                variant.contentId .. " fills below outline data: " .. recorder.callCount("nvgFill")
                    .. " < " .. expectedFills)
            assert(recorder.callCount("nvgBeginPath") >= 2 * (variant.outlines + variant.land),
                variant.contentId .. " begin paths below outline polygons")
        end
    end)

    check("variant_reefcluster_draws_five_independent_shoals", function()
        -- 礁石群：5 个子多边形各自独立成岸块（outline 全收、无 land）。
        local variant = assert(variantByContentId("island_reefcluster_v1"), "reefcluster mirror missing")
        local entry = assert(fixedIsland("island_reefcluster_v1"), "reefcluster placement missing")
        recorder.reset()
        drawVariantIsland(entry)
        assert(recorder.callCount("nvgBeginPath") >= variant.outlines * 2,
            "reefcluster must draw five independent shoals (fill+stroke each)")
        assert(recorder.callCount("nvgFill") >= variant.outlines,
            "reefcluster fills below five shoals")
    end)

    check("variant_stele_draws_pillar_and_rocks", function()
        -- 石碑岛：中央石柱 + 双散石（pillar 增量高于裸轮廓+陆地 2 fill）。
        local entry = assert(fixedIsland("island_stele_v1"), "stele placement missing")
        recorder.reset()
        drawVariantIsland(entry)
        assert(recorder.callCount("nvgFill") >= 5,
            "stele must fill outline+land+2 rocks+pillar, got " .. recorder.callCount("nvgFill"))
    end)

    check("variant_placement_keeps_clearance", function()
        local blockers = {
            { position = ISLAND_01.position, radius = ISLAND_01.radius },
            { position = ISLAND_02.position, radius = ISLAND_02.radius },
            { position = BARREL.position, radius = BARREL.radius },
        }
        local entries = {}
        for _, variant in ipairs(VARIANT_MIRROR) do
            entries[#entries + 1] = assert(fixedIsland(variant.contentId),
                variant.contentId .. " placement missing")
        end
        for index, entry in ipairs(entries) do
            for other = index + 1, #entries do
                local gap = distance(entry.position, entries[other].position)
                assert(gap >= entry.radius + entries[other].radius + CLEARANCE,
                    entry.contentId .. " and " .. entries[other].contentId
                        .. " are too close: " .. string.format("%.1f", gap))
            end
            for _, blocker in ipairs(blockers) do
                local gap = distance(entry.position, blocker.position)
                assert(gap >= entry.radius + blocker.radius + CLEARANCE,
                    entry.contentId .. " crowd a blocking object: "
                        .. string.format("%.1f", gap))
            end
        end
    end)

    check("variant_config_radius_follows_texture_bounds", function()
        for _, variant in ipairs(VARIANT_MIRROR) do
            local entry = assert(fixedIsland(variant.contentId), variant.contentId .. " missing")
            assert(entry.radius == variant.radius,
                variant.contentId .. " radius drifted from mirror: " .. tostring(entry.radius))
            assert(entry.radius <= variant.maxRadius,
                variant.contentId .. " radius exceeds texture outer bounds: "
                    .. tostring(entry.radius) .. " > " .. variant.maxRadius)
        end
    end)

    check("variant_draw_is_read_only", function()
        for _, variant in ipairs(VARIANT_MIRROR) do
            local entry = assert(fixedIsland(variant.contentId), variant.contentId .. " missing")
            local runtime = makeRuntime(vantageOf(entry))
            local before = captureState(runtime)
            SeaViewArt.Island({}, runtime.movement, islandEntity(entry), 0, 0)
            assertUnchanged(before, captureState(runtime), variant.contentId)
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
