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
    -- 2026-10-20：14,6 距港口 15.2m，r2 + 8m 安全裕度 = 11.8m，正好压在回港走廊上，
    -- 是所有“直线回港”被 no_viable_detour 拒绝的主因（船一从港口方向驶回就撞上它的
    -- 裕度圈）。
    -- 新位置 34,10（距港 35.4m，东北向）：仍在出港第一屏可见（木桶剪影不被地平线
    -- 切线剔掉，Circle1A2BarrelRenderTests 的 barrel+distance 出发点也全部落在
    -- 可航行海域），不再骑在港口正前航道，也不再与 island_01 的裕度圈叠加。
    fixedBarrel = { position = { x = 34, y = 10 }, radius = 2,
        tuningStatus = "V28_DISCOVERABILITY_GEOMETRY" },
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
    -- 2026-10-20（V2.8 截止前可发现性 + 自动返航修复）：旧坐标把六座**实体阻挡**岛全部
    -- 挤在港口 70m 内（55,-20 / 70,10 / 5,55 / -15,40 / -30,-15 / 20,-30）。后果有两个：
    --  ① 出港第一眼全是岛，后面 V2.7/V2.8 的海上内容全被遮在背后，玩家反馈“东西好像
    --     都没放到海上”；
    --  ② 岛与岛之间的间隙普遍小于自动返航的 8m 安全裕度之和，船在岛边起航时起点
    --     已经落在邻岛的裕度圈里，自动返航直接 no_viable_detour（真实玩家可复现）。
    -- 新坐标按“近港留空 → 东/东南/西北/北分向”拉开：近港 30m 内只留木桶，
    -- 六岛分居 4 个象限的 60~135m 环，彼此与岛_01/02/木桶间距 ≥ r_i+r_j+4m。
    --
    -- 2026-10-20 真人试玩修复（HUMAN-PLAYTEST-RCA-FIX-01）：这六座是**实体阻挡的岛**，
    -- 玩家能看见、会撞上，但旧实现里它们没有任何交互资格 —— “明明是岛却什么都
    -- 不能做”。现在每座带一句 0 体力/即时/可重复/不掉落/不存档的环境观察文本
    -- （复用现有 observe 能力，只走 V28ContentActions，不写完成态）。
    -- 仍然：无 rewardId / 无 actionKind / 无 memory / 原地可重复。
    -- 两座正式岛 island_01 / island_02 的【探索岛屿】与奖励规则完全不变。
    fixedIslands = {
        { entityType = "island", contentId = "island_peak_v1",
            position = { x = 115, y = 25 }, radius = 7, blocking = true,
            tuningStatus = "V28_DISCOVERABILITY_GEOMETRY",
            observe = {
                promptText = "观察岛屿",
                text = "一座顶着一道尖坡的小岛，坡上零星长着几棵树。浪打在东侧的岩根上，碎成白沫。",
            } },
        { entityType = "island", contentId = "island_reefcluster_v1",
            position = { x = 112, y = -62 }, radius = 9, blocking = true,
            tuningStatus = "V28_DISCOVERABILITY_GEOMETRY",
            observe = {
                promptText = "观察岛屿",
                text = "几块低矮的礁洲各自破水而出，中间隔着浅浅的水道，礁面上覆着薄薄一层青苔。",
            } },
        { entityType = "island", contentId = "island_cliff_v1",
            position = { x = -70, y = -55 }, radius = 9, blocking = true,
            tuningStatus = "V28_DISCOVERABILITY_GEOMETRY",
            observe = {
                promptText = "观察岛屿",
                text = "一道陡直的崖壁立在水上，崖脚堆着崩落的碎石，没有可以靠船的地方。",
            } },
        { entityType = "island", contentId = "island_stele_v1",
            position = { x = 55, y = -135 }, radius = 4, blocking = true,
            tuningStatus = "V28_DISCOVERABILITY_GEOMETRY",
            observe = {
                promptText = "观察岛屿",
                text = "一块矮岛上立着一根被风和盐磨圆了的石柱，柱脚散着几块同色的碎石。",
            } },
        { entityType = "island", contentId = "island_twinhills_v1",
            position = { x = 20, y = 125 }, radius = 10, blocking = true,
            tuningStatus = "V28_DISCOVERABILITY_GEOMETRY",
            observe = {
                promptText = "观察岛屿",
                text = "两个差不多高的丘并排立着，两丘之间凹下去一道浅浅的缝，风从缝里穿过去。",
            } },
        { entityType = "island", contentId = "island_sandbar_v1",
            position = { x = -55, y = 130 }, radius = 10, blocking = true,
            tuningStatus = "V28_DISCOVERABILITY_GEOMETRY",
            observe = {
                promptText = "观察岛屿",
                text = "一片平缓的沙洲，林线沿着岸势铺开，近水的沙面被潮水冲出一道道细纹。",
            } },
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
    -- 2026-10-19 真机二轮：白波纹「太淡不明显 + 密度过大」→ alpha 0.6→0.9、
    -- tileScale 1.0→1.6（瓦片放大，同屏波纹数量降到约 1/2.6，笔画也随之更粗）。
    -- 2026-10-20 用户裁定：波纹改回程序 crest marks（enabled=false，绘制成功即
    -- 跳过 crests 的门控天然失效），贴图样式改由程序层参考实现（见 visual.crest）。
    -- 本层资产与代码路径完整保留：enabled=true 即一键回切旧口径，不删不弃。
    seaRipple = { enabled = false, alpha = 0.9, tileScale = 1.6, scrollScale = 1.0 },
    -- 近景海面动态效果（2026-10-20，焦散 + DuDv）：纯表现层，不影响世界/玩法。
    -- 背景与限定：海面底图（seaSurface）与波纹（seaRipple）都是屏幕空间材质层，
    -- 船一动就与世界实体速率脱节；本层改用世界米制投影，随船移动但钉在世界平面。
    --
    -- 实现路线（AB，无 GPU Shader）：NanoVG 图片分片贴图 + 逐顶点 UV 位移。
    --   · 焦散贴图 water_caustic_light（512²，RGBA，双向无缝）由
    --     tests/prepare_ocean_water_fx_art.py 程序化生成水彩亮丝网；
    --   · 区域以相机（Movement 里跟随船，带 followSec 平滑）为中心的 sizeMeters 方形，
    --     按 cellMeters 切网格，每片两个三角形做仿射贴图（与 ImageArt.triangle 同口径）；
    --   · 边缘径向渐隐 feather + 哈希抗抖，无矩形边界；
    --   · DuDv（water_dudv_flow，R/G 中性 0.5）在 CPU 解码成位移网格，
    --     逐顶点偏移焦散 UV —— 这是 NanoVG 下真正生效的「采样偏移」，不是叠图。
    --
    -- 成本：每片 2 次 nvgFill（默认 6×6=36 片 → 72 fill/帧），单层、无 RenderTarget、
    -- 无全屏 Shader；片数有 MAX_TILES_PER_SIDE=12 硬上限，亚像素片剔除。
    -- 关闭方式：enabled=false（或只关 DuDv：dudvEnabled=false）。
    -- 另有 SeaDebug 面板的 NearWater 按钮可运行时对比开关。
    nearWaterFX = {
        enabled = true,
        -- 贴图层
        causticName = "water_caustic_light",
        causticAltName = "water_caustic_light_alt",
        secondLayer = false,        -- 双层焦散（不同方向/速度），默认单层
        secondLayerAlpha = 0.6,
        alpha = 0.16,               -- 焦散不透明度（需求建议区间 0.06~0.20）
        -- 区域与网格（世界米制）；数值按 960×540 离线预览调到「盖住近水、
        -- 边缘在屏幕内完全淡完、不伸到天空」，真机可再微调。
        sizeMeters = 84,            -- 区域边长（视野高 45m 的近水面约占下半屏）
        cellMeters = 12,            -- 单格边长（84/12=7×7=49 片；地形畸变需细分）
        feather = 0.52,             -- 径向渐隐起点（越早开始越柔，但中心也被淡化）
        edgeJitter = 0.45,          -- 边缘按片哈希降权，打散同心色阶
        edgeJitterSeed = 0.17,
        -- 纹理滚动（归一化纹理单位/秒；与船位置完全解耦，船动不重置）
        tileMeters = 22,            -- 一个瓦片覆盖的世界米数（越小网越密）
        scrollX = 0.012,
        scrollY = 0.008,
        -- DuDv 置换
        dudvEnabled = true,
        dudvName = "water_dudv_flow",
        dudvStrength = 0.008,       -- UV 偏移强度（建议 0.003~0.015）
        dudvTileMeters = 26,
        dudvScrollX = 0.017,
        dudvScrollY = -0.011,
        dudvResolution = 16,        -- 解码网格分辨率（顶点/边），只解码一次
        -- 昼夜（复用现有 clock，不新增时钟）：夜间压到 nightScale
        dayScale = 1.0,
        nightScale = 0.28,
    },
    -- 程序 crest marks 贴图样式（2026-10-20 用户裁定「参考贴图样式」）。以
    -- sea_ripple_overlay 水彩波纹贴图的笔触特征为参照目标：白沫色、细短弧线、
    -- 缓 S 形、两端渐细、疏朗分布。全部为表现层参数，不触碰世界/玩法。
    --   skipRatio      世界格密度呼吸：按格哈希跳过该比例（贴图式疏朗，也省 draw）
    --   lengthJitter   长短笔触变化幅度（0=等长机械，1=长短错落如贴图）
    --   skewMax        手绘感非对称弯度上限（贝塞尔控制点偏移）
    --   taperAt/taperTip  尾端渐细：在 t 处拆分三次贝塞尔，后段线宽×taperTip
    --   haloWidth/haloAlpha  水彩晕染柔边：整条再描一遍更宽更淡的同色笔画
    --   companionChance/companionScale  伴生短笔触（贴图里主弧旁的卫星小笔）
    --   color          白沫主色（贴图取色）；altColor 冷调变体（笔触色相抖动，
    --                  配了才分桶；近景笔画仅 1~1.7px，冷暖差肉眼几乎不可辨却
    --                  使 stroke 批次翻倍，故默认不配，留作可选旋钮）
    --   alpha 为 color[4]，沿用 visual.wave 同口径（×layerWeight×0.66）。
    crest = { skipRatio = 0.3, lengthJitter = 0.9, skewMax = 0.3,
        taperAt = 0.6, taperTip = 0.62,
        haloWidth = 1.85, haloAlpha = 0.38,
        companionChance = 0.45, companionScale = 0.55,
        color = { 244, 250, 242, 150 } },
    -- 天空图图层（2026-10-18 读海美术接入）：屏幕空间满幅天空贴图，绘于背景渐变
    -- 之上、日月云鸟之下（方案 B：不依赖 scissor，零回归）。昼夜相位复用 seaSurface
    -- 的 duskFrom/duskSpan/nightFade 映射（SkyFrame 委托 SeaSurfaceFrame，仅改写键名
    -- 为 sky_day/sky_dusk）；夜间沿用昼天图过夜罩（方案 A 夜罩不动）。preload=false
    -- （画面贴图懒加载，首个 Backdrop 帧按需加载一次，句柄缓存）；scroll 默认开启、
    -- scrollScale 提供视差（天空无天区世界实体，横移仅微移纹理，与用户"随镜头横滚"一致）。
    skyLayer = { enabled = true, alpha = 1.0, scroll = true, scrollScale = 0.35 },
    -- 日月云贴图层（2026-10-19 读海美术接入）：屏幕空间装饰精灵（ImageArt.ScreenSprite），
    -- 替换矢量日/月/云（day=sky_sun+sky_cloud_light、night=sky_moon+sky_cloud_dark、
    -- day 末段按 seaSurface 同源 blend 交叉淡入夜云）。贴图优先、加载失败回退矢量
    -- （零回归）；preload=false 懒加载；enabled=false 整层回退矢量旧观感。
    skyDecor = { enabled = true, alpha = 1.0 },
    -- 探海镜水体光学层（2026-10-19 用户红框反馈「透镜 90° 扇形内水下鱼与海面渲染
    -- 融为一体、肉眼无法区分」，裁决 A 全套 + 远端 0.55）。病根双重：生态鱼贴图
    -- （蓝绿水彩）与海面贴图（青绿水彩）同色相同明度同笔触；且 SeaDraw 层级中鱼
    -- （ImageArt.Plane altitude=0）与海面同平面相贴，中间没有水体介质。本组把扇区
    -- 从「一层 alpha=24 淡青描边」升级为「一块有光学性质的水」：
    --   ① 水深渐变：以船→扇区远端为渐变轴，近端浅青、远端深蓝青且压明度——鱼从
    --      海面波纹里「沉」出来；渐变随船转向，无需额外状态；
    --   ② 鱼体三件套：接触阴影（把鱼压进水体的接触感）+ 背光高光（水面透光的
    --      湿感）+ 距离衰减（远处鱼化开水色、强化纵深）；
    --   ③ 透镜边缘：亮青白 rim + 外圈柔光 glow + 双光柱 shaft（神器感与玻璃感）；
    --   ④ 远景兜底：鱼屏幕长度 < silhouetteMinPx 切暗色剪影（复用 WorldRise 语言）。
    -- 纯渲染层：零新素材、零包体增长、零行为/零世界状态变化；enabled=false 一鍵回退。
    scopeLens = {
        enabled = true,
        nearColor = { 150, 225, 215 }, farColor = { 18, 84, 104 },
        nearAlpha = 0.30, farAlpha = 0.55,
        rimColor = { 235, 252, 246 }, rimAlpha = 190, rimWidth = 1.4,
        glowColor = { 200, 240, 235 }, glowAlpha = 60, glowWidth = 4.0,
        shaftColor = { 235, 250, 245 }, shaftAlpha = 24,
        shadowColor = { 10, 50, 66 }, shadowAlpha = 70,
        glintColor = { 255, 250, 225 }, glintAlpha = 150,
        fadeFarAlpha = 0.82, fadeStartRatio = 0.35,
        silhouetteMinPx = 14,
    },
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
    -- V2.8 首版试玩参数（集中存放，实机可单独调参而不改规则）：
    -- 海眼 60m 吸小鱼 / 90m 吸大鱼、持续 20 秒；巨骨分区 4小+2大；
    -- 探海镜连续观察 1 秒；固定内容交互 ≤5m；打捞 40 体力 / 4 秒。
    v28 = {
        tuningStatus = "V28_PLAYTEST_PARAMETERS",
        interactDistance = 5,
        lensMarkDurationSec = 1,
        salvageDurationSec = 4,
        salvageStaminaCost = 40,
        vortex = {
            smallFishAttractRadius = 60,
            bigFishAttractRadius = 90,
            attractDurationSec = 20,
            dropRadius = 5,
            noNetRadius = 3,
            observeRadius = 5,
            pearlItemId = "abyss_pearl",
        },
        -- 巨骨所在 120×120m 中海分区：默认 5小1大 → 4小2大（总数仍 6）。
        leviathan = {
            contentId = "leviathan_bones_01",
            regionSize = 120,
            sardineCount = 4,
            tunaCount = 2,
            bigFishRingMin = 15,
            bigFishRingMax = 45,
        },
    },
    seaTitle = "渔夫漂流记 · Sea Runtime V1",
}
-- Compatibility speed alias; all level speeds and the map derive from this one table.
Config.ship.speed = Config.ship.speedByLevel[Config.ship.defaultLevel]
Config.ship.maxSpeed = math.max(table.unpack(Config.ship.speedByLevel))
Config.world.mapSize = Config.ship.maxSpeed * Config.world.travelSec
Config.world.halfSize = Config.world.mapSize / 2
return Config
