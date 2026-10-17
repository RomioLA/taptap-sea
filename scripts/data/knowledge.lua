--[[
  knowledge.lua — 海域认知度系统 数据契约骨架 (A 侧)
  =====================================================================
  所有权: A = scripts/ (工程骨架) ; B = data/ + docs/ (desc/name 文案)
  运行时加载路径: scripts/data/knowledge.lua (打包根 = scripts/)
  ⚠️ 根目录 data/ 仅 B 侧基准表，勿错拷进 scripts/data/ (铁律)

  契约约束 (设计 v1.0 + 工程审查 R1/R2/R3):
  - 数据源锁定 Ocean 真实层 (Ocean/Fish.lua 的 entity.state/fsm + Ocean/SurfaceSignals.lua)，禁读 Systems 演示层
  - predicate 仅允许白名单类型；新增类型必须走代码评审 (§8.1)，不允许内容侧自由写表达式
  - 条目 once=true 且 run="run" → 本周目内首次触发授予，重复动作不涨 Lv (C1/C3)
  - Lv 由条目数派生，不另存计数器；Domain Lv 本周目重置、图鉴跨周目保留
  - 首批 8 条 (K-abn-2 已 R2 挪二批，本骨架不含)

  🚫 提案「未知」项 — 严禁升格为定稿，本文件内一律以 TBD 占位:
    U1 存档字段名 (knowledgeLog/domainLevels/storyLayerFlags/achievements) 待按 Config.persistence 核对，不擅自新增/写死
    U4 批量 Flee 阈值、水花预判距离 X 待首轮实测
    U2 K-abn-2 区域划分口径未定 (二批)
  详见文件末尾 PERSISTENCE_NOTE / UNKNOWN 段
]]
local TBD = "__TBD__"  -- 未知项哨兵：任何等于 TBD 的字段在实现前不得当作定稿值使用

-- predicate 白名单：KnowledgeSystem 加载时按此表校验，非法 type 直接拒绝 (防 B 侧自由表达式)
-- locked=true  → 基础白名单，可直接用
-- locked=false → 首批需要的复合类型，PROPOSED，须经代码评审通过后改为 locked 方可启用
local PREDICATE_WHITELIST = {
  attractOnBait      = { locked = true,  params = { minFish = "number?" } },
  chaseObserved      = { locked = true,  params = { minDuration = "number", requireStationary = "bool?" } },
  birdSignalCast     = { locked = true,  params = { hitRequired = "bool?" } },
  hypothesisConfirmed = { locked = false, params = { hypothesisId = "string" } }, -- 由 EvidenceSystem 显式 Grant，不参与轮询
  fleeAvoid          = { locked = true,  params = { fleeBatchThreshold = TBD } },          -- U4：批量阈值未知
  splashPreemptCatch = { locked = true,  params = { withinSeconds = TBD, maxDist = TBD } }, -- U4：距离未知
  -- —— 以下 2 个首批 PROPOSED 类型，已于 2026-10-11 代码评审通过 (见对话评审结论)，改 locked=true 启用 ——
  repeatCastNoBird   = { locked = true,
                        -- 评审修订: 合并 fish/bird 同一执行器; track 仅作风味标签不进判定;
                        -- "命中"=投放成功生成 worldEffect (DropItem→spawnDroppedItem 链路), 不要求捕获;
                        -- 轮询0.25s读 SurfaceSignals 鸟群集合: 每次投饵事件 castCount+1; 投饵时刻鸟群为空→noBirdCastHappened=true;
                        -- 授予: castCount>=minCasts 且 (requireNoBirdOnce? noBirdCastHappened:true)
                        params = { track = "fish|bird", minCasts = "number", requireNoBirdOnce = "bool?" } },
  emptyNetWhileFlee  = { locked = true,
                        -- 评审修订: 工程无 zone 系统 (R2 同因把 K-abn-2 挪二批),"逃散区域"不存在 →
                        -- 改用"当前 Flee 信号有效"代理, 复用 fleeAvoid 原语 (SurfaceSignals 逃散类/鱼群批量 Flee);
                        -- 连续空网计数来自 FishingRecord.result=empty; 任意成功捕获 或 投饵时无非逃散信号→计数器清零
                        params = { consecutiveEmpty = "number" } },
}

return {
  version = "1.0.0",

  -- 白名单随数据导出，供 KnowledgeSystem 运行时校验；新增类型须改此处并走评审
  predicateWhitelist = PREDICATE_WHITELIST,

  domains = {
    fish = {
      name = "鱼群知识",
      maxLv = 3,
      entries = {
        {
          id = "K-fish-1", lv = 1,
          name = "鱼群知识 1",
          desc = "你投出诱饵，有鱼被吸引过来——海里的饭局，鱼也认得。",
          predicate = { type = "attractOnBait", minFish = 1 },
          unlockedBy = "首次投饵命中",
          once = true, run = "run",
        },
        {
          id = "K-fish-2", lv = 2,
          name = "鱼群知识 2",
          desc = "不止一回喂到了鱼，而且有一回鸟不在头顶盯着——你学会了不在鸟眼皮底下下网。",
          predicate = { type = "repeatCastNoBird", track = "fish", minCasts = 2, requireNoBirdOnce = true },
          unlockedBy = "二次无信号投饵",
          once = true, run = "run",
          -- note: repeatCastNoBird 已于 2026-10-11 评审通过 (locked=true)，执行器见 KnowledgeSystem.lua
        },
        {
          id = "K-fish-3", lv = 3,
          name = "鱼群知识 3",
          desc = "你停船撒饵，引得大鱼循味追猎了两秒往上——你摸到了「诱」的火候。",
          predicate = { type = "chaseObserved", minDuration = 2, requireStationary = true },
          unlockedBy = "停船诱出追猎",
          once = true, run = "run",
        },
      },
    },

    bird = {
      name = "鸟群知识",
      maxLv = 3,
      entries = {
        {
          id = "K-bird-1", lv = 1,
          name = "鸟群知识 1",
          desc = "顺着鸟影落饵，真的有鱼——你读懂了鸟在替你指路。",
          predicate = { type = "birdSignalCast", hitRequired = true },
          unlockedBy = "循鸟影投饵命中",
          once = true, run = "run",
        },
        {
          id = "K-bird-2", lv = 2,
          name = "鸟群知识 2",
          desc = "没有鸟的时候，你也凭自己的判断找到了鱼——你不再只靠着鸟。",
          predicate = { type = "repeatCastNoBird", track = "bird", minCasts = 2 },
          unlockedBy = "无鸟主动搜索投饵",
          once = true, run = "run",
          -- note: repeatCastNoBird 已于 2026-10-11 评审通过 (locked=true)，执行器见 KnowledgeSystem.lua
        },
        {
          id = "K-bird-3", lv = 3,
          name = "鸟群知识 3",
          desc = "你看清水花的方向，提前把网撒在它前头，大鱼撞了进来——你学会了读海的「脚印」。",
          predicate = { type = "splashPreemptCatch", withinSeconds = TBD, maxDist = TBD }, -- U4 距离待实测
          unlockedBy = "水花预判捕鱼",
          once = true, run = "run",
        },
      },
    },

    island = {
      name = "陆地方位知识",
      maxLv = 1,
      entries = {
        {
          id = "K-isl-1", lv = 1,
          name = "这个方向可能有陆地",
          desc = "这些鸟总朝着相近的方向飞，也许那边有陆地。",
          predicate = { type = "hypothesisConfirmed", hypothesisId = "H-isle-bearing-01" },
          unlockedBy = "多日观察通勤海鸟",
          once = true, run = "run",
        },
      },
    },

    anomaly = {
      name = "异常海域知识",
      maxLv = 3,
      entries = {
        {
          id = "K-abn-1", lv = 1,
          name = "异常海域 1",
          desc = "鱼群突然四散逃开，你立刻收手停船——你认出了「危险」长什么样。",
          predicate = { type = "fleeAvoid", fleeBatchThreshold = TBD }, -- U4 批量阈值待实测
          unlockedBy = "遇逃散停船回避",
          once = true, run = "run",
        },
        {
          id = "K-abn-3", lv = 2,
          name = "异常海域 3",
          desc = "明知道这片在逃散，你还是连撒两网都落空——有些险，硬闯只会扑空。",
          predicate = { type = "emptyNetWhileFlee", consecutiveEmpty = 2 },
          unlockedBy = "无视逃散连续空网",
          once = true, run = "run",
          -- note: emptyNetWhileFlee 已于 2026-10-11 评审通过 (locked=true)，"逃散区域"→"Flee 信号有效"代理，执行器见 KnowledgeSystem.lua
        },
        -- K-abn-2 (回访区域大鱼变少) 已 R2 挪二批：依赖区域划分口径，新增 4 字节区域计数，
        -- 口径未定前不新增事件表字段，故本骨架不含 (U2)。
      },
    },
  },

  --[[
    PERSISTENCE_NOTE (U1)
    本文件【不定义】任何存档键名。跨局持久化字段如下，其具体键名待负责人按
    Config.persistence.schemaVersion 现有 Schema 核对后，由 Persistence 层落地，
    严禁在 KnowledgeSystem 内擅自写死/新增：
      · 图鉴条目 knowledgeLog      → 跨周目保留 (条目 id → 首获周目)
      · Domain Lv domainLevels     → 本周目重置，由 knowledgeLog+本周目集合重算，不作唯一真相
      · 剧情层   storyLayerFlags   → 本周目重置
      · 成就     achievements       → 跨周目保留
    profile 双层存档层尚未新建 (审查 §3.3)，属 C2-1 范围；实现前上述键名一律 TBD。
  ]]

  --[[
    UNKNOWN (提案未知项，严禁升格为定稿)
      U1 存档字段名                → 待 Config.persistence 核对
      U2 K-abn-2 区域划分口径       → 二批，口径未定
      U4 批量 Flee 阈值 / 水花距离 X → 首轮实测，本骨架以 TBD 占位
      U5 elder 苹果计数字段落点      → 审查 §七.3 (A3 依赖)
      U6 云存档双文件支持 / profile 版本策略 → 审查 §3.3/§七.4
      U7 图鉴跨周目 UI             → Schema 未就位则挂 D-4
    凡含 TBD 的字段，在任何实现规格中一律保留占位，不得覆盖为具体数值。
  ]]
}
