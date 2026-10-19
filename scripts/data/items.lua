-- 物品定义适配层；价格和世界效果集中在此处。
-- V1_IMPLEMENTATION_VALUE：本表价格/恢复量与配置中的生命周期均已由用户确认。
-- V2.8：新增珠宝/珊瑚枝/深海珍珠/海底金属货箱（普通船舱 1 格、可出售）
--       与航海残页/生锈钥匙（独立道具栏、不可出售/丢弃）。
local ItemRows = require("GeneratedData.Items")

local Items = {}
Items.Categories = { "fish", "food", "bait", "treasure", "misc" }
Items.WorldEffects = { "ATTRACT_SMALL_FISH", "ATTRACT_BIG_FISH", "NONE" }

-- V2.8：独立道具栏（不限格、不占普通船舱、不可出售/丢弃）的持有物。
-- 只登记这些 id；其它 treasure 分类仍按普通宝物处理。
local INDEPENDENT_BAR = {
    sea_note_01 = true,
    sea_note_02 = true,
    rusty_key = true,
}

---@class ItemDefinition
---@field id string
---@field name string
---@field category "fish"|"food"|"bait"|"treasure"|"misc"
---@field buyPrice number|nil
---@field sellPrice number
---@field heal number
---@field canEat boolean
---@field canGive boolean
---@field protected boolean
---@field worldEffect string
---@field lifetimeSec number
---@field independentBar boolean 独立道具栏持有物（不占普通船舱格）
---@field useText string|nil 使用/查看时的正文
---@field elderText string|nil 给老人展示时的回应
---@field readTitle string|nil 可阅读物品的标题

---@type table<string, ItemDefinition>
local definitions = {}
-- Giving permissions remain code-owned; the v1 data contract has no canGive field.
-- V2.8：新增交易品与关键道具都提供“给老人=展示且不消耗”。
local giveable = {
    apple = true, bait = true, sardine = true, tuna = true,
    shipwreck_jewelry = true, coral_branch = true, abyss_pearl = true, salvaged_chest = true,
    sea_note_01 = true, sea_note_02 = true, rusty_key = true,
}
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
        protected = row.protected == true,
        worldEffect = row.worldEffect,
        lifetimeSec = row.worldDuration,
        independentBar = INDEPENDENT_BAR[row.id] == true,
        useText = row.useText,
        elderText = row.elderText,
        readTitle = row.readTitle,
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
        protected = definition.protected,
        worldEffect = definition.worldEffect,
        lifetimeSec = definition.lifetimeSec,
        independentBar = definition.independentBar,
        useText = definition.useText,
        elderText = definition.elderText,
        readTitle = definition.readTitle,
    }
    if definition.buyPrice ~= nil then
        copy.buyPrice = definition.buyPrice
    end
    return copy
end

---独立道具栏持有物（不占普通船舱格、不可出售/丢弃）。
---@param itemId string
---@return boolean
function Items.IsIndependentBar(itemId)
    return type(itemId) == "string" and INDEPENDENT_BAR[itemId] == true
end

return Items
