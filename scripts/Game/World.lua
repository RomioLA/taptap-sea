-- 轻量世界容器：管理 Entity 生命周期，并按注册顺序更新 World System。
local EntityFactory = require("Entities.EntityFactory")

local World = {}
World.__index = World

function World.New()
    local self = setmetatable({}, World)
    self.entities = {}
    self.systems = {}
    self.entityFactory = EntityFactory.New()
    return self
end

function World:AddSystem(system)
    assert(type(system) == "table" and type(system.Update) == "function",
        "World System must provide Update(world, dt)")
    self.systems[#self.systems + 1] = system
end

function World:CreateEntity(kind, data)
    local entity = self.entityFactory:Create(kind, data)
    self.entities[#self.entities + 1] = entity
    return entity
end

function World:GetEntity(entityId)
    for _, entity in ipairs(self.entities) do
        if entity.id == entityId then
            return entity
        end
    end
    return nil
end

function World:GetEntities()
    local snapshot = {}
    for _, entity in ipairs(self.entities) do
        snapshot[#snapshot + 1] = entity
    end
    return snapshot
end

function World:RemoveEntity(entityId)
    for index = #self.entities, 1, -1 do
        local entity = self.entities[index]
        if entity.id == entityId then
            entity.alive = false
            table.remove(self.entities, index)
            return true
        end
    end
    return false
end

function World:Clear()
    for _, entity in ipairs(self.entities) do
        entity.alive = false
    end
    self.entities = {}
end

function World:Update(dt)
    for _, system in ipairs(self.systems) do
        system:Update(self, dt)
    end
end

return World
