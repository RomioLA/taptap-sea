-- 开发模式下使用的受限调试命令；不负责写入任何额外存档。
local Config = require("config.gameplay")
local Items = require("data.items")
local AudioDirector = require("Gameplay.AudioDirector")
local PerfProbe = require("Ocean.PerfProbe")

---@class GameplayDebug
---@field loop GameplayLoop
---@field enabled boolean
local Debug = {}
Debug.__index = Debug

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function readNumber(value)
    local number = type(value) == "number" and value or tonumber(value)
    if not isFiniteNumber(number) then return nil end
    return number
end

function Debug.New(loop, enabled)
    local self = setmetatable({}, Debug)
    self:init(loop, enabled)
    return self
end

function Debug:init(loop, enabled)
    self.loop = loop
    self.enabled = enabled == true
end

local function executeTimeScale(loop, argument)
    local scale = readNumber(argument)
    if not scale then return false, "invalid_time_scale" end

    local allowed = false
    for _, configuredScale in ipairs(Config.debug.timeScales or {}) do
        if scale == configuredScale then
            allowed = true
            break
        end
    end
    if not allowed then return false, "time_scale_not_configured" end

    loop.clock:SetTimeScale(scale)
    return true, "时间倍率已调整为 " .. tostring(scale)
end

local function executeSeek(loop, phase, argument)
    local elapsed = readNumber(argument)
    if not elapsed or elapsed < 0 then return false, "invalid_elapsed" end
    local duration = phase == "day" and Config.clock.daySec or Config.clock.nightSec
    if elapsed > duration then return false, "elapsed_exceeds_phase" end
    loop.clock:Seek(phase, elapsed)
    if loop.inPort then loop.portNightElapsed = phase == "night" and elapsed or 0 end
    -- 恰好跳到夜晚终点时，让 Loop 立即创建强制返港状态。
    loop:RefreshClockStatus()
    return true, (phase == "day" and "已跳转到白天 " or "已跳转到夜晚 ")
        .. string.format("%.0f 秒", elapsed)
end

local function executeStamina(loop, direction, argument)
    local amount = readNumber(argument)
    if not amount then amount = Config.debug.staminaStep end
    if not isFiniteNumber(amount) or amount <= 0 then return false, "invalid_stamina_step" end

    local stamina = loop.player.stamina + direction * amount
    loop.player.stamina = math.max(0, math.min(loop.player.maxStamina, stamina))
    return true, "体力已调整为 " .. tostring(loop.player.stamina)
end

local function executeMoney(loop, argument)
    local amount = readNumber(argument)
    if not amount then amount = Config.debug.moneyStep end
    if not isFiniteNumber(amount) or amount <= 0 then return false, "invalid_money_step" end

    loop.player.money = loop.player.money + math.floor(amount)
    return true, "金钱已增加 " .. tostring(math.floor(amount))
end

local function executeAddItem(loop, argument)
    local definition = type(argument) == "string" and Items.GetDefinition(argument)
    if not definition then
        return false, "unknown_item"
    end
    local added, reason = loop.player.inventory:Add(argument)
    if not added then return false, reason or "inventory_full" end
    return true, "已加入物品：" .. definition.name
end

local function executeClearInventory(loop)
    local inventory = loop.player.inventory
    local items = inventory:GetItems()
    while #items > 0 do
        local removed, reason = inventory:Remove(#items)
        if not removed then return false, reason or "remove_failed" end
        items = inventory:GetItems()
    end
    return true, "背包已清空"
end

local function executeSettleDay(loop)
    if loop.busy or loop.loading or loop.dropInFlight then return false, "busy" end
    if loop.forcedReturnPending then
        local settled, reason = loop:ConfirmForcedReturn()
        if not settled then return false, reason end
        return true, "已确认强制返港并开始结算存档"
    end
    if loop.settlementPending then
        local settled, reason = loop:ConfirmSettlement()
        if not settled then return false, reason end
        return true, "已重试当前结算并开始自动保存"
    end

    if not loop.inPort then
        local returned, reason = loop:ReturnToPort()
        if not returned then return false, reason end
    end
    local opened, reason = loop:EndToday()
    if not opened then return false, reason end
    local settled, settleReason = loop:ConfirmSettlement()
    if not settled then return false, settleReason end
    return true, "已确认每日结算，正在自动保存"
end

local function executeAction(loop, action)
    local completed, reason = loop:CompleteAction(action)
    if not completed then return false, reason end
    local cost = action == "fishing" and Config.stamina.fishingCost or Config.stamina.salvageCost
    local name = action == "fishing" and "钓鱼" or "打捞"
    return true, name .. "动作已消耗 " .. tostring(cost) .. " 体力"
end

function Debug:Execute(command, argument)
    if not self.enabled then return false, "development_only" end
    if not self.loop or type(command) ~= "string" then return false, "invalid_debug_call" end

    local loop = self.loop
    if command ~= "pauseReasons" and command ~= "settleDay"
        and command ~= "audioClick" and command ~= "audioAmb"
        and command ~= "perfToggle" and command ~= "perfRead"
        and (loop.busy or loop.loading or loop.settlementPending
            or loop.forcedReturnPending or loop.dropInFlight) then
        return false, "busy"
    end
    if command == "timeScale" then return executeTimeScale(loop, argument) end
    if command == "seekDay" then return executeSeek(loop, "day", argument) end
    if command == "seekNight" then return executeSeek(loop, "night", argument) end
    if command == "staminaPlus" then return executeStamina(loop, 1, argument) end
    if command == "staminaMinus" then return executeStamina(loop, -1, argument) end
    if command == "moneyPlus" then return executeMoney(loop, argument) end
    if command == "addItem" then return executeAddItem(loop, argument) end
    if command == "clearInventory" then return executeClearInventory(loop) end
    if command == "settleDay" then return executeSettleDay(loop) end
    if command == "fishing" then return executeAction(loop, "fishing") end
    if command == "salvage" then return executeAction(loop, "salvage") end
    if command == "pauseReasons" then
        local reasons = loop.clock:GetPauseReasons()
        return true, #reasons > 0 and table.concat(reasons, "、") or "当前没有暂停原因"
    end
    if command == "audioClick" then
        -- S0 音频验证桩：试听 UI 点击音，附带能力状态行（屏幕通道验收）。
        local ok, message = AudioDirector.Play("ui.button_click")
        return ok, ok and (message .. "｜" .. AudioDirector.Status()) or message
    end
    if command == "audioAmb" then
        -- S0 音频验证桩：白天声床循环开关，附带能力状态行。
        local ok, message = AudioDirector.ToggleBed("amb.calm_sea")
        return ok, ok and (message .. "｜" .. AudioDirector.Status()) or message
    end
    if command == "perfToggle" then
        -- T3 海岛帧耗时探针开关；开启后绕岛航行数秒再按"性能读数"。
        PerfProbe.SetEnabled(not PerfProbe.IsEnabled())
        return true, PerfProbe.IsEnabled() and "探针已开启：绕岛航行数秒后按性能读数"
            or "探针已关闭"
    end
    if command == "perfRead" then
        return true, PerfProbe.SnapshotAndReset()
    end
    return false, "unknown_debug_command"
end

return Debug
