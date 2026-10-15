-- One entity registry and system scheduler. Ocean.World adds sea-specific operations.
local EntityFactory = require("Entities.EntityFactory")
---@class GameWorld
---@field entities table[]
---@field byId table<any, table>
---@field systems table[]
---@field systemCadences table<table, string>
local World = {}
World.__index = World

---@return GameWorld
function World.New(options)
    local self = setmetatable({}, World)
    self:Init(options)
    return self
end

function World:Init(options)
    self.entities = {}
    self.byId = {}
    self.nextId = 0
    self.systems = {}
    self.systemCadences = {}
    self.entitiesDirty = false
    self.blockingList = {}
    self.entityFactory = EntityFactory.New(options and options.idPrefix)
end

function World:AddSystem(system, cadence)
    assert(type(system) == "table" and type(system.Update) == "function",
        "World System must provide Update(world, dt)")
    cadence = cadence or "simulation"
    assert(cadence == "frame" or cadence == "simulation", "unsupported System cadence")
    for _, registered in ipairs(self.systems) do
        if registered == system then
            assert(self.systemCadences[system] == cadence, "System cadence cannot change after registration")
            return false
        end
    end
    self.systems[#self.systems + 1] = system
    self.systemCadences[system] = cadence
    return true
end

-- S1-b（2026-10-15 卡顿排查）：blocking 持久索引。getAvoidance/isPositionFree/
-- CreateWaterQuery 此前每调用一次都全表扫 entities 再按 blocking 过滤；这三者是
-- 每鱼每步的热路径（31 活跃鱼 × 4 子步 × 全表 67）。改为维护 blockingList：
-- CreateEntity 时入表、RemoveEntity 时摘除。blocking/removed 无运行时直写
-- （唯一写点是 spawn 初始化），索引不会失效；compact 不动实体对象，索引稳定。
function World:CreateEntity(kind, data)
    local entity = self.entityFactory:Create(kind, data)
    self.nextId = self.entityFactory.nextId - 1
    self.entities[#self.entities + 1] = entity
    self.byId[entity.id] = entity
    if entity.blocking then self.blockingList[#self.blockingList + 1] = entity end
    return entity
end

function World:GetEntity(entityId)
    return self.byId[entityId]
end

function World:GetEntities()
    local snapshot = {}
    for _, entity in ipairs(self.entities) do
        if not entity.removed then snapshot[#snapshot + 1] = entity end
    end
    return snapshot
end

function World:RemoveEntity(entityId, reason, deferCompact)
    local entity = self.byId[entityId]
    if not entity then return false end
    entity.alive, entity.removed, entity.active, entity.frozen = false, true, false, false
    entity.state = "Removed"
    entity.removeReason = reason or "removed"
    self.byId[entityId] = nil
    self.entitiesDirty = true
    for index, blocker in ipairs(self.blockingList) do
        if rawequal(blocker, entity) then
            self.blockingList[index] = self.blockingList[#self.blockingList]
            self.blockingList[#self.blockingList] = nil
            break
        end
    end
    if not deferCompact then self:Compact() end
    return true
end

-- S1-a（2026-10-15 卡顿排查）：compact 脏标记。SeaRuntime.Advance 此前每个子步
-- 都无条件重建 live 表（4 子步/帧 × 新表+全量拷贝），而实体删除只发生在换日/
-- 过期/移除路径——无删除时 compact 是纯浪费。dirty 只在 RemoveEntity 置位；
-- 唯一写 entity.removed 的地方是 spawn 初始化（false），无旁路失效风险。
function World:Compact()
    if not self.entitiesDirty then return end
    local live = {}
    for _, entity in ipairs(self.entities) do
        if not entity.removed then live[#live + 1] = entity end
    end
    self.entities = live
    self.entitiesDirty = false
end

function World:Clear()
    for _, entity in ipairs(self:GetEntities()) do self:RemoveEntity(entity.id) end
end

function World:Update(dt, cadence)
    cadence = cadence or "simulation"
    assert(cadence == "frame" or cadence == "simulation", "unsupported System cadence")
    for _, system in ipairs(self.systems) do
        if self.systemCadences[system] == cadence then system:Update(self, dt) end
    end
end

return World
