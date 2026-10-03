-- 纯 Lua 昼夜时钟；只管理阶段时间、暂停原因与调试倍率。
---@class GameClock
---@field daySec number
---@field nightSec number
---@field graceSec number
---@field penaltyPerSec number
---@field forcedStaminaRatio number
---@field timeScales number[]
---@field initialTimeScale number
---@field phase string
---@field elapsed number
---@field exhausted boolean
---@field timeScale number
---@field pauseReasons table<string, boolean>
local GameClock = {}
GameClock.__index = GameClock

---@param value any
---@return boolean
local function isFiniteNumber(value)
    if type(value) ~= "number" then
        return false
    end

    return value == value and value ~= math.huge and value ~= -math.huge
end

---@param value any
---@param name string
---@param minimum number
---@return number
local function requireNumberAtLeast(value, name, minimum)
    if not isFiniteNumber(value) or value < minimum then
        error(name .. " must be a finite number >= " .. tostring(minimum), 3)
    end

    return value
end

---@return GameClock
function GameClock.New()
    local self = setmetatable({}, GameClock)
    self:Init()
    return self
end

function GameClock:Init()
    local gameplayConfig = require("config.gameplay")
    if type(gameplayConfig) ~= "table" then
        error("config.gameplay must return a table", 2)
    end

    local clockConfig = gameplayConfig.clock
    if type(clockConfig) ~= "table" then
        error("config.gameplay.clock must be a table", 2)
    end

    local debugConfig = gameplayConfig.debug
    if type(debugConfig) ~= "table" or type(debugConfig.timeScales) ~= "table" then
        error("config.gameplay.debug.timeScales must be an array", 2)
    end

    self.daySec = requireNumberAtLeast(clockConfig.daySec, "clock.daySec", 0)
    self.nightSec = requireNumberAtLeast(clockConfig.nightSec, "clock.nightSec", 0)
    if self.daySec == 0 or self.nightSec == 0 then
        error("clock.daySec and clock.nightSec must be greater than 0", 2)
    end

    self.graceSec = requireNumberAtLeast(clockConfig.graceSec, "clock.graceSec", 0)
    self.penaltyPerSec = requireNumberAtLeast(clockConfig.penaltyPerSec, "clock.penaltyPerSec", 0)
    self.forcedStaminaRatio = requireNumberAtLeast(clockConfig.forcedStaminaRatio, "clock.forcedStaminaRatio", 0)
    if self.forcedStaminaRatio > 1 then
        error("clock.forcedStaminaRatio must be <= 1", 2)
    end

    self.timeScales = {}
    local scaleCount = #debugConfig.timeScales
    if scaleCount == 0 then
        error("config.gameplay.debug.timeScales must contain at least one scale", 2)
    end

    for index = 1, scaleCount do
        local scale = requireNumberAtLeast(debugConfig.timeScales[index], "debug.timeScales[" .. index .. "]", 0)
        if scale == 0 then
            error("debug.timeScales values must be greater than 0", 2)
        end
        self.timeScales[index] = scale
    end

    self.initialTimeScale = assert(self.timeScales[1])
    self:Reset()
end

---@param reason string
function GameClock:Pause(reason)
    if type(reason) ~= "string" or reason == "" then
        error("pause reason must be a non-empty string", 2)
    end

    self.pauseReasons[reason] = true
end

---@param reason string
function GameClock:Resume(reason)
    if type(reason) ~= "string" or reason == "" then
        error("pause reason must be a non-empty string", 2)
    end

    self.pauseReasons[reason] = nil
end

---@return string[]
function GameClock:GetPauseReasons()
    local reasons = {}
    for reason in pairs(self.pauseReasons) do
        reasons[#reasons + 1] = reason
    end

    table.sort(reasons)
    return reasons
end

---@return boolean
function GameClock:IsPaused()
    return next(self.pauseReasons) ~= nil
end

---@param dt number
---@return boolean newlyExhausted
function GameClock:Update(dt)
    if not isFiniteNumber(dt) or dt < 0 then
        error("dt must be a finite non-negative number", 2)
    end

    if self:IsPaused() or self.exhausted or dt == 0 then
        return false
    end

    local secondsUntilExhausted = self.nightSec - self.elapsed
    if self.phase == "day" then
        secondsUntilExhausted = self.daySec - self.elapsed + self.nightSec
    end

    -- 先按未缩放的剩余时长比较，避免巨大但有限的 dt 与倍率相乘后溢出。
    if dt >= secondsUntilExhausted / self.timeScale then
        self.phase = "night"
        self.elapsed = self.nightSec
        self.exhausted = true
        return true
    end

    local gameSeconds = dt * self.timeScale
    while true do
        local phaseDuration = self.phase == "day" and self.daySec or self.nightSec
        local phaseRemaining = phaseDuration - self.elapsed

        if gameSeconds < phaseRemaining then
            self.elapsed = self.elapsed + gameSeconds
            if self.elapsed < phaseDuration then return false end
            -- Addition can round to the exact phase boundary (59.9 + 0.1).
            -- Resolve it now so the caller never receives a zero-time unfinished phase.
            if self.phase == "day" then
                self.phase, self.elapsed = "night", 0
                return false
            end
            self.elapsed, self.exhausted = self.nightSec, true
            return true
        end

        gameSeconds = gameSeconds - phaseRemaining
        if self.phase == "day" then
            self.phase = "night"
            self.elapsed = 0
            if gameSeconds == 0 then
                return false
            end
        else
            self.elapsed = self.nightSec
            self.exhausted = true
            return true
        end
    end
end

function GameClock:Reset()
    self.phase = "day"
    self.elapsed = 0
    self.exhausted = false
    self.timeScale = self.initialTimeScale
    self.pauseReasons = {}
end

---@param scale number
function GameClock:SetTimeScale(scale)
    local isAllowed = false
    for index = 1, #self.timeScales do
        if self.timeScales[index] == scale then
            isAllowed = true
            break
        end
    end

    if not isAllowed then
        error("timeScale is not listed in config.gameplay.debug.timeScales", 2)
    end

    self.timeScale = scale
end

---@param phase string
---@param elapsed number
function GameClock:Seek(phase, elapsed)
    if phase ~= "day" and phase ~= "night" then
        error("phase must be 'day' or 'night'", 2)
    end
    if not isFiniteNumber(elapsed) or elapsed < 0 then
        error("elapsed must be a finite non-negative number", 2)
    end

    local duration = phase == "day" and self.daySec or self.nightSec
    if elapsed > duration then
        error("elapsed must not exceed the selected phase duration", 2)
    end

    self.phase = phase
    self.elapsed = elapsed
    self.exhausted = phase == "night" and elapsed == self.nightSec
end

---@return table
function GameClock:GetState()
    local duration = self.phase == "day" and self.daySec or self.nightSec
    return {
        phase = self.phase,
        elapsed = self.elapsed,
        remaining = math.max(0, duration - self.elapsed),
        paused = self:IsPaused(),
        pauseReasons = self:GetPauseReasons(),
        exhausted = self.exhausted,
        timeScale = self.timeScale,
    }
end

return GameClock
