-- GameClock 系统（STEP-5）：昼夜推进 + 夜晚超时记录。
-- 经 World:AddSystem 注册进唯一更新链，每帧恰好推进一次（AGENTS.md 调度约定）。
-- 状态保存在 world.clock（Game.New 创建、Game.Reset 重置），System 本体无跨帧私有状态；
-- 暂停由 Game.pauseReasons 统一门控（World 更新链整体冻结，时钟随之暂停）。
local Config = require("Ocean.Config")

local ClockSystem = {}

function ClockSystem.NewState()
    return {
        day = 1,
        phase = "day",        -- "day" | "night"
        remaining = Config.clock.dayLength,
        nightElapsed = 0,     -- 当晚已流逝秒数（0~60）
        lastNightSeconds = 0, -- 昨夜实际流逝秒数（M1 体力结算消费：>30 部分每晚 1 秒减 1）
    }
end

-- 就地重置（保留 table 引用，state.clock / GetClock 的持有者无需重建）
function ClockSystem.ResetState(clock)
    local fresh = ClockSystem.NewState()
    for key, value in pairs(fresh) do
        clock[key] = value
    end
end

function ClockSystem:Update(world, dt)
    local clock = world.clock
    if not clock then return end
    clock.remaining = clock.remaining - dt
    if clock.phase == "night" then
        clock.nightElapsed = clock.nightElapsed + dt
    end
    if clock.remaining <= 0 then
        if clock.phase == "day" then
            clock.phase = "night"
            clock.remaining = Config.clock.nightLength
            clock.nightElapsed = 0
            print(string.format("[时钟] 第%d天入夜", clock.day))
        else
            -- 夜晚 60s 耗尽：自动结束当天，进入次日白天（体力处罚由 M1 每日结算消费）。
            clock.lastNightSeconds = clock.nightElapsed
            clock.day = clock.day + 1
            clock.phase = "day"
            clock.remaining = Config.clock.dayLength
            clock.nightElapsed = 0
            print(string.format("[时钟] 第%d天开始（昨夜 %.0fs，超时 %.0fs）",
                clock.day, clock.lastNightSeconds,
                math.max(0, clock.lastNightSeconds - Config.clock.nightGraceSeconds)))
        end
    end
end

return ClockSystem
