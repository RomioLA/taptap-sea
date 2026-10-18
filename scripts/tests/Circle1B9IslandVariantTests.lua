-- 2026-10-18：6 座新岛屿变体放置契约白盒测试（OceanIslands 批次）。
-- 用户指令：「和以上会话的岛屿的同样方法处理这几个岛屿图，并在世界生成这几张图的
-- 矢量图，参考复用现有实体岛屿，矢量绘画根据图中尺寸比例绘制」；2026-10-18 晚追加
-- 「做实体体积和对应岛屿素材渲染接入」。落地口径：
-- Config.world.fixedIslands 独立清单 + World:Init kind="scenery" + blocking=true
-- （实体阻挡，进 blockingList，island_01/02 同构；A2 冻结契约数 kind=="fixed" 不变）
-- + ISLAND_VARIANTS 变体数据；渲染=竖幅公告板优先（2026-10-18 真机二轮：Plane
-- 平铺呈漂浮贴图块被否决，改 Upright——contentId 即 catalog 条目名，底沿坐岛心、
-- 高度=clamp(r*0.55, 2.6, 6.0)）、加载失败回退变体矢量轮廓（立牌成功时矢量
-- 丘/树/石/柱抑制）。
-- 守护契约：
--   1) 注册与冻结：6 岛全部以 kind="scenery"+blocking=true 注册且 contentId 防重登记；
--      冻结契约不受影响（fixedObjects 双岛、kind=="fixed" 计数不变）；blockingList
--      含全部六岛（实体体积）；
--   2) 立牌优先：绘制时以 contentId 名调用 Upright 恰一次（位置=岛心、高度口径
--      锚定），零 Plane 调用（防回退平铺），且矢量植被被抑制（nvgFill 低于兜底）；
--   3) 矢量兜底：立牌加载失败时 Upright 仍尝试恰一次，零 Plane 调用
--      （不回退 island.png），矢量填充 ≥ 镜像布点下界；
--   4) 轮廓分量：nvgFill 下界 = outline 多边形数 + land + hills + trees + rocks + pillar
--      （镜像 ISLAND_VARIANTS 数据，布点漂移即红）；
--   5) 礁石群：5 个子多边形各自独立成岸块（无 land），beginPath 下界 10；
--   6) 石碑岛：中央石柱 + 双散石确有绘制（pillar 增量高于裸轮廓）；
--   7) 放置间距：两两岛距 ≥ r_i+r_j+4m，距 island_01/02/barrel ≥ r+r_block+4m；
--   8) 尺寸比例：Config radius 与镜像一致且 ≤ 贴图外接半径×12/512（island_01 口径）；
--   9) 零状态改写：Island 不推进 time/世界/船/相机/实体。
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

-- 观察点：岛体为阻挡实体，停泊点取岛南 25m 可航水域（避开 blocking 碰撞圈）。
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

-- 桩 ImageArt.Upright（2026-10-18 真机二轮：变体岛贴图由 Plane 平铺改竖幅公告板）
-- 与 ImageArt.Plane：uprightResult 控制 Upright 返回值（headless 无图，false=加载
-- 失败走矢量兜底）；Plane 恒 false（变体岛不应有任何平面贴图，防回退平铺）。
local function withBillboardRecorder(uprightResult, fn)
    local calls = {}
    local originalPlane, originalUpright = ImageArt.Plane, ImageArt.Upright
    ImageArt.Plane = function(ctx, name, movement, origin, length, width, heading, altitude, alpha)
        calls[#calls + 1] = { mode = "plane", name = name }
        return false
    end
    ImageArt.Upright = function(ctx, name, movement, position, worldHeight, alpha)
        calls[#calls + 1] = { mode = "upright", name = name, x = position.x, y = position.y,
            height = worldHeight, alpha = alpha }
        return uprightResult
    end
    local ok, err = pcall(fn)
    ImageArt.Plane, ImageArt.Upright = originalPlane, originalUpright
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

-- 变体岛矢量绘制（立牌加载失败）：返回 Upright/Plane 调用表；nvg 计数经 recorder 读取。
local function drawVariantIsland(entry)
    local runtime = makeRuntime(vantageOf(entry))
    return withBillboardRecorder(false, function()
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
                -- 实体体积（2026-10-18 晚）：blocking=true 进 blockingList，船不可穿越。
                assert(entity.blocking == true,
                    entity.contentId .. " must block navigation (solid island volume)")
                assert(world.fixedContentEntities[entity.contentId] == entity,
                    entity.contentId .. " must register into fixedContentEntities")
                sceneryCount = sceneryCount + 1
            end
        end
        assert(sceneryCount == 6, "all six variant islands must register, got " .. sceneryCount)
        -- 冻结契约复核：双岛集 / fixed 计数不因本批扩张（六岛 kind=="scenery"）。
        assert(#Config.world.fixedObjects == 2, "the frozen fixed-object set must stay at two")
        local fixedKind = 0
        for _, entity in ipairs(world.entities) do
            if entity.kind == "fixed" then fixedKind = fixedKind + 1 end
        end
        assert(fixedKind == 4, "kind==fixed count drifted: " .. fixedKind)
        -- 实体体积：blockingList 必须含全部六岛，且各恰好一次。
        local blockedVariants = {}
        for _, entity in ipairs(world.blockingList) do
            if entity.contentId and VARIANT_TEXTURE_NAMES[entity.contentId] then
                blockedVariants[entity.contentId] = (blockedVariants[entity.contentId] or 0) + 1
            end
        end
        for _, variant in ipairs(VARIANT_MIRROR) do
            assert(blockedVariants[variant.contentId] == 1,
                variant.contentId .. " must enter the blocking list exactly once, got "
                    .. tostring(blockedVariants[variant.contentId]))
        end
    end)

    check("variant_islands_draw_billboard_upright_first", function()
        -- 素材渲染接入（2026-10-18 真机二轮）：变体岛贴图走竖幅公告板投影
        -- （Upright，与 sign_* 岛饰同口径）——contentId 名、底沿坐岛心、
        -- 高度=clamp(r*0.55, 2.6, 6.0)；零 Plane 调用（防回退平铺）；立牌成功时
        -- 矢量丘/树/石/柱被抑制（fills 低于兜底路径）。
        local minHeight, maxHeight = 2.6, 6.0
        for _, variant in ipairs(VARIANT_MIRROR) do
            local entry = assert(fixedIsland(variant.contentId), variant.contentId .. " missing")
            recorder.reset()
            local textureCalls = withBillboardRecorder(true, function()
                local runtime = makeRuntime(vantageOf(entry))
                SeaViewArt.Island({}, runtime.movement, islandEntity(entry), 0, 0)
            end)
            local uprights, planes = {}, 0
            for _, call in ipairs(textureCalls) do
                if call.mode == "upright" then uprights[#uprights + 1] = call
                elseif call.mode == "plane" then planes = planes + 1 end
            end
            assert(#uprights == 1,
                variant.contentId .. " must draw exactly one upright billboard, got " .. #uprights)
            local billboard = uprights[1]
            assert(billboard.name == variant.contentId,
                variant.contentId .. " billboard must use its catalog name, got " .. billboard.name)
            assert(billboard.x == entry.position.x and billboard.y == entry.position.y,
                variant.contentId .. " billboard must anchor at the island center")
            local expectedHeight = math.max(minHeight,
                math.min(maxHeight, entry.radius * 0.55))
            assert(math.abs(billboard.height - expectedHeight) < 1e-9,
                variant.contentId .. " billboard height drift: " .. billboard.height
                    .. " != " .. expectedHeight)
            assert(planes == 0,
                variant.contentId .. " must never draw a flat texture plane, got " .. planes)
            recorder.reset()
            withBillboardRecorder(true, function()
                local runtime = makeRuntime(vantageOf(entry))
                SeaViewArt.Island({}, runtime.movement, islandEntity(entry), 0, 0)
            end)
            local textureFills = recorder.callCount("nvgFill")
            local vectorEntry = assert(fixedIsland(variant.contentId), variant.contentId .. " missing")
            recorder.reset()
            drawVariantIsland(vectorEntry)
            local vectorFills = recorder.callCount("nvgFill")
            -- 抑制量下界：立牌路径比兜底至少少 hills+trees+rocks+pillar 个 fill
            -- （每树/丘实际产主体+高光多个 fill，只做下界；reefcluster 无植被则 0）。
            local suppressedExpected = variant.hills + variant.trees + variant.rocks + variant.pillar
            assert(vectorFills - textureFills >= suppressedExpected,
                variant.contentId .. " billboard must suppress its vector decor: delta "
                    .. (vectorFills - textureFills) .. " < " .. suppressedExpected)
        end
    end)

    check("variant_islands_fallback_to_vector_on_load_failure", function()
        -- 立牌加载失败回退变体矢量轮廓（与映射岛的「贴图优先/矢量兜底」同构；
        -- 桩环境无图即此路径）。Upright 以 contentId 尝试恰一次，且零 Plane 调用
        -- （不回退 island.png，也不回退平铺）。
        for _, variant in ipairs(VARIANT_MIRROR) do
            local entry = assert(fixedIsland(variant.contentId), variant.contentId .. " missing")
            recorder.reset()
            local calls = drawVariantIsland(entry)
            assert(countCalls(calls, variant.contentId) == 1,
                variant.contentId .. " fallback must attempt its upright billboard once, got "
                    .. countCalls(calls, variant.contentId))
            for _, call in ipairs(calls) do
                assert(call.mode ~= "plane",
                    variant.contentId .. " fallback must not draw any flat plane, got "
                        .. tostring(call.name))
            end
            assert(recorder.callCount("nvgFill") > 0,
                variant.contentId .. " vector fallback added no fills")
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

    check("variant_vector_shore_is_not_painted_under_covering_billboard", function()
        -- 2026-10-19 真机二轮红框（沙洲/岩岛背后大块土黄矩形）：矢量岸块
        -- （SAND_SHORE 外框 + SAGE_LAND 内芯）先填色，覆盖立牌随后绘制——贴图
        -- 内容主体的透明留边压不住下层色块，真机呈现「岛心一小团贴图 + 四周大块
        -- 土黄/橄榄矩形」。修法：填色延后到立牌判定之后，覆盖成功即抑制。
        -- 桩环境无图会走 Upright 返回 false 的回退路径，故此处显式注入一个
        -- 「覆盖成功」的假 UprightCover，验证该分支下矢量岸块零填色。
        for _, variant in ipairs(VARIANT_MIRROR) do
            local entry = assert(fixedIsland(variant.contentId), variant.contentId .. " missing")
            local runtime = makeRuntime(vantageOf(entry))
            local original = ImageArt.UprightCover
            local coverCalls, coverError = 0, nil
            ImageArt.UprightCover = function(_, name, cover)
                coverCalls = coverCalls + 1
                local ok, err = pcall(function()
                    assert(name == variant.contentId,
                        "cover billboard must use the island content id, got " .. tostring(name))
                    assert(cover and cover.minX < cover.maxX and cover.minY < cover.maxY,
                        "cover billboard needs a valid projected bounds rectangle")
                end)
                if not ok then coverError = err end
                return true -- 模拟覆盖成功
            end
            recorder.reset()
            SeaViewArt.Island({}, runtime.movement, islandEntity(entry), 0, 0)
            ImageArt.UprightCover = original
            assert(not coverError, tostring(coverError))
            assert(coverCalls == 1,
                variant.contentId .. " must attempt the covering billboard exactly once, got "
                    .. coverCalls)
            assert(recorder.callCount("nvgFill") == 0,
                variant.contentId .. " painted vector shore under a covering billboard: "
                    .. recorder.callCount("nvgFill") .. " fills (expected 0)")
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
