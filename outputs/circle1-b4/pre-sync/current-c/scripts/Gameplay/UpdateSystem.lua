-- Frame-level gameplay update registered in the same World as sea simulation systems.
---@class GameplayUpdateSystem
---@field loop GameplayLoop
local UpdateSystem = {}
UpdateSystem.__index = UpdateSystem

function UpdateSystem.New(loop)
    return setmetatable({ loop = loop }, UpdateSystem)
end

function UpdateSystem:Update(_, dt)
    self.loop:Update(dt)
end

return UpdateSystem
