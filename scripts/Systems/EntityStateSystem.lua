-- 推进带有 FSM 的 Entity；World 统一负责每帧调度此 System。
local EntityStateSystem = {}

function EntityStateSystem:Update(world, dt)
    for _, entity in ipairs(world:GetEntities()) do
        if entity.alive and entity.fsm then
            entity.fsm:Update(dt)
        end
    end
end

return EntityStateSystem
