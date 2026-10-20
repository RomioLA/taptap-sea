-- GENERATED from data/items.lua; edit the source, never this file.
-- Regenerate: python tests/sync_runtime_data.py; verify: add --check.
-- Source SHA-256: 92805980c086f6b34fe6c3915bd7a2efea543abb7349a76ff3061ad4c24eb411
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
  -- ===== V2.8 新增物品（来源：游戏道具总表 35~43、56~67 行）=====
  -- 珠宝/珊瑚枝/深海珍珠/海底金属货箱：普通船舱 1 格、可出售、不可投海。
  {
    id = "shipwreck_jewelry",
    name = "珠宝",
    category = "misc",
    sell = 90,                      -- 来源：游戏道具总表「珠宝」G列
    worldEffect = "NONE",
    worldDuration = 20,
    description = "从沉船里捞出的珠宝，带回港口能卖个好价钱。",
    useText = "你擦了擦珠宝。亮得晃眼，带回港口一定能卖不少钱。",
    elderText = "珠宝？沉船里捞的？他娘的，你小子发财了。收好，回港卖了够你吃半年。",
  },
  {
    id = "coral_branch",
    name = "珊瑚枝",
    category = "misc",
    sell = 45,                      -- 来源：游戏道具总表「珊瑚枝」G列
    worldEffect = "NONE",
    worldDuration = 20,
    description = "一截色泽鲜艳的红珊瑚枝，枝杈完整。",
    useText = "一截色泽鲜艳的红珊瑚枝，枝杈完整，带回港口应该能卖个好价钱。",
    elderText = "珊瑚枝？在咱海上可不值钱，可到岸上那就不一样咯。",
  },
  {
    id = "abyss_pearl",
    name = "深海珍珠",
    category = "misc",
    sell = 260,                     -- 来源：游戏道具总表「深海珍珠」G列
    worldEffect = "NONE",
    worldDuration = 20,
    description = "从海眼深处涌出的硕大珍珠，表面泛着幽蓝与银白交织的光泽。",
    useText = "一颗从海眼深处涌出的硕大珍珠，表面泛着幽蓝与银白交织的光泽。带回港口一定能卖出高价。",
    elderText = "你往海眼里面扔了条金枪鱼？！他娘的，也就是你小子敢拿大鱼喂海眼……不过它吐出来的这颗深海珠子，可比鱼值钱多了！",
  },
  {
    id = "salvaged_chest",
    name = "海底金属货箱",
    category = "misc",
    sell = 110,                     -- 来源：游戏道具总表「海底金属货箱」G列
    worldEffect = "NONE",
    worldDuration = 20,
    description = "从浮藻假岛水下打捞上来的沉重金属货箱，锁扣已经打开。",
    useText = "一只从浮藻假岛水下打捞上来的沉重金属货箱，锁扣已经用生锈钥匙打开，里面装着封存完好的航海器物，带回港口能卖个好价钱。",
    elderText = "假岛底下捞上来的铁箱子？亏你小子找得到钥匙。带回港口卖给识货的商人吧，值不少钱。",
  },
  -- 航海残页与生锈钥匙：独立道具栏（不占普通船舱），不可出售、不可丢弃。
  {
    id = "sea_note_01",
    name = "航海残页（一）",
    category = "treasure",
    protected = true,
    worldEffect = "NONE",
    worldDuration = 20,
    description = "记录着北偏西深水慢气泡与巨骨大鱼经验的航海残页。",
    useText = "瓶里塞着半页被海水泡黄的笔记：“往北偏西再走百来米，海面上总有洗不散的孤泡。早年我贴着水面往下看，隐约瞧见一副吓人的大骨头……怪的是，那儿的小鱼虽少，大鱼却总爱围着骨头转悠。”",
    elderText = "北边深水里的大骨头？老辈人常说，大鱼喜欢在那种大骸骨附近寻食。你若是拿到了探海镜，顺着冒泡的海面往下照照就知道了。",
    readTitle = "航海残页（一）",
  },
  {
    id = "sea_note_02",
    name = "航海残页（二）",
    category = "treasure",
    protected = true,
    worldEffect = "NONE",
    worldDuration = 20,
    description = "记录着东偏北中海漩涡传导气味与海眼回应经验的航海残页。",
    useText = "纸页边缘已经烂了，只剩几行歪斜的字：“东北边的中海有一处打旋的海眼，里头连着深水暗流。我试着往旋儿里扔过平时喂鱼的碎食，也扔过刚捞上来的活小鱼，水底下的动静一次比一次凶……要是有人舍得把海里最肥的大物扔进去，不知那海眼最底下会吐出什么来？”",
    elderText = "海眼漩涡？那地方水流怪得很，随手往船边丢东西可没用，得认认真真往漩涡中心【投放】，暗流才会把味儿传开。",
    readTitle = "航海残页（二）",
  },
  {
    id = "rusty_key",
    name = "生锈钥匙",
    category = "treasure",
    protected = true,
    worldEffect = "NONE",
    worldDuration = 20,
    description = "一把沾着海藻的旧铜钥匙，上面刻着模糊的箱扣纹路。",
    useText = "一把沾着海藻的旧铜钥匙，上面刻着模糊的箱扣纹路。靠近需要钥匙的水下货箱打捞时即可派上用场。",
    elderText = "这是老式货箱上的铜钥匙……海上留下来的东西，总有它原来的主人。",
  },
}
