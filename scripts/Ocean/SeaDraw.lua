-- Read-only 2.5D sea presentation. All interaction ranges stay in world meters.
local Config = require("Ocean.Config")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.Draw")
local Art = require("Ocean.SeaViewArt")
local Geometry = require("Ocean.ProjectedGeometry")
local Presentation = require("Ocean.SeaPresentation")
local Atmosphere = require("Ocean.SeaAtmosphere")
local ImageArt = require("Ocean.ImageArt")
local Projection = require("Ocean.Projection")
local PerfProbe = require("Ocean.PerfProbe")
local SeaDraw = {}
local FIXED_BARREL_CONTENT_ID = "driftwood_barrel"
local PORT_MARK_RADIUS = 16
local BIRD_SPAN_METERS = Presentation.BIRD_SPAN_METERS

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function onScreen(x, y, margin, width, height, horizon)
    return finite(x) and finite(y) and x + margin >= 0 and x - margin <= width
        and y + margin >= horizon and y - margin <= height
end

local function color(value)
    return nvgRGBA(value[1], value[2], value[3], value[4] or 255)
end

local function isVisible(world, entity)
    if world and type(world.isVisible) == "function" then return world:isVisible(entity) end
    return entity.layer ~= "underwater"
end

-- C2（2026-10-17）生态层组件 v2（assets/image/OceanEco，锚点链派生自主场景昼夜套件）。
-- 鱼/海鸟/木桶贴图三帧循环优先，加载失败逐级回退旧图/矢量，绘制口径与既有 PNG 路径同构
-- （ImageArt.Plane 世界平面分片投影 + LOD + 懒加载）。帧选择只读 time/phase，不写任何状态。
-- 鱼/鸟贴图头朝 +X（入库时水平翻转）：heading 直传实体世界朝向即鼻朝游向。
local ECO_FRAME_COUNT, ECO_FRAME_FPS = 3, 6
local ECO_SPECIES_BASE = { sardine = "eco_fish_small", tuna = "eco_fish_big" }

local function ecoFrameName(base, time, phase)
    local index = math.floor(((time or 0) * ECO_FRAME_FPS + (phase or 0) * ECO_FRAME_COUNT))
        % ECO_FRAME_COUNT
    return base .. "_f" .. (index + 1)
end

-- 实体稳定相位偏移：同帧循环下不同鱼不同相，避免全体同步摆尾。
local function ecoEntityPhase(entity)
    if type(entity.phase) == "number" then return entity.phase end
    local id = type(entity.id) == "number" and entity.id or 0
    return (id * 0.37) % 1
end

local function entityHeading(entity)
    local heading = entity.rotation or 0
    local direction = entity.direction
    if type(direction) == "table" and type(direction.x) == "number" and type(direction.y) == "number"
        and (math.abs(direction.x) + math.abs(direction.y)) > 0.000001 then
        heading = math.atan(direction.y, direction.x)
    end
    return heading
end

-- 海鸥立牌的屏幕空间最小翼展（像素）。
-- 2026-10-19 真机二轮反馈：俯冲姿态下翼展缩到 0.68m，远处按透视折算后不足
-- ImageArt.UPRIGHT_MIN_PX=2 亚像素剔除线，立牌返回 false 回退 WorldSeabird
-- 矢量折线鸟。因此需要一个“技术不被剔除”的下限。
-- 2026-10-20 真人试玩 RCA（HUMAN-PLAYTEST-RCA-FIX-01）：这个 3px 只是**技术**
-- 下限（刚过剔除线），远低于**玩家可辨识**下限——真人反馈“鸟确实生成了，但屏幕
-- 上几乎看不见”。现在把两个概念分开：
--   · BIRD_MIN_SCREEN_SPAN_PX —— 玩家可辨识下限（首轮试玩值 10px），
--     决定立牌实际画多大；
--   · BIRD_RASTER_MIN_SPAN_PX —— 引擎亚像素剔除线，只用作“完全不可见”兜底。
-- 只改 presentation，不动鸟与小鱼对应关系、出现条件、鱼 AI、捕鱼范围。
local BIRD_MIN_SCREEN_SPAN_PX = 10
-- 引擎侧亚像素剔除线（ImageArt.UPRIGHT_MIN_PX=2）上方的最低安全值。
local BIRD_RASTER_MIN_SPAN_PX = 3
-- 俯冲末帧的可读性下限（2026-10-20 修复：俯冲结束像「鸟消失」）。
-- 旧口径把 diveProgress 线性乘进体量：dive=1 时翼展 1.8m→0.684m（38%）、
-- 悬停高度 1.2m→0（贴住水面）。鸟群此刻本应继续盘旋并被绘制，但「38% 体量 +
-- 零高度」在远处只剩几像素且与水面糊在一起，玩家读到的就是「鸟没了」。
-- 因此俯冲只表达姿态、不表达体量归零：折叠幅度与下压高度都设下限，
-- 满折叠仍保有 72% 翼展、45% 悬停高度，立牌/平铺/矢量三条绘制路径共用同一口径。
local BIRD_DIVE_FOLD_MAX = 0.45
local BIRD_DIVE_ALTITUDE_MIN_RATIO = 0.45

-- 俯冲进度 → 折叠幅度（0..BIRD_DIVE_FOLD_MAX）：满折叠不再继续压翼展。
local function birdDiveFold(dive)
    local value = finite(dive) and dive or 0
    return math.min(BIRD_DIVE_FOLD_MAX, math.max(0, value))
end
-- 立牌水平镜像死区（cos heading 的绝对值）：正前/正后飞时 cos≈0，若跟随符号翻转
-- 会每帧抖动，故 ±0.26 内一律不翻转（≈ ±15°），保留"明显朝左/朝右"的朝向可读性。
local BIRD_FLIP_DEADZONE = 0.26

-- 屏幕空间水平朝向：投影为固定偏航（无相机偏航旋转），世界 heading 的屏幕横向
-- 分量 ∝ cos(heading)。素材头朝 +X，故 cos<0（朝世界 -X）时需水平镜像才朝对方向。
local function birdFlipsScreen(heading)
    local cosine = math.cos(heading or 0)
    if math.abs(cosine) < BIRD_FLIP_DEADZONE then return false end
    return cosine < 0
end

-- Keep the existing vector silhouettes, projecting each meter-space path
-- through the same surface and height occlusion as islands and water.
local function groundFrame(ctx, movement, point, altitude, callback, extentMeters)
    if not movement:WorldToScreen(point, altitude) then return end
    callback(1, Geometry.ArtAPI(ctx, movement, point, altitude))
end

local function worldLine(ctx, movement, a, b, tint, width)
    Geometry.WorldLine(ctx, movement, a, b, tint, width)
end

local function drawFloat(ctx, movement, entity, outlineOnly, recognized, time)
    local point, radius = entity.position, entity.radius or 1
    -- 只缩小木桶的视觉尺寸，原radius/识别/交互/阻挡边界不变。
    local visualRadius = radius * 0.65
    ImageArt.ContactRipple(ctx, movement, point, time, visualRadius)
    -- 2026-10-18 真机验收：eco_barrel 为预烘焙斜视资产（且烘焙了水纹），平铺在
    -- 世界平面会被引擎斜投影二次压扁（「木桶显示被平铺」）→ 改竖幅公告板投影
    -- （Upright，与树/丘/岛饰同一投影口径）立起；内容主体世界高度=2×visualRadius
    -- （与旧平铺内容口径一致）。旧桶图 barrel 为正俯视（ART_PIPELINE 合规），
    -- 保持平铺（Plane）作二级回退；再失败走矢量剪影。
    local barrelContent = visualRadius * 2
    if not outlineOnly then
        -- C2：生态层木桶三帧（浮起/半浸/下沉）循环优先；Upright 立起。
        if ImageArt.Upright(ctx, ecoFrameName("eco_barrel", time, 0), movement, point,
            barrelContent) then return end
        local barrelCanvas = barrelContent / 0.88
        if ImageArt.Plane(ctx, "barrel", movement, point, barrelCanvas, barrelCanvas, 0, 0) then return end
    end
    Geometry.WorldCircle(ctx, movement, point, radius, outlineOnly and nil or Config.visual.float,
        { 225, 203, 156, 160 }, 1.5)
    if not recognized then return end
    Geometry.WorldCircle(ctx, movement, point, radius * 0.72, nil, { 225, 203, 156, 210 }, 1.3)
    local tint = { 225, 203, 156, 210 }
    for _, offset in ipairs({ -0.3, 0.3 }) do
        worldLine(ctx, movement, { x = point.x - radius * 0.55, y = point.y + radius * offset },
            { x = point.x + radius * 0.55, y = point.y + radius * offset }, tint, 1.1)
    end
    worldLine(ctx, movement, { x = point.x, y = point.y - radius * 0.65 },
        { x = point.x, y = point.y + radius * 0.65 }, tint, 1.1)
end

local function drawFixedBarrel(ctx, runtime, entity, snapshot, recognizedQuery)
    local world = runtime.world
    if entity ~= world.fixedBarrel or entity.entityType ~= "float" or entity.kind ~= "fixed"
        or entity.layer ~= "surface" or entity.contentId ~= FIXED_BARREL_CONTENT_ID
        or type(snapshot) ~= "table" or snapshot.id ~= entity.id
        or snapshot.contentId ~= FIXED_BARREL_CONTENT_ID or snapshot.generation ~= world.fixedBarrelGeneration
        or type(snapshot.position) ~= "table" or not finite(snapshot.position.x) or not finite(snapshot.position.y) then return end
    local point = runtime.ship.position
    local dx, dy = point.x - snapshot.position.x, point.y - snapshot.position.y
    local squared = dx * dx + dy * dy
    if squared > Config.interaction.outlineDistance ^ 2 then return end
    -- Keep persistent-recognition reads behind the same visible-world geometry
    -- filter as the barrel silhouette, including partially visible shore edges.
    if #Geometry.ClipPolygon(runtime.movement,
        Geometry.SampleCircle(snapshot.position, entity.radius or 1)) < 3 then return end
    local recognized = squared <= Config.interaction.recognitionDistance ^ 2
        or type(recognizedQuery) == "function" and recognizedQuery(snapshot.contentId) == true
    drawFloat(ctx, runtime.movement, entity, not recognized, recognized, runtime.time)
end

local function drawDroppedItem(ctx, movement, entity)
    local point, radius = entity.position, entity.radius or 0.7
    local tint = entity.worldEffect and entity.worldEffect ~= "NONE" and Config.visual.effect or Config.visual.float
    Geometry.WorldPolygon(ctx, movement, {
        { x = point.x, y = point.y + radius }, { x = point.x + radius, y = point.y },
        { x = point.x, y = point.y - radius }, { x = point.x - radius, y = point.y },
    }, tint, { 255, 238, 192, 210 }, 1)
    if entity.worldEffect == "ATTRACT_SMALL_FISH" then
        Geometry.WorldCircle(ctx, movement, point, FishData.sardine.attractRadius,
            nil, { 255, 204, 111, 48 }, 1)
    end
end

-- 距离衰减系数（探海镜水体，2026-10-19 用户锁定 A 全套）：近处 1.0 线性淡出到
-- 远端 settings.fadeFarAlpha，强化「越远越沉入水色」的纵深。纯函数，渲染与契约
-- 测试共用；缺省 settings / 非有限值一律返回 1（零衰减、零回归）。
function SeaDraw.ScopeLensFade(settings, distance, radius)
    if not settings or not finite(distance) or not finite(radius) or radius <= 0 then return 1 end
    local start = radius * (settings.fadeStartRatio or 0.35)
    local span = radius - start
    if span <= 0 or distance <= start then return 1 end
    local t = math.min(1, (distance - start) / span)
    return 1 - (1 - (settings.fadeFarAlpha or 1)) * t
end

-- 探海镜水体（2026-10-19 用户红框反馈「镜内水下鱼与海面融为一体、无法区分」，
-- 裁决 A 全套 + 远端 0.55）：把 90° 扇区从「一层 alpha=24 淡青描边」升级为
-- 「一块越往里越深的水」。渐变轴=船→扇区远端（世界坐标投影到屏幕），船转向时
-- 水体整体跟着转，无任何额外状态；鱼在实体循环内随后绘制，天然位于水体之上。
-- 顺序：水深渐变底 → 双光柱 → 外圈柔光 → 亮 rim（先宽后窄叠出 Fresnel 感）。
local function drawScopeWater(ctx, movement, scope)
    local settings = Config.visual.scopeLens
    if not settings or settings.enabled == false then
        -- 旧观感回退：一层淡青填充 + 亮青描边（2026-10-19 水体层之前的口径）
        Geometry.WorldSector(ctx, movement, scope.center, scope.radius, scope.heading, scope.halfAngle,
            { 172, 232, 224, 24 }, { 197, 243, 226, 130 }, 1.2)
        return
    end
    local shipX, shipY = movement:WorldToScreen(scope.center)
    local farPoint = { x = scope.center.x + math.cos(scope.heading) * scope.radius,
        y = scope.center.y + math.sin(scope.heading) * scope.radius }
    local farX, farY = movement:WorldToScreen(farPoint)
    if not shipX or not farX then return end
    -- ① 水深渐变底：近端浅青、远端深蓝青且压明度（0.55），鱼从海面波纹里沉出来
    local paint = nvgLinearGradient(ctx, shipX, shipY, farX, farY,
        nvgRGBA(settings.nearColor[1], settings.nearColor[2], settings.nearColor[3],
            math.floor(255 * settings.nearAlpha)),
        nvgRGBA(settings.farColor[1], settings.farColor[2], settings.farColor[3],
            math.floor(255 * settings.farAlpha)))
    Geometry.WorldSector(ctx, movement, scope.center, scope.radius, scope.heading, scope.halfAngle,
        nil, nil, nil, 0, paint)
    -- ③ 双光柱：自船身发散入水的微弱楔形（低 alpha，仅作水体体积光暗示）
    for _, sign in ipairs({ -1, 1 }) do
        local base = scope.heading + sign * scope.halfAngle * 0.55
        local spread = 0.05
        local function tip(angle)
            return movement:WorldToScreen({
                x = scope.center.x + math.cos(angle) * scope.radius * 0.98,
                y = scope.center.y + math.sin(angle) * scope.radius * 0.98 })
        end
        local ax, ay = tip(base - spread)
        local bx, by = tip(base + spread)
        if ax and bx then
            nvgBeginPath(ctx)
            nvgMoveTo(ctx, shipX, shipY)
            nvgLineTo(ctx, ax, ay)
            nvgLineTo(ctx, bx, by)
            nvgClosePath(ctx)
            nvgFillColor(ctx, nvgRGBA(settings.shaftColor[1], settings.shaftColor[2],
                settings.shaftColor[3], settings.shaftAlpha))
            nvgFill(ctx)
        end
    end
    -- ③ 外圈柔光 + 亮 rim
    Geometry.WorldSector(ctx, movement, scope.center, scope.radius, scope.heading, scope.halfAngle,
        nil, { settings.glowColor[1], settings.glowColor[2], settings.glowColor[3], settings.glowAlpha },
        settings.glowWidth)
    Geometry.WorldSector(ctx, movement, scope.center, scope.radius, scope.heading, scope.halfAngle,
        nil, { settings.rimColor[1], settings.rimColor[2], settings.rimColor[3], settings.rimAlpha },
        settings.rimWidth)
end

-- 背光高光：鱼体背脊两颗小高光点（世界坐标沿 heading 偏移，随曲面投影落位），
-- 贴图与矢量两路鱼体通用；尺寸随屏幕像素收敛，远处不过曝。
local function drawFishGlint(ctx, movement, entity, renderLength, fishPx, lens)
    local heading = entityHeading(entity)
    local cosine, sine = math.cos(heading), math.sin(heading)
    for _, offset in ipairs({ { 0.20, 0.10 }, { 0.00, 0.13 } }) do
        local along, side = offset[1] * renderLength, offset[2] * renderLength
        local gx, gy = movement:WorldToScreen({
            x = entity.position.x + cosine * along - sine * side,
            y = entity.position.y + sine * along + cosine * side })
        if gx then
            nvgBeginPath(ctx)
            nvgEllipse(ctx, gx, gy, math.max(0.6, fishPx * 0.06), math.max(0.5, fishPx * 0.05))
            nvgFillColor(ctx, nvgRGBA(lens.glintColor[1], lens.glintColor[2],
                lens.glintColor[3], lens.glintAlpha))
            nvgFill(ctx)
        end
    end
end

local function drawFish(ctx, movement, entity, showActivity, time, inLens, scopeRadius)
    if not FishData[entity.species] then return end
    if showActivity then
        local tint = entity.frozen and { 179, 190, 202, 180 }
            or entity.active and { 120, 232, 166, 210 } or { 202, 169, 122, 170 }
        Geometry.WorldCircle(ctx, movement, entity.position, entity.radius or FishData[entity.species].radius,
            nil, tint, 1.3)
    end
    local renderLength = FishData[entity.species].renderLength or 1
    -- 探海镜水体三件套 + 远景剪影兜底：仅「镜内可见鱼」挂载——inLens 且 scope 实际
    -- 开启（scopeRadius 非空即 GetScopeView 有值）；镜关闭/调试直显路径零变化，
    -- 保证 WorldFish 调用计数等旧契约不回退（Circle1A2FishingTests 剔除计数）。
    local lens = inLens and scopeRadius and Config.visual.scopeLens or nil
    local fishPx, fishAlpha
    if lens and lens.enabled ~= false then
        local screenX, screenY, screenScale = movement:WorldToScreen(entity.position)
        if screenX and screenScale then
            fishPx = renderLength * screenScale
            -- ④ 远景兜底：屏幕长度不足阈值切暗色剪影（复用 WorldRise 剪影+亮环语言）
            if fishPx < (lens.silhouetteMinPx or 14) then
                local riseCopy = { species = entity.species, rotation = entityHeading(entity),
                    direction = entity.direction, phase = entity.phase or 0, surfaceDepth = 1 }
                groundFrame(ctx, movement, entity.position, 0, function(scale, api)
                    Draw.WorldRise(ctx, 0, 0, scale, riseCopy, time, api)
                end, renderLength * 1.2)
                return
            end
            -- ②a 接触阴影：鱼体前下方暗青椭圆（世界坐标偏移，随曲面投影落位）
            Geometry.WorldCircle(ctx, movement,
                { x = entity.position.x, y = entity.position.y - renderLength * 0.12 },
                renderLength * 0.62,
                { lens.shadowColor[1], lens.shadowColor[2], lens.shadowColor[3], lens.shadowAlpha })
            -- ②c 距离衰减：按到船（相机锚点）的世界距离淡出（仅贴图路可传 alpha）
            local camera = movement.camera
            if camera and scopeRadius then
                local dx, dy = entity.position.x - camera.x, entity.position.y - camera.y
                fishAlpha = SeaDraw.ScopeLensFade(lens, math.sqrt(dx * dx + dy * dy), scopeRadius)
            end
        end
    end
    -- C2：生态层鱼贴图（sardine→小鱼 / tuna→大鱼）三帧摆尾优先，heading 直传实体朝向；
    -- 贴图加载失败保持原矢量鱼体（含尾摆动画与 FSM 配色），零行为变化。
    local base = ECO_SPECIES_BASE[entity.species]
    local drawn = false
    if base then
        drawn = ImageArt.Plane(ctx, ecoFrameName(base, time, ecoEntityPhase(entity)), movement,
            entity.position, renderLength, renderLength, entityHeading(entity), 0, fishAlpha)
    end
    if not drawn then
        groundFrame(ctx, movement, entity.position, 0, function(scale, api)
            Draw.WorldFish(ctx, 0, 0, scale, entity, time, api)
        end, renderLength * 1.2)
    end
    -- ②b 背光高光（鱼体之上，两路通用）
    if lens and fishPx then drawFishGlint(ctx, movement, entity, renderLength, fishPx, lens) end
end

-- Ocean validates fixed identity and visibility; Gameplay contributes only the
-- read-only marked bit used for the small completion glyph.
local function drawFixedTreasure(ctx, runtime, entity, marked)
    if entity.kind ~= "fixed" or entity.entityType ~= "treasure"
        or entity.layer ~= "underwater" or entity.contentId ~= "underwater_treasure_01"
        or type(runtime.GetFixedContentGeneration) ~= "function"
        or type(runtime.GetWorldContent) ~= "function" then return end
    local generationOk, generation = pcall(runtime.GetFixedContentGeneration, runtime)
    if not generationOk or type(generation) ~= "number" then return end
    local snapshotOk, snapshot = pcall(runtime.GetWorldContent, runtime, entity.contentId)
    if not snapshotOk or type(snapshot) ~= "table" or snapshot.entityId ~= entity.id
        or snapshot.generation ~= generation or snapshot.layer ~= "underwater"
        or type(snapshot.position) ~= "table" or not finite(snapshot.position.x)
        or not finite(snapshot.position.y) then return end
    marked = marked == true
    local point = snapshot.position
    local radius = math.max(0.75, (snapshot.radius or 0.5) * 1.5)
    local ink = marked and { 255, 218, 150, 235 } or { 113, 232, 220, 220 }
    local glow = marked and { 255, 202, 116, 45 } or { 105, 230, 222, 38 }
    local diamond = {
        { x = point.x, y = point.y + radius },
        { x = point.x + radius * 0.68, y = point.y },
        { x = point.x, y = point.y - radius },
        { x = point.x - radius * 0.68, y = point.y },
    }
    Presentation.Draw(ctx, runtime.movement, point, radius * 2.2, -0.8, function()
        -- 2026-10-20 正式素材优先（水下宝藏 PNG），失败回退既有矢量菱形标记。
        -- 世界直径取 8×radius（radius=0.5 → 4m）：与该节点 5m 探海镜作用范围同量级，
        -- 太小会在 1080p 下只剩十几个像素。内容比走 ContentPlaneSize，不拉伸。
        local treasureLength, treasureWidth = ImageArt.ContentPlaneSize("underwater_treasure_01", radius * 8)
        local textureDrawn = treasureLength ~= nil and type(Art.Plane) == "function"
            and Art.Plane(ctx, "underwater_treasure_01", runtime.movement, point,
                treasureLength, treasureWidth, 0, 0)
        if not textureDrawn then
            Geometry.WorldCircle(ctx, runtime.movement, point, radius * 1.75, glow, ink, 1.2)
            Geometry.WorldPolygon(ctx, runtime.movement, diamond, glow, ink, 1.5)
        end
        -- 贴图自带半透明光晕，夜间/水下整体压暗后描边容易糊掉；
        -- 贴图模式下补一圈细光环，保证「已发现的水下宝藏」在斜视投影里仍可辨识，
        -- 但不覆盖素材本身（只画描边，不填充）。
        if textureDrawn then
            Geometry.WorldCircle(ctx, runtime.movement, point, radius * 1.35, nil, glow, 1.0)
        end
        if marked then
            worldLine(ctx, runtime.movement,
                { x = point.x - radius * 0.35, y = point.y },
                { x = point.x - radius * 0.08, y = point.y - radius * 0.28 }, ink, 1.8)
            worldLine(ctx, runtime.movement,
                { x = point.x - radius * 0.08, y = point.y - radius * 0.28 },
                { x = point.x + radius * 0.38, y = point.y + radius * 0.3 }, ink, 1.8)
        else
            Geometry.WorldCircle(ctx, runtime.movement, point, radius * 0.2, ink, nil, 0)
        end
    end)
end

-- C2（2026-10-17）：主场景组件渲染（OceanComponents 藏品，World:Init 以 kind="scenery"
-- 放置的固定装饰实体）。2026-10-18 真机验收：礁石/海岸 oblique 组件撤出独立海面投放
-- （原平铺呈漂浮贴图块），改作 island_01/02 既有岛屿底图（见 SeaViewArt
-- ISLAND_BASE_TEXTURES，契约在 Circle1B5ComponentPlacementTests）；本入口保留服务
-- fixedComponents 回填的后续方案。水下沉船（shipwreck_v1 顶视）走 SeaViewArt.Component
-- 贴图（世界平面 Plane + ContentPlaneSize 内容比换算 + LOD + 懒加载），贴图失败回退
-- 矢量剪影，与生态层鱼/鸟/桶的「贴图优先、失败回退」口径一致。实体校验走
-- fixedContentEntities 身份直查（scenery 不进 Runtime 快照接口），只读渲染，零世界状态改写。
local COMPONENT_ENTITY_TYPES = { reef = true, coast = true }
local WRECK_ENTITY_TYPE, WRECK_CONTENT_ID = "wreck", "shipwreck_v1"
local SCENERY_FALLBACK_FILL = { 198, 188, 170, 205 }
local SCENERY_FALLBACK_INK = { 150, 142, 126, 225 }

local function sceneryEntityOk(world, entity)
    return type(world) == "table" and type(world.fixedContentEntities) == "table"
        and type(entity.contentId) == "string"
        and world.fixedContentEntities[entity.contentId] == entity
        and type(world.get) == "function" and world:get(entity.id) == entity
        and not entity.removed and entity.alive ~= false
        and finite(entity.position.x) and finite(entity.position.y)
end

local function drawSurfaceComponent(ctx, runtime, entity)
    if entity.kind ~= "scenery" or entity.layer ~= "surface"
        or not COMPONENT_ENTITY_TYPES[entity.entityType] then return end
    if not sceneryEntityOk(runtime.world, entity) then return end
    local radius = math.max(1, finite(entity.radius) and entity.radius or 1)
    if Art.Component(ctx, entity.contentId, runtime.movement, entity.position,
        radius * 2, 0, nil) then return end
    Geometry.WorldCircle(ctx, runtime.movement, entity.position, radius,
        SCENERY_FALLBACK_FILL, SCENERY_FALLBACK_INK, 1.4)
end

local function drawFixedWreck(ctx, runtime, entity)
    if entity.kind ~= "scenery" or entity.entityType ~= WRECK_ENTITY_TYPE
        or entity.layer ~= "underwater" or entity.contentId ~= WRECK_CONTENT_ID then return end
    if not sceneryEntityOk(runtime.world, entity) then return end
    local point = entity.position
    -- 内容主体填满世界直径 2r（与 island/reef/coast 同一口径），海面微沉贴合水下观感。
    local contentSize = math.max(2, (finite(entity.radius) and entity.radius or 1) * 2)
    Presentation.Draw(ctx, runtime.movement, point, contentSize * 1.1, -0.8, function()
        if Art.Component(ctx, WRECK_CONTENT_ID, runtime.movement, point, contentSize, 0, nil) then return end
        local hull = {
            { x = point.x - contentSize * 0.5, y = point.y },
            { x = point.x - contentSize * 0.28, y = point.y - contentSize * 0.32 },
            { x = point.x + contentSize * 0.28, y = point.y - contentSize * 0.32 },
            { x = point.x + contentSize * 0.5, y = point.y },
            { x = point.x + contentSize * 0.28, y = point.y + contentSize * 0.32 },
            { x = point.x - contentSize * 0.28, y = point.y + contentSize * 0.32 },
        }
        Geometry.WorldPolygon(ctx, runtime.movement, hull, SCENERY_FALLBACK_FILL, SCENERY_FALLBACK_INK, 1.4)
        worldLine(ctx, runtime.movement,
            { x = point.x - contentSize * 0.18, y = point.y - contentSize * 0.2 },
            { x = point.x - contentSize * 0.18, y = point.y + contentSize * 0.2 }, SCENERY_FALLBACK_INK, 1.1)
        worldLine(ctx, runtime.movement,
            { x = point.x + contentSize * 0.18, y = point.y - contentSize * 0.2 },
            { x = point.x + contentSize * 0.18, y = point.y + contentSize * 0.2 }, SCENERY_FALLBACK_INK, 1.1)
    end)
end

-- V2.8 固定海上内容的占位渲染（用户规则：占位优先复用几何/色块/文字，
-- 不制作正式美术）。正式美术接入时只需替换本函数，不改玩法逻辑。
local V28_PALETTE = {
    reef = { fill = { 122, 132, 118, 210 }, ink = { 196, 206, 186, 235 } },
    debris = { fill = { 168, 138, 100, 200 }, ink = { 226, 202, 158, 235 } },
    bottle = { fill = { 150, 210, 206, 205 }, ink = { 226, 248, 240, 240 } },
    bones = { fill = { 226, 224, 208, 190 }, ink = { 250, 248, 232, 235 } },
    vortex = { fill = { 78, 128, 158, 170 }, ink = { 176, 226, 238, 230 } },
    net = { fill = { 150, 140, 110, 200 }, ink = { 214, 200, 160, 235 } },
    kelp = { fill = { 88, 138, 96, 190 }, ink = { 176, 216, 158, 225 } },
    wreck = { fill = { 128, 116, 100, 205 }, ink = { 208, 194, 170, 235 } },
}

local function v28EntityOk(world, entity)
    return type(world) == "table" and type(world.fixedContentEntities) == "table"
        and type(entity.contentId) == "string"
        and world.fixedContentEntities[entity.contentId] == entity
        and type(world.get) == "function" and world:get(entity.id) == entity
        and not entity.removed and entity.alive ~= false
        and finite(entity.position.x) and finite(entity.position.y)
end

-- 浮藻假岛（kelp_mirage_01）是「海面假象」：策划要求 80m 内显岛影轮廓、20m 内识破为藻层。
-- 它登记在 underwater 层（水下货箱在藻层下方，需探海镜标记），但岛影本身必须从海面可见，
-- 否则无探海镜时 isVisible 恒为 false，80m 轮廓永远不会绘制（本函数即为此补正）。
local function v28SurfaceIllusion(entity)
    return entity.entityType == "kelp"
end

-- 2026-10-20：V2.8 固定海上节点从矢量占位升级为正式水彩素材。
-- 映射依据 assets/image/OceanArtCollection/manifest.json：
--   debris      -> debris_01        （漂浮木板带）
--   wreck       -> shipwreck_01     （水下旧木船）
--   bones       -> leviathan_bones_01（巨兽骸骨）
--   vortex      -> sea_eye_vortex_01（常态）/ sea_eye_vortex_01_boost（投放增强态）
--   bottle      -> bottle_note_01   （漂流瓶）
--   net         -> trapped_net_01   （06 破渔网；2026-10-20 第二批交付接入）
--   kelp        -> kelp_mirage_01   （12 浮藻假岛岛影态）/ kelp_mirage_01_b（识破态）
-- 贴图尺寸只由**世界尺寸**决定（不按像素推断玩法），绘制失败/未接入时退回
-- 原有矢量占位（ART_PIPELINE §2.3：不得为了换美术删除回退路径）。
local V28_TEXTURE = {
    debris = "debris_01",
    wreck = "shipwreck_01",
    bones = "leviathan_bones_01",
    vortex = "sea_eye_vortex_01",
    bottle = "bottle_note_01",
    net = "trapped_net_01",
}
-- 双态贴图：entityType -> {default, alt, when}。海眼已由 vortexBoostedFromWorld 单独
-- 判定；浮藻假岛按「20m 识破后」在岛影态与藻层态之间切换（recognized 由 Gameplay
-- 只读派生，不新增状态位，也不写存档）。
local V28_TEXTURE_STATES = {
    kelp = { default = "kelp_mirage_01", alt = "kelp_mirage_01_b", when = "recognized" },
}
-- 素材是正俯视水彩绘本（ART_PIPELINE §3），因此用世界平面投影 Plane。
-- visualRadius 给出的是“岛影/油环”这类视觉外接半径。
--
-- 2026-10-20 修复：旧实现把 length/width 都传 worldDiameter，即一律按正方形投放，
-- 素材内容框长宽比不等时主体会被拉伸（巨骨 2.17:1、气泡 1:2.79、沉船 1.93:1）。
-- 改为走 ImageArt.ContentPlaneSize：以**内容主体最长边**为世界直径，另一维按
-- catalog 的内容比换算，画布则按 pixel/content 补留边。语义与
-- SeaViewArt.Component / Island.Plane 底图同口径（单一尺寸换算入口）。
---@param worldDiameter number 内容主体的世界最长边（米）
local function v28PlaneTexture(ctx, movement, entity, name, worldDiameter, heading, alpha)
    if type(Art.Plane) ~= "function" then return false end
    local canvasLength, canvasWidth = ImageArt.ContentPlaneSize(name, worldDiameter)
    if not canvasLength then return false end
    local ok, drawn = pcall(Art.Plane, ctx, name, movement, entity.position,
        canvasLength, canvasWidth, heading or 0, 0, alpha)
    return ok and drawn == true
end

---海眼是否处于“投放增强态”。
---只用世界已有的 `vortexBoost` 临时诱饵**只读派生**，不新增状态位、不写存档。
---@param world table
---@return boolean
local function vortexBoostedFromWorld(world)
    if type(world) ~= "table" or type(world.entities) ~= "table" then return false end
    for _, candidate in ipairs(world.entities) do
        if not candidate.removed and candidate.kind == "temporary" then
            local payload = candidate.payload
            if type(payload) == "table" and payload.vortexBoost == true then return true end
        end
    end
    return false
end

local function drawV28Node(ctx, runtime, entity, contentId, marked, recognized, picked)
    local palette = V28_PALETTE[entity.entityType]
    if not palette then return end
    local movement, point = runtime.movement, entity.position
    local radius = math.max(1.2, finite(entity.radius) and entity.radius or 2)
    local visual = finite(entity.visualRadius) and entity.visualRadius or radius

    -- ① 贴图优先。worldDiameter 用视觉半径×2（缺省时用碰撞半径×2）——
    -- 世界米制尺寸是唯一口径，素材像素分辨率不参与玩法。
    local state = V28_TEXTURE_STATES[entity.entityType]
    local textureName = V28_TEXTURE[entity.entityType] or (state and state.default)
    if not picked and textureName then
        -- 海眼：投放增强态（世界里有 vortexBoost 临时诱饵时）换 boost 素材。
        if entity.entityType == "vortex" and vortexBoostedFromWorld(runtime.world) then
            textureName = "sea_eye_vortex_01_boost"
        end
        -- 浮藻假岛：20m 识破后换藻层态（岛影态 -> 藻层态），同一世界锚点与尺寸。
        if state and state.when == "recognized" and recognized then
            textureName = state.alt
        end
        local worldDiameter = visual * 2
        -- 漂流瓶体量小，用碰撞半径的两倍作世界直径更贴近“一只瓶子”的观感。
        if entity.entityType == "bottle" then worldDiameter = radius * 2 end
        if v28PlaneTexture(ctx, movement, entity, textureName, worldDiameter) then
            -- 贴图成功：保留“已标记”的完成记号（不重复画矢量主体）。
            if marked then
                local markX, markY = point.x + visual * 0.9, point.y + visual * 0.9
                worldLine(ctx, movement, { x = markX - 0.8, y = markY },
                    { x = markX - 0.2, y = markY - 0.7 }, { 255, 218, 150, 235 }, 1.8)
                worldLine(ctx, movement, { x = markX - 0.2, y = markY - 0.7 },
                    { x = markX + 0.9, y = markY + 0.7 }, { 255, 218, 150, 235 }, 1.8)
            end
            return
        end
    end

    if entity.entityType == "reef" then
        -- 礁石：三层不规则色块，保持 blocking 体积不变。
        Geometry.WorldCircle(ctx, movement, point, visual, palette.fill, palette.ink, 1.4)
        Geometry.WorldCircle(ctx, movement, { x = point.x + visual * 0.4, y = point.y - visual * 0.3 },
            visual * 0.5, palette.fill, palette.ink, 1.0)
        Geometry.WorldCircle(ctx, movement, { x = point.x - visual * 0.45, y = point.y + visual * 0.25 },
            visual * 0.42, palette.fill, palette.ink, 1.0)
    elseif entity.entityType == "debris" then
        for index = -1, 1 do
            local offset = index * visual * 0.55
            Geometry.WorldPolygon(ctx, movement, {
                { x = point.x + offset - visual * 0.5, y = point.y + visual * 0.2 },
                { x = point.x + offset + visual * 0.5, y = point.y + visual * 0.05 },
                { x = point.x + offset + visual * 0.45, y = point.y - visual * 0.18 },
                { x = point.x + offset - visual * 0.45, y = point.y - visual * 0.1 },
            }, palette.fill, palette.ink, 1.0)
        end
    elseif entity.entityType == "bottle" then
        if picked then return end
        Geometry.WorldCircle(ctx, movement, point, visual, palette.fill, palette.ink, 1.3)
        Geometry.WorldCircle(ctx, movement, point, visual * 0.35, palette.ink, nil, 0)
    elseif entity.entityType == "bones" then
        -- 巨骨：横贯的脊骨 + 肋条（只在探海镜/水下可见时绘制）。
        worldLine(ctx, movement, { x = point.x - visual * 2.4, y = point.y },
            { x = point.x + visual * 2.4, y = point.y }, palette.ink, 2.2)
        for index = -3, 3 do
            local x = point.x + index * visual * 0.65
            worldLine(ctx, movement, { x = x, y = point.y },
                { x = x + visual * 0.4, y = point.y - visual * 1.1 }, palette.ink, 1.4)
            worldLine(ctx, movement, { x = x, y = point.y },
                { x = x + visual * 0.4, y = point.y + visual * 1.1 }, palette.ink, 1.4)
        end
        Geometry.WorldCircle(ctx, movement, point, visual * 1.6, nil, palette.ink, 1.0)
    elseif entity.entityType == "vortex" then
        -- 海眼：同心环 + 中心暗点；中心 3m 禁网区用深色小圈表达。
        for ring = 1, 3 do
            Geometry.WorldCircle(ctx, movement, point, visual * (0.35 + ring * 0.22),
                nil, palette.ink, 1.2)
        end
        Geometry.WorldCircle(ctx, movement, point, visual * 0.18, palette.fill, palette.ink, 1.2)
    elseif entity.entityType == "net" then
        Geometry.WorldCircle(ctx, movement, point, visual, palette.fill, palette.ink, 1.4)
        for index = -1, 1 do
            worldLine(ctx, movement, { x = point.x - visual, y = point.y + index * visual * 0.45 },
                { x = point.x + visual, y = point.y - index * visual * 0.45 }, palette.ink, 1.0)
        end
    elseif entity.entityType == "kelp" then
        -- 浮藻假岛：80m 内显未知轮廓，20m 内识破为藻层。
        local radiusForView = recognized and visual * 0.55 or visual
        Geometry.WorldCircle(ctx, movement, point, radiusForView,
            recognized and palette.fill or { 150, 170, 150, 90 }, palette.ink, 1.4)
        if recognized then
            for index = -2, 2 do
                local offset = index * radiusForView * 0.32
                worldLine(ctx, movement, { x = point.x + offset, y = point.y - radiusForView * 0.7 },
                    { x = point.x + offset * 0.6, y = point.y + radiusForView * 0.7 }, palette.ink, 1.0)
            end
        end
    elseif entity.entityType == "wreck" then
        local size = visual * 1.6
        Geometry.WorldPolygon(ctx, movement, {
            { x = point.x - size, y = point.y },
            { x = point.x - size * 0.5, y = point.y - size * 0.55 },
            { x = point.x + size * 0.6, y = point.y - size * 0.5 },
            { x = point.x + size, y = point.y + size * 0.1 },
            { x = point.x + size * 0.4, y = point.y + size * 0.6 },
            { x = point.x - size * 0.6, y = point.y + size * 0.55 },
        }, palette.fill, palette.ink, 1.4)
        worldLine(ctx, movement, { x = point.x - size * 0.5, y = point.y },
            { x = point.x + size * 0.7, y = point.y }, palette.ink, 1.2)
    end
    -- 已标记：右上角小勾，与既有固定宝藏的完成记号同构。
    if marked then
        local markX, markY = point.x + visual * 0.9, point.y + visual * 0.9
        worldLine(ctx, movement, { x = markX - 0.8, y = markY },
            { x = markX - 0.2, y = markY - 0.7 }, { 255, 218, 150, 235 }, 1.8)
        worldLine(ctx, movement, { x = markX - 0.2, y = markY - 0.7 },
            { x = markX + 0.9, y = markY + 0.7 }, { 255, 218, 150, 235 }, 1.8)
    end
end

-- V2.8 巨骨：海面 5m 内的深水慢气泡（与 A06 大鱼移动水花明显区分：
-- 位置固定、上升缓慢、无方向尾迹）。只读固定坐标 + 运行时时间。
local function drawLeviathanBubbles(ctx, runtime, time)
    local world = runtime.world
    if type(world) ~= "table" or type(world.fixedContentEntities) ~= "table" then return end
    local entity = world.fixedContentEntities["leviathan_bones_01"]
    if not entity or entity.removed or type(entity.position) ~= "table" then return end
    local definition = entity
    local bubble = { intervalSec = 1.5, surfaceRadius = 5 }
    for _, item in ipairs(require("data.content").fixed) do
        if item.contentId == "leviathan_bones_01" and type(item.bubble) == "table" then bubble = item.bubble end
    end
    local ship = runtime.ship
    if type(ship) ~= "table" or type(ship.position) ~= "table" then return end
    local dx = entity.position.x - ship.position.x
    local dy = entity.position.y - ship.position.y
    if dx * dx + dy * dy > (bubble.surfaceRadius or 5) ^ 2 then return end
    local interval = bubble.intervalSec or 1.5
    for index = 0, 2 do
        local phase = ((time or 0) / interval + index * 0.37) % 1
        local radius = 0.25 + phase * 0.55
        local offset = math.sin(index * 2.1 + time * 0.4) * 1.1
        local alpha = math.floor(210 * (1 - phase))
        if alpha > 0 then
            local center = { x = entity.position.x + offset, y = entity.position.y + offset * 0.6 }
            -- 2026-10-20 正式素材优先（气泡簇 PNG），失败回退原矢量气泡圆。
            -- 尺寸走同一换算入口：气泡素材内容比 1:2.79，正方形投放会压扁。
            local bubbleLength, bubbleWidth = ImageArt.ContentPlaneSize("leviathan_bubbles_01", radius * 6)
            local drew = (bubbleLength ~= nil and type(Art.Plane) == "function" and Art.Plane(
                ctx, "leviathan_bubbles_01", runtime.movement, center,
                bubbleLength, bubbleWidth, 0, 0, (alpha / 255) * 0.9)) or false
            if not drew then
                Geometry.WorldCircle(ctx, runtime.movement, center,
                    radius, nil, { 214, 240, 246, alpha }, 1.2)
            end
        end
    end
end

local function drawPerception(ctx, movement, entity)
    local data = FishData[entity.species]
    if not data then return end
    local function circle(radius, tint)
        if type(radius) == "number" and radius > 0 then
            Geometry.WorldCircle(ctx, movement, entity.position, radius, nil, tint, 1.2)
        end
    end
    if entity.species == "sardine" then
        circle(data.dangerRadius, { 246, 104, 119, 100 })
        circle(data.attractRadius, { 255, 207, 111, 100 })
    elseif entity.species == "tuna" then circle(data.preyRadius, { 103, 192, 255, 96 }) end
end

local function drawTarget(ctx, movement)
    local target = movement.target
    if not target then return end
    local x, y = movement:WorldToScreen(target)
    if not x then return end
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, 8)
    nvgMoveTo(ctx, x - 12, y)
    nvgLineTo(ctx, x + 12, y)
    nvgMoveTo(ctx, x, y - 12)
    nvgLineTo(ctx, x, y + 12)
    nvgStrokeColor(ctx, color(Config.visual.target))
    nvgStrokeWidth(ctx, 1.5)
    nvgStroke(ctx)
end

-- 2026-10-20：屏幕四角压暗（vignette）。纯屏幕空间一次径向渐变填充。
-- 为什么用径向渐变而不是四角四块：单次 nvgFill、无接缝、形状天然圆润，
-- 不会在角落留下方形边界。内圈半径外才开始压暗，中心区严格不动，
-- 保证船与近水交互点（礁石/漂流瓶/渔网）的可读性不被削弱。
-- 层级：必须在整个世界层（含夜罩、雾、港口标记）之后，否则会被后续绘制抹掉。
-- 不碰世界投影、不改任何实体或玩法状态；enabled=false 即完全回退。
---@param ctx NVGContextWrapper
---@param width number
---@param height number
---@return boolean drawn
local function drawVignette(ctx, width, height)
    local settings = Config.visual.vignette
    if type(settings) ~= "table" or settings.enabled == false then return false end
    if not finite(width) or not finite(height) or width <= 0 or height <= 0 then return false end
    local strength = settings.strength
    if not finite(strength) or strength <= 0 then return false end
    local inner = settings.innerRadius
    if not finite(inner) or inner < 0 then inner = 0.55 end
    if inner >= 1 then return false end
    local color = settings.color or { 26, 46, 58 }
    -- 以外接圆为准：保证屏幕四角都落在渐变外缘，横屏竖屏行为一致。
    local cx, cy = width * 0.5, height * 0.5
    local outerRadius = math.sqrt(cx * cx + cy * cy)
    local innerRadius = outerRadius * inner
    local alpha = math.floor(math.max(0, math.min(1, strength)) * 255)
    if alpha <= 0 then return false end
    nvgSave(ctx)
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, width, height)
    nvgFillPaint(ctx, nvgRadialGradient(ctx, cx, cy, innerRadius, outerRadius,
        nvgRGBA(color[1], color[2], color[3], 0),
        nvgRGBA(color[1], color[2], color[3], alpha)))
    nvgFill(ctx)
    nvgRestore(ctx)
    return true
end

local function drawPortMark(ctx, runtime, width, height, horizon)
    if type(runtime.GetPortPosition) ~= "function" then return end
    local point = runtime:GetPortPosition()
    local x, y = runtime.movement:WorldToScreen(point)
    if not onScreen(x, y, PORT_MARK_RADIUS + 2, width, height, horizon) then return end
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, PORT_MARK_RADIUS)
    nvgStrokeColor(ctx, nvgRGBA(12, 42, 52, 235))
    nvgStrokeWidth(ctx, 5)
    nvgStroke(ctx)
    nvgBeginPath(ctx)
    nvgCircle(ctx, x, y, PORT_MARK_RADIUS)
    nvgMoveTo(ctx, x, y - 8)
    nvgLineTo(ctx, x, y + 5)
    nvgMoveTo(ctx, x - 8, y - 2)
    nvgLineTo(ctx, x + 8, y - 2)
    nvgMoveTo(ctx, x - 8, y + 3)
    nvgLineTo(ctx, x - 6, y + 8)
    nvgLineTo(ctx, x, y + 10)
    nvgLineTo(ctx, x + 6, y + 8)
    nvgLineTo(ctx, x + 8, y + 3)
    nvgStrokeColor(ctx, color(Config.visual.ship))
    nvgStrokeWidth(ctx, 1.6)
    nvgStroke(ctx)
end

local function nearbyEntities(runtime)
    local world = runtime.world
    if not world then return {} end
    -- The authoritative collection is shared with gameplay. Per-object height
    -- and footprint bounds are evaluated by Presentation, with no distant-type
    -- whitelist or fixed extension that could hide a newly registered object.
    return world.entities
end

-- Place a three-bird commuter formation on the current screen edge along the
-- live ship-to-island bearing. It is presentation only; no World entity or
-- authored route is created.
local function commuterFlockLayout(runtime, width, height, isLocationRecognized)
    if type(isLocationRecognized) ~= "function" then return nil end
    local movement = runtime and runtime.movement
    if not movement or movement.viewportReady ~= true or type(runtime.GetTrace) ~= "function" then return nil end
    local trace = runtime:GetTrace("flock_commute")
    if not trace or trace.valid ~= true or trace.sourceContentId ~= "island_02"
        or trace.birdCount ~= 3 or trace.dives ~= false or trace.circlesFish ~= false
        or not finite(trace.distance) or trace.distance <= Config.interaction.recognitionDistance
        or not finite(trace.bearingRadians) then
        return nil
    end
    local recognizedOk, recognized = pcall(isLocationRecognized, "island_02")
    if not recognizedOk or recognized == true then return nil end

    local ship = movement.ship
    if not ship or type(ship.position) ~= "table" then return nil end
    local altitude = Config.visual.projection.birdAltitude
    local originX, originY = movement:WorldToScreen(ship.position, altitude)
    if not finite(originX) or not finite(originY) then return nil end
    local lookAhead = {
        x = ship.position.x + math.cos(trace.bearingRadians) * 8,
        y = ship.position.y + math.sin(trace.bearingRadians) * 8,
    }
    local aheadX, aheadY = movement:WorldToScreen(lookAhead, altitude)
    if not finite(aheadX) or not finite(aheadY) then return nil end
    local dx, dy = aheadX - originX, aheadY - originY
    local length = math.sqrt(dx * dx + dy * dy)
    if not finite(length) or length <= 1e-6 then return nil end
    dx, dy = dx / length, dy / length

    local margin = math.min(28, width * 0.08, height * 0.08)
    local t = math.huge
    if dx > 1e-6 then t = math.min(t, (width - margin - originX) / dx)
    elseif dx < -1e-6 then t = math.min(t, (margin - originX) / dx) end
    if dy > 1e-6 then t = math.min(t, (height - margin - originY) / dy)
    elseif dy < -1e-6 then t = math.min(t, (margin - originY) / dy) end
    if not finite(t) or t <= 0 then return nil end

    local edgeX, edgeY = originX + dx * t, originY + dy * t
    local perpendicularX, perpendicularY = -dy, dx
    local elapsed = finite(runtime.time) and math.max(0, runtime.time) or 0
    local flowOffset = -64 + ((elapsed * 0.2) % 1) * 48
    return {
        bearingRadians = trace.bearingRadians,
        screenDirection = { x = dx, y = dy },
        birds = {
            { x = edgeX + dx * (flowOffset - 10), y = edgeY + dy * (flowOffset - 10) },
            { x = edgeX + dx * (flowOffset - 34) + perpendicularX * 15,
                y = edgeY + dy * (flowOffset - 34) + perpendicularY * 15 },
            { x = edgeX + dx * (flowOffset - 34) - perpendicularX * 15,
                y = edgeY + dy * (flowOffset - 34) - perpendicularY * 15 },
        },
    }
end

local function drawCommuterFlock(ctx, width, height, runtime, isLocationRecognized)
    local layout = commuterFlockLayout(runtime, width, height, isLocationRecognized)
    if not layout then return 0 end
    -- 2026-10-20 真人试玩 RCA（HUMAN-PLAYTEST-RCA-FIX-01）：通勤鸟群是 island_02 的
    -- 唯一早期引导线索，但原 14 号屏幕尺寸在真机上偏小、难被注意到。
    -- 首轮试玩值：整体视觉尺寸 ×1.6（14 -> 22.4）。
    -- 只改 presentation：三只编队规则/只引导 island_02/识别后消失全部不变，
    -- 不新增地图箭头、UI 导航线或新系统。
    local COMMUTER_BIRD_SCREEN_SCALE = 14 * 1.6
    for _, bird in ipairs(layout.birds) do
        Draw.WorldSeabird(ctx, bird.x, bird.y, COMMUTER_BIRD_SCREEN_SCALE, layout.bearingRadians, 0)
    end
    return #layout.birds
end

local function drawFishing(ctx, runtime, view)
    if type(view) ~= "table" or type(view.center) ~= "table"
        or not finite(view.center.x) or not finite(view.center.y) then return end
    local phase, elapsed = view.phase, view.elapsedSec
    if phase ~= "aim" and phase ~= "casting" and phase ~= "reeling" then return end
    if not finite(elapsed) or elapsed < 0 then return end
    local movement, center = runtime.movement, view.center
    local radius, landingSec = Config.fishing.netRadius, 0.5
    if phase == "casting" and elapsed < landingSec then
        local progress, ship = elapsed / landingSec, runtime.ship.position
        local flight = { x = ship.x + (center.x - ship.x) * progress,
            y = ship.y + (center.y - ship.y) * progress }
        Geometry.WorldCircle(ctx, movement, flight, radius * progress, nil,
            { 255, 236, 183, 210 }, 1.8, radius * math.sin(math.pi * progress))
        return
    end
    local reeling = phase == "reeling" and math.max(0, math.min(1,
        (elapsed - landingSec) / (Config.fishing.durationSec - landingSec))) or 0
    local netRadius = radius * (1 - reeling)
    Geometry.WorldCircle(ctx, movement, center, netRadius, nil,
        { 255, 236, 183, phase == "aim" and 150 or 220 }, phase == "aim" and 1.4 or 2)
    if phase ~= "aim" then
        for index = -2, 2 do
            local offset = netRadius * index / 3
            local chord = math.sqrt(math.max(0, netRadius * netRadius - offset * offset))
            worldLine(ctx, movement, { x = center.x + offset, y = center.y - chord },
                { x = center.x + offset, y = center.y + chord }, { 255, 236, 183, 90 }, 1)
            worldLine(ctx, movement, { x = center.x - chord, y = center.y + offset },
                { x = center.x + chord, y = center.y + offset }, { 255, 236, 183, 90 }, 1)
        end
    end
    if phase == "reeling" then
        worldLine(ctx, movement, runtime.ship.position, center, { 255, 236, 183, 170 }, 1.5)
    elseif phase == "casting" then
        local lifetime, age = Config.surfaceSignals.splashLifetime, elapsed - landingSec
        if age >= 0 and age < lifetime then
            groundFrame(ctx, movement, center, 0, function(scale, api)
                Draw.WorldSplash(ctx, 0, 0, scale, lifetime - age, lifetime, 0, 0, api)
            end)
        end
    end
end

-- Scalar signal visitors validate their live sources. Store only frame-local
-- presentation records and never manufacture fish cues in the distant backdrop.
local function surfaceEntries(runtime, entities)
    local entries, world, movement = {}, runtime.world, runtime.movement
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.id ~= runtime.ship.id then
            if isVisible(world, entity) and entity.layer ~= "underwater" then
                entries[#entries + 1] = { kind = "entity", position = entity.position, entity = entity }
            end
            if not entity.captureLocked and entity.active ~= false and not entity.frozen
                and entity.species == "sardine" and (entity.surfaceDepth or 0) > 0 then
                entries[#entries + 1] = { kind = "rise", position = entity.position, entity = entity }
            end
        end
    end
    entries[#entries + 1] = { kind = "ship", position = runtime.ship.position, entity = runtime.ship }
    local signals = runtime.surfaceSignals
    if signals then
        local function splash(x, y, remaining, lifetime, heading, length)
            entries[#entries + 1] = { kind = "splash", position = { x = x, y = y },
                remaining = remaining, lifetime = lifetime, heading = heading or 0, length = length or 2 }
        end
        local function bird(x, y, heading, dive)
            entries[#entries + 1] = { kind = "bird", position = { x = x, y = y },
                heading = heading or 0, dive = dive }
        end
        if type(signals.VisitSplashes) == "function" then signals:VisitSplashes(splash)
        else
            for _, cue in ipairs(signals:GetSplashes()) do
                splash(cue.position.x, cue.position.y, cue.remaining, cue.lifetime, cue.heading, cue.trailLength)
            end
        end
        if type(signals.VisitBirds) == "function" then signals:VisitBirds(bird)
        else
            for _, cue in ipairs(signals:GetBirds()) do bird(cue.position.x, cue.position.y, cue.heading, cue.diveProgress) end
        end
    end
    -- Stable painter ordering: distant ship/floats/cues go behind nearer islands.
    for index, entry in ipairs(entries) do entry.order = index end
    table.sort(entries, function(a, b)
        if a.position.y == b.position.y then return a.order < b.order end
        return a.position.y > b.position.y
    end)
    return entries
end

---@param ctx NVGContextWrapper
---@param width number Mode B logical pixels.
---@param height number Mode B logical pixels.
---@param runtime table
---@param clock table? Existing read-only Gameplay clock.
---@param fishingView table? Existing read-only Gameplay fishing view.
---@param isLocationRecognized (fun(contentId: string): boolean)?
---@param isWorldContentMarked (fun(contentId: string): boolean)? Read-only Gameplay progress query.
function SeaDraw.Scene(ctx, width, height, runtime, clock, fishingView, isLocationRecognized, isWorldContentMarked)
    if not ctx or width <= 0 or height <= 0 or not runtime or not runtime.movement then return end
    local movement, world, time = runtime.movement, runtime.world, runtime.time or 0
    -- T3 帧耗时探针：全帧对照基准（岛分项见 SeaViewArt）。
    local probeSceneStop = PerfProbe.Timer()
    PerfProbe.Frame()
    local horizon = movement:GetHorizonY()
    Art.Backdrop(ctx, width, height, time, clock, movement)
    -- C2（2026-10-17）：海面贴图相位映射需要 clock（昼/夜 progress）；
    -- SeaViewArt.Surface 对缺省 clock 退化为昼图独显，三参旧调用零回归。
    Art.Surface(ctx, movement, time, clock)
    -- T5（2026-10-06 美术审核确认）：昼夜色罩移到世界实体之后统一染色——
    -- 旧层级（实体前）导致 PNG 船/岛/木桶等贴图实体夜间不被染暗。
    -- 层级：天空海面 → 世界实体 → 昼夜罩 → 雾/港口标记/功能信号（保持可读）。
    nvgSave(ctx)
    Atmosphere.CloudShadows(ctx, movement, time, runtime.daySeed)
    local flags, entities = runtime.debug or Config.debug, nearbyEntities(runtime)
    local scope = world and type(world.GetScopeView) == "function" and world:GetScopeView() or nil
    if scope then drawScopeWater(ctx, movement, scope) end
    for _, entity in ipairs(entities) do
        if not entity.removed and entity.species and entity.layer == "underwater" and isVisible(world, entity) then
            Presentation.Draw(ctx, movement, entity.position, FishData[entity.species].renderLength, 0,
                function() drawFish(ctx, movement, entity, flags.showActivity, time, true, scope and scope.radius) end)
        elseif not entity.removed and entity.layer == "underwater" and entity.entityType == "treasure"
            and entity.contentId == "underwater_treasure_01" then
            local marked = false
            if type(isWorldContentMarked) == "function" then
                local queryOk, value = pcall(isWorldContentMarked, entity.contentId)
                marked = queryOk and value == true
            end
            -- Once Gameplay marks this fixed treasure, keep that known map glyph
            -- visible with the scope closed. This is presentation only; action
            -- eligibility still uses Runtime:IsWorldContentInScope.
            if marked or isVisible(world, entity) then
                drawFixedTreasure(ctx, runtime, entity, marked)
            end
        elseif not entity.removed and entity.layer == "underwater" and entity.entityType == WRECK_ENTITY_TYPE
            and entity.contentId == WRECK_CONTENT_ID then
            -- C2：海底沉船残骸（纯景观，无 marked 常驻逻辑）：scope 楔形内或水下显示时绘制。
            if isVisible(world, entity) then
                drawFixedWreck(ctx, runtime, entity)
            end
        elseif not entity.removed and entity.kind == "fixed" and V28_PALETTE[entity.entityType]
            and v28EntityOk(world, entity) then
            -- V2.8 固定海上内容：水下节点只在探海镜/水下可见时绘制，
            -- 已标记/已识别的节点保持常驻记号（与固定宝藏同口径）。
            local marked, recognized = false, false
            if type(isWorldContentMarked) == "function" then
                local ok, value = pcall(isWorldContentMarked, entity.contentId)
                marked = ok and value == true
            end
            -- 20m 识破后改画藻层（drawV28Node 依赖该标志切换轮廓半径）。
            if type(isLocationRecognized) == "function" then
                local ok, value = pcall(isLocationRecognized, entity.contentId)
                recognized = ok and value == true
            end
            -- 浮藻假岛的 80m 岛影是海面假象：不依赖探海镜可见性，按 outlineDistance 绘制。
            local illusion = false
            if v28SurfaceIllusion(entity) then
                local ship = runtime.ship
                if type(ship) == "table" and type(ship.position) == "table" then
                    local dx = entity.position.x - ship.position.x
                    local dy = entity.position.y - ship.position.y
                    illusion = dx * dx + dy * dy <= Config.interaction.outlineDistance ^ 2
                end
            end
            if entity.layer == "underwater" then
                if marked or illusion or isVisible(world, entity) then
                    drawV28Node(ctx, runtime, entity, entity.contentId, marked, recognized, false)
                end
            end
        end
    end
    Art.Wake(ctx, movement, movement.wake)
    drawLeviathanBubbles(ctx, runtime, time)
    local snapshot = type(runtime.GetFixedBarrel) == "function" and runtime:GetFixedBarrel() or nil
    for _, entry in ipairs(surfaceEntries(runtime, entities)) do
        local entity, point = entry.entity, entry.position
        local speciesData = entity and entity.species and FishData[entity.species]
        local radius = entity and (entity.species
            and ((speciesData and speciesData.renderLength) or entity.radius or 1)
            or (entity.radius or 1)) or math.max(3, entry.length or 0)
        -- 广相剔除高度：立牌海鸟的顶端在 birdAltitude + 立牌高（内容高宽比 < 1，
        -- 取 BIRD_SPAN_METERS 作保守上界），否则公告板顶部会被地平线遮挡误剔除。
        local altitude = entry.kind == "entity" and entity.entityType == "island" and 5.4
            or entry.kind == "bird"
                and (Config.visual.projection.birdAltitude + BIRD_SPAN_METERS) or 0
        if entry.kind == "bird" or entry.kind == "splash" then
            radius, altitude = Presentation.SignalBounds(entry.kind, entry.length)
        end
        if entry.kind == "ship" then
            Art.Boat(ctx, movement, entity, time)
        else
            Presentation.Draw(ctx, movement, point, radius, altitude, function(appearance)
                if entry.kind == "entity" then
                    if entity.entityType == "island" then
                        Art.Island(ctx, movement, entity, time, appearance and appearance.airMix or 0)
                    elseif COMPONENT_ENTITY_TYPES[entity.entityType] then
                        drawSurfaceComponent(ctx, runtime, entity)
                    elseif entity.entityType == "float" then
                        if world and entity == world.fixedBarrel then
                            drawFixedBarrel(ctx, runtime, entity, snapshot, isLocationRecognized)
                        else drawFloat(ctx, movement, entity, false, false, time) end
                    elseif entity.kind == "fixed" and V28_PALETTE[entity.entityType]
                        and v28EntityOk(world, entity) then
                        -- V2.8 海面固定节点：礁石/木板/漂流瓶/海眼/破渔网/浮藻假岛。
                        local marked = false
                        if type(isWorldContentMarked) == "function" then
                            local ok, value = pcall(isWorldContentMarked, entity.contentId)
                            marked = ok and value == true
                        end
                        local picked = false
                        if type(runtime.GetV28Picked) == "function" then
                            local ok, value = pcall(runtime.GetV28Picked, runtime, entity.contentId)
                            picked = ok and value == true
                        end
                        local recognized = false
                        if type(isLocationRecognized) == "function" then
                            local ok, value = pcall(isLocationRecognized, entity.contentId)
                            recognized = ok and value == true
                        end
                        drawV28Node(ctx, runtime, entity, entity.contentId, marked, recognized, picked)
                    elseif entity.entityType == "droppedItem" then drawDroppedItem(ctx, movement, entity)
                    elseif entity.species then drawFish(ctx, movement, entity, flags.showActivity, time) end
                elseif entry.kind == "rise" then
                    groundFrame(ctx, movement, point, 0,
                        function(scale, api) Draw.WorldRise(ctx, 0, 0, scale, entity, time, api) end,
                        (FishData[entity.species].renderLength or 1) * 1.5)
                elseif entry.kind == "splash" then
                    local alpha = math.max(0, math.min(1, entry.remaining / entry.lifetime))
                    if not ImageArt.Sprite(ctx, "splash", movement, point, math.max(2, entry.length),
                        entry.heading, 0, alpha) then
                        groundFrame(ctx, movement, point, 0, function(scale, api)
                            Draw.WorldSplash(ctx, 0, 0, scale, entry.remaining, entry.lifetime, entry.heading, entry.length, api)
                        end, math.max(3, entry.length))
                    end
                    -- Keep the directional trace: its position/heading/lifetime
                    -- comes from the existing live fish signal, not a new effect timer.
                    if ImageArt.IsLoaded(ctx, "splash") then
                        worldLine(ctx, movement, point,
                            { x = point.x - math.cos(entry.heading) * entry.length,
                              y = point.y - math.sin(entry.heading) * entry.length },
                            { 221, 239, 235, math.floor(alpha * 150) }, 1.2)
                    end
                elseif entry.kind == "bird" then
                    -- 2026-10-19 真机验收：eco_bird_f* 是水彩侧视素材（ART_PIPELINE
                    -- 合规正视图），按 Plane 平铺在世界平面会被引擎斜投影二次压扁，
                    -- 真机呈「漂浮贴图块」（用户红框标注）——与 10-18 木桶/岛饰/丘/树
                    -- 同一病根，改竖幅公告板投影（Upright，与岛饰同一口径）立起。
                    -- 尺寸口径由「画布米制」改为「内容主体米制」：Upright 的 worldWidth
                    -- 直接是 catalog 内容框宽度，1.8m 与旧平铺的实际可见翼展
                    -- （3.2m 画布 × 580/1024 ≈ 1.81m）一致，故本次只改投影模式不改体量。
                    -- 悬停高度透传为立牌底沿 altitude（否则会站在水面上）；朝向按
                    -- heading 的屏幕横向分量镜像（固定偏航投影下 ∝ cos(heading)，
                    -- 死区避免正前/正后飞时来回翻转）。回退链不变：俯视素材
                    -- gull/gull_dive 保持 Plane（正俯视本就该平铺），再失败走矢量。
                    local dive = finite(entry.dive) and entry.dive or 0
                    dive = math.min(1, math.max(0, dive))
                    -- 俯冲只折叠姿态：折叠幅度与下压高度都有下限（见 BIRD_DIVE_FOLD_MAX），
                    -- 满折叠的末帧仍有 72% 翼展、45% 悬停高度——鸟群继续盘旋时不会「缩没」。
                    local fold = birdDiveFold(dive)
                    local birdAltitude = math.max(
                        Config.visual.projection.birdAltitude * (1 - dive),
                        Config.visual.projection.birdAltitude * BIRD_DIVE_ALTITUDE_MIN_RATIO)
                    local birdWidth = BIRD_SPAN_METERS * (1 - 0.62 * fold)
                    -- 2026-10-19 真机二轮反馈（红框截图：天空三只海鸥是白色折线鸟）：
                    -- 俯冲时翼展缩到 0.68m，远处 screenWidth 跌破 ImageArt 的
                    -- UPRIGHT_MIN_PX=2 亚像素剔除线 → Upright 返回 false，回退
                    -- WorldSeabird 矢量折线鸟（水彩立牌失效，即用户红框所见）。
                    -- 立牌在此按屏幕像素给一个可见下限：远处海鸥即便按透视缩到
                    -- 亚像素也照常贴水彩图，只有完全不可见时才交给矢量兜底。
                    -- 换算回世界米制需除以该深度的投影 scale（Projection.Project
                    -- 第三返回值即米→像素的 scale），故先取 scale。
                    local _, _, spanScale = Projection.Project(movement, point, birdAltitude)
                    if type(spanScale) == "number" and spanScale > 0 then
                        -- 先保证过剔除线（技术下限），再抬到玩家可辨识下限。
                        birdWidth = math.max(birdWidth, BIRD_RASTER_MIN_SPAN_PX / spanScale)
                        birdWidth = math.max(birdWidth, BIRD_MIN_SCREEN_SPAN_PX / spanScale)
                    end
                    if not ImageArt.Upright(ctx, ecoFrameName("eco_bird", time, 0), movement,
                        point, nil, 1, birdWidth, birdAltitude, birdFlipsScreen(entry.heading)) then
                        local flapScale = 1 + math.sin(time * 3.2) * 0.035
                        local fallback = dive > 0.05
                            and ImageArt.IsLoaded(ctx, "gull_dive") and "gull_dive" or "gull"
                        local birdLength = 3.2
                        local birdSpan = birdLength * (1 - 0.62 * fold)
                        if not ImageArt.Plane(ctx, fallback, movement, point, birdLength,
                            birdSpan * flapScale, entry.heading, birdAltitude) then
                            groundFrame(ctx, movement, point, birdAltitude, function(scale, api)
                                Draw.WorldSeabird(ctx, 0, 0, scale, entry.heading, fold, api)
                            end)
                        end
                    end
                end
            end)
        end
    end
    drawCommuterFlock(ctx, width, height, runtime, isLocationRecognized)
    Atmosphere.Fog(ctx, movement, time, runtime.daySeed)
    drawFishing(ctx, runtime, fishingView)
    -- Grade all world content, including PNG ship/islands, fish in the scope,
    -- signal VFX and fog. Port/navigation marks and the separately rendered UI
    -- remain readable. No clock, simulation or pause state is changed here.
    if clock and clock.phase == "night" then Draw.NightOverlay(ctx, width, height, clock) end
    drawPortMark(ctx, runtime, width, height, horizon)
    if flags.showPerception then
        for _, entity in ipairs(entities) do
            if not entity.removed and entity.species and isVisible(world, entity) then drawPerception(ctx, movement, entity) end
        end
    end
    drawTarget(ctx, movement)
    -- 2026-10-20：四角压暗必须压在**所有世界与信号层之后**（含夜罩/雾/港口标记），
    -- 否则会被后续绘制抹掉。放在 showBounds 之前：调试可视化不被压暗，
    -- 保证调试读数仍然清楚。
    drawVignette(ctx, width, height)
    if flags.showBounds then
        local half = Config.world.halfSize
        Geometry.WorldPolygon(ctx, movement, { { x = -half, y = -half }, { x = half, y = -half },
            { x = half, y = half }, { x = -half, y = half } }, nil, Config.visual.bound, 1.2)
        for _, entity in ipairs(entities) do
            if entity.entityType == "island" and not entity.removed and isVisible(world, entity) then
                Geometry.WorldCircle(ctx, movement, entity.position, entity.radius, nil, Config.visual.bound, 1.2)
            end
        end
    end
    nvgRestore(ctx)
    PerfProbe.Sample("scene", probeSceneStop())
end

-- Read-only screen-edge view used by Scene and the headless presentation tests.
SeaDraw.BuildCommuterFlockLayout = commuterFlockLayout
-- 俯冲末帧可读性契约（供离线渲染测试直接引用，避免测试里重复写死魔数）。
SeaDraw.BIRD_DIVE_FOLD_MAX = BIRD_DIVE_FOLD_MAX
SeaDraw.BIRD_DIVE_ALTITUDE_MIN_RATIO = BIRD_DIVE_ALTITUDE_MIN_RATIO
SeaDraw.BirdDiveFold = birdDiveFold

return SeaDraw
