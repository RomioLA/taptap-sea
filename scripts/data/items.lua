-- 四种基础物品定义；价格和世界效果集中在此处。
-- V1_IMPLEMENTATION_VALUE：本表价格/恢复量与配置中的生命周期均已由用户确认。
local GameConfig = require "config.gameplay"

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
local definitions = {
    apple = {
        id = "apple",
        name = "苹果",
        category = "food",
        buyPrice = 30,
        sellPrice = 0,
        heal = 20,
        canEat = true,
        canGive = true,
        worldEffect = "ATTRACT_SMALL_FISH",
        lifetimeSec = GameConfig.drop.lifetimeSec,
    },
    bait = {
        id = "bait",
        name = "鱼饵",
        category = "bait",
        buyPrice = 20,
        sellPrice = 0,
        heal = 0,
        canEat = false,
        canGive = true,
        worldEffect = "ATTRACT_SMALL_FISH",
        lifetimeSec = GameConfig.drop.lifetimeSec,
    },
    sardine = {
        id = "sardine",
        name = "沙丁鱼",
        category = "fish",
        sellPrice = 70,
        heal = 10,
        canEat = true,
        canGive = true,
        worldEffect = "ATTRACT_BIG_FISH",
        lifetimeSec = GameConfig.drop.lifetimeSec,
    },
    tuna = {
        id = "tuna",
        name = "金枪鱼",
        category = "fish",
        sellPrice = 120,
        heal = 20,
        canEat = true,
        canGive = true,
        worldEffect = "NONE",
        lifetimeSec = GameConfig.drop.lifetimeSec,
    },
}

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
