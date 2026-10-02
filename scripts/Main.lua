-- 海风小岛：基于 templates/scaffold-2d.lua 的轻量 2D 项目框架。
-- 层次：飞鸟 → 海浪与鱼群 → 船只 → 小岛。
-- 操作：WASD/方向键在海面任意移动（点击海面也可），空格暂停，R 重置。
-- STEP-7/8 调试信号：B=在最近点击处放诱饵（触发 Attracted），N=放捕食者（触发 Flee）；
-- 屏幕按钮同效（诱饵/捕食者）。
local UI = require("urhox-libs/UI")
local Config = require("Ocean.Config")
local Camera = require("Ocean.Camera")
local Game = require("Game.Game")
local Draw = require("Ocean.Draw")
local HUD = require("Ocean.HUD")

-- 启动自检（STEP-2 数据加载验证）：确认根目录 data/ 数据表可被运行时 require。
-- data/ 为纯数据表（DATA_SCHEMA 契约），加载失败只报警不阻断启动。
-- 结果同时写入 HUD 诊断行（Maker 预览无控制台日志，屏幕可见优先）。
local dataCheckText = "数据自检未运行"
do
    local okFish, fishData = pcall(require, "data.fish")
    local okItems, itemsData = pcall(require, "data.items")
    local fishInfo = okFish and (#fishData .. "种") or ("失败:" .. tostring(fishData):sub(1, 60))
    local itemsInfo = okItems and (#itemsData .. "种") or ("失败:" .. tostring(itemsData):sub(1, 60))
    dataCheckText = string.format("数据自检 fish=%s(%s) items=%s(%s)",
        tostring(okFish), fishInfo, tostring(okItems), itemsInfo)
    print("[数据自检] " .. dataCheckText)
end

---@type NVGContextWrapper?
local oceanContext = nil
local game = Game.New()
---@type { togglePause: function, reset: function, refresh: function }?
local hud = nil
local lastWidth, lastHeight = 0, 0
local firstFrame = true

function Start()
    graphics.windowTitle = Config.title
    input.mouseMode = MM_ABSOLUTE
    input.mouseVisible = true
    print("[海洋框架] 开始初始化")

    oceanContext = nvgCreate(1)
    if not oceanContext then
        print("[海洋框架] 错误：无法创建场景绘图上下文")
        return
    end
    -- 场景先绘制，UI 组件由引擎随后绘制，避免层级冲突。
    nvgSetRenderOrder(oceanContext, 0)
    UI.Init({
        theme = "default-taptap",
        scale = UI.Scale.DEFAULT,
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/MiSans-Regular.ttf",
                bold = "Fonts/MiSans-Regular.ttf",
            } },
        },
    })
    hud = HUD.Create(game)
    if hud.updateDiagnostics then
        hud.updateDiagnostics(dataCheckText .. " | 点击: -")
    end
    SubscribeToEvent(oceanContext, "NanoVGRender", "HandleOceanRender")
    SubscribeToEvent("Update", "HandleOceanUpdate")
    SubscribeToEvent("KeyDown", "HandleOceanKeyDown")
    SubscribeToEvent("MouseButtonDown", "HandleOceanMouseDown")
    SubscribeToEvent("TouchBegin", "HandleOceanTouchBegin")
    print("[海洋框架] 初始化完成")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleOceanUpdate(eventType, eventData)
    -- STEP-8 船 2D 化：WASD/方向键双轴移动（屏幕 y 向下，故上键为 -1）
    local dirX, dirY = 0, 0
    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        dirX = dirX - 1
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        dirX = dirX + 1
    end
    if input:GetKeyDown(KEY_W) or input:GetKeyDown(KEY_UP) then
        dirY = dirY - 1
    end
    if input:GetKeyDown(KEY_S) or input:GetKeyDown(KEY_DOWN) then
        dirY = dirY + 1
    end
    game:Update(eventData:GetFloat("TimeStep"), dirX, dirY)
    -- STEP-5 昼夜倒计时上屏（文本变化时才重排，见 HUD.Tick）
    if hud and hud.tick then hud.tick() end
end

---@param eventType string
---@param eventData VariantMap
function HandleOceanRender(eventType, eventData)
    if not oceanContext then return end
    local physW, physH = graphics:GetWidth(), graphics:GetHeight()
    if physW <= 0 or physH <= 0 then return end
    local dpr = math.max(graphics:GetDPR(), 0.1)
    local w, h = physW / dpr, physH / dpr
    if physW ~= lastWidth or physH ~= lastHeight then
        lastWidth, lastHeight = physW, physH
        print(string.format("[海洋框架] 画面 %dx%d，DPR %.2f，逻辑尺寸 %.1fx%.1f", physW, physH, dpr, w, h))
    end
    -- 模式 B：系统逻辑分辨率，响应式比例布局；不用 graphics:SetMode。
    nvgBeginFrame(oceanContext, w, h, dpr)
    Draw.Scene(oceanContext, w, h, game:GetRenderState(), game:GetRenderWorld())
    nvgEndFrame(oceanContext)
    if firstFrame then
        firstFrame = false
        print("[海洋框架] 首帧绘制完成")
    end
end

-- STEP-3 米制坐标基座（STEP-6 修正：换算统一走 Ocean.Camera）：
-- 最小镜头模型（参数表「船镜头」）：正交视高 45m（正方形像素），
-- 世界原点 = 船初始位置的锚点，不随船移动（船动过之后点击坐标依然准确）。
local function ScreenPointToWorldMeters(screenX, screenY)
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    if width <= 0 or height <= 0 then return nil, nil end
    local dpr = math.max(graphics:GetDPR(), 0.1)
    local logicalW, logicalH = width / dpr, height / dpr
    return Camera.ScreenToWorld(logicalW, logicalH, game:GetRenderState(),
        screenX / dpr, screenY / dpr)
end

local function MoveToScreenPoint(x, y)
    if game:IsPaused() then return end
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    if width <= 0 or height <= 0 then return end
    -- 仅海面接收点击，顶部标题与底部按钮不触发移动。
    local ratioY = y / height
    if ratioY < 0.36 or ratioY > 0.78 then return end
    if UI.IsPointerOverUI() then return end
    -- STEP-8 船 2D 化：点击点即双轴目标
    game:SetTarget(x / width, y / height)
    local worldX, worldY = ScreenPointToWorldMeters(x, y)
    if worldX then
        local dpr = math.max(graphics:GetDPR(), 0.1)
        local logicalW, logicalH = width / dpr, height / dpr
        local state = game:GetRenderState()
        local dxMeters = worldX - Camera.BoatWorldX(state, logicalW, logicalH)
        local dyMeters = worldY - Camera.BoatWorldY(state, logicalH)
        local dist = math.sqrt(dxMeters ^ 2 + dyMeters ^ 2)
        -- STEP-7：记录最近点击的世界坐标，B/N 调试信号源生成于此
        game.lastClickWorld = { x = worldX, y = worldY }
        local clickText = string.format("点击 (%.1f, %.1f)m 距船 %.1fm", worldX, worldY, dist)
        print(string.format("[米制坐标] %s", clickText))
        if hud and hud.updateDiagnostics then
            hud.updateDiagnostics(dataCheckText .. " | " .. clickText)
        end
    end
    print(string.format("[海洋框架] 船只目标位置 %.2f", game:GetTargetX()))
end

---@param eventType string
---@param eventData MouseButtonDownEventData
function HandleOceanMouseDown(eventType, eventData)
    if eventData:GetInt("Button") ~= MOUSEB_LEFT then return end
    local point = input:GetMousePosition()
    MoveToScreenPoint(point.x, point.y)
end

---@param eventType string
---@param eventData TouchBeginEventData
function HandleOceanTouchBegin(eventType, eventData)
    MoveToScreenPoint(eventData:GetInt("X"), eventData:GetInt("Y"))
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleOceanKeyDown(eventType, eventData)
    if not hud or eventData:GetBool("Repeat") then return end
    local key = eventData:GetInt("Key")
    if key == KEY_SPACE then hud.togglePause() end
    if key == KEY_R then hud.reset() end
    -- STEP-7 调试信号源：先点海面选位置，再按键生成（默认船首前方 12m）
    if key == KEY_B then
        game:SpawnDebugBait(game.lastClickWorld or { x = 12, y = 0 })
    end
    if key == KEY_N then
        game:SpawnDebugPredator(game.lastClickWorld or { x = 12, y = 0 })
    end
end

function Stop()
    UnsubscribeFromEvent("Update")
    UnsubscribeFromEvent("KeyDown")
    UnsubscribeFromEvent("MouseButtonDown")
    UnsubscribeFromEvent("TouchBegin")
    if oceanContext then
        UnsubscribeFromEvent(oceanContext, "NanoVGRender")
        nvgDelete(oceanContext)
        oceanContext = nil
    end
    UI.Shutdown()
    hud = nil
    print("[海洋框架] 场景资源已释放")
end
