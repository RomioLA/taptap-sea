-- Coordinates existing gameplay and sea modules; owns no duplicate player/world state.
local GameplayUpdateSystem = require("Gameplay.UpdateSystem")
local OceanConfig = require("Ocean.Config")
---@class SeaGameplayGame
---@field runtime table
---@field loop GameplayLoop
---@field gameplaySystem table
local Game = {}
Game.__index = Game

---@return SeaGameplayGame
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
    -- 每帧路径零闭包分配（真机卡顿优化）：advanceWorld 闭包只在 Init 创建一次，
    -- 每帧仅刷新 _frameDt/_axisX/_axisY 三个字段，消除逐帧闭包+upvalue 的 GC 抖动。
    self._advanceWorld = function(slice)
        self:Sync()
        local blocked = self.loop:IsMovementBlocked()
        if blocked then self.runtime:ClearMovementTarget() end
        local frameDt = self._frameDt
        local seaSlice = frameDt > 0 and math.min(frameDt, OceanConfig.world.maxFrameSec) * (slice / frameDt) or 0
        self.runtime:Update(seaSlice, blocked and 0 or self._axisX, blocked and 0 or self._axisY)
    end
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

---@return boolean paused, number shipLevel, boolean scopeSynced, string? scopeReason
function Game:Sync()
    local paused = self.loop.clock:IsPaused()
    local shipLevel = self.loop.player.boatSpeedLevel
    self.runtime.paused = paused
    self.runtime:SetShipLevel(shipLevel)
    local scopeSynced, scopeReason = self.loop:SyncScope()
    return paused, shipLevel, scopeSynced, scopeReason
end

function Game:Update(dt, axisX, axisY)
    -- One frame System dispatch receives the full dt. Boundary slices share the
    -- original Runtime frame budget, so a large dt never increases sea simulation.
    self._frameDt, self._axisX, self._axisY = dt, axisX, axisY
    self.gameplaySystem.advanceWorld = self._advanceWorld
    local ok, reason = pcall(self.RunFrame, self, dt)
    self.gameplaySystem.advanceWorld = nil
    if not ok then
        if self.loop.actions then self.loop.actions:CancelActiveFishing("fishing_update_failed") end
        error(reason, 0)
    end
    self:Sync()
end

-- Split from Update so the per-frame pcall wraps a fixed method instead of a
-- fresh closure (no per-frame function object allocation).
function Game:RunFrame(dt)
    self:GetWorld():Update(dt, "frame")
end

return Game
