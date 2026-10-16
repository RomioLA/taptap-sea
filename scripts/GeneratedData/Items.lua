-- GENERATED from data/items.lua; edit the source, never this file.
-- Regenerate: python tests/sync_runtime_data.py; verify: add --check.
-- Source SHA-256: 1a369da6cfe8ed9a0e1f1df975fe49896c08981dfc40f4cd86a2a254a6fedd45
-- data/items.lua — 物品表
-- 格式契约见 docs/DATA_SCHEMA.md 第 1 节；本文件由 B 维护（基准行由 A 预填）
-- 纯数据：不写函数、不 require

return {
  {
    id = "apple",
    name = "苹果",
    category = "food",
    buy = 30,                       -- 来源：参数表「Apple」
    heal = 20,                      -- 来源：参数表「Apple」；不超过 maxStamina
    worldEffect = "ATTRACT_SMALL_FISH", -- 来源：参数表「Apple」
    worldDuration = 20,             -- 来源：参数表「Apple」
    shopStockPerDay = 2,            -- 来源：参数表「Apple商店库存」
    description = "唯一的食物，可以吃、给老人或投进海里。",
  },
  {
    id = "bait",
    name = "鱼饵",
    category = "bait",
    buy = 20,                       -- 来源：参数表「Bait」
    worldEffect = "ATTRACT_SMALL_FISH", -- 来源：参数表「Bait」
    worldDuration = 20,             -- 来源：参数表「Bait」
    shopStockPerDay = 2,            -- 来源：参数表「Bait商店库存」
    description = "专门吸引小鱼的诱饵，不恢复体力。",
  },
  {
    id = "sardine",
    name = "沙丁鱼",
    category = "fish",
    sell = 70,                      -- 来源：参数表「Sardine物品」
    heal = 10,                      -- 来源：参数表「Sardine物品」
    worldEffect = "ATTRACT_BIG_FISH", -- 来源：参数表「Sardine物品」；投海即大鱼诱饵
    worldDuration = 20,
    description = "普通稳定的小鱼获。投进海里会把大鱼引来。",
  },
  {
    id = "tuna",
    name = "金枪鱼",
    category = "fish",
    sell = 120,                     -- 来源：参数表「Tuna物品」
    heal = 20,                      -- 来源：参数表「Tuna物品」
    worldEffect = "NONE",
    worldDuration = 20,
    description = "正确读海与构造捕食链的奖励，比沙丁鱼高 50。",
  },
  -- TODO(B)：M3 阶段追加 category=treasure 宝藏条目，无统一售价，逐条单独定义
}
