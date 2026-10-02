-- FishSystem（STEP-6）：鱼群生成 + Wander 行为定义。
-- 数值全部读 scripts/data/fish.lua（DATA_SCHEMA 契约）；本模块不推进 FSM——
-- 所有实体的 fsm:Update 由 EntityStateSystem 在 World 更新链里统一推进，避免双推进。
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

-- 世界边缘回正：临近边界时把目标朝向指向世界中心（推回 3m/s 属 M0 世界规则，此处仅转向）
local function SteerAwayFromEdge(entity)
    local half = Config.world.worldSize / 2
    local margin = Config.fish.worldMargin
    if math.abs(entity.position.x) < half - margin
        and math.abs(entity.position.y) < half - margin then
        return
    end
    entity.targetHeading = math.atan(-entity.position.y, -entity.position.x)
end

-- Wander：通用实现（各鱼种按自己的 speeds.wander / turnRate 驱动）。
-- 读海规范：Wander = 无水面信号，本状态不产生任何涟漪/水花。
local WanderStates = {
    Wander = {
        enter = function(entity)
            entity.retargetTimer = RandRange(Config.fish.wanderRetargetMin, Config.fish.wanderRetargetMax)
            entity.targetHeading = entity.heading or 0
        end,
        update = function(entity, dt)
            local def = SPECIES[entity.fishKey]
            if not def then return end
            entity.retargetTimer = entity.retargetTimer - dt
            if entity.retargetTimer <= 0 then
                entity.retargetTimer = RandRange(Config.fish.wanderRetargetMin, Config.fish.wanderRetargetMax)
                -- 相对当前朝向 ±120° 内偏转，不做瞬间掉头
                entity.targetHeading = entity.heading + (math.random() * 2 - 1) * 120 * DEG
            end
            SteerAwayFromEdge(entity)
            TurnToward(entity, dt, entity.targetHeading, def.turnRate)
            local speed = def.speeds.wander
            entity.position.x = entity.position.x + math.cos(entity.heading) * speed * dt
            entity.position.y = entity.position.y + math.sin(entity.heading) * speed * dt
        end,
    },
}

-- 生成一条鱼并挂 Wander FSM；离船/离出发点距离约束由调用方保证
function FishSystem.SpawnFish(world, speciesId, position)
    local entity = world:CreateEntity("fish", { position = position })
    entity.fishKey = speciesId
    entity.heading = math.random() * 2 * math.pi
    entity.fsm = StateMachine.New(WanderStates, "Wander", entity)
    return entity
end

-- STEP-6 初始沙丁鱼群：围绕锚点环形随机分布（离船 ≥15m，参数表「区域生成防贴脸」）
function FishSystem.SpawnSardines(world, count, center)
    center = center or { x = 0, y = 0 }
    local def = SPECIES.sardine
    for _ = 1, count do
        local angle = math.random() * 2 * math.pi
        local dist = RandRange(def.spawn.minDistFromBoat, def.spawn.minDistFromBoat + 25)
        FishSystem.SpawnFish(world, "sardine", {
            x = center.x + math.cos(angle) * dist,
            y = center.y + math.sin(angle) * dist,
        })
    end
    print(string.format("[鱼群] 初始生成 %d 条沙丁鱼（Wander，离船≥%dm）",
        count, def.spawn.minDistFromBoat))
end

return FishSystem
