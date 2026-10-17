-- 固定世界内容点的长期标记、完成状态与记忆归属。
-- 正式记忆保存在 player.treasures，不进入背包；进度由 story/treasures 随存档跨日保留。
local Circle1B2 = require "Gameplay.Circle1B2Progress"
local Content = require "data.content"

local Progress = {}

local STORY_KEY = "worldContent"
local CONTENT_IDS, CONTENT_DEFINITIONS = {}, {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validLensKeySource(definition)
    local action = definition.action
    return type(definition.contentId) == "string" and definition.contentId ~= ""
        and definition.rewardId == nil and definition.keySource == true
        and definition.revealMethod == "lens" and definition.markable == true
        and type(definition.keyId) == "string" and definition.keyId ~= ""
        and type(action) == "table" and type(action.kind) == "string" and action.kind ~= ""
        and finite(action.duration) and action.duration > 0
        and finite(action.staminaCost) and action.staminaCost >= 0
end

for _, definition in ipairs(Content.fixed) do
    if definition.rewardId ~= nil then
        assert(type(definition.rewardId) == "string" and type(definition.markable) == "boolean",
            "fixed content progress metadata is incomplete")
        CONTENT_IDS[#CONTENT_IDS + 1] = definition.contentId
        CONTENT_DEFINITIONS[definition.contentId] = {
            rewardId = definition.rewardId, markable = definition.markable,
        }
    elseif validLensKeySource(definition) then
        CONTENT_IDS[#CONTENT_IDS + 1] = definition.contentId
        CONTENT_DEFINITIONS[definition.contentId] = { markable = true, sourceOnly = true }
    end
end

local function validContentId(contentId)
    return type(contentId) == "string" and CONTENT_DEFINITIONS[contentId] ~= nil
end

local function getContainers(data)
    local story = rawget(data, "story")
    local treasures = rawget(data, "treasures")
    if story ~= nil and type(story) ~= "table" then
        return nil, nil, "invalid_story_progress"
    end
    if treasures ~= nil and type(treasures) ~= "table" then
        return nil, nil, "invalid_treasure_progress"
    end
    return story, treasures, nil
end

local function validateContentProgress(data)
    local story, treasures, containerError = getContainers(data)
    if containerError then return false, containerError end

    local contentProgress = story and rawget(story, STORY_KEY)
    if contentProgress ~= nil and type(contentProgress) ~= "table" then
        return false, "invalid_world_content_progress"
    end

    if contentProgress then
        for contentId, record in next, contentProgress do
            if not validContentId(contentId) then return false, "invalid_content_id" end
            if type(record) ~= "table" then return false, "invalid_content_progress" end
            local definition = CONTENT_DEFINITIONS[contentId]
            for field in next, record do
                if definition.sourceOnly then
                    if field ~= "marked" then return false, "invalid_content_progress_field" end
                elseif field ~= "completed" and (field ~= "marked" or not definition.markable) then
                    return false, "invalid_content_progress_field"
                end
            end
            if definition.sourceOnly then
                if type(rawget(record, "marked")) ~= "boolean" then
                    return false, "invalid_content_marked"
                end
            else
                if type(rawget(record, "completed")) ~= "boolean" then
                    return false, "invalid_content_completed"
                end
            end
            if not definition.sourceOnly and definition.markable then
                if type(rawget(record, "marked")) ~= "boolean" then
                    return false, "invalid_content_marked"
                end
            elseif not definition.sourceOnly and rawget(record, "marked") ~= nil then
                return false, "invalid_content_progress_field"
            end
        end
    end

    for _, contentId in ipairs(CONTENT_IDS) do
        local definition = CONTENT_DEFINITIONS[contentId]
        if not definition.sourceOnly then
            local record = contentProgress and rawget(contentProgress, contentId) or nil
            local completed = record and rawget(record, "completed") == true or false
            local owned = treasures and rawget(treasures, definition.rewardId) or nil
            if owned ~= nil and type(owned) ~= "boolean" then
                return false, "invalid_memory_ownership"
            end
            owned = owned == true
            if definition.markable and completed and not rawget(record, "marked") then
                return false, "completed_content_not_marked"
            end
            if completed ~= owned then return false, "content_reward_completion_mismatch" end
        end
    end
    return true
end

---纯校验世界内容进度及 Circle1B2 既有进度，不补默认值。
---@param player table
---@return boolean, string|nil
function Progress.Validate(player)
    if type(player) ~= "table" then return false, "invalid_player_state" end

    local callOk, circleOk, circleError = pcall(Circle1B2.Validate, player)
    if not callOk then return false, "invalid_progress_state" end
    if not circleOk then return false, circleError or "invalid_progress_state" end
    return validateContentProgress(player)
end

---只补缺失的世界内容记录；已有畸形状态先拒绝。
---@param player table
---@return boolean, string|nil
function Progress.Initialize(player)
    local valid, validationError = Progress.Validate(player)
    if not valid then return false, validationError end

    local circleOk, circleError = Circle1B2.Initialize(player)
    if not circleOk then return false, circleError or "invalid_progress_state" end

    local story = rawget(player, "story")
    local treasures = rawget(player, "treasures")
    if type(story) ~= "table" then
        story = {}
        rawset(player, "story", story)
    end
    if type(treasures) ~= "table" then
        treasures = {}
        rawset(player, "treasures", treasures)
    end

    local contentProgress = rawget(story, STORY_KEY)
    if contentProgress == nil then
        contentProgress = {}
        rawset(story, STORY_KEY, contentProgress)
    end
    for _, contentId in ipairs(CONTENT_IDS) do
        local definition = CONTENT_DEFINITIONS[contentId]
        if rawget(contentProgress, contentId) == nil then
            local record = definition.sourceOnly and { marked = false } or { completed = false }
            if definition.markable and not definition.sourceOnly then record.marked = false end
            rawset(contentProgress, contentId, record)
        end
        if not definition.sourceOnly and rawget(treasures, definition.rewardId) == nil then
            rawset(treasures, definition.rewardId, false)
        end
    end
    return Progress.Validate(player)
end

local function prepare(player, contentId)
    if not validContentId(contentId) then return false, "invalid_content_id" end
    local initialized, reason = Progress.Initialize(player)
    if not initialized then return false, reason end
    return true
end

local function stateFor(player, contentId)
    local story = rawget(player, "story")
    local treasures = rawget(player, "treasures")
    local record = rawget(rawget(story, STORY_KEY), contentId)
    local definition = CONTENT_DEFINITIONS[contentId]
    if definition.sourceOnly then return { marked = rawget(record, "marked") } end
    local state = {
        completed = rawget(record, "completed"),
        rewardOwned = rawget(treasures, definition.rewardId),
    }
    if definition.markable then state.marked = rawget(record, "marked") end
    return state
end

---读取一个固定内容点的标记、完成和奖励归属状态。
---@param player table
---@param contentId string
---@return table|nil, string|nil
function Progress.GetState(player, contentId)
    local ready, reason = prepare(player, contentId)
    if not ready then return nil, reason end
    return stateFor(player, contentId)
end

---标记内容已发现；重复调用幂等。
---@param player table
---@param contentId string
---@return boolean, string|nil
function Progress.Mark(player, contentId)
    if not validContentId(contentId) then return false, "invalid_content_id" end
    local definition = assert(CONTENT_DEFINITIONS[contentId])
    if not definition.markable then
        return false, "content_not_markable"
    end
    local ready, reason = prepare(player, contentId)
    if not ready then return false, reason end
    local story = rawget(player, "story")
    local records = rawget(story, STORY_KEY)
    local record = rawget(records, contentId)
    rawset(record, "marked", true)
    return true
end

local function snapshotFor(contentId, state)
    if state.completed == nil and state.rewardOwned == nil then
        return { contentId = contentId, marked = state.marked }
    end
    local snapshot = {
        contentId = contentId,
        completed = state.completed,
        rewardOwned = state.rewardOwned,
    }
    if state.marked ~= nil then snapshot.marked = state.marked end
    return snapshot
end

---捕获单个内容点的可恢复快照，供外围事务失败时调用 Restore。
---@param player table
---@param contentId string
---@return table|nil, string|nil
function Progress.Snapshot(player, contentId)
    local ready, reason = prepare(player, contentId)
    if not ready then return nil, reason end
    return snapshotFor(contentId, stateFor(player, contentId))
end

---恢复 Snapshot 捕获的单点状态；畸形快照或进度不匹配时不写入。
---@param player table
---@param contentId string
---@param snapshot table
---@return boolean, string|nil
function Progress.Restore(player, contentId, snapshot)
    local ready, reason = prepare(player, contentId)
    if not ready then return false, reason end
    local definition = assert(CONTENT_DEFINITIONS[contentId])
    if definition.sourceOnly then
        if type(snapshot) ~= "table" or rawget(snapshot, "contentId") ~= contentId
            or type(rawget(snapshot, "marked")) ~= "boolean" then
            return false, "invalid_progress_snapshot"
        end
        for field in next, snapshot do
            if field ~= "contentId" and field ~= "marked" then
                return false, "invalid_progress_snapshot"
            end
        end
        local record = rawget(rawget(rawget(player, "story"), STORY_KEY), contentId)
        local before = rawget(record, "marked")
        local writeOk = pcall(rawset, record, "marked", rawget(snapshot, "marked"))
        if not writeOk then
            rawset(record, "marked", before)
            return false, "progress_restore_failed"
        end
        local valid, validationError = Progress.Validate(player)
        if not valid then
            rawset(record, "marked", before)
            return false, validationError or "progress_restore_failed"
        end
        return true
    end
    if type(snapshot) ~= "table" or rawget(snapshot, "contentId") ~= contentId
        or type(rawget(snapshot, "completed")) ~= "boolean"
        or type(rawget(snapshot, "rewardOwned")) ~= "boolean" then
        return false, "invalid_progress_snapshot"
    end
    for field in next, snapshot do
        if field ~= "contentId" and field ~= "completed" and field ~= "rewardOwned"
            and (field ~= "marked" or not definition.markable) then
            return false, "invalid_progress_snapshot"
        end
    end
    ---@type boolean|nil
    local marked
    if definition.markable then
        marked = rawget(snapshot, "marked")
        if type(marked) ~= "boolean" then return false, "invalid_progress_snapshot" end
    elseif rawget(snapshot, "marked") ~= nil then
        return false, "invalid_progress_snapshot"
    end
    local completed = rawget(snapshot, "completed")
    local rewardOwned = rawget(snapshot, "rewardOwned")
    if (definition.markable and completed and not marked) or (completed ~= rewardOwned) then
        return false, "invalid_progress_snapshot"
    end

    local before = stateFor(player, contentId)
    local story = rawget(player, "story")
    local treasures = rawget(player, "treasures")
    local record = rawget(rawget(story, STORY_KEY), contentId)
    local writeOk = pcall(function()
        if definition.markable then rawset(record, "marked", marked) end
        rawset(record, "completed", completed)
        rawset(treasures, definition.rewardId, rewardOwned)
    end)
    if not writeOk then
        if definition.markable then rawset(record, "marked", before.marked) end
        rawset(record, "completed", before.completed)
        rawset(treasures, definition.rewardId, before.rewardOwned)
        return false, "progress_restore_failed"
    end

    local valid, validationError = Progress.Validate(player)
    if not valid then
        if definition.markable then rawset(record, "marked", before.marked) end
        rawset(record, "completed", before.completed)
        rawset(treasures, definition.rewardId, before.rewardOwned)
        return false, validationError or "progress_restore_failed"
    end
    return true
end

---完成内容并登记对应奖励；重复提交不重复授予。
---@param player table
---@param contentId string
---@return boolean, string|nil
function Progress.Commit(player, contentId)
    local ready, reason = prepare(player, contentId)
    if not ready then return false, reason end

    if CONTENT_DEFINITIONS[contentId].sourceOnly then
        return false, "content_not_committable"
    end

    local state = stateFor(player, contentId)
    if state.completed then return true, "already_completed" end
    local definition = assert(CONTENT_DEFINITIONS[contentId])
    if definition.markable and not state.marked then return false, "content_not_marked" end

    local snapshot = snapshotFor(contentId, state)
    local story = rawget(player, "story")
    local treasures = rawget(player, "treasures")
    local record = rawget(rawget(story, STORY_KEY), contentId)
    local writeOk = pcall(function()
        rawset(record, "completed", true)
        rawset(treasures, definition.rewardId, true)
    end)
    if not writeOk then
        if definition.markable then rawset(record, "marked", snapshot.marked) end
        rawset(record, "completed", snapshot.completed)
        rawset(treasures, definition.rewardId, snapshot.rewardOwned)
        return false, "progress_commit_failed"
    end

    local valid, validationError = Progress.Validate(player)
    if not valid then
        if definition.markable then rawset(record, "marked", snapshot.marked) end
        rawset(record, "completed", snapshot.completed)
        rawset(treasures, definition.rewardId, snapshot.rewardOwned)
        return false, validationError or "progress_commit_failed"
    end
    return true, "committed"
end

return Progress
