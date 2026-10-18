-- Lightweight entity construction; extensions supply their own data, not subclasses.
local EntityFactory = {}
EntityFactory.__index = EntityFactory

function EntityFactory.New(idPrefix)
    local self = setmetatable({}, EntityFactory)
    self:Init(idPrefix)
    return self
end

function EntityFactory:Init(idPrefix)
    self.nextId = 1
    self.idPrefix = idPrefix
end

function EntityFactory:Create(kind, data)
    assert(type(kind) == "string" and kind ~= "", "Entity kind must be a non-empty string")
    data = data or {}
    local entity = {}
    for key, value in pairs(data) do entity[key] = value end
    local position = data.position or { x = 0, y = 0 }
    entity.position = { x = position.x, y = position.y }
    entity.velocity = data.velocity or { x = 0, y = 0 }
    entity.id = self.idPrefix and (self.idPrefix .. self.nextId) or self.nextId
    entity.kind = kind
    entity.alive = true
    entity.removed = false
    self.nextId = self.nextId + 1
    return entity
end

return EntityFactory
