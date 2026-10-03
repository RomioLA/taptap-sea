-- B 玩法接线器：宿主初始化 UI 后显式调用 Init，并在自己的 Update 中转交 dt。
local Loop = require("Gameplay.Loop")
local HUD = require("Gameplay.HUD")
local Debug = require("Gameplay.Debug")
local World = require("Game.World")
local UpdateSystem = require("Gameplay.UpdateSystem")

local Bootstrap = {}

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Bootstrap.Init(options)
    local initOptions = options or {}
    local loop = Loop.New(initOptions)
    local world = World.New()
    world:AddSystem(UpdateSystem.New(loop), "frame")
    local development = initOptions.development == true
    local debugTools = Debug.New(loop, development)
    local hud = HUD.Create(loop, initOptions.parent, development and debugTools or nil)
    local stopped = false

    local function Update(dt)
        if stopped then return false, "stopped" end
        if not isFiniteNumber(dt) or dt < 0 then return false, "invalid_dt" end
        world:Update(dt, "frame")
        hud.Refresh()
        return true
    end

    local function Stop()
        if stopped then return end
        if loop.actions then
            local ok, reason = loop.actions:CancelActiveFishing("scene_stopped")
            if not ok then return false, reason end
        end
        stopped = true
        hud.Destroy()
    end

    -- 读取由宿主 store/cloud 注入的每日结算存档；默认云变量实现不创建本地存档。
    if initOptions.loadSaved ~= false then
        loop:LoadSaved(function()
            if not stopped then hud.Refresh() end
        end)
        hud.Refresh()
    end

    return loop, hud, Update, Stop
end

return Bootstrap
