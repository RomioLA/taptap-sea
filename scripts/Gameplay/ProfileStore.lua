--[[
  ProfileStore.lua — ③ profile 双层存档层 (C2-1)
  =====================================================================
  职责：承载【跨周目保留】数据
    · knowledgeLog  : 图鉴条目 id → 首获周目 (由 KnowledgeSystem 写入)
    · achievements  : 成就 id → true          (由 AchievementSystem 写入)
  本周目字段 (domainLevels / storyLayerFlags) 由 KnowledgeSystem 派生/重算，
  不在此持久化（审查 §3.3 / 契约）。

  设计约束：
  - 使用 Config.persistence.profileKey 作为独立云 key，等同「双文件」语义；
    云不支持多 key 时，调用方 (Loop) 也可改为并入现有 snapshot 的命名空间字段。
  - 不修改 Persistence.lua / PlayerState.lua 核心结构（降低与并行会话冲突）；
    仅依赖 Config.persistence 已登记的键（铁律5：禁止自由加键）。
  - 接口对齐 Persistence 约定：Save/Load 异步回调，单次回调保障；schemaVersion 校验。
  - 云不可用时退化为内存/本地，不阻塞游戏（与 Persistence 一致）。

  接线点（由 Loop 在合适时机调用，本模块不自行动）：
  - 启动时：profile = ProfileStore.New(cloud, localBackend); profile:Load(function(ok,data) ... end)
  - KnowledgeSystem/AchievementSystem 持有 profile 实例，授予时写内存，定期/关键节点 profile:Save(done)
  - NewRun 时不清 profile（跨周目保留）；仅 KnowledgeSystem.ResetRun 清本周目运行态
]]
local Config = require("config.gameplay")
local LocalSaveBackend = require("Gameplay.LocalSaveBackend")

local ProfileStore = {}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

local function fresh()
    return {
        schemaVersion = Config.persistence.profileSchemaVersion,
        knowledgeLog = {},
        achievements = {},
    }
end

-- 统一 backend 接口：Save(value, done) / Load(done)，done(ok, data)
-- 入参 cloud/localBackend 与 Persistence.Dual 同签名；缺省回退全局 clientCloud / 内存。
local function makeBackend(cloud, localBackend)
    if localBackend ~= nil then
        -- 对齐 LocalSaveBackend: Save(snapshot, cb) / Load(cb)
        return localBackend
    end
    local key = Config.persistence.profileKey
    local c = cloud or _G.clientCloud
    if c ~= nil then
        return {
            Save = function(value, done)
                c:Set(key, value, {
                    ok = function() done(true) end,
                    error = function(code, reason) done(false, tostring(code) .. ":" .. tostring(reason)) end,
                    timeout = function() done(false, "timeout") end,
                })
            end,
            Load = function(done)
                c:Get(key, {
                    ok = function(values) done(true, values and values[key] or nil) end,
                    error = function(code, reason) done(false, tostring(code) .. ":" .. tostring(reason)) end,
                    timeout = function() done(false, "timeout") end,
                })
            end,
        }
    end
    -- 离线 / 单测：纯内存（注意首参 self 占位，统一用 backend:Save / backend:Load 调用）
    local mem
    return {
        Save = function(_, value, done) mem = copy(value); if done then done(true) end end,
        Load = function(_, done) if done then done(true, mem and copy(mem) or nil) end end,
    }
end

function ProfileStore.New(cloud, localBackend)
    if localBackend == nil and LocalSaveBackend.Available() then
        localBackend = LocalSaveBackend.New()
    end
    local backend = makeBackend(cloud, localBackend)
    local cache = fresh()
    local loaded = false

    -- 回填：保留已有 knowledgeLog/achievements，schemaVersion 不符则丢弃（视为无存档）
    local function applyLoaded(data)
        if type(data) ~= "table" then return false end
        if data.schemaVersion ~= Config.persistence.profileSchemaVersion then return false end
        if type(data.knowledgeLog) == "table" then
            for k, v in pairs(data.knowledgeLog) do cache.knowledgeLog[k] = v end
        end
        if type(data.achievements) == "table" then
            for k, v in pairs(data.achievements) do cache.achievements[k] = v end
        end
        loaded = true
        return true
    end

    local api = {
        -- 内存查询（注意：这些方法是用 profile:Method(x) 冒号调用的，
        -- 首参 self 必须显式占位，否则 entryId/achId 会被 self 顶替 —— 同 :/. 陷阱）
        GetCache = function() return cache end,
        IsLoaded = function() return loaded end,
        HasKnowledge = function(_, entryId) return cache.knowledgeLog[entryId] ~= nil end,
        GetKnowledgeFirstWeek = function(_, entryId) return cache.knowledgeLog[entryId] end,
        HasAchievement = function(_, achId) return cache.achievements[achId] == true end,

        -- 写入（仅改内存；Save 才落盘）
        RecordKnowledge = function(_, entryId, week)
            if cache.knowledgeLog[entryId] == nil then cache.knowledgeLog[entryId] = week or 1 end
        end,
        MarkAchievement = function(_, achId) cache.achievements[achId] = true end,

        -- 持久化
        Save = function(_, done)
            backend:Save(copy(cache), function(ok, err)
                if type(done) == "function" then done(ok, err) end
            end)
        end,
        Load = function(_, done)
            backend:Load(function(ok, data)
                local applied = false
                if ok and data ~= nil then applied = applyLoaded(data) end
                if type(done) == "function" then done(ok and applied, data) end
            end)
        end,

        -- 调试 / 清档
        ResetCache = function() cache = fresh(); loaded = false end,
    }
    return api
end

return ProfileStore
