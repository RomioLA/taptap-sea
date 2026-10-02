-- 海风小岛：基于 templates/scaffold-2d.lua 的轻量 2D 项目框架。
-- 层次：飞鸟 → 海浪与鱼群 → 船只 → 小岛。
-- 操作：A/D 或方向键移动，空格暂停，R 重置；点击海面也可移动船只。
local UI = require("urhox-libs/UI")
local Config = require("Ocean.Config")
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
    local direction = 0
    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        direction = direction - 1
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        direction = direction + 1
    end
    game:Update(eventData:GetFloat("TimeStep"), direction)
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

-- STEP-3 米制坐标基座：屏幕点 → 世界米制坐标。
-- 最小镜头模型（参数表「船镜头」）：正交视高 45m（正方形像素），船锚点比例 (boatX, 0.60)。
-- M0 接入真实船世界坐标后，原点替换为船的世界位置；当前以船锚点为临时原点 (0,0)。
local function ScreenPointToWorldMeters(screenX, screenY)
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    if width <= 0 or height <= 0 then return nil, nil end
    local dpr = math.max(graphics:GetDPR(), 0.1)
    local logicalW, logicalH = width / dpr, height / dpr
    local metersPerLogicalPixel = Config.world.viewHeight / logicalH
    local state = game:GetRenderState()
    local anchorX = logicalW * (state and state.boatX or 0.5)
    local anchorY = logicalH * 0.60
    local dx = screenX / dpr - anchorX
    local dy = screenY / dpr - anchorY
    return dx * metersPerLogicalPixel, -dy * metersPerLogicalPixel
end

local function MoveToScreenPoint(x, y)
    if game:IsPaused() then return end
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    if width <= 0 or height <= 0 then return end
    -- 仅海面中部接收点击，顶部标题与底部按钮不触发移动。
    local ratioY = y / height
    if ratioY < 0.36 or ratioY > 0.76 then return end
    if UI.IsPointerOverUI() then return end
    game:SetTarget(x / width)
    local worldX, worldY = ScreenPointToWorldMeters(x, y)
    if worldX then
        local dist = math.sqrt(worldX * worldX + worldY * worldY)
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
