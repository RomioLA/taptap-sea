-- The sole automatic updater of entity FSMs; activity/freeze gates preserve sea behavior.
local EntityStateSystem = {}

function EntityStateSystem:Update(world, dt)
    for _, entity in ipairs(world:GetEntities()) do
        if entity.alive and not entity.removed and entity.active ~= false
            and entity.frozen ~= true and entity.captureLocked ~= true and entity.fsm then
            entity.fsm:Update(dt)
        end
    end
end

return EntityStateSystem
