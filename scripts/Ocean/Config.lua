-- Legacy illustration config plus centralized Sea Runtime values.
-- World lengths are meters. Camera full height is stable; width derives from aspect.
local FishRows = require("GeneratedData.Fish")
local Content = require("data.content")
local activityRange = FishRows[1].ai
local fixedObjects, fixedTreasure = {}, nil
for _, definition in ipairs(Content.fixed) do
    if definition.entityType == "island" then
        fixedObjects[#fixedObjects + 1] = definition
    elseif definition.entityType == "treasure" then
        assert(fixedTreasure == nil, "only the existing fixed treasure is production content")
        fixedTreasure = definition
    end
end
assert(#fixedObjects == 2 and fixedTreasure
    and fixedTreasure.contentId == "underwater_treasure_01", "fixed content contract is incomplete")
-- The existing world has one shared activity range, not per-species thresholds.
for _, row in ipairs(FishRows) do
    assert(row.ai.fullRange == activityRange.fullRange and row.ai.freezeRange == activityRange.freezeRange,
        "fish AI ranges must match the shared world activity range")
end
---@type number[]
-- 真机反馈（2026-10-05）：6/8/10 m/s 体感过慢，整体上调 50%~60%；
-- 地图尺寸随 maxSpeed 自动推导（16×180=2880m），边界/时序测试均按配置表取值。
local shipSpeeds = { 9.0, 12.0, 16.0 }
local Config = {
    units = { length = "meter", metersPerWorldUnit = 1, speed = "meter_per_second" },
    title = "海风小岛",
    layers = {
        birds = 0.21,
        waves = 0.32,
        fish = 0.44,
        boat = 0.61,
        island = 0.83,
    },
    boat = {
        initialX = 0.5,
        minX = 0.18,
        maxX = 0.82,
        speed = 0.24,
        buttonStep = 0.12,
    },
    birds = {
        { x = 0.39, phase = 0, scale = 1 },
        { x = 0.62, phase = 1.8, scale = 0.82 },
    },
    fish = {
        { x = 0.38, phase = 0, direction = 1, color = { 255, 165, 112, 255 } },
        { x = 0.65, phase = 2.4, direction = -1, color = { 176, 238, 218, 255 } },
    },
    -- Legacy fields remain compatible with the unmodified HUD/Draw.
    ship = { tuningStatus = "V1_IMPLEMENTATION_VALUE", defaultLevel = 1,
    speedByLevel = shipSpeeds, speed = 0, maxSpeed = 0, turnDegPerSec = 180, arrivalRadius = 1.5,
    radius = 1.8, start = { x = 0, y = 0 } },
    world = { tuningStatus = "V1_IMPLEMENTATION_VALUE", travelSec = 180, visualPadding = 100, pushSpeed = 3, pushSec = 0.3,
    temporaryLifetimeSec = 20, activateRadius = activityRange.fullRange, freezeRadius = activityRange.freezeRange,
    maxStepSec = 0.05, maxFrameSec = 0.25, spawnAttempts = 1000, seed = 271828, spawnInset = 8,
    mapSize = 0, halfSize = 0, overlapRadius = 3, epsilon = 0.000001, regionSize = 120,
    fixedObjects = fixedObjects, -- 兼容视图；正式来源为 data.content。
    fixedTreasure = fixedTreasure, -- 兼容视图；正式来源为 data.content。
    -- 非阻挡漂浮物，靠近 ≤ operateDistance(5m) 可检查（World:Init 注册）。
    -- 真机反馈（2026-10-05）：原演示漂浮物 float(10,0) 无任何玩法功能，
    -- 在返航点旁渲染为无意义圆形色块，已删除。
    fixedBarrel = { position = { x = 14, y = 6 }, radius = 2,
        tuningStatus = "TUTORIAL_PROVISIONAL_GEOMETRY" },
    -- C2（2026-10-17）：主场景组件世界放置（assets/image/OceanComponents，oblique 海面组件）。
    -- 与 fixedObjects（冻结的双岛集）/fixedTreasure 并列的独立清单：World:Init 以
    -- kind="scenery" 注册的非阻挡装饰实体，不影响航行/捕鱼/交互，仅 SeaDraw 贴图渲染。
    -- 真机反馈（2026-10-18）：礁石/海岸 oblique 组件原按独立世界放置平铺在开阔海面，
    -- 呈漂浮贴图块（白边、与世界实体速率脱节——「岛的素材接入进海面了」）。用户裁决：
    -- 两张 oblique 组件改作既有岛屿底图（island_01←海岸 / island_02←礁石，见
    -- SeaViewArt ISLAND_BASE_TEXTURES），不再独立投放。放置机制保留：清单为空即零
    -- 投放，后续方案/SeaDebug 回填条目即可复用（坐标须满足 isPositionFree）。
    fixedComponents = {},
    -- C2（2026-10-17）：海底沉船残骸（固定水下内容，与 fixedTreasure 同构：
    -- layer="underwater"、非阻挡、望远镜 scope 楔形内可见时 SeaDraw 绘制顶视 sprite）。
    -- 位于第一座岛南侧可航水域，距固定宝藏 (35,45) 15m，构成「宝藏海域」叙事。
    fixedWrecks = {
        { entityType = "wreck", contentId = "shipwreck_v1",
            position = { x = 35, y = 60 }, radius = 3, blocking = false,
            tuningStatus = "C2_PLAYTEST_GEOMETRY" },
    },
    -- 2026-10-18：6 座新岛屿矢量变体（assets/image/OceanIslands，用户指令
    -- 「在世界生成这几张图的矢量图，参考复用现有实体岛屿，矢量绘画根据图中
    -- 尺寸比例绘制」）。与 fixedComponents 同构的独立清单：World:Init 以
    -- kind="scenery" 注册（entityType="island" 复用既有岛屿绘制入口
    -- SeaViewArt.Island，contentId 命中 ISLAND_VARIANTS；渲染=贴图优先走
    -- Plane（contentId 即 catalog 条目名）、加载失败回退变体矢量轮廓）。
    -- 2026-10-18 晚（用户「做实体体积和对应岛屿素材渲染接入」）：blocking=true
    -- 进 blockingList（船不可穿越，island_01/02 同构实体体积；A2 冻结契约数
    -- kind=="fixed" 不受影响）；贴图从备用转正为岛体底图。半径=贴图实体外接
    -- 半径×12/512（island_01 口径）取整；坐标满足 isPositionFree（避 island_01
    -- r12 / island_02 r20 / barrel r2 碰撞圈，彼此视觉间距 ≥ r_i+r_j+4）。
    -- 放置参数待真机观感调校。
    fixedIslands = {
        { entityType = "island", contentId = "island_peak_v1",
            position = { x = 70, y = 10 }, radius = 7, blocking = true,
            tuningStatus = "ISLAND_VARIANT_PLAYTEST_GEOMETRY" },
        { entityType = "island", contentId = "island_reefcluster_v1",
            position = { x = 55, y = -20 }, radius = 9, blocking = true,
            tuningStatus = "ISLAND_VARIANT_PLAYTEST_GEOMETRY" },
        { entityType = "island", contentId = "island_cliff_v1",
            position = { x = -30, y = -15 }, radius = 9, blocking = true,
            tuningStatus = "ISLAND_VARIANT_PLAYTEST_GEOMETRY" },
        { entityType = "island", contentId = "island_stele_v1",
            position = { x = 20, y = -30 }, radius = 4, blocking = true,
            tuningStatus = "ISLAND_VARIANT_PLAYTEST_GEOMETRY" },
        { entityType = "island", contentId = "island_twinhills_v1",
            position = { x = 5, y = 55 }, radius = 10, blocking = true,
            tuningStatus = "ISLAND_VARIANT_PLAYTEST_GEOMETRY" },
        { entityType = "island", contentId = "island_sandbar_v1",
            position = { x = -15, y = 40 }, radius = 10, blocking = true,
            tuningStatus = "ISLAND_VARIANT_PLAYTEST_GEOMETRY" },
    },
},
    camera = { tuningStatus = "SEA_VIEW_VISUAL_TEST_VALUE",
    minX = 0.35, maxX = 0.65, minY = 0.45, maxY = 0.75,
    -- min/max retained for legacy callers; continuous follow no longer uses a dead zone.
    anchorX = 0.5, anchorY = 0.72, followSec = 0.15, viewHeight = 45,
    horizonY = 0.24, depthCompression = 0.65, farDepth = 110 },
    fishing = { tuningStatus = "V1_IMPLEMENTATION_VALUE", maxCastDistance = 30,
        netRadius = 8, durationSec = 4, maxCatchCount = 1 },
    -- Circle 1 confirmed playtest value; not a new planning/data-schema field.
    predation = { cooldownSeconds = 5, tuningStatus = "USER_APPROVED_TEST_VALUE" },
    interaction = { tuningStatus = "V1_IMPLEMENTATION_VALUE", operateDistance = 5,
        portDistance = 10, maxThrowDistance = 12, outlineDistance = 80,
        recognitionDistance = 20, revealRadius = 20 },
    debug = { enabled = true, showUnderwater = false, showStates = false, showPerception = false,
    showActivity = false, showBounds = false, spawnOffset = 12, baitOffset = 8,
    refreshSec = 0.25 },
    visual = { waveSpacing = 12, waveLength = 3, waveSpeed = 0.6,
    -- Presentation-only temporary values; no world interaction/AI distances change.
    surface = { spacingMeters = 12, lengthMeters = 3, driftSpeed = 0.6,
        amplitudeMeters = 0.18, periodSec = 5, maxMarks = 1800,
        nearSpacingMeters = 12, farSpacingMeters = 6,
        detailTransitionStartMeters = 35, detailTransitionEndMeters = 110 },
    -- 纯海面贴图层（2026-10-17 C2，方案 A 夜罩不动）：屏幕空间材质层，
    -- 参数仅影响表现，不触碰世界/玩法。duskFrom/duskSpan 控制昼相末段向
    -- 黄昏图交叉淡入；nightFade 控制入夜前 10% 淡回昼图（夜罩瞬间叠加
    -- 不跳变）；scroll 关闭后贴图静止（仅 gradient/纸纹兜底时等同旧观感）。
    -- 纯海面 v2 贴图层（C2，方案 A 夜罩不动）。scroll=false（2026-10-18 真机
    -- 验收裁定）：底图固定不跟随船移动——海面为屏幕空间材质层，横移视差会让
    -- 世界实体（岛/桶/波纹）与贴图速率脱节；保留开关供 SeaDebug/后续方案回退。
    seaSurface = { enabled = true, alpha = 1.0, duskFrom = 0.8, duskSpan = 0.2,
        nightFade = 0.1, scroll = false, scrollScale = 1.0 },
    -- 波纹平铺层（2026-10-18 C4，用户提供水彩波纹纹理 sea_ripple_overlay）：
    -- 屏幕空间双向平铺（imagePattern REPEATX|REPEATY），叠加于海面底图之上，
    -- 替换程序 crest marks（贴图优先、加载失败回退 crests，零回归）。
    -- alpha 为叠加不透明度；tileScale 为瓦片缩放（1=资产原生 512×288，调大=波纹更稀）。
    -- 2026-10-18 晚修复：素材原为 RGB 无 alpha（白底不透明平铺→海面发白雾、
    -- 波纹不可见），已去白底提取浪花白沫 alpha 通道（RGBA，.tmp/ripple_alpha_fix.py，
    -- 接缝保持 0.0）；素材自持透明度后 0.28 压雾保守值上调 0.5 恢复波纹可见度。
    -- 2026-10-19 真机二次修复：源图白底白波纹笔画色距极浅（raw max 78、p99=19），
    -- 旧线性 GAIN=3.2 提取后 93.7% 像素 alpha=0 → 贴图不可见且 crests 被跳过
    -- （两者同时消失的根因）。重提取改伽马 0.55 按源图动态范围归一
    -- （.tmp/ripple_alpha_boost.py，笔画核心 alpha>160、接缝保持 0.0），alpha 0.5→0.6。
    -- 随船移动：scrollScale=1 按近水速率随相机横移（与 SeaSurface scroll 同口径，
    -- 1 世界米 = height/viewHeight 屏距）；0=钉死屏幕。
    seaRipple = { enabled = true, alpha = 0.6, tileScale = 1.0, scrollScale = 1.0 },
    -- 天空图图层（2026-10-18 读海美术接入）：屏幕空间满幅天空贴图，绘于背景渐变
    -- 之上、日月云鸟之下（方案 B：不依赖 scissor，零回归）。昼夜相位复用 seaSurface
    -- 的 duskFrom/duskSpan/nightFade 映射（SkyFrame 委托 SeaSurfaceFrame，仅改写键名
    -- 为 sky_day/sky_dusk）；夜间沿用昼天图过夜罩（方案 A 夜罩不动）。preload=false
    -- （画面贴图懒加载，首个 Backdrop 帧按需加载一次，句柄缓存）；scroll 默认开启、
    -- scrollScale 提供视差（天空无天区世界实体，横移仅微移纹理，与用户"随镜头横滚"一致）。
    skyLayer = { enabled = true, alpha = 1.0, scroll = true, scrollScale = 0.35 },
    wake = { lifetimeSec = 3, spacingMeters = 0.6, minSpeed = 0.15, maxSamples = 96,
        initialWidth = 0.65, spreadPerSec = 0.45, sternOffset = 2.5, opacity = 125 },
    projection = { circleSegments = 48, sectorSegments = 32, birdAltitude = 1.2 },
    boatMotion = { enabled = true, heaveMeters = 0.35, maxRollDegrees = 7,
        turnRateForMaxRoll = math.pi, turnSmoothSec = 0.22 },
    curvature = { heightRatio = 0.045 },
    horizonOcclusion = { tangentSpan = 0.1 },
    aerialPerspective = { enabled = true, startDepthMeters = 18,
        endDepthMeters = 125, maxOpacityLoss = 0.48 },
    atmosphere = { cloudShadowCount = 10, cloudShadowOpacity = 40,
        cloudShadowDriftMps = 0.55, cloudShadowRadiusMeters = 24,
        fogCount = 10, fogOpacity = 46, fogDriftMps = 0.30,
        fogRadiusMeters = 22, fogNearOpacityScale = 0.12 },
    -- shoreFoam 键已移除（2026-10-18 真机反馈岛外围白色泡沫观感不佳，全体岛屿
    -- 移除泡沫渲染；SurfaceEffects.ShoreFoamArc 数学函数保留供契约直测）。
    -- Remote STEP-5 visual, confirmed by the planning workbook's night-visual rule.
    nightOverlay = { 10, 22, 48, 190 },
    background = { 15, 91, 125, 255 }, wave = { 109, 207, 216, 145 },
    island = { 135, 171, 110, 255 }, shore = { 209, 193, 137, 255 },
    ship = { 251, 222, 139, 255 }, float = { 184, 130, 90, 255 },
    effect = { 255, 192, 97, 255 }, bound = { 145, 231, 255, 180 },
    target = { 243, 247, 208, 160 }, shipLength = 5, shipWidth = 2.4 },
    tuningStatus = "V1_PROVISIONAL_TUNING",
    -- User-approved playtest values; this table does not amend planning documents.
    surfaceSignals = {
        enabled = true, riseSeconds = 2, riseTuningStatus = "USER_APPROVED_TEST_VALUE",
        birdOffset = 9, birdRadius = 3, birdsPerGroup = 1, birdPollSeconds = 0.25,
        birdDiveSeconds = 1.5, birdAngularSpeed = 1.8, birdAnimationStatus = "VISUAL_TEST_VALUE",
        splashInterval = 1, chaseSplashInterval = 0.5, splashLifetime = 0.6, trailLength = 2,
    },
    seaTitle = "渔夫漂流记 · Sea Runtime V1",
}
-- Compatibility speed alias; all level speeds and the map derive from this one table.
Config.ship.speed = Config.ship.speedByLevel[Config.ship.defaultLevel]
Config.ship.maxSpeed = math.max(table.unpack(Config.ship.speedByLevel))
Config.world.mapSize = Config.ship.maxSpeed * Config.world.travelSec
Config.world.halfSize = Config.world.mapSize / 2
return Config
