-- V2.8 海上内容周目状态。
-- 设计约束（V2.8 最终封板 / 系统规则·V2.8检查点增量）：
--   * 能由物品持有推导的状态一律不落盘：漂流瓶拾取由 treasures.sea_note_01/02 推导；
--   * 海眼珍珠因可出售/丢弃，单独保存 story.v28.vortexPearlClaimed；
--   * 其它固定内容复用 story.worldContent 的 recognized/marked/completed；
--   * V2.7 旧档缺字段时按 false / 未持有初始化，不判坏档、不强制 NewRun；
--   * 运行中可立即内存置位防同局重复，但持久化只随正式检查点（日结/终局/NewRun）。
local Content = require "data.content"
local WorldContentProgress = require "Gameplay.WorldContentProgress"

local V28 = {}

local STORY_KEY = "v28"

-- 由 data.content 的 stateFields 声明的额外状态字段（例如 leviathan recognized）。
local FIELD_BY_CONTENT = {}
local CONTENT_IDS = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validContentId(contentId)
    return type(contentId) == "string" and contentId ~= ""
end

for _, definition in ipairs(Content.fixed) do
    if type(definition.contentId) == "string" and type(definition.stateFields) == "table" then
        local fields = {}
        for _, field in ipairs(definition.stateFields) do
            assert(field == "marked" or field == "completed" or field == "recognized",
                "unsupported V2.8 content state field: " .. tostring(field))
            fields[field] = true
        end
        FIELD_BY_CONTENT[definition.contentId] = fields
        CONTENT_IDS[#CONTENT_IDS + 1] = definition.contentId
    end
end

---Return the authored state-field set for one V2.8 content id.
---@param contentId string
---@return table|nil
function V28.StateFields(contentId)
    return FIELD_BY_CONTENT[contentId]
end

---Read the raw V2.8 namespace without creating it.
---@param player table
---@return table|nil
local function rawNamespace(player)
    local story = type(player) == "table" and rawget(player, "story") or nil
    if type(story) ~= "table" then return nil end
    local namespace = rawget(story, STORY_KEY)
    return type(namespace) == "table" and namespace or nil
end

---Pure validation; never fills defaults.
---@param player table
---@return boolean, string|nil
function V28.Validate(player)
    if type(player) ~= "table" then return false, "invalid_player_state" end
    local story = rawget(player, "story")
    if story ~= nil and type(story) ~= "table" then return false, "invalid_story_progress" end
    if type(story) == "table" then
        local namespace = rawget(story, STORY_KEY)
        if namespace ~= nil then
            if type(namespace) ~= "table" then return false, "invalid_v28_progress" end
            for key, value in next, namespace do
                if key ~= "vortexPearlClaimed" and key ~= "content" then
                    return false, "invalid_v28_progress_field"
                end
                if key == "vortexPearlClaimed" and type(value) ~= "boolean" then
                    return false, "invalid_v28_pearl_claim"
                end
                if key == "content" then
                    if type(value) ~= "table" then return false, "invalid_v28_content_progress" end
                    for contentId, record in next, value do
                        local fields = validContentId(contentId) and FIELD_BY_CONTENT[contentId] or nil
                        if not fields then return false, "invalid_v28_content_id" end
                        if type(record) ~= "table" then return false, "invalid_v28_content_progress" end
                        for field, flag in next, record do
                            if not fields[field] then return false, "invalid_v28_content_progress_field" end
                            if type(flag) ~= "boolean" then return false, "invalid_v28_content_flag" end
                        end
                    end
                end
            end
        end
    end

    local treasures = rawget(player, "treasures")
    if treasures ~= nil and type(treasures) ~= "table" then
        return false, "invalid_treasure_progress"
    end
    if type(treasures) == "table" then
        for _, id in ipairs({ "sea_note_01", "sea_note_02", "rusty_key" }) do
            local owned = rawget(treasures, id)
            if owned ~= nil and type(owned) ~= "boolean" then
                return false, "invalid_v28_treasure_flag"
            end
        end
    end
    return true
end

---Fill only missing V2.8 fields; explicit wrong types stay rejected by Validate.
---@param player table
---@return boolean, string|nil
function V28.Initialize(player)
    if type(player) ~= "table" then return false, "invalid_player_state" end
    local story = rawget(player, "story")
    if story == nil then
        story = {}
        rawset(player, "story", story)
    end
    if type(story) ~= "table" then return false, "invalid_story_progress" end
    local namespace = rawget(story, STORY_KEY)
    if namespace == nil then
        namespace = {}
        rawset(story, STORY_KEY, namespace)
    end
    if type(namespace) ~= "table" then return false, "invalid_v28_progress" end
    if rawget(namespace, "vortexPearlClaimed") == nil then
        rawset(namespace, "vortexPearlClaimed", false)
    end
    local contentProgress = rawget(namespace, "content")
    if contentProgress == nil then
        contentProgress = {}
        rawset(namespace, "content", contentProgress)
    end
    if type(contentProgress) ~= "table" then return false, "invalid_v28_content_progress" end
    for _, contentId in ipairs(CONTENT_IDS) do
        local record = rawget(contentProgress, contentId)
        if record == nil then
            record = {}
            rawset(contentProgress, contentId, record)
        end
        if type(record) ~= "table" then return false, "invalid_v28_content_progress" end
        for field in pairs(FIELD_BY_CONTENT[contentId]) do
            if rawget(record, field) == nil then rawset(record, field, false) end
        end
    end

    local treasures = rawget(player, "treasures")
    if treasures == nil then
        treasures = {}
        rawset(player, "treasures", treasures)
    end
    if type(treasures) ~= "table" then return false, "invalid_treasure_progress" end
    for _, id in ipairs({ "sea_note_01", "sea_note_02", "rusty_key" }) do
        if rawget(treasures, id) == nil then rawset(treasures, id, false) end
    end
    return V28.Validate(player)
end

---Read one boolean V2.8 flag (never creates it).
---@param player table
---@param contentId string
---@param field string
---@return boolean
function V28.GetFlag(player, contentId, field)
    local namespace = rawNamespace(player)
    local records = namespace and rawget(namespace, "content") or nil
    local record = type(records) == "table" and rawget(records, contentId) or nil
    if type(record) ~= "table" then return false end
    return rawget(record, field) == true
end

---Set one boolean V2.8 flag; the caller decides when it is persisted.
---@param player table
---@param contentId string
---@param field string
---@param value boolean
---@return boolean, string|nil
function V28.SetFlag(player, contentId, field, value)
    local fields = FIELD_BY_CONTENT[contentId]
    if not fields or not fields[field] then return false, "invalid_v28_content_field" end
    if type(value) ~= "boolean" then return false, "invalid_v28_content_flag" end
    local initialized, reason = V28.Initialize(player)
    if not initialized then return false, reason end
    local records = rawget(rawget(rawget(player, "story"), STORY_KEY), "content")
    rawset(rawget(records, contentId), field, value)
    return true
end

---Runtime recognition flag (bones / kelp mirage disguise).
---@param player table
---@param contentId string
---@return boolean
function V28.IsRecognized(player, contentId)
    return V28.GetFlag(player, contentId, "recognized")
end

---@param player table
---@param contentId string
---@return boolean, string|nil
function V28.MarkRecognized(player, contentId)
    return V28.SetFlag(player, contentId, "recognized", true)
end

---Owned independent-bar treasure flag (sea notes, rusty key).
---@param player table
---@param treasureId string
---@return boolean
function V28.HasTreasure(player, treasureId)
    local treasures = type(player) == "table" and rawget(player, "treasures") or nil
    return type(treasures) == "table" and rawget(treasures, treasureId) == true
end

---Grant one independent-bar treasure; idempotent, never touches the cargo grid.
---@param player table
---@param treasureId string
---@return boolean, string|nil
function V28.GrantTreasure(player, treasureId)
    if type(treasureId) ~= "string" or treasureId == "" then return false, "invalid_treasure_id" end
    local initialized, reason = V28.Initialize(player)
    if not initialized then return false, reason end
    rawset(rawget(player, "treasures"), treasureId, true)
    return true, "granted"
end

---Consume one independent-bar treasure; returns false when it was not owned.
---@param player table
---@param treasureId string
---@return boolean, string|nil
function V28.ConsumeTreasure(player, treasureId)
    if not V28.HasTreasure(player, treasureId) then return false, "missing_key" end
    local initialized, reason = V28.Initialize(player)
    if not initialized then return false, reason end
    rawset(rawget(player, "treasures"), treasureId, false)
    return true, "consumed"
end

---Sea-eye pearl claim: once true it stays true for the whole run, even after the
---pearl is sold or dropped.
---@param player table
---@return boolean
function V28.IsPearlClaimed(player)
    local namespace = rawNamespace(player)
    return type(namespace) == "table" and rawget(namespace, "vortexPearlClaimed") == true
end

---@param player table
---@param claimed boolean
---@return boolean, string|nil
function V28.SetPearlClaimed(player, claimed)
    if type(claimed) ~= "boolean" then return false, "invalid_v28_pearl_claim" end
    local initialized, reason = V28.Initialize(player)
    if not initialized then return false, reason end
    rawset(rawget(rawget(player, "story"), STORY_KEY), "vortexPearlClaimed", claimed)
    return true
end

---Derived: a fixed bottle is present only while its note is not owned.
---@param player table
---@param contentId string
---@return boolean
function V28.IsBottlePicked(player, contentId)
    for _, definition in ipairs(Content.fixed) do
        if definition.contentId == contentId then
            local pickup = definition.pickup
            if type(pickup) ~= "table" or type(pickup.treasureId) ~= "string" then return false end
            return V28.HasTreasure(player, pickup.treasureId)
        end
    end
    return false
end

---NewRun reset: V2.8 周目状态全部回到初始值。
---@param player table
---@return boolean, string|nil
function V28.ResetRun(player)
    if type(player) ~= "table" then return false, "invalid_player_state" end
    local story = rawget(player, "story")
    if type(story) ~= "table" then
        story = {}
        rawset(player, "story", story)
    end
    local namespace = rawget(story, STORY_KEY)
    if type(namespace) ~= "table" then
        namespace = {}
        rawset(story, STORY_KEY, namespace)
    end
    local contentProgress = rawget(namespace, "content")
    if type(contentProgress) ~= "table" then
        contentProgress = {}
        rawset(namespace, "content", contentProgress)
    end
    for _, contentId in ipairs(CONTENT_IDS) do
        local record = rawget(contentProgress, contentId)
        if type(record) ~= "table" then
            record = {}
            rawset(contentProgress, contentId, record)
        end
        for field in pairs(FIELD_BY_CONTENT[contentId]) do rawset(record, field, false) end
    end
    rawset(namespace, "vortexPearlClaimed", false)
    local treasures = rawget(player, "treasures")
    if type(treasures) ~= "table" then
        treasures = {}
        rawset(player, "treasures", treasures)
    end
    for _, id in ipairs({ "sea_note_01", "sea_note_02", "rusty_key" }) do
        rawset(treasures, id, false)
    end
    return V28.Validate(player)
end

---V2.8 新增普通船舱交易品的可售性（不是鱼，也不是宝藏栏物品）。
---@param definition table|nil
---@return boolean
function V28.IsSellableCargo(definition)
    if type(definition) ~= "table" then return false end
    if type(definition.sellPrice) ~= "number" or definition.sellPrice <= 0 then return false end
    if definition.category == "treasure" then return false end
    return definition.category == "fish" or definition.category == "misc"
end

---@param contentId string
---@return boolean
function V28.IsKnownContent(contentId)
    return validContentId(contentId) and FIELD_BY_CONTENT[contentId] ~= nil
end

---V2.8 content completion + WorldContentProgress integration guard.
---@param player table
---@param contentId string
---@return table|nil, string|nil
function V28.GetProgressState(player, contentId)
    if not validContentId(contentId) then return nil, "invalid_content_id" end
    local ok, reason = WorldContentProgress.Initialize(player)
    if not ok then return nil, reason end
    local fields = FIELD_BY_CONTENT[contentId]
    if not fields then return nil, "invalid_v28_content_id" end
    local initialized, initError = V28.Initialize(player)
    if not initialized then return nil, initError end
    local state = {}
    for field in pairs(fields) do state[field] = V28.GetFlag(player, contentId, field) end
    return state
end

---Snapshot one V2.8 content record (for rollback on a failed 4s transaction).
---@param player table
---@param contentId string
---@return table|nil, string|nil
function V28.Snapshot(player, contentId)
    local state, reason = V28.GetProgressState(player, contentId)
    if not state then return nil, reason end
    return { contentId = contentId, fields = state }
end

---Restore one V2.8 content record.
---@param player table
---@param contentId string
---@param snapshot table
---@return boolean, string|nil
function V28.Restore(player, contentId, snapshot)
    if type(snapshot) ~= "table" or snapshot.contentId ~= contentId
        or type(snapshot.fields) ~= "table" then
        return false, "invalid_v28_progress_snapshot"
    end
    local fields = FIELD_BY_CONTENT[contentId]
    if not fields then return false, "invalid_v28_content_id" end
    for field, value in next, snapshot.fields do
        if not fields[field] or type(value) ~= "boolean" then
            return false, "invalid_v28_progress_snapshot"
        end
    end
    for field in pairs(fields) do
        local value = rawget(snapshot.fields, field)
        if type(value) ~= "boolean" then return false, "invalid_v28_progress_snapshot" end
        local ok, reason = V28.SetFlag(player, contentId, field, value)
        if not ok then return false, reason end
    end
    return true
end

return V28
