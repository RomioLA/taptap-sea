-- Circle 1B2 的长期进度；仅在明确的日结入口推进老人结局。
local Progress = {}

local RECORD_KEY = "circle1B2"
local ELDER_DEFAULTS = { applesGiven = 0, decision = "pending", teachingDone = false }
local STORY_DEFAULTS = { barrelStage = 0, paperShown = false }

local function finite(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function integer(value, minimum)
    return finite(value) and value >= minimum and value == math.floor(value)
end

local function initializeRecord(namespace, defaults)
    local record = namespace[RECORD_KEY]
    if record == nil then
        record = {}
        namespace[RECORD_KEY] = record
    end
    if type(record) ~= "table" then return end

    for key, defaultValue in pairs(defaults) do
        if record[key] == nil then record[key] = defaultValue end
    end
end

local function initializeNamespace(player, key, defaults)
    local namespace = player[key]
    if namespace == nil then
        namespace = {}
        player[key] = namespace
    end
    if type(namespace) ~= "table" then return end
    initializeRecord(namespace, defaults)
end

---只补全缺失字段；显式错误类型留给 Validate 拒绝。
---@param player table
---@return boolean, string|nil
function Progress.Initialize(player)
    if type(player) ~= "table" then return false, "invalid_player_state" end

    initializeNamespace(player, "elder", ELDER_DEFAULTS)
    initializeNamespace(player, "story", STORY_DEFAULTS)

    if player.treasures == nil then player.treasures = {} end
    if type(player.treasures) == "table" and player.treasures.scopeLens == nil then
        player.treasures.scopeLens = false
    end
    return true
end

local function checkNamespace(player, key, label)
    local namespace = player[key]
    if namespace == nil then return true, nil, nil end
    if type(namespace) ~= "table" then return false, nil, "invalid_" .. label end

    local record = namespace[RECORD_KEY]
    if record == nil then return true, namespace, nil end
    if type(record) ~= "table" then return false, nil, "invalid_" .. label .. "_circle1B2" end
    return true, namespace, record
end

---纯校验圈1B2进度，不补默认值、不推进日期或剧情。
---@param data table
---@return boolean, string|nil
function Progress.Validate(data)
    if type(data) ~= "table" then return false, "invalid_progress_state" end

    local elderOk, _, elder = checkNamespace(data, "elder", "elder_progress")
    if not elderOk then return false, elder end
    if elder then
        local applesGiven = elder.applesGiven
        if not integer(applesGiven, 0) then
            return false, "invalid_elder_apples_given"
        end

        local decision = elder.decision
        if decision ~= "pending" and decision ~= "saved" and decision ~= "dead" then
            return false, "invalid_elder_decision"
        end

        if elder.teachingDone ~= nil and type(elder.teachingDone) ~= "boolean" then
            return false, "invalid_elder_teaching_done"
        end

        if decision == "saved" or decision == "dead" then
            local day = data.day
            if not integer(day, 1) or day < 4 then return false, "invalid_elder_decision_day" end
            if decision == "saved" and applesGiven < 3 then return false, "invalid_elder_saved_count" end
            if decision == "dead" and applesGiven >= 3 then return false, "invalid_elder_dead_count" end
        end
    end

    local storyOk, _, story = checkNamespace(data, "story", "story_progress")
    if not storyOk then return false, story end
    if story then
        local barrelStage = story.barrelStage
        if not integer(barrelStage, 0) or barrelStage > 3 then
            return false, "invalid_barrel_stage"
        end
        if type(story.paperShown) ~= "boolean" then
            return false, "invalid_paper_shown"
        end
        if story.paperShown and (not integer(data.day, 1) or data.day < 7) then
            return false, "paper_shown_before_day_seven"
        end
    end

    local treasures = data.treasures
    if treasures ~= nil and type(treasures) ~= "table" then
        return false, "invalid_treasure_progress"
    end
    if type(treasures) == "table" and treasures.scopeLens ~= nil
        and type(treasures.scopeLens) ~= "boolean" then
        return false, "invalid_scope_lens"
    end

    if story and story.barrelStage == 3
        and (type(treasures) ~= "table" or treasures.scopeLens ~= true) then
        return false, "final_barrel_stage_requires_lens"
    end
    return true
end

local function getRecord(player, namespaceKey, label)
    if type(player) ~= "table" then return nil, "invalid_player_state" end
    local namespace = player[namespaceKey]
    if namespace == nil then return nil, nil end
    if type(namespace) ~= "table" then return nil, "invalid_" .. label end
    local record = namespace[RECORD_KEY]
    if record == nil then return nil, nil end
    if type(record) ~= "table" then return nil, "invalid_" .. label .. "_circle1B2" end
    return record, nil
end

local function ensureRecord(player, namespaceKey, defaults, label)
    local initialized, reason = Progress.Initialize(player)
    if not initialized then return nil, reason end
    local record, recordError = getRecord(player, namespaceKey, label)
    if recordError then return nil, recordError end
    if not record then return nil, "invalid_" .. label .. "_circle1B2" end
    for key, defaultValue in pairs(defaults) do
        if record[key] == nil then record[key] = defaultValue end
    end
    return record, nil
end

local function validDecision(decision)
    return decision == "pending" or decision == "saved" or decision == "dead"
end

---仅在第4天或以后、且仍待判定时结算老人结局。
---@param player table
---@return boolean, string|nil
function Progress.OnDayStarted(player)
    local record, reason = ensureRecord(player, "elder", ELDER_DEFAULTS, "elder_progress")
    if not record then return false, reason end
    if not integer(player.day, 1) then return false, "invalid_day" end
    if not integer(record.applesGiven, 0) then return false, "invalid_elder_apples_given" end
    if not validDecision(record.decision) then return false, "invalid_elder_decision" end

    if player.day >= 4 and record.decision == "pending" then
        record.decision = record.applesGiven >= 3 and "saved" or "dead"
    end
    return true
end

---第1至3天记录已交付的苹果；不改变体力。
---@param player table
---@return boolean, string|nil
function Progress.RecordApple(player)
    local record, reason = ensureRecord(player, "elder", ELDER_DEFAULTS, "elder_progress")
    if not record then return false, reason end
    if not integer(player.day, 1) then return false, "invalid_day" end
    if player.day > 3 then return false, "apple_gift_window_closed" end
    if not integer(record.applesGiven, 0) then return false, "invalid_elder_apples_given" end
    if not validDecision(record.decision) then return false, "invalid_elder_decision" end
    if record.decision ~= "pending" then return false, "elder_decision_finalized" end

    local nextCount = record.applesGiven + 1
    if not integer(nextCount, 0) or nextCount <= record.applesGiven then
        return false, "invalid_elder_apples_given"
    end
    record.applesGiven = nextCount
    return true
end

---按天数及已判定结局查询老人在场状态。
---@param player table
---@return boolean, string|nil
function Progress.IsElderPresent(player)
    if type(player) ~= "table" or not integer(player.day, 1) then return false, "invalid_day" end
    local record, reason = getRecord(player, "elder", "elder_progress")
    if reason then return false, reason end

    local applesGiven = record and record.applesGiven or 0
    local decision = record and record.decision or "pending"
    if not integer(applesGiven, 0) then return false, "invalid_elder_apples_given" end
    if not validDecision(decision) then return false, "invalid_elder_decision" end

    if player.day <= 3 then return true end
    if player.day <= 7 then
        if decision == "saved" and applesGiven >= 3 then return true end
        return false, "elder_not_present"
    end
    return false, "规则尚未确定"
end

---查询教学是否已完成（首次领取捕鱼收获后置位）。
---@param player table
---@return boolean, string|nil
function Progress.IsTeachingDone(player)
    if type(player) ~= "table" then return false, "invalid_player_state" end
    local record, reason = getRecord(player, "elder", "elder_progress")
    if reason then return false, reason end
    if not record or record.teachingDone == nil then return false end
    if type(record.teachingDone) ~= "boolean" then return false, "invalid_elder_teaching_done" end
    return record.teachingDone
end

---标记看海教学完成；重复标记幂等。由首次领取捕鱼收获触发（05 页：
---"配合一次玩家实际投饵、捕鱼和结果反馈"）。
---@param player table
---@return boolean, string|nil
function Progress.MarkTeachingDone(player)
    if type(player) ~= "table" or not integer(player.day, 1) then return false, "invalid_day" end
    local record, reason = ensureRecord(player, "elder", ELDER_DEFAULTS, "elder_progress")
    if not record then return false, reason end
    if record.teachingDone ~= nil and type(record.teachingDone) ~= "boolean" then
        return false, "invalid_elder_teaching_done"
    end
    record.teachingDone = true
    return true
end

---查询是否持有透镜。
---@param player table
---@return boolean, string|nil
function Progress.HasLens(player)
    if type(player) ~= "table" then return false, "invalid_player_state" end
    local treasures = player.treasures
    if treasures == nil then return false end
    if type(treasures) ~= "table" then return false, "invalid_treasure_progress" end
    local hasLens = treasures.scopeLens
    if hasLens == nil then return false end
    if type(hasLens) ~= "boolean" then return false, "invalid_scope_lens" end
    return hasLens
end

---授予透镜；授予来源由调用方决定。
---@param player table
---@return boolean, string|nil
function Progress.GrantLens(player)
    local initialized, reason = Progress.Initialize(player)
    if not initialized then return false, reason end
    local treasures = player.treasures
    if type(treasures) ~= "table" then return false, "invalid_treasure_progress" end
    if treasures.scopeLens ~= nil and type(treasures.scopeLens) ~= "boolean" then
        return false, "invalid_scope_lens"
    end
    treasures.scopeLens = true
    return true
end

---读取木桶阶段；未初始化的旧状态视为阶段0。
---@param player table
---@return integer|nil, string|nil
function Progress.GetBarrelStage(player)
    local record, reason = getRecord(player, "story", "story_progress")
    if reason then return nil, reason end
    if not record or record.barrelStage == nil then return 0 end
    if not integer(record.barrelStage, 0) or record.barrelStage > 3 then
        return nil, "invalid_barrel_stage"
    end
    return record.barrelStage
end

---设置圈1B2规定的木桶阶段0至3。
---@param player table
---@param stage integer
---@return boolean, string|nil
function Progress.SetBarrelStage(player, stage)
    if not integer(stage, 0) or stage > 3 then return false, "invalid_barrel_stage" end
    local record, reason = ensureRecord(player, "story", STORY_DEFAULTS, "story_progress")
    if not record then return false, reason end
    if not integer(record.barrelStage, 0) or record.barrelStage > 3 then
        return false, "invalid_barrel_stage"
    end
    if stage == 3 then
        local hasLens, lensError = Progress.HasLens(player)
        if lensError then return false, lensError end
        if not hasLens then return false, "final_barrel_stage_requires_lens" end
    end
    record.barrelStage = stage
    return true
end

---查询第7天纸条是否已明确展示。
---@param player table
---@return boolean, string|nil
function Progress.IsPaperShown(player)
    local record, reason = getRecord(player, "story", "story_progress")
    if reason then return false, reason end
    if not record or record.paperShown == nil then return false end
    if type(record.paperShown) ~= "boolean" then return false, "invalid_paper_shown" end
    return record.paperShown
end

---标记纸条已展示，不会自动打开或创建对话。
---@param player table
---@return boolean, string|nil
function Progress.MarkPaperShown(player)
    if type(player) ~= "table" or not integer(player.day, 1) then return false, "invalid_day" end
    if player.day ~= 7 then return false, "paper_not_available_today" end
    local record, reason = ensureRecord(player, "story", STORY_DEFAULTS, "story_progress")
    if not record then return false, reason end
    if record.paperShown ~= nil and type(record.paperShown) ~= "boolean" then
        return false, "invalid_paper_shown"
    end
    record.paperShown = true
    return true
end

return Progress
