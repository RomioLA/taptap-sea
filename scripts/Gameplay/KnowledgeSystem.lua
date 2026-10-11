--[[
  KnowledgeSystem.lua — ② 海域认知度系统执行器 (A 侧工程)
  =====================================================================
  数据源：只读 Ocean 真实层公开接口 runtime.surfaceSignals
          (SurfaceSignals.GetBirds / GetSplashes)。
  禁读 Systems 演示层（审查 R3）。
  predicate 仅允许 knowledge.lua 白名单类型；locked=false 显式跳过（不静默放行）。
  轮询 0.25s（与 SurfaceSignals 同节奏）。once=true, run="run"：本周目内每 entry 至多授予一次。

  谓词评估分工：
    attractOnBait / birdSignalCast / repeatCastNoBird / emptyNetWhileFlee → 自动（事件/轮询驱动）
    chaseObserved / fleeAvoid / splashPreemptCatch → 经外部钩子 Note* 触发
      （chase/flee/splash 需 Fish fsm 或船位语义，由 Loop 在观测到时调用；U4 距离/阈值 TBD 时跳过）
  未知项（U4 等）参数 == "__TBD__" 时一律跳过授予，严禁升格为定稿值。

  接线点（由 Loop 在合适时机调用，本模块不自行动）：
    ks = KnowledgeSystem.New{ data=knowledge, surfaceSignals=runtime.surfaceSignals, profile=profile, currentWeek=week }
    Loop:Update(dt)        → ks:Update(dt)            -- 0.25s 轮询观测
    Loop:DropItem          → ks:OnDropItem(payload)   -- payload.worldEffect
    Actions 捕鱼结算       → ks:OnFishingResolved(record)
    鱼群 Chase 观测        → ks:NoteChaseObserved(durationSec, stationary)
    遇逃散停船            → ks:NoteFleeAvoid()
    水花预判撒网命中      → ks:NoteSplashPreempt()
    Loop:NewRun           → ks:ResetRun()            -- 清本周目运行态，跨周目 knowledgeLog 保留
]]
local KnowledgeSystem = {}
local POLL_INTERVAL = 0.25
local TBD = "__TBD__"

local function isTBD(v) return type(v) == "string" and v == TBD end
local function num(v, d) return type(v) == "number" and v or d end

function KnowledgeSystem.New(opts)
    opts = opts or {}
    local data = opts.data or require("data.knowledge")
    local surfaceSignals = opts.surfaceSignals   -- runtime.surfaceSignals
    local profile = opts.profile                 -- ProfileStore 实例
    local onGrant = opts.onGrant                 -- 可选回调(id, domain, entry)

    local whitelist = data.predicateWhitelist
    local function isLocked(t) return whitelist[t] and whitelist[t].locked == true end

    -- 索引 entries 与 domains
    local entries = {}
    local domains = {}
    for domainName, domain in pairs(data.domains) do
        domains[domainName] = { name = domain.name, maxLv = domain.maxLv, granted = 0 }
        for i = 1, #domain.entries do
            local e = domain.entries[i]
            entries[e.id] = { domain = domainName, entry = e }
        end
    end

    -- 运行态（本周目）
    local grantedThisRun = {}
    local castCount = 0
    local noBirdCastHappened = false
    local emptyNetStreak = 0
    local pollAccum = 0
    -- 观测态（轮询更新）
    local birdsPresent = false
    local fleeSignalActive = false

    local function grant(id)
        local info = entries[id]
        if not info then return end
        if grantedThisRun[id] then return end          -- once=true, run="run"
        grantedThisRun[id] = true
        domains[info.domain].granted = domains[info.domain].granted + 1
        if profile then profile:RecordKnowledge(id, opts.currentWeek or 1) end
        if onGrant then onGrant(id, info.domain, info.entry) end
    end

    -- 只读 SurfaceSignals 公开接口（与 EMCues.lua 同防御范式：pcall）
    local function pollObservation()
        if surfaceSignals and type(surfaceSignals.GetBirds) == "function" then
            local ok, birds = pcall(surfaceSignals.GetBirds, surfaceSignals)
            if ok and birds then
                birdsPresent = (#birds > 0)
                fleeSignalActive = false
                for _, b in ipairs(birds) do
                    if b.escaping then fleeSignalActive = true; break end   -- source 鱼群 Flee 状态映射
                end
            end
        end
    end

    -- 投饵命中（worldEffect 成功生成，非 NONE）；评审：命中=投放成功，不要求捕获
    local function onDropItem(payload)
        if not payload or type(payload.worldEffect) ~= "string" then return end
        if payload.worldEffect == "NONE" then return end
        castCount = castCount + 1
        if not birdsPresent then noBirdCastHappened = true end
        for id, info in pairs(entries) do
            local p = info.entry.predicate
            if p.type == "attractOnBait" and isLocked("attractOnBait") then
                grant(id)
            elseif p.type == "birdSignalCast" and isLocked("birdSignalCast") then
                if birdsPresent then grant(id) end
            elseif p.type == "repeatCastNoBird" and isLocked("repeatCastNoBird") then
                local minCasts = num(p.minCasts, 2)
                local reqNoBird = p.requireNoBirdOnce
                if castCount >= minCasts and (not reqNoBird or noBirdCastHappened) then
                    grant(id)
                end
            end
        end
    end

    -- 捕鱼结算（Actions.lua: record.result[2] ∈ {empty, caught, pending_catch}）
    local function onFishingResolved(record)
        if not record or not record.result then return end
        local outcome = record.result[2]
        if outcome == "empty" then
            if fleeSignalActive then
                emptyNetStreak = emptyNetStreak + 1
            else
                emptyNetStreak = 0          -- 非逃散信号 → 清零（防平静日误授）
            end
        else
            emptyNetStreak = 0              -- 成功捕获或异常 → 清零
        end
        for id, info in pairs(entries) do
            local p = info.entry.predicate
            if p.type == "emptyNetWhileFlee" and isLocked("emptyNetWhileFlee") then
                local need = num(p.consecutiveEmpty, 2)
                if emptyNetStreak >= need then grant(id) end
            end
        end
    end

    -- 外部钩子：鱼群 Chase 观测（需 Fish fsm；Loop 观测到 Chase 时调用）
    local function noteChaseObserved(durationSec, stationary)
        for id, info in pairs(entries) do
            local p = info.entry.predicate
            if p.type == "chaseObserved" and isLocked("chaseObserved") then
                if isTBD(p.minDuration) then return end   -- U4 未定，跳过
                local minDur = num(p.minDuration, 2)
                local needStat = (p.requireStationary ~= false)   -- 默认要求停船
                if durationSec >= minDur and (not needStat or stationary) then grant(id) end
            end
        end
    end

    -- 外部钩子：遇逃散停船回避（fleeAvoid）
    local function noteFleeAvoid()
        for id, info in pairs(entries) do
            local p = info.entry.predicate
            if p.type == "fleeAvoid" and isLocked("fleeAvoid") then
                if isTBD(p.fleeBatchThreshold) then return end   -- U4 未定，跳过
                grant(id)
            end
        end
    end

    -- 外部钩子：水花预判捕鱼（splashPreemptCatch）
    local function noteSplashPreempt()
        for id, info in pairs(entries) do
            local p = info.entry.predicate
            if p.type == "splashPreemptCatch" and isLocked("splashPreemptCatch") then
                if isTBD(p.withinSeconds) or isTBD(p.maxDist) then return end   -- U4 未定，跳过
                grant(id)
            end
        end
    end

    local function update(dt)
        pollAccum = pollAccum + (dt or 0)
        if pollAccum >= POLL_INTERVAL then
            pollAccum = pollAccum - POLL_INTERVAL
            pollObservation()
        end
    end

    -- NewRun：清本周目运行态；跨周目 knowledgeLog 由 profile 保留，不清
    local function resetRun()
        grantedThisRun = {}
        castCount = 0; noBirdCastHappened = false; emptyNetStreak = 0; pollAccum = 0
        for _, d in pairs(domains) do d.granted = 0 end
    end

    local function getDomainLevel(name)
        local d = domains[name]
        return d and d.granted or 0
    end

    -- 注意：以下用 function(_, ...) 显式忽略 self，避免 ks:Method(x) 调用时 self 顶替首个实参
    -- （经典 :/. 陷阱；测试已验证修复前 update 收到 table 导致算术错误）
    return {
        Update = function(_, dt) update(dt) end,
        OnDropItem = function(_, payload) onDropItem(payload) end,
        OnFishingResolved = function(_, record) onFishingResolved(record) end,
        NoteChaseObserved = function(_, durationSec, stationary) noteChaseObserved(durationSec, stationary) end,
        NoteFleeAvoid = function(_) noteFleeAvoid() end,
        NoteSplashPreempt = function(_) noteSplashPreempt() end,
        ResetRun = function(_) resetRun() end,
        GetDomainLevel = function(_, name) return getDomainLevel(name) end,
        IsGranted = function(_, id) return grantedThisRun[id] == true end,
        HasKnowledge = function(_, id) return (profile and profile:HasKnowledge(id)) or grantedThisRun[id] == true end,
        Grant = function(_, id) grant(id) end,
        _debug = { entries = entries, domains = domains },
    }
end

return KnowledgeSystem
