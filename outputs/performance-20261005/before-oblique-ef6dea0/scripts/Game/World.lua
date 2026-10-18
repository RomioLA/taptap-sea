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

function World:CreateEntity(kind, data)
    local entity = self.entityFactory:Create(kind, data)
    self.nextId = self.entityFactory.nextId - 1
    self.entities[#self.entities + 1] = entity
    self.byId[entity.id] = entity
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
    if not deferCompact then self:Compact() end
    return true
end

function World:Compact()
    local live = {}
    for _, entity in ipairs(self.entities) do
        if not entity.removed then live[#live + 1] = entity end
    end
    self.entities = live
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
