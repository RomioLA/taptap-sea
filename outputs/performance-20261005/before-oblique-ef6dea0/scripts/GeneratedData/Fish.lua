-- GENERATED from data/fish.lua; edit the source, never this file.
-- Regenerate: python tests/sync_runtime_data.py; verify: add --check.
-- Source SHA-256: f6563e4cfc32c55adbd471118c43658e1c59d27fffc8d752dffc4c688bdd7a21
-- data/fish.lua — 鱼种表
-- 格式契约见 docs/DATA_SCHEMA.md 第 2 节；本文件由 B 维护（基准行由 A 预填）
-- 纯数据：不写函数、不 require
-- 注意：Wander 换向区间、区域密度(20/4)、每日刷新规则在代码侧 Config.lua，不在这里

return {
  {
    id = "sardine",
    name = "沙丁鱼",
    speeds = { wander = 4, attracted = 5, flee = 7 }, -- 来源：参数表「Sardine移动」
    turnRate = 220,                                   -- °/s
    attractedBy = "ATTRACT_SMALL_FISH",               -- 响应 bait/apple 投海
    sense = {
      attract = 18,                                   -- 来源：参数表「Sardine感知」ATTRACT_SMALL_FISH 18m
      danger  = 12,                                   -- 来源：同上；危险感知故意短（Tuna 30>12 先发现它）
    },
    avoid = {
      predict = 4,                                    -- 来源：参数表「Sardine避障」
      steerInterval = 0.4,                            -- 来源：参数表「Sardine逃跑」
      steerDeviation = 25,                            -- ±25°，最终方向仍须远离危险
    },
    spawn = {
      minDistFromBoat = 15,                           -- 来源：参数表「区域生成防贴脸」
    },
    ai = { fullRange = 120, freezeRange = 150 },      -- 来源：参数表「离屏对象」双阈值
    itemDropped = "sardine",                          -- 被捕获后进入背包的物品 id
  },
  {
    id = "tuna",
    name = "金枪鱼",
    speeds = { wander = 5, attracted = 6, chase = 8 }, -- 来源：参数表「Tuna移动」，保持 5<6<8
    turnRate = 90,
    attractedBy = "ATTRACT_BIG_FISH",                  -- 响应玩家投海的 sardine 等大鱼诱饵
    sense = {
      attract = 36,                                    -- 来源：参数表「Tuna大鱼诱饵感知」36m，与普通感知不同来源
      prey    = 30,                                    -- 来源：参数表「Tuna正常猎物感知」30m，30>12 使它先发现小鱼
    },
    avoid = {
      predict = 6,                                     -- 来源：参数表「Tuna避障」速度更快、转向更慢需更早预判
    },
    predation = {
      contact = 1.5,                                   -- 来源：参数表「捕食」接触距离
      loseTargetAfter = 2,                             -- 丢失猎物 2s 后回 Wander
    },
    spawn = {
      minDistFromBoat = 30,                            -- 来源：参数表「区域生成防贴脸」
      minDistFromDayStart = 200,                       -- 来源：参数表「Tuna新日生成限制」
    },
    ai = { fullRange = 120, freezeRange = 150 },
    itemDropped = "tuna",
  },
}
