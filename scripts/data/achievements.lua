--[[
  achievements.lua — 成就系统 数据契约骨架 (A 侧)
  =====================================================================
  所有权: A = scripts/ (工程骨架 + predicate 机制) ; B = data/ + docs/ (name/desc 文案)
  运行时加载路径: scripts/data/achievements.lua (打包根 = scripts/)
  ⚠️ 根目录 data/ 仅 B 侧基准表，勿错拷进 scripts/data/ (铁律)

  契约约束 (设计 v1.0 §6 + 工程审查 §3.6):
  - 成就 = 纯聚合层，判定源全部现成 (审查 §3.6)，无新依赖
  - predicate 仅允许白名单类型 (声明式，非裸代码)，新增须走代码评审 (D-E)
  - 奖励类型仅限信息类 (codexRecall / elderComment / logLine)，严禁体力/金钱/鱼价/速度/掉落/透镜/关键物品/隐藏结局输入 (§6.5 红线)
  - 全部 9 条成就跨周目保留 (persist = "profile")，奖励不给数值，以免污染 Q-011 经济观察 (§6.5)

  🚫 提案「未知」项 — 严禁升格为定稿:
    U1 存档键名 (achievements 等) 待按 Config.persistence 核对，不擅自新增/写死
    U5 elder 苹果计数字段落点 (A3 依赖) 待负责人核对
    U6 云存档双文件支持 / profile 版本策略 待确认
  详见文件末尾 PERSISTENCE_NOTE / UNKNOWN 段
]]
local TBD = "__TBD__"  -- 未知项哨兵：任何等于 TBD 的字段在实现前不得当作定稿值使用

-- predicate 白名单：AchievementSystem 加载时校验，非法 type 直接拒绝
-- 判定源全部现成 (审查 §3.6)，locked=true 表示类型已批准，执行器随聚合层实现
local PREDICATE_WHITELIST = {
  firstDayLens   = { locked = true, params = {} },                                  -- A1 木桶阶段3
  zeroEmptyDay   = { locked = true, params = { requirePaidCast = true } },           -- A2 当日空网=0 且≥1付费捕鱼
  appleCount     = { locked = true, params = { min = 3, withinDays = 3 } },           -- A3 前三天累计3苹果
  unusualBranch  = { locked = true, params = {} },                                   -- A4 事件状态机非常规结果 id
  bigFishRatio   = { locked = true, params = { gte = 0.6, minCount = 5 } },          -- A5 单日大鱼≥60% 且≥5条
  noForceReturn  = { locked = true, params = { maxLateSeconds = 30 } },              -- A6 每日晚归≤30s (03页安全边界)
  domainLv       = { locked = true, params = { domain = "fish|bird|anomaly", gte = "number" } }, -- C1~C3 派生
}

-- 奖励白名单：仅信息类，严禁数值/物品 (§6.5)
local REWARD_WHITELIST = {
  codexRecall  = true,  -- 图鉴条目回忆页 + 老人一句评价
  elderComment = true,  -- 老人一句评价 (本周目首次)
  logLine      = true,  -- 结局后「航海日志」一行统计
}

return {
  version = "1.0.0",

  predicateWhitelist = PREDICATE_WHITELIST,
  rewardWhitelist = REWARD_WHITELIST,

  -- 行为成就 6 条 (圈2 已锁定，不改)
  behavior = {
    { id = "A1", name = "首日透镜",
      desc = "出海第一天，你就把透镜捞出了木桶。眼界，从这一刻开了。",
      predicate = { type = "firstDayLens" },
      reward = { type = "logLine" }, persist = "profile" },
    { id = "A2", name = "单日零空网",
      desc = "总有那么一天，你撒下的每一网都不落空。手感最好的一天。",
      predicate = { type = "zeroEmptyDay" },
      reward = { type = "logLine" }, persist = "profile" },
    { id = "A3", name = "三个苹果",
      desc = "前三天，你给老人攒齐了三个苹果。他没说谢谢，但你看得出。",
      predicate = { type = "appleCount", min = 3, withinDays = 3 },
      reward = { type = "logLine" }, persist = "profile" },  -- U5: 苹果计数字段落点待核对
    { id = "A4", name = "非常规分支",
      desc = "海上的事不都按剧本走。你撞见了一个没人提起过的转折。",
      predicate = { type = "unusualBranch" },
      reward = { type = "logLine" }, persist = "profile" },
    { id = "A5", name = "满载而归",
      desc = "那天你拉上来的，多半是大家伙。船吃水都深了。",
      predicate = { type = "bigFishRatio", gte = 0.6, minCount = 5 },
      reward = { type = "logLine" }, persist = "profile" },
    { id = "A6", name = "无强返通关",
      desc = "整整七天，没有一夜是被强行赶回港的。你把控住了自己的节奏。",
      predicate = { type = "noForceReturn", maxLateSeconds = 30 },  -- 30s 为 03 页定稿值，非 TBD
      reward = { type = "logLine" }, persist = "profile" },
  },

  -- 认知成就 3 条 (新增，派生自 KnowledgeSystem Lv 变化；零额外监听成本)
  cognition = {
    { id = "C1", name = "认得鱼群",
      desc = "鱼群，你认得门道了。老人说你「开始像个打鱼的人」。",
      predicate = { type = "domainLv", domain = "fish", gte = 2 },
      reward = { type = "codexRecall" }, persist = "profile" },
    { id = "C2", name = "认得鸟群",
      desc = "鸟群，你也读得懂了。天上那本账，你翻开了。",
      predicate = { type = "domainLv", domain = "bird", gte = 2 },
      reward = { type = "codexRecall" }, persist = "profile" },
    { id = "C3", name = "认得异常海域",
      desc = "哪片海不安生，你心里有了数。老人点点头：「你学会怕海了。」",
      predicate = { type = "domainLv", domain = "anomaly", gte = 2 },
      reward = { type = "codexRecall" }, persist = "profile" },  -- U3: C3 首轮达成率≥60% 为 [PLACEHOLDER] 假设，非定稿目标
  },

  --[[
    PERSISTENCE_NOTE (U1)
    本文件【不定义】存档键名。成就记录跨周目保留，其具体键名 (候选语义 achievements)
    待负责人按 Config.persistence.schemaVersion 现有 Schema 核对后，由 Persistence 层落地，
    严禁在 AchievementSystem 内擅自写死/新增。persist = "profile" 仅表示作用域语义，
    非字面存储键。profile 双层存档层尚未新建 (审查 §3.3)，属 C2-1 范围。
  ]]

  --[[
    UNKNOWN (提案未知项，严禁升格为定稿)
      U1 存档键名                → 待 Config.persistence 核对
      U3 C3 首轮达成率 ≥60%      → [PLACEHOLDER·假设·3人试玩]，非定稿验收目标
      U5 elder 苹果计数字段落点   → 审查 §七.3 (A3 依赖)
      U6 云存档双文件支持 / profile 版本策略 → 审查 §3.3/§七.4
    凡含 TBD 的字段，在任何实现规格中一律保留占位，不得覆盖为具体数值。
  ]]
}
