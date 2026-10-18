-- BirdSystem（STEP-10）：海鸟 Cruise→Dive→Circle 行为（T4/T5，读海信号链第三段）。
-- T4 契约：海鸟只读 fish.fsm.current=="Flee" + 距离≤15m 发现目标，不修改鱼的核心 FSM。
-- T5 契约：Cruise 6~9m/s → 发现 Flee 目标 → Dive/Circle 共 8~12s → 返回 Cruise。
-- 数值为代码侧演示参数（Config.birdSystem），正式值待 birds.lua 数据契约（B 侧）迁移。
-- FSM 推进归 EntityStateSystem 统一链，与 FishSystem 同构。
local StateMachine = require("FSM.StateMachine")
local Config = require("Ocean.Config")

local BirdSystem = {}

local DEG = math.pi / 180

local function RandRange(min, max)
    return min + math.random() * (max - min)
end

-- 以最短角差逼近目标朝向（速率限制，°/s）——与 FishSystem 同构的本地实现
local function TurnToward(bird, dt, targetHeading, rateDeg)
    local diff = (targetHeading - bird.heading + math.pi) % (2 * math.pi) - math.pi
    local maxStep = rateDeg * DEG * dt
    if math.abs(diff) <= maxStep then
        bird.heading = targetHeading
    else
        bird.heading = bird.heading + (diff > 0 and maxStep or -maxStep)
    end
end

-- 边界回正：海面活动带（与鱼群同带；海鸟不飞进天空/小岛区）
local function SteerIntoBounds(bird)
    local bandMargin = Config.fishSystem.bandMargin
    local keepX = math.cos(bird.heading) >= 0 and 2 or -2
    if bird.position.y > Config.world.seaTopY - bandMargin then
        bird.targetHeading = math.atan(-3, keepX)
    elseif bird.position.y < Config.world.seaBottomY + bandMargin then
        bird.targetHeading = math.atan(3, keepX)
    end
end

-- T4：扫描 Flee 目标（只读鱼的 FSM 状态，不修改）
local function FindFleeingFish(bird)
    local radius = Config.birdSystem.detectionRadius
    local best, bestD2 = nil, radius * radius
    for _, other in ipairs(bird.world:GetEntities()) do
        if other.alive and other.kind == "fish"
            and other.fsm and other.fsm.current == "Flee" then
            local dx = other.position.x - bird.position.x
            local dy = other.position.y - bird.position.y
            local d2 = dx * dx + dy * dy
            if d2 <= bestD2 then
                best, bestD2 = other, d2
            end
        end
    end
    return best
end

local BirdStates = {
    -- Cruise：6~9m/s 巡航，每 3~6s 缓慢换向，持续监听 Flee 目标
    Cruise = {
        enter = function(bird)
            bird.speed = RandRange(Config.birdSystem.cruiseSpeedMin, Config.birdSystem.cruiseSpeedMax)
            bird.retargetTimer = RandRange(Config.birdSystem.cruiseRetargetMin, Config.birdSystem.cruiseRetargetMax)
            bird.targetHeading = bird.heading or 0
        end,
        update = function(bird, dt)
            local target = FindFleeingFish(bird)
            if target then
                bird.target = target
                bird.fsm:Change("Dive")
                return
            end
            bird.retargetTimer = bird.retargetTimer - dt
            if bird.retargetTimer <= 0 then
                bird.retargetTimer = RandRange(Config.birdSystem.cruiseRetargetMin, Config.birdSystem.cruiseRetargetMax)
                bird.targetHeading = bird.heading + (math.random() * 2 - 1) * 90 * DEG
            end
            SteerIntoBounds(bird)
            TurnToward(bird, dt, bird.targetHeading, 180) -- 海鸟转向灵活（演示值）
            local speed = bird.speed
            bird.position.x = bird.position.x + math.cos(bird.heading) * speed * dt
            bird.position.y = bird.position.y + math.sin(bird.heading) * speed * dt
        end,
    },

    -- Dive：朝 Flee 目标俯冲（diveSpeed），距目标 diveArriveRadius 内转盘旋；
    -- actionTimer 为 T5 的 8~12s 总时长（Dive+Circle 共用）
    Dive = {
        enter = function(bird)
            bird.actionTimer = RandRange(Config.birdSystem.actionDurationMin, Config.birdSystem.actionDurationMax)
            bird.circleCenter = nil
        end,
        update = function(bird, dt)
            local target = bird.target
            -- 目标消失或不再逃跑（回 Wander 等）：返回巡航
            if not target or not target.alive
                or not target.fsm or target.fsm.current ~= "Flee" then
                bird.target = nil
                bird.fsm:Change("Cruise")
                return
            end
            bird.actionTimer = bird.actionTimer - dt
            if bird.actionTimer <= 0 then
                bird.target = nil
                bird.fsm:Change("Cruise")
                return
            end
            local dx = target.position.x - bird.position.x
            local dy = target.position.y - bird.position.y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= Config.birdSystem.diveArriveRadius then
                bird.circleCenter = { x = target.position.x, y = target.position.y }
                bird.fsm:Change("Circle")
                return
            end
            bird.targetHeading = math.atan(dy, dx)
            TurnToward(bird, dt, bird.targetHeading, 240) -- 俯冲转向更快（演示值）
            local speed = Config.birdSystem.diveSpeed
            bird.position.x = bird.position.x + math.cos(bird.heading) * speed * dt
            bird.position.y = bird.position.y + math.sin(bird.heading) * speed * dt
        end,
    },

    -- Circle：绕目标点盘旋至 actionTimer 耗尽，随后返回 Cruise
    Circle = {
        enter = function(bird)
            bird.circleAngle = math.atan(
                bird.position.y - bird.circleCenter.y,
                bird.position.x - bird.circleCenter.x)
        end,
        update = function(bird, dt)
            bird.actionTimer = bird.actionTimer - dt
            if bird.actionTimer <= 0 or not bird.circleCenter then
                bird.target = nil
                bird.circleCenter = nil
                bird.fsm:Change("Cruise")
                return
            end
            -- 目标仍在逃跑：盘旋中心每帧跟随目标（绕着移动的鱼转）
            local t = bird.target
            if t and t.alive and t.fsm and t.fsm.current == "Flee" then
                bird.circleCenter = { x = t.position.x, y = t.position.y }
            end
            bird.circleAngle = bird.circleAngle + Config.birdSystem.circleAngularSpeed * dt
            local r = Config.birdSystem.circleRadius
            bird.position.x = bird.circleCenter.x + math.cos(bird.circleAngle) * r
            bird.position.y = bird.circleCenter.y + math.sin(bird.circleAngle) * r
            bird.heading = bird.circleAngle + math.pi / 2 -- 朝切线方向飞行
        end,
    },
}

-- 生成海鸟并挂 FSM；挂 world 引用供 T4 扫描
function BirdSystem.SpawnBirds(world, count)
    for _ = 1, count do
        local bird = world:CreateEntity("bird", {
            position = {
                x = RandRange(-40, 40),
                y = RandRange(Config.world.seaBottomY + 2, Config.world.seaTopY - 2),
            },
        })
        bird.world = world
        bird.heading = math.random() * 2 * math.pi
        bird.fsm = StateMachine.New(BirdStates, "Cruise", bird)
    end
    print(string.format("[海鸟] 初始生成 %d 只海鸟（Cruise，监听 Flee 目标）", count))
end

return BirdSystem
