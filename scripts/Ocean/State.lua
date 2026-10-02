-- 独立于绘图的状态模块，后续可在这里接入任务、钓鱼或航行逻辑。
local Config = require("Ocean.Config")

local State = {}
State.__index = State

function State.New()
    local self = setmetatable({}, State)
    self:Init()
    return self
end

function State:Init()
    self.time = 0
    self.paused = false
    self.boatX = Config.boat.initialX
    self.boatY = Config.boat.initialY
    self.targetX = Config.boat.initialX
    self.targetY = Config.boat.initialY
    print("[海洋框架] 初始化状态：飞鸟 2，鱼群 2，船只 1，小岛 1")
end

function State:Reset()
    self.time = 0
    self.paused = false
    self.boatX = Config.boat.initialX
    self.boatY = Config.boat.initialY
    self.targetX = Config.boat.initialX
    self.targetY = Config.boat.initialY
    print("[海洋框架] 场景已重置")
end

function State:TogglePause()
    self.paused = not self.paused
    print("[海洋框架] " .. (self.paused and "动画已暂停" or "动画已继续"))
end

-- STEP-8 船 2D 化：x/y 双轴目标，各自夹在海面活动范围内
function State:SetTarget(x, y)
    if self.paused then return end
    self.targetX = math.max(Config.boat.minX, math.min(Config.boat.maxX, x))
    y = y or self.targetY
    self.targetY = math.max(Config.boat.minY, math.min(Config.boat.maxY, y))
end

function State:MoveBy(direction)
    self:SetTarget(self.targetX + direction * Config.boat.buttonStep)
end

function State:Update(dt, dirX, dirY)
    if self.paused then return end
    -- 防止切回应用时，一次过大的时间步造成位置跳变。
    local step = math.max(0, math.min(dt, 0.05))
    self.time = self.time + step
    if dirX ~= 0 then
        self:SetTarget(self.targetX + dirX * Config.boat.speed * step)
    end
    if dirY ~= 0 then
        self:SetTarget(self.targetX, self.targetY + dirY * Config.boat.speed * step)
    end
    local blend = 1 - math.exp(-9 * step)
    self.boatX = self.boatX + (self.targetX - self.boatX) * blend
    self.boatY = self.boatY + (self.targetY - self.boatY) * blend
end

return State
