-- Preserve the original HUD contract while driving the real sea simulation.
local Config = require("Ocean.Config")
local Math = require("Ocean.Math")
---@class OceanSceneState
---@field runtime table
---@field onReset (fun())?
---@field time number
---@field paused boolean
local SceneState = {}
SceneState.__index = SceneState

---@param runtime table
---@param onReset (fun())?
---@return OceanSceneState
function SceneState.New(runtime, onReset)
    ---@type OceanSceneState
    local self = setmetatable({ runtime = runtime, onReset = onReset }, SceneState)
    self:Sync()
    return self
end

function SceneState:Sync()
    local changed = self.paused ~= self.runtime.paused
    self.time, self.paused = self.runtime.time, self.runtime.paused
    return changed
end

function SceneState:TogglePause()
    self.runtime:TogglePause()
    self:Sync()
end

function SceneState:Reset()
    self.runtime:Reset()
    if self.onReset then self.onReset() end
    self:Sync()
end

function SceneState:MoveBy(direction)
    if self.runtime.paused then return end
    ---@type OceanMovement
    local movement = self.runtime.movement
    local ship = self.runtime.ship
    local target = Math.copy(movement.target or ship.position)
    local bound = Config.world.halfSize - ship.radius
    target.x = Math.clamp(target.x + direction * movement.viewWidth * Config.boat.buttonStep, -bound, bound)
    movement:SetTarget(target)
end

return SceneState
