-- data/events.lua — 事件表
-- 格式契约见 docs/DATA_SCHEMA.md 第 3 节；本文件由 B 维护
-- 纯数据：不写函数、不 require
--
-- 硬性设计约束（验收会检查）：
-- 1. 实操选项 reward 必须非空（钱/物品/flag 至少一样）——花40不能什么都没有
-- 2. 触发与观察免费，只有玩家主动选实操选项才扣体力
-- 3. v1 总事件池约 10 个，一二周目共用；二周目新结果填 ngPlusResult（M5 再填）
-- 4. trigger.pos 为占位坐标，正式坐标由 A 结合世界布局统一下发后更新

return {
  {
    -- 示例条目：仅作格式示范，B 按此格式补齐其余事件
    id = "driftwood_barrel",
    name = "漂流木桶",
    trigger = { type = "proximity", pos = { x = 400, y = 300 }, radius = 30 },
    observeText = "海面上漂着一只半沉的木桶，隐约能看见里面的东西。",
    options = {
      {
        text = "靠近打捞",
        staminaCost = 40,              -- 来源：参数表「打捞」一次实际打捞 40 stamina
        interactRadius = 5,            -- 来源：参数表「普通海上交互距离」≤5m
        resultText = "你把木桶捞上船，里面有几份用得上的东西。",
        reward = { items = { "bait", "apple" } },
      },
      { text = "离开", staminaCost = 0 },
    },
    once = true,
  },

  -- TODO(B)：按上述格式补齐其余事件，目标池共约 10 个：
  -- 免费观察型（0 体力）与实操型（40 体力）混合；
  -- 至少 1 个与透视镜相关（二周目可快速重复的功能性事件）；
  -- 每条数据注明来源（策划文档/平衡表），坐标先占位。
}
