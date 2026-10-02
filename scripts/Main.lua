-- 海风小岛：基于 templates/scaffold-2d.lua 的轻量 2D 项目框架。
-- 层次：飞鸟 → 海浪与鱼群 → 船只 → 小岛。
-- 操作：A/D 或方向键移动，空格暂停，R 重置；点击海面也可移动船只。
local UI = require("urhox-libs/UI")
local Config = require("Ocean.Config")
local Game = require("Game.Game")
local Draw = require("Ocean.Draw")
local HUD = require("Ocean.HUD")

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
    Draw.Scene(oceanContext, w, h, game:GetRenderState())
    nvgEndFrame(oceanContext)
    if firstFrame then
        firstFrame = false
        print("[海洋框架] 首帧绘制完成")
    end
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
