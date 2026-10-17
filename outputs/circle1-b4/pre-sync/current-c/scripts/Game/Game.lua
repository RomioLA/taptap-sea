-- Coordinates existing gameplay and sea modules; owns no duplicate player/world state.
local GameplayUpdateSystem = require("Gameplay.UpdateSystem")
local Game = {}
Game.__index = Game

function Game.New(runtime, loop)
    local self = setmetatable({}, Game)
    self:Init(runtime, loop)
    return self
end

function Game:Init(runtime, loop)
    assert(type(runtime) == "table" and type(loop) == "table", "Game requires runtime and gameplay loop")
    self.runtime = runtime
    self.loop = loop
    self.gameplaySystem = GameplayUpdateSystem.New(loop)
    self:GetWorld()
end

function Game:GetWorld()
    -- Runtime.Reset can replace its world; never retain a stale second registry.
    local world = self.runtime.world
    world:AddSystem(self.gameplaySystem, "frame")
    return world
end

function Game:GetPlayerState()
    return self.loop.player
end

function Game:Sync()
    local paused = self.loop.clock:IsPaused()
    local shipLevel = self.loop.player.boatSpeedLevel
    self.runtime.paused = paused
    self.runtime:SetShipLevel(shipLevel)
    return paused, shipLevel
end

function Game:Update(dt, axisX, axisY)
    -- Preserve the prior order: raw gameplay clock, sync pause/speed, clamped sea simulation.
    self:GetWorld():Update(dt, "frame")
    self:Sync()
    self.runtime:Update(dt, axisX, axisY)
end

return Game
