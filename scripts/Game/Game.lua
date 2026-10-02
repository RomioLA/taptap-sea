-- 整局游戏的协调层：连接现有 Ocean 演示状态与可扩展的 World。
local Config = require("Ocean.Config")
local State = require("Ocean.State")
local World = require("Game.World")
local EntityStateSystem = require("Systems.EntityStateSystem")
local ClockSystem = require("Systems.ClockSystem")

local Game = {}
Game.__index = Game

function Game.New()
    local self = setmetatable({}, Game)
    self.state = State.New()
    self.world = World.New()
    -- STEP-5 昼夜时钟：状态挂 world.clock，System 进唯一更新链（每帧只推进一次）。
    self.world.clock = ClockSystem.NewState()
    self.world:AddSystem(ClockSystem)
    self.world:AddSystem(EntityStateSystem)
    -- STEP-5 多来源暂停：reason 集合（"user"=暂停按钮；"port"/"event"/"dialog" 等留给 M1/M3）。
    self.pauseReasons = {}
    -- 渲染/HUD/Draw 经 state 只读时钟（引用共享，Reset 就地重建字段）。
    self.state.clock = self.world.clock
    -- STEP-4 渲染通道验证：调试实体，世界坐标 10m 处（船锚点右侧 10m 应可见同尺寸标记）。
    if Config.debug and Config.debug.spawnTestEntity then
        self.world:CreateEntity("debug_marker", { position = { x = 10, y = 0 } })
    end
    return self
end

function Game:Update(dt, direction)
    -- 演示层仍读 state.paused；由 pauseReasons 集合统一推导。
    self.state.paused = self:IsPaused()
    self.state:Update(dt, direction)
    if not self.state.paused then
        self.world:Update(math.max(0, math.min(dt, 0.05)))
    end
end

-- STEP-5 多来源暂停：任意一个 reason 存在即视为暂停；来源互不覆盖。
function Game:AddPause(reason)
    self.pauseReasons[reason] = true
    self.state.paused = true
end

function Game:RemovePause(reason)
    self.pauseReasons[reason] = nil
    self.state.paused = self:IsPaused()
end

function Game:IsPaused()
    for _ in pairs(self.pauseReasons) do
        return true
    end
    return false
end

function Game:TogglePause()
    if self.pauseReasons.user then
        self.pauseReasons.user = nil
    else
        self.pauseReasons.user = true
    end
    self.state.paused = self:IsPaused()
end

function Game:Reset()
    self.state:Reset()
    self.world:Clear()
    ClockSystem.ResetState(self.world.clock)
    self.pauseReasons = {}
    self.state.paused = false
end

function Game:SetTarget(x)
    self.state:SetTarget(x)
end

function Game:MoveBy(direction)
    self.state:MoveBy(direction)
end

-- STEP-5 时钟只读访问（HUD/调试消费；渲染走 state.clock 引用）。
function Game:GetClock()
    return self.world.clock
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
