-- 成就状态桩（设计方案 v2.0 §7.4，2026-10-07）。
-- 6 条最小集（圈2 决策 B3）：文案/判定条件待 B 侧定稿后逐项替换 Evaluate 分支。
-- UI 侧只读本模块接口；跨周目保存字段待 B 侧 Schema（team/07 页已留接口），
-- 当前解锁记录仅存内存（桩），接入保存时改持久化即可，HUD 无感知。
-- 纯逻辑模块：不依赖引擎与 UI，测试桩可直接加载。
local Achievements = {
    unlocked = {},   -- id -> true（跨周目保存接入点：此处换持久化后端）
    toastQueue = {}, -- 待展示的解锁 toast（FIFO，HUD 每次 refresh 取一条）
}

-- 最小集 6 条定义（名称/文案为占位，正式文案待 B 侧 Q-006 定稿）。
local DEFINITIONS = {
    { id = "first_lens",    name = "初见透镜",   desc = "首日获得透镜" },
    { id = "zero_skunk",    name = "满载而归",   desc = "单日零空网" },
    { id = "save_elder",    name = "救命之饵",   desc = "救下老人" },
    { id = "alt_branch",    name = "非常规之路", desc = "触发非常规分支" },
    { id = "big_catch",     name = "大鱼当家",   desc = "单日大鱼占比 60%" },
    { id = "no_forced_end", name = "从容归来",   desc = "通关且未被强制返港" },
}

function Achievements.Definitions()
    return DEFINITIONS
end

function Achievements.IsUnlocked(id)
    return Achievements.unlocked[id] == true
end

-- 解锁入口：幂等；判定落位前供调试/真机试水（SeaDebug 或临时接线触发）。
function Achievements.Unlock(id)
    if Achievements.unlocked[id] then return false end
    for _, def in ipairs(DEFINITIONS) do
        if def.id == id then
            Achievements.unlocked[id] = true
            Achievements.toastQueue[#Achievements.toastQueue + 1] = def
            return true
        end
    end
    return false
end

-- 桩判定：每帧由 HUD refresh 调用，context 提供 day/hasLens 等已算好的字段。
-- 首条先行试水：首日透镜（D6 裁决 A 案）；其余待 B 侧判定条件。
function Achievements.Evaluate(context)
    context = context or {}
    if not Achievements.unlocked.first_lens
        and context.day == 1 and context.hasLens == true then
        Achievements.Unlock("first_lens")
    end
end

-- HUD 每次 refresh 取一条待展示 toast；无则返回 nil。
function Achievements.PollToast()
    return table.remove(Achievements.toastQueue, 1)
end

return Achievements
