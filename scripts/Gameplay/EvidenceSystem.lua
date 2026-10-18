-- Persistent evidence progress for the single confirmed Phase 1 hypothesis.
local HypothesisData = require "data.hypotheses"

local EvidenceSystem = {}
local STORY_KEY = "hypotheses"
local TRACE_ID = "flock_commute"
local SOURCE_CONTENT_ID = "island_02"
local HYPOTHESIS_ID = "H-isle-bearing-01"
local DEFINITIONS = {}
for _, definition in ipairs(HypothesisData.hypotheses) do
    assert(type(definition.id) == "string" and DEFINITIONS[definition.id] == nil,
        "duplicate hypothesis id")
    DEFINITIONS[definition.id] = definition
end
assert(#HypothesisData.hypotheses == 1 and DEFINITIONS[HYPOTHESIS_ID],
    "only H-isle-bearing-01 is approved for production")

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function integer(value, minimum)
    return finite(value) and value >= minimum and value == math.floor(value)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function bearingSpread(evidenceByDay)
    local values = {}
    for _, bearing in pairs(evidenceByDay) do values[#values + 1] = bearing end
    if #values < 2 then return 0 end
    table.sort(values)
    local largestGap = 0
    for index = 1, #values do
        local nextValue = values[index % #values + 1]
        local gap = (nextValue - values[index]) % 360
        if gap > largestGap then largestGap = gap end
    end
    return 360 - largestGap
end

local function validateProgress(value)
    if value == nil then return true end
    if type(value) ~= "table" then return false, "invalid_hypothesis_progress" end
    for hypothesisId, record in next, value do
        if not DEFINITIONS[hypothesisId] then return false, "invalid_hypothesis_id" end
        if type(record) ~= "table" then return false, "invalid_hypothesis_record" end
        for field in next, record do
            if field ~= "evidenceByDay" and field ~= "confirmed" then
                return false, "invalid_hypothesis_field"
            end
        end
        local evidenceByDay = rawget(record, "evidenceByDay")
        if type(evidenceByDay) ~= "table" then return false, "invalid_hypothesis_evidence" end
        for dayKey, bearing in next, evidenceByDay do
            if type(dayKey) ~= "string" or dayKey == "" then return false, "invalid_hypothesis_day" end
            local day = tonumber(dayKey)
            if not integer(day, 1) or tostring(day) ~= dayKey then return false, "invalid_hypothesis_day" end
            if not finite(bearing) or bearing < 0 or bearing >= 360 then
                return false, "invalid_hypothesis_bearing"
            end
        end
        local confirmed = rawget(record, "confirmed")
        if type(confirmed) ~= "boolean" then return false, "invalid_hypothesis_confirmation" end
        if confirmed then
            local count = 0
            for _ in next, evidenceByDay do count = count + 1 end
            local definition = DEFINITIONS[hypothesisId]
            if count < definition.minDistinctDays
                or bearingSpread(evidenceByDay) > definition.maxBearingSpreadDeg then
                return false, "invalid_confirmed_hypothesis"
            end
        end
    end
    return true
end

local function getProgress(player)
    if type(player) ~= "table" then return nil, nil, "invalid_player_state" end
    local story = rawget(player, "story")
    if story ~= nil and type(story) ~= "table" then return nil, nil, "invalid_story_progress" end
    local progress = story and rawget(story, STORY_KEY) or nil
    local valid, reason = validateProgress(progress)
    if not valid then return nil, nil, reason end
    return story, progress or {}, nil
end

local function ensureStory(player)
    if type(player) ~= "table" then return nil, "invalid_player_state" end
    local story = rawget(player, "story")
    if story == nil then
        story = {}
        rawset(player, "story", story)
    elseif type(story) ~= "table" then
        return nil, "invalid_story_progress"
    end
    return story
end

local function stateView(hypothesisId, record)
    local definition = DEFINITIONS[hypothesisId]
    local evidenceByDay = record and record.evidenceByDay or {}
    local days = {}
    for dayKey in pairs(evidenceByDay) do days[#days + 1] = tonumber(dayKey) end
    table.sort(days)
    return {
        hypothesisId = hypothesisId,
        claim = definition.claim,
        hint = definition.hint,
        confirmed = record and record.confirmed == true or false,
        evidenceByDay = copy(evidenceByDay),
        distinctDays = #days,
        days = days,
        bearingSpreadDeg = bearingSpread(evidenceByDay),
    }
end

function EvidenceSystem.Validate(player)
    if type(player) ~= "table" then return false, "invalid_player_state" end
    local story = rawget(player, "story")
    if story ~= nil and type(story) ~= "table" then return false, "invalid_story_progress" end
    return validateProgress(story and rawget(story, STORY_KEY) or nil)
end

function EvidenceSystem.Initialize(player)
    local valid, reason = EvidenceSystem.Validate(player)
    if not valid then return false, reason end
    local story, storyError = ensureStory(player)
    if not story then return false, storyError end
    if rawget(story, STORY_KEY) == nil then rawset(story, STORY_KEY, {}) end
    return EvidenceSystem.Validate(player)
end

function EvidenceSystem.ResetRun(player)
    local initialized, reason = EvidenceSystem.Initialize(player)
    if not initialized then return false, reason end
    rawset(player.story, STORY_KEY, {})
    return true
end

function EvidenceSystem.GetState(player, hypothesisId)
    if not DEFINITIONS[hypothesisId] then return nil, "invalid_hypothesis_id" end
    local _, progress, reason = getProgress(player)
    if not progress then return nil, reason end
    return stateView(hypothesisId, rawget(progress, hypothesisId))
end

function EvidenceSystem.HasEvidenceForDay(player, hypothesisId, day)
    if not DEFINITIONS[hypothesisId] then return false, "invalid_hypothesis_id" end
    if not integer(day, 1) then return false, "invalid_day" end
    local _, progress, reason = getProgress(player)
    if not progress then return false, reason end
    local record = rawget(progress, hypothesisId)
    return record ~= nil and rawget(record.evidenceByDay, tostring(day)) ~= nil or false
end

function EvidenceSystem.RecordObservation(player, event, knowledge, context)
    context = type(context) == "table" and context or {}
    if type(player) ~= "table" then return false, "invalid_player_state" end
    if type(event) ~= "table" or event.type ~= "observation_recorded"
        or event.traceId ~= TRACE_ID or event.traceType ~= TRACE_ID
        or event.sourceContentId ~= SOURCE_CONTENT_ID or event.birdCount ~= 3
        or event.dives ~= false or event.circlesFish ~= false or event.observable ~= true
        or not integer(event.day, 1) or not integer(context.day, 1)
        or event.day ~= context.day or not integer(rawget(player, "day"), 1)
        or player.day ~= context.day or not integer(event.generation, 1)
        or not integer(context.generation, 1) or event.generation ~= context.generation
        or not finite(event.bearing) or event.bearing < 0 or event.bearing >= 360 then
        return false, "invalid_evidence"
    end
    if type(player.IsRecognized) ~= "function" then return false, "recognition_state_unavailable" end
    local recognitionOk, recognized = pcall(player.IsRecognized, player, SOURCE_CONTENT_ID)
    if not recognitionOk then return false, "recognition_state_unavailable" end
    if recognized == true then
        return false, "already_recognized"
    end
    if type(knowledge) ~= "table" or type(knowledge.Grant) ~= "function"
        or type(knowledge.HasKnowledge) ~= "function" then
        return false, "knowledge_unavailable"
    end
    local initialized, initError = EvidenceSystem.Initialize(player)
    if not initialized then return false, initError end
    local definition = DEFINITIONS[HYPOTHESIS_ID]
    local progress = rawget(player.story, STORY_KEY)
    local record = rawget(progress, definition.id)
    if record == nil then
        record = { evidenceByDay = {}, confirmed = false }
        rawset(progress, definition.id, record)
    end
    if record.confirmed then return true, "already_confirmed", stateView(definition.id, record) end

    local dayKey = tostring(event.day)
    local added = rawget(record.evidenceByDay, dayKey) == nil
    if added then rawset(record.evidenceByDay, dayKey, event.bearing) end
    local state = stateView(definition.id, record)
    if state.distinctDays < definition.minDistinctDays
        or state.bearingSpreadDeg > definition.maxBearingSpreadDeg then
        return true, added and "recorded" or "duplicate_day", state
    end

    local grantOk = pcall(knowledge.Grant, knowledge, definition.knowledgeId)
    local hasCallOk, hasKnowledge = pcall(knowledge.HasKnowledge, knowledge, definition.knowledgeId)
    if not grantOk or not hasCallOk or hasKnowledge ~= true then
        return false, "knowledge_grant_failed", stateView(definition.id, record)
    end
    rawset(record, "confirmed", true)
    local confirmed = stateView(definition.id, record)
    return true, "confirmed", confirmed
end

function EvidenceSystem.Snapshot(player)
    local valid, reason = EvidenceSystem.Validate(player)
    if not valid then return nil, reason end
    local story = rawget(player, "story")
    return copy(story and rawget(story, STORY_KEY) or {})
end

function EvidenceSystem.Restore(player, snapshot)
    if snapshot == nil then snapshot = {} end
    local valid, reason = validateProgress(snapshot)
    if not valid then return false, reason end
    local story, storyError = ensureStory(player)
    if not story then return false, storyError end
    local previous = rawget(story, STORY_KEY)
    rawset(story, STORY_KEY, copy(snapshot))
    local restored, restoreError = EvidenceSystem.Validate(player)
    if not restored then
        rawset(story, STORY_KEY, previous)
        return false, restoreError
    end
    return true
end

return EvidenceSystem
