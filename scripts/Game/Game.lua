-- 整局游戏的协调层：连接现有 Ocean 演示状态与可扩展的 World。
local Config = require("Ocean.Config")
local State = require("Ocean.State")
local World = require("Game.World")
local EntityStateSystem = require("Systems.EntityStateSystem")

local Game = {}
Game.__index = Game

function Game.New()
    local self = setmetatable({}, Game)
    self.state = State.New()
    self.world = World.New()
    self.world:AddSystem(EntityStateSystem)
    -- STEP-4 渲染通道验证：调试实体，世界坐标 10m 处（船锚点右侧 10m 应可见同尺寸标记）。
    if Config.debug and Config.debug.spawnTestEntity then
        self.world:CreateEntity("debug_marker", { position = { x = 10, y = 0 } })
    end
    return self
end

function Game:Update(dt, direction)
    local wasPaused = self.state.paused
    self.state:Update(dt, direction)
    if not wasPaused then
        self.world:Update(math.max(0, math.min(dt, 0.05)))
    end
end

function Game:TogglePause()
    self.state:TogglePause()
end

function Game:Reset()
    self.state:Reset()
    self.world:Clear()
end

function Game:SetTarget(x)
    self.state:SetTarget(x)
end

function Game:MoveBy(direction)
    self.state:MoveBy(direction)
end

function Game:IsPaused()
    return self.state.paused
end

function Game:GetTargetX()
    return self.state.targetX
end

-- 渲染层只读取现有演示状态，不直接改写 World 或 Entity。
function Game:GetRenderState()
    return self.state
end

-- STEP-4 渲染通道：World 实体的只读渲染入口（EntityDraw 消费，禁止反向修改）。
function Game:GetRenderWorld()
    return self.world
end

return Game
