--[[
  AchievementSystem.lua — ② 成就系统执行器 (A 侧工程)
  =====================================================================
  纯聚合层：判定源全部现成（审查 §3.6），无新依赖。
  行为成就 A1-A6（圈2 锁定集）+ 认知成就 C1-C3（派生自 KnowledgeSystem domainLv）。
  奖励仅信息类（codexRecall / elderComment / logLine），严禁数值/物品（§6.5 红线），
  以免污染 Q-011 经济观察。全部 9 条成就跨周目保留（写入 profile.achievements）。

  未知项隔离（严禁升格）：
    U3 C3 首轮达成率 ≥60% 为 [PLACEHOLDER] 假设，非定稿验收目标 — 此处仅按 gte=2 判定。
    U5 elder 苹果计数字段落点：A3 用 data 中 min=3/withinDays=3；实际落点待负责人核对（不影响判定）。
    U6 云存档：成就记录经 profile（ProfileStore）持久化，双文件语义由 ProfileStore 承担。

  接线点（由 Loop 在合适时机调用，本模块不自行动）：
    ach = AchievementSystem.New{ data=achievements, knowledge=ks, profile=profile, player=player }
    Actions 捕鱼结算   → ach:OnFishingResolved(record, isBigFish, isPaidCast)
    透镜出木桶事件    → ach:NoteLensUnlocked(day)
    给老人苹果事件    → ach:NoteAppleGiven(day)
    事件非常规分支    → ach:NoteUnusualBranch()
    每日晚归事件      → ach:NoteLateReturn(lateSeconds)
    每日结算 / day 变化 → ach:SettleDay()
    run 结算（结局）   → ach:SettleRun()  -- 终判 A6 + cognition 终检
    Loop:NewRun       → ach:ResetRun()   -- 清本周目进度，跨周目成就从 profile 恢复
]]
local AchievementSystem = {}

function AchievementSystem.New(opts)
    opts = opts or {}
    local data = opts.data or require("data.achievements")
    local knowledge = opts.knowledge          -- KnowledgeSystem 实例（查 domainLv）
    local profile = opts.profile             -- ProfileStore 实例
    local player = opts.player                -- PlayerState（查 day 等）
    local onUnlock = opts.onUnlock           -- 可选回调(id, achievement)

    local whitelist = data.predicateWhitelist
    local function isLocked(t) return whitelist[t] and whitelist[t].locked == true end

    -- 索引全部成就
    local all = {}
    for _, grp in ipairs({ data.behavior, data.cognition }) do
        for i = 1, #grp do
            local a = grp[i]
            all[a.id] = a
        end
    end

    -- 运行态（本周目进度）
    local granted = {}               -- [id]=true（含跨周目已解锁）
    local dayEmptyCount = 0
    local dayPaidCast = 0
    local appleCount3 = 0
    local dayBigCount = 0
    local dayTotalCount = 0
    local forceReturnViolation = false
    local currentDay = player and player.day or 1

    -- 跨周目已授予：从 profile 恢复
    if profile then
        for id, _ in pairs(all) do
            if profile:HasAchievement(id) then granted[id] = true end
        end
    end

    local function unlock(id)
        if granted[id] then return end
        if profile then profile:MarkAchievement(id) end
        granted[id] = true
        if onUnlock then onUnlock(id, all[id]) end
    end

    -- 每日结算：在 day 变化或主动调用时触发
    local function settleDay()
        -- A2 单日零空网（且 ≥1 付费捕鱼）
        if not granted["A2"] and isLocked("zeroEmptyDay") then
            local needPaid = all["A2"].predicate.requirePaidCast
            if dayEmptyCount == 0 and (not needPaid or dayPaidCast >= 1) then unlock("A2") end
        end
        -- A5 单日大鱼 ≥60% 且 ≥5 条
        if not granted["A5"] and isLocked("bigFishRatio") then
            local p = all["A5"].predicate
            local gte = p.gte or 0.6
            local minCount = p.minCount or 5
            if dayTotalCount >= minCount and dayBigCount / dayTotalCount >= gte then unlock("A5") end
        end
        dayEmptyCount = 0; dayPaidCast = 0; dayBigCount = 0; dayTotalCount = 0
    end

    -- 捕鱼结算（record.result[2] ∈ {empty, caught, pending_catch}）
    local function onFishingResolved(record, isBig, paid)
        if not record or not record.result then return end
        local outcome = record.result[2]
        local day = player and player.day or currentDay
        if day ~= currentDay then
            currentDay = day
            settleDay()
        end
        if outcome == "empty" then
            dayEmptyCount = dayEmptyCount + 1
        elseif outcome == "caught" or outcome == "pending_catch" then
            dayTotalCount = dayTotalCount + 1
            if isBig then dayBigCount = dayBigCount + 1 end
            if paid then dayPaidCast = dayPaidCast + 1 end
        end
    end

    local function noteLensUnlocked(day)
        if not granted["A1"] and isLocked("firstDayLens") then
            if (day or (player and player.day or 1)) == 1 then unlock("A1") end
        end
    end
    local function noteAppleGiven(day)
        if not granted["A3"] and isLocked("appleCount") then
            if (day or 0) <= (all["A3"].predicate.withinDays or 3) then
                appleCount3 = appleCount3 + 1
                if appleCount3 >= (all["A3"].predicate.min or 3) then unlock("A3") end
            end
        end
    end
    local function noteUnusualBranch()
        if not granted["A4"] and isLocked("unusualBranch") then unlock("A4") end
    end
    local function noteLateReturn(seconds)
        local p = all["A6"].predicate
        local maxLate = p.maxLateSeconds or 30
        if seconds > maxLate then forceReturnViolation = true end
    end

    -- 认知成就：基于 domainLv 重算（每周目 domainLv 由 KnowledgeSystem.ResetRun 清零后重新累计）
    local function checkCognition()
        if not knowledge then return end
        for id, a in pairs(all) do
            if a.predicate.type == "domainLv" and isLocked("domainLv") and not granted[id] then
                local lv = knowledge:GetDomainLevel(a.predicate.domain) or 0
                if lv >= (a.predicate.gte or 2) then unlock(id) end
            end
        end
    end

    -- run 结算（第七天 / 结局）：终判 A6 + cognition 终检
    local function settleRun()
        if not granted["A6"] and isLocked("noForceReturn") then
            if not forceReturnViolation then unlock("A6") end
        end
        checkCognition()
    end

    -- NewRun：清本周目进度；跨周目成就从 profile 恢复
    local function resetRun()
        granted = {}
        if profile then
            for id, _ in pairs(all) do
                if profile:HasAchievement(id) then granted[id] = true end
            end
        end
        dayEmptyCount = 0; dayPaidCast = 0; appleCount3 = 0
        dayBigCount = 0; dayTotalCount = 0; forceReturnViolation = false
        currentDay = player and player.day or 1
    end

    -- 注意：用 function(_, ...) 显式忽略 self，避免 ach:Method(x) 调用时 self 顶替首个实参
    return {
        OnFishingResolved = function(_, record, isBig, paid) onFishingResolved(record, isBig, paid) end,
        NoteLensUnlocked = function(_, day) noteLensUnlocked(day) end,
        NoteAppleGiven = function(_, day) noteAppleGiven(day) end,
        NoteUnusualBranch = function(_) noteUnusualBranch() end,
        NoteLateReturn = function(_, seconds) noteLateReturn(seconds) end,
        CheckCognition = function(_) checkCognition() end,
        SettleDay = function(_) settleDay() end,
        SettleRun = function(_) settleRun() end,
        ResetRun = function(_) resetRun() end,
        IsUnlocked = function(_, id) return granted[id] == true end,
        HasAchievement = function(_, id) return (profile and profile:HasAchievement(id)) or granted[id] == true end,
        Unlock = function(_, id) unlock(id) end,
        _debug = { all = all },
    }
end

return AchievementSystem
