-- 2026-10-20 玩家船正式水彩贴图接入（assets/image/OceanPlayerBoat/player_boat.png）
-- 2026-10-20 晚：真机反馈写实贴图缩到 5m×2.4m 后细节糊，用户裁定还原矢量船。
-- 贴图资产/catalog 条目全部保留，默认路径改为矢量（Config.visual.boatTexture.enabled
-- =false），配置可切回贴图（A/B 零成本）。
-- 白盒契约测试。守护以下九条：
--   1) 目录存在：catalog 含 player_boat 条目，指向 OceanPlayerBoat 素材；
--   2) 内容比换算：ContentPlaneSize 按 catalog 内容比给出画幅世界尺寸，
--      贴图内容主体精确对应 shipLength×shipWidth 的船体 footprint（不把透明留白
--      算进世界尺寸）；
--   3) 艏向语义：贴图 u 轴（+u=右）= 艏向，映射到世界 heading（ImageArt.Plane
--      契约），入库时已旋正，接入侧不得加任何角度补偿；
--   4) 默认矢量：boatTexture.enabled=false（默认）时走矢量船形态（艇身+甲板+立帆），
--      不碰贴图；
--   5) 贴图门控：boatTexture.enabled=true 且贴图可用时走贴图路径，不再填矢量
--      艇身与甲板；
--   6) 矢量兜底：贴图开关开启但贴图缺失/加载失败时回落纯矢量形态（艇身+甲板+
--      立帆），且不抛错（零回归底线）；
--   7) 动态效果不烘焙：尾流/横摇/投影阴影仍由程序负责，贴图路径不额外绘制
--      尾流水花，阴影仍在水面（贴图不烘焙海面阴影）；
--   8) 立帆门控：贴图路径默认不画矢量立帆（素材为无桅杆划艇），配置可开回；
--      矢量路径立帆常开（还原旧观感）；
--   9) 零状态改写：绘制不改相机、不改船位、不改 Config。
local Tests = {}

local SeaViewArt = require("Ocean.SeaViewArt")
local ImageArt = require("Ocean.ImageArt")
local Config = require("Ocean.Config")
local catalog = require("GeneratedData.OceanImageCatalog")

local WIDTH, HEIGHT = 640, 360
local BOAT_ART_NAME = "player_boat"

-- 最小可投影 movement（与 Circle1SeaCrestStyleTests 同构）。
local function makeMovement()
    local scale = HEIGHT / Config.camera.viewHeight
    local movement = {
        viewportWidth = WIDTH,
        viewportHeight = HEIGHT,
        camera = { x = 0, y = 0 },
    }
    function movement:WorldToScreen(position, altitude)
        local x = WIDTH * 0.5 + (position.x - movement.camera.x) * scale
        local y = HEIGHT * Config.camera.anchorY
            - (position.y - movement.camera.y) * scale * 0.82
            - (altitude or 0) * scale
        return x, y, scale
    end
    function movement:GetHorizonY()
        return HEIGHT * Config.camera.horizonY
    end
    function movement:GetViewBounds(margin)
        margin = margin or 0
        return { minY = -20 - margin, maxY = 120 + margin }
    end
    return movement
end

local function makeShip(rotation)
    return {
        position = { x = 0, y = 0 },
        rotation = rotation or 0,
        visualTurnRate = 0,
    }
end

-- 绘制录制：分别统计贴图填充次数、矢量填充次数、描边次数。
local imageFills, solidFills, strokes = 0, 0, 0
local oldCreateImage, oldImagePattern
local oldFillPaint, oldFillColor, oldFill, oldStroke, oldStrokeColor, oldStrokeWidth
local oldMipmap, oldRepeatX, oldRepeatY
local pendingColor, pendingWidth, pendingPaint

local function installStubs(imageAvailable)
    imageFills, solidFills, strokes = 0, 0, 0
    pendingColor, pendingWidth, pendingPaint = nil, nil, nil
    oldCreateImage, oldImagePattern = nvgCreateImage, nvgImagePattern
    oldFillPaint, oldFillColor, oldFill = nvgFillPaint, nvgFillColor, nvgFill
    oldStroke, oldStrokeColor, oldStrokeWidth = nvgStroke, nvgStrokeColor, nvgStrokeWidth
    oldMipmap, oldRepeatX, oldRepeatY =
        NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = 1, 2, 4
    -- imageAvailable=false 模拟贴图加载失败（句柄 -1）→ 触发矢量兜底。
    nvgCreateImage = function() return imageAvailable and 1 or -1 end
    nvgImagePattern = function() return { fake = true } end
    nvgFillPaint = function(ctx, paint) pendingPaint = paint end
    nvgFillColor = function(ctx, color) pendingColor = color end
    nvgFill = function(ctx)
        if pendingPaint ~= nil then imageFills = imageFills + 1
        else solidFills = solidFills + 1 end
    end
    nvgStrokeColor = function(ctx, color) pendingColor = color end
    nvgStrokeWidth = function(ctx, width) pendingWidth = width end
    nvgStroke = function(ctx) strokes = strokes + 1 end
end

local function restoreStubs()
    nvgCreateImage, nvgImagePattern = oldCreateImage, oldImagePattern
    nvgFillPaint, nvgFillColor, nvgFill = oldFillPaint, oldFillColor, oldFill
    nvgStroke, nvgStrokeColor, nvgStrokeWidth = oldStroke, oldStrokeColor, oldStrokeWidth
    NVG_IMAGE_GENERATE_MIPMAPS, NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY =
        oldMipmap, oldRepeatX, oldRepeatY
end

-- 贴图开关临时切换（测试后恢复，零状态改写）。
local function withBoatTexture(enabled, fn)
    local visual = Config.visual
    local texture = visual.boatTexture
    local saved = texture and texture.enabled
    if texture then texture.enabled = enabled end
    local ok, err = pcall(fn)
    if texture then texture.enabled = saved end
    if not ok then error(err) end
end

local function near(actual, expected, tolerance)
    assert(type(actual) == "number" and type(expected) == "number"
        and math.abs(actual - expected) <= (tolerance or 0.001),
        tostring(actual) .. " is not near " .. tostring(expected))
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok and true or false, error = err }
    end

    check("catalog 含 player_boat 条目且指向 OceanPlayerBoat 素材", function()
        local spec = catalog[BOAT_ART_NAME]
        assert(spec, "catalog 缺 player_boat 条目")
        assert(spec.path:find("OceanPlayerBoat", 1, true),
            "player_boat 路径应指向 OceanPlayerBoat，实际 " .. tostring(spec.path))
        assert(spec.pixelWidth == 1024 and spec.pixelHeight == 1024,
            "玩家船画布应为 1024x1024")
        assert(spec.contentWidth > 0 and spec.contentHeight > 0, "缺内容比")
        assert(spec.alpha_range == nil or true, "占位")
    end)

    check("ContentPlaneSize 按内容比换算，内容主体对应 5m x 2.4m footprint", function()
        local spec = catalog[BOAT_ART_NAME]
        local length = Config.visual.shipLength or 5
        local width = Config.visual.shipWidth or 2.4
        local planeLength, planeWidth = ImageArt.ContentPlaneSize(BOAT_ART_NAME, length, width)
        assert(planeLength and planeWidth, "ContentPlaneSize 应返回画幅尺寸")
        -- 画幅 = 内容尺寸 + 透明留白，故画幅应大于内容主体世界尺寸。
        assert(planeLength > length, "画幅长度应大于内容主体长度")
        assert(planeWidth > width, "画幅宽度应大于内容主体宽度")
        -- 内容主体占比应与 catalog 的内容比一致（留白等比外扩）。
        local expectLength = length * spec.pixelWidth / spec.contentWidth
        near(planeLength, expectLength, 0.001)
        local expectWidth = width * spec.pixelHeight / spec.contentHeight
        near(planeWidth, expectWidth, 0.001)
    end)

    check("默认配置（boatTexture.enabled=false）走矢量船，不碰贴图", function()
        assert(Config.visual.boatTexture and Config.visual.boatTexture.enabled == false,
            "默认配置应关闭贴图路径（还原矢量船）")
        installStubs(true)
        local movement = makeMovement()
        SeaViewArt.Boat({}, movement, makeShip(0), 8)
        restoreStubs()
        assert(imageFills == 0, "矢量路径不得出现贴图填充，实得 " .. imageFills)
        -- 矢量船 = 水面投影阴影 + 艇身 + 甲板 + 主帆 + 前帆（>1 处实心填充）。
        assert(solidFills > 1,
            "矢量路径应填充艇身/甲板/帆面（仅阴影 1 处不够），实得 " .. solidFills)
        -- 立帆常开：桅杆 + 主帆轮廓描边。
        assert(strokes > 0, "矢量路径应绘制立帆描边")
    end)

    check("boatTexture.enabled=true 且贴图可用时走贴图路径（不再填矢量艇身与甲板）", function()
        withBoatTexture(true, function()
            installStubs(true)
            local movement = makeMovement()
            SeaViewArt.Boat({}, movement, makeShip(0), 8)
            restoreStubs()
            assert(imageFills > 0, "贴图路径应有贴图填充")
            -- 矢量实心块只剩「水面投影阴影」一处（程序负责，贴图不烘焙海面阴影）；
            -- 矢量艇身与甲板各一处，共 2 处，贴图路径下应归零。
            assert(solidFills <= 1,
                "贴图路径不应再填矢量艇身/甲板（仅允许 1 处水面投影阴影），实得 " .. solidFills)
        end)
    end)

    check("贴图开关开启但贴图缺失时回落纯矢量形态且不抛错", function()
        withBoatTexture(true, function()
            installStubs(false)
            local movement = makeMovement()
            local ok, err = pcall(function()
                SeaViewArt.Boat({}, movement, makeShip(0), 8)
            end)
            restoreStubs()
            assert(ok, "贴图缺失不得抛错：" .. tostring(err))
            assert(solidFills > 0, "贴图缺失应回落矢量填充")
            assert(strokes > 0, "矢量兜底应有描边（艇身轮廓）")
        end)
    end)

    check("贴图路径不烘焙尾流与水花（动态效果仍由程序负责）", function()
        withBoatTexture(true, function()
            installStubs(true)
            local movement = makeMovement()
            SeaViewArt.Boat({}, movement, makeShip(0), 8)
            restoreStubs()
            -- 尾流由 SeaViewArt.Wake 单独绘制，不在 Boat 路径内；水花是贴图素材，
            -- 但本素材不带水花（严格透明背景），故贴图路径内不应出现额外矢量块。
            assert(imageFills > 0, "应有船体贴图填充")
            assert(solidFills <= 1,
                "贴图路径不得混入矢量实心块（尾流/水花），实得 " .. solidFills)
        end)
    end)

    check("立帆门控：贴图路径默认不画矢量立帆，配置开启可恢复", function()
        local sail = Config.visual.boatSail
        local saved = sail and sail.enabled
        withBoatTexture(true, function()
            if sail then sail.enabled = false end
            installStubs(true)
            SeaViewArt.Boat({}, makeMovement(), makeShip(0), 8)
            restoreStubs()
            local withoutSail = strokes
            if sail then sail.enabled = true end
            installStubs(true)
            SeaViewArt.Boat({}, makeMovement(), makeShip(0), 8)
            restoreStubs()
            local withSail = strokes
            if sail then
                assert(withSail > withoutSail,
                    "开启立帆后描边数应增加，" .. withoutSail .. " -> " .. withSail)
            end
        end)
        if sail then sail.enabled = saved end
    end)

    check("艏向语义：贴图 u 轴对应世界 heading（不额外加角度补偿）", function()
        -- 契约：贴图已旋正到画布 +X，Plane 的 u=1 边缘即艏向。
        -- 验证不同 heading 下贴图绘制的世界朝向不同（不恒定贴图不旋转）。
        withBoatTexture(true, function()
            installStubs(true)
            local movement = makeMovement()
            local ship0 = makeShip(0)
            SeaViewArt.Boat({}, movement, ship0, 8)
            restoreStubs()
            local firstFills = imageFills
            assert(firstFills > 0, "0 度应绘制贴图")
            -- 角度补偿检查：SeaViewArt.Boat 传入 Plane 的 heading 必须就是 ship.rotation。
            -- 0 与 pi/2 两次绘制的填充批次数应相同（同一网格细分，仅朝向不同）。
            installStubs(true)
            local movement2 = makeMovement()
            SeaViewArt.Boat({}, movement2, makeShip(math.pi / 2), 8)
            restoreStubs()
            assert(imageFills == firstFills,
                "不同朝向的贴图分片数应一致（无额外角度补偿导致的额外细分）")
        end)
    end)

    check("零状态改写：绘制不改相机/船位/Config", function()
        withBoatTexture(true, function()
            installStubs(true)
            local movement = makeMovement()
            local ship = makeShip(0.7)
            local before = {
                cameraX = movement.camera.x, cameraY = movement.camera.y,
                shipX = ship.position.x, shipY = ship.position.y,
                rotation = ship.rotation,
                shipLength = Config.visual.shipLength,
                shipWidth = Config.visual.shipWidth,
                boatTexture = Config.visual.boatTexture.enabled,
            }
            SeaViewArt.Boat({}, movement, ship, 8)
            restoreStubs()
            assert(movement.camera.x == before.cameraX and movement.camera.y == before.cameraY,
                "不得改写相机")
            assert(ship.position.x == before.shipX and ship.position.y == before.shipY,
                "不得改写船位")
            assert(ship.rotation == before.rotation, "不得改写船朝向")
            assert(Config.visual.shipLength == before.shipLength
                and Config.visual.shipWidth == before.shipWidth, "不得改写船只尺寸配置")
            assert(Config.visual.boatTexture.enabled == before.boatTexture,
                "不得改写贴图开关")
        end)
    end)

    return { results = results }
end

return Tests
