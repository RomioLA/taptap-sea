-- FishSystem（STEP-6/7）：鱼群生成 + FSM 状态定义（Wander/Attracted/Flee）。
-- 数值全部读 scripts/data/fish.lua（DATA_SCHEMA 契约）；本模块不推进 FSM——
-- 所有实体的 fsm:Update 由 EntityStateSystem 在 World 更新链里统一推进，避免双推进。
-- 状态优先级（FEASIBILITY_PLAN）：边界/危险 > 吸引 > Wander（Chase/Avoid 属后续 Step）。
-- 调试信号源：bait/predator 实体由按键生成（Main 调 SpawnDebugBait/Predator），
-- 正式入口=投海道具与 Tuna Chase，落地后本模块的调试生成路径即可退役。
local StateMachine = require("FSM.StateMachine")
local Config = require("Ocean.Config")
local FishData = require("data.fish")

local FishSystem = {}

local SPECIES = {}
for _, def in ipairs(FishData) do
    SPECIES[def.id] = def
end

local DEG = math.pi / 180

local function RandRange(min, max)
    return min + math.random() * (max - min)
end

local function Dist2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end

-- 以最短角差逼近目标朝向（速率限制，°/s）
local function TurnToward(entity, dt, targetHeading, rateDeg)
    local diff = (targetHeading - entity.heading + math.pi) % (2 * math.pi) - math.pi
    local maxStep = rateDeg * DEG * dt
    if math.abs(diff) <= maxStep then
        entity.heading = targetHeading
    else
        entity.heading = entity.heading + (diff > 0 and maxStep or -maxStep)
    end
end

-- 边界回正（STEP-8 扩展）：世界边缘 + 演示视口海面活动带。
-- 鱼游到带边（海面线/小岛上沿）即把目标朝向改指带内，防止"沙丁鱼在天上游"。
local function SteerIntoBounds(entity)
    local half = Config.world.worldSize / 2
    local margin = Config.fishSystem.worldMargin
    if math.abs(entity.position.x) >= half - margin
        or math.abs(entity.position.y) >= half - margin then
        entity.targetHeading = math.atan(-entity.position.y, -entity.position.x)
        return
    end
    local bandMargin = Config.fishSystem.bandMargin
    local keepX = math.cos(entity.heading) >= 0 and 2 or -2 -- 回正时保留水平趋势
    if entity.position.y > Config.world.seaTopY - bandMargin then
        entity.targetHeading = math.atan(-3, keepX)
    elseif entity.position.y < Config.world.seaBottomY + bandMargin then
        entity.targetHeading = math.atan(3, keepX)
    end
end

-- 找半径内最近的指定 kind 实体（当前实体规模 O(n) 遍历无压力）
local function FindNearest(entity, kind, radius)
    local best, bestD2 = nil, radius * radius
    for _, other in ipairs(entity.world:GetEntities()) do
        if other ~= entity and other.alive and other.kind == kind then
            local d2 = Dist2(entity.position, other.position)
            if d2 <= bestD2 then
                best, bestD2 = other, d2
            end
        end
    end
    return best
end

-- 感知决策：危险 > 吸引；鱼种缺对应感知字段时跳过该路
local function Sense(entity, def)
    if def.sense.danger then
        local predator = FindNearest(entity, "predator", def.sense.danger)
        if predator then
            entity.dangerSource = predator
            entity.fsm:Change("Flee")
            return true
        end
    end
    if def.sense.attract then
        local bait = FindNearest(entity, "bait", def.sense.attract)
        if bait then
            entity.baitTarget = bait
            entity.fsm:Change("Attracted")
            return true
        end
    end
    return false
end

-- Wander：通用实现（各鱼种按自己的 speeds.wander / turnRate 驱动）。
-- 读海规范：Wander = 无水面信号，本状态不产生任何涟漪/水花。
local FishStates = {
    Wander = {
        enter = function(entity)
            entity.retargetTimer = RandRange(Config.fishSystem.wanderRetargetMin, Config.fishSystem.wanderRetargetMax)
            entity.targetHeading = entity.heading or 0
        end,
        update = function(entity, dt)
            local def = SPECIES[entity.fishKey]
            if not def then return end
            -- 每帧感知：危险/诱饵进入半径即切换状态
            if def.sense and Sense(entity, def) then return end
            entity.retargetTimer = entity.retargetTimer - dt
            if entity.retargetTimer <= 0 then
                entity.retargetTimer = RandRange(Config.fishSystem.wanderRetargetMin, Config.fishSystem.wanderRetargetMax)
                -- 相对当前朝向 ±120° 内偏转，不做瞬间掉头
                entity.targetHeading = entity.heading + (math.random() * 2 - 1) * 120 * DEG
            end
            SteerIntoBounds(entity)
            TurnToward(entity, dt, entity.targetHeading, def.turnRate)
            local speed = def.speeds.wander
            entity.position.x = entity.position.x + math.cos(entity.heading) * speed * dt
            entity.position.y = entity.position.y + math.sin(entity.heading) * speed * dt
        end,
    },

    -- Attracted：朝诱饵游（speeds.attracted），聚集涟漪为读海信号（R1）
    Attracted = {
        enter = function(entity)
            entity.rippleTimer = 0 -- 聚集涟漪相位（表现层 EntityDraw 读）
        end,
        update = function(entity, dt)
            local def = SPECIES[entity.fishKey]
            if not def then return end
            -- 危险优先于吸引：感知半径内出现捕食者立即转 Flee
            if def.sense.danger then
                local predator = FindNearest(entity, "predator", def.sense.danger)
                if predator then
                    entity.dangerSource = predator
                    entity.fsm:Change("Flee")
                    return
                end
            end
            local bait = entity.baitTarget
            if not bait or not bait.alive then
                entity.fsm:Change("Wander")
                return
            end
            local dx = bait.position.x - entity.position.x
            local dy = bait.position.y - entity.position.y
            local dist = math.sqrt(dx * dx + dy * dy)
            entity.targetHeading = math.atan(dy, dx)
            TurnToward(entity, dt, entity.targetHeading, def.turnRate)
            -- 到达减速聚集：距诱饵 baitContact 内降到 30% 速度，成团不穿模
            local speed = def.speeds.attracted
            if dist < Config.fishSystem.baitContact then
                speed = speed * 0.3
            end
            entity.position.x = entity.position.x + math.cos(entity.heading) * speed * dt
            entity.position.y = entity.position.y + math.sin(entity.heading) * speed * dt
            entity.rippleTimer = entity.rippleTimer + dt
        end,
    },

    -- Flee：T1 上浮剪影 2s（不水平移动）→ 出水水花 → speeds.flee 远离危险源
    Flee = {
        enter = function(entity)
            entity.riseTimer = Config.fishSystem.fleeRiseSeconds
            entity.depth = 0       -- 0 水下 → 1 水面（表现层读）
            entity.splashTimer = 0 -- 出水水花剩余时间（表现层读）
            entity.steerTimer = 0
            entity.targetHeading = entity.heading or 0
        end,
        update = function(entity, dt)
            local def = SPECIES[entity.fishKey]
            if not def then return end
            -- T1 上浮阶段：depth 渐近 1，原地剪影，结束后打水花
            if entity.riseTimer > 0 then
                entity.riseTimer = entity.riseTimer - dt
                entity.depth = 1 - math.max(0, entity.riseTimer) / Config.fishSystem.fleeRiseSeconds
                if entity.riseTimer <= 0 then
                    entity.riseTimer = 0
                    entity.splashTimer = 0.6
                end
                return
            end
            local danger = entity.dangerSource
            if not danger or not danger.alive then
                entity.fsm:Change("Wander")
                return
            end
            -- 每 steerInterval 秒在「远离危险」方向 ±steerDeviation 内重新定向
            entity.steerTimer = entity.steerTimer - dt
            if entity.steerTimer <= 0 then
                entity.steerTimer = def.avoid.steerInterval
                local away = math.atan(
                    entity.position.y - danger.position.y,
                    entity.position.x - danger.position.x)
                local dev = (math.random() * 2 - 1) * def.avoid.steerDeviation * DEG
                entity.targetHeading = away + dev
            end
            SteerIntoBounds(entity) -- 边界优先级高于危险方向
            TurnToward(entity, dt, entity.targetHeading, def.turnRate)
            local speed = def.speeds.flee
            entity.position.x = entity.position.x + math.cos(entity.heading) * speed * dt
            entity.position.y = entity.position.y + math.sin(entity.heading) * speed * dt
            if entity.splashTimer > 0 then
                entity.splashTimer = math.max(0, entity.splashTimer - dt)
            end
            -- 游出安全距离解除警报
            local calm = Config.fishSystem.fleeCalmDistance
            if Dist2(entity.position, danger.position) > calm * calm then
                entity.fsm:Change("Wander")
            end
        end,
        exit = function(entity)
            entity.depth = 0
            entity.riseTimer = 0
        end,
    },
}

-- 生成一条鱼并挂 FSM；挂 world 引用供感知查询，离船约束由调用方保证
function FishSystem.SpawnFish(world, speciesId, position)
    local entity = world:CreateEntity("fish", { position = position })
    entity.fishKey = speciesId
    entity.world = world
    entity.heading = math.random() * 2 * math.pi
    entity.fsm = StateMachine.New(FishStates, "Wander", entity)
    return entity
end

-- STEP-6 初始沙丁鱼群：在海面活动带内随机分布（离船 ≥15m，参数表「区域生成防贴脸」）。
-- STEP-8：带内生成，防止开局就有鱼出现在画面上方的天空区。
function FishSystem.SpawnSardines(world, count, center)
    center = center or { x = 0, y = 0 }
    local def = SPECIES.sardine
    local top = Config.world.seaTopY - 2
    local bottom = Config.world.seaBottomY + 2
    for _ = 1, count do
        local x, y
        for _ = 1, 20 do -- 拒绝采样：落在离船 15m 内则重抽
            x = center.x + RandRange(-35, 35)
            y = center.y + RandRange(bottom - center.y, top - center.y)
            local dx, dy = x - center.x, y - center.y
            if dx * dx + dy * dy >= def.spawn.minDistFromBoat ^ 2 then break end
        end
        FishSystem.SpawnFish(world, "sardine", { x = x, y = y })
    end
    print(string.format("[鱼群] 初始生成 %d 条沙丁鱼（Wander，海面带内，离船≥%dm）",
        count, def.spawn.minDistFromBoat))
end

-- STEP-7/8 调试信号源：诱饵（Attracted 触发）与捕食者（Flee 触发，Tuna Chase 替身）。
-- 生成位置夹在海面活动带内，保证信号出现在海里。
local function ClampToBand(y)
    local top = Config.world.seaTopY - 2
    local bottom = Config.world.seaBottomY + 2
    return math.max(bottom, math.min(top, y))
end

function FishSystem.SpawnBait(world, position)
    position = { x = position.x, y = ClampToBand(position.y) }
    local entity = world:CreateEntity("bait", { position = position })
    entity.ttl = Config.fishSystem.baitTtl
    print(string.format("[鱼群] 生成诱饵 (%.1f, %.1f)m，%ds 后消散",
        position.x, position.y, entity.ttl))
    return entity
end

function FishSystem.SpawnPredator(world, position)
    position = { x = position.x, y = ClampToBand(position.y) }
    local entity = world:CreateEntity("predator", { position = position })
    print(string.format("[鱼群] 生成捕食者 (%.1f, %.1f)m", position.x, position.y))
    return entity
end

-- System 契约（World:AddSystem 调度）：诱饵倒计时，过期移除后感知自动解除
function FishSystem:Update(world, dt)
    for _, entity in ipairs(world:GetEntities()) do
        if entity.alive and entity.kind == "bait" then
            entity.ttl = entity.ttl - dt
            if entity.ttl <= 0 then
                world:RemoveEntity(entity.id)
                print("[鱼群] 诱饵消散，附近鱼群回 Wander")
            end
        end
    end
end

return FishSystem
