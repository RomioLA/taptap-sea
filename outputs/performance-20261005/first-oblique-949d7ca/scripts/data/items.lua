-- 四种基础物品定义；价格和世界效果集中在此处。
-- V1_IMPLEMENTATION_VALUE：本表价格/恢复量与配置中的生命周期均已由用户确认。
local ItemRows = require("GeneratedData.Items")

local Items = {}
Items.Categories = { "fish", "food", "bait", "treasure", "misc" }
Items.WorldEffects = { "ATTRACT_SMALL_FISH", "ATTRACT_BIG_FISH", "NONE" }

---@class ItemDefinition
---@field id string
---@field name string
---@field category "fish"|"food"|"bait"|"treasure"|"misc"
---@field buyPrice number|nil
---@field sellPrice number
---@field heal number
---@field canEat boolean
---@field canGive boolean
---@field worldEffect string
---@field lifetimeSec number

---@type table<string, ItemDefinition>
local definitions = {}
-- Giving permissions remain code-owned; the v1 data contract has no canGive field.
local giveable = { apple = true, bait = true, sardine = true, tuna = true }
for _, row in ipairs(ItemRows) do
    assert(definitions[row.id] == nil, "duplicate item ID in data table")
    definitions[row.id] = {
        id = row.id,
        name = row.name,
        category = row.category,
        buyPrice = row.buy,
        sellPrice = row.sell or 0,
        heal = row.heal or 0,
        canEat = row.heal ~= nil,
        canGive = giveable[row.id] == true,
        worldEffect = row.worldEffect,
        lifetimeSec = row.worldDuration,
    }
end

---返回独立定义副本；未知物品返回 nil。
---@param itemId string
---@return ItemDefinition|nil
function Items.GetDefinition(itemId)
    if type(itemId) ~= "string" then
        return nil
    end

    local definition = definitions[itemId]
    if not definition then
        return nil
    end

    local copy = {
        id = definition.id,
        name = definition.name,
        category = definition.category,
        sellPrice = definition.sellPrice,
        heal = definition.heal,
        canEat = definition.canEat,
        canGive = definition.canGive,
        worldEffect = definition.worldEffect,
        lifetimeSec = definition.lifetimeSec,
    }
    if definition.buyPrice ~= nil then
        copy.buyPrice = definition.buyPrice
    end
    return copy
end

return Items
