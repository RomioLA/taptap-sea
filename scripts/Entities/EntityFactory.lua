-- 无继承的轻量实体构造器；具体规则由后续 Behavior/System 提供。
local EntityFactory = {}
EntityFactory.__index = EntityFactory

function EntityFactory.New()
    return setmetatable({ nextId = 1 }, EntityFactory)
end

function EntityFactory:Create(kind, data)
    assert(type(kind) == "string" and kind ~= "", "Entity kind must be a non-empty string")
    data = data or {}

    local entity = {
        id = self.nextId,
        kind = kind,
        position = data.position or { x = 0, y = 0 },
        velocity = data.velocity or { x = 0, y = 0 },
        state = data.state,
        target = data.target,
        fsm = data.fsm,
        alive = true,
    }
    self.nextId = self.nextId + 1
    return entity
end

return EntityFactory
