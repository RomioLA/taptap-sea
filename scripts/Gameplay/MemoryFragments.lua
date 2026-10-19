-- Read-only access to W-08 story copy for an already-owned world-content reward.
local Content = require "data.content"
local Definitions = require "data.memory_fragments"

local MemoryFragments = {}
local CONTENT_BY_REWARD = {}
local FRAGMENT_BY_CONTENT = {}

for _, definition in ipairs(Content.fixed) do
    local rewardId = definition.rewardId
    if type(rewardId) == "string" then
        assert(CONTENT_BY_REWARD[rewardId] == nil, "duplicate fixed-content reward id")
        CONTENT_BY_REWARD[rewardId] = definition.contentId
    end
end

for rewardId, definition in pairs(Definitions) do
    assert(type(rewardId) == "string" and type(definition) == "table"
        and type(definition.contentId) == "string"
        and type(definition.theme) == "string"
        and type(definition.workingTitle) == "string",
        "invalid W-08 memory-fragment definition")
    assert(CONTENT_BY_REWARD[rewardId] == definition.contentId,
        "W-08 reward/content mapping mismatch")
    assert(FRAGMENT_BY_CONTENT[definition.contentId] == nil,
        "duplicate W-08 content mapping")
    FRAGMENT_BY_CONTENT[definition.contentId] = {
        rewardId = rewardId,
        definition = definition,
    }
end

local function hasText(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

---Return authored player copy only when the matching memory is currently owned.
---@param player table
---@param contentId string
---@return table|nil
function MemoryFragments.GetOwnedStory(player, contentId)
    if type(player) ~= "table" then return nil end
    local mapping = FRAGMENT_BY_CONTENT[contentId]
    if not mapping then return nil end

    local treasures = rawget(player, "treasures")
    if type(treasures) ~= "table" or rawget(treasures, mapping.rewardId) ~= true then
        return nil
    end

    local definition = mapping.definition
    local body = rawget(definition, "body")
    if not hasText(body) then return nil end

    local playerTitle = rawget(definition, "playerTitle")
    if not hasText(playerTitle) then playerTitle = nil end
    return { title = playerTitle, text = body }
end

return MemoryFragments
