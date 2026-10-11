-- data/elder_qa.lua — 老人知识问答知识库（B 侧纯数据）
-- 格式契约：return {...}，纯数据：不写函数、不 require。
-- 字段：
--   id        唯一标识
--   tag       分类（fish/bird/weather/wreck/lamp/anomaly/gameplay/lore/meta）
--   keywords  命中关键词数组（玩家输入包含其中任一子串即计分，越长越优先）
--   answer    老人口吻答复
--
-- 匹配由 scripts/Gameplay/ElderQA.lua 负责；本文件只描述“知识”。
-- 首版由 WorkBuddy 起草（2026-10-09），后续由 Codex 扩充内容。

return {
  -- ===== 玩法 / 操作 =====
  {
    id = "gameplay_fishing",
    tag = "gameplay",
    keywords = { "捕鱼", "钓鱼", "下网", "下钩", "怎么捕鱼", "怎么钓鱼", "鱼怎么捕", "撒网" },
    answer = "投了饵，看水鸟往哪盘旋、看水花往哪翻，再下网。白天出海，别一上来就急着撒。",
  },
  {
    id = "gameplay_bait",
    tag = "gameplay",
    keywords = { "鱼饵", "饵", "放饵", "鱼饵怎么用", "诱饵", "怎么用饵" },
    answer = "饵抛在船尾水面，越远越好。饵不包你一定上鱼，多试几次，海有海的脾气。",
  },
  {
    id = "gameplay_lens",
    tag = "gameplay",
    keywords = { "透镜", "望远镜", "怎么用透镜", "怎么用望远镜", "望远处", "看远处" },
    answer = "对着海面望，能看清远处的暗流、礁石和漂浮的东西。海上认路，全靠它。",
  },
  {
    id = "gameplay_stamina",
    tag = "gameplay",
    keywords = { "体力", "累", "恢复体力", "饿了", "没体力", "stamina" },
    answer = "吃个苹果、吃条沙丁鱼都能回点力气。别硬撑到透支，海上没力气比没鱼更要命。",
  },
  {
    id = "gameplay_sell",
    tag = "gameplay",
    keywords = { "卖鱼", "卖钱", "换钱", "卖", "卖东西", "鱼卖给谁", "卖鱼给" },
    answer = "回港找商人，鱼都卖给他。价随鱼种走，大鱼比小鱼值钱得多。",
  },
  {
    id = "gameplay_return",
    tag = "gameplay",
    keywords = { "返港", "回港", "回家", "靠岸", "回港口", "回岸" },
    answer = "天黑前得回港。夜里海上不认人，晚归的都要多吃一回苦头。",
  },
  {
    id = "gameplay_barrel",
    tag = "gameplay",
    keywords = { "木桶", "打捞", "桶", "海岸木桶", "木桶干嘛", "桶里" },
    answer = "海岸边那只木桶，下面多半压着东西。靠上去点检查，多打捞几次就有收获。",
  },
  {
    id = "gameplay_shop",
    tag = "gameplay",
    keywords = { "商店", "买", "商人", "买什么", "shop", "商铺" },
    answer = "港口商人那儿能买苹果和鱼饵，也能花钱把船养得更经用。",
  },
  {
    id = "gameplay_upgrade",
    tag = "gameplay",
    keywords = { "升级", "船", "船速", "快一点", "升级船", "买船", "改造" },
    answer = "攒下的钱能升级体力、船速和船舱容量。船快了，一天能跑更多地方。",
  },
  {
    id = "gameplay_daynight",
    tag = "gameplay",
    keywords = { "白天", "黑夜", "夜晚", "昼夜", "天黑", "时间", "一天", "白天多长" },
    answer = "一天里白天长些、夜晚短些，周而复始。白日讨海，夜里归舱，别乱了时辰。",
  },
  {
    id = "gameplay_cargo",
    tag = "gameplay",
    keywords = { "满舱", "船舱", "容量", "装不下", "背包满", "舱满了" },
    answer = "船舱就那么大，装满了就回港卖了再装。贪多撑破舱，反而误事。",
  },
  {
    id = "gameplay_nightrisk",
    tag = "gameplay",
    keywords = { "晚归", "夜晚风险", "晚上回不去", "罚", "迟到", "夜罚" },
    answer = "天黑还漂在外头，风浪和暗流都来欺负你。能早回就早回，别赌运气。",
  },
  {
    id = "gameplay_give",
    tag = "gameplay",
    keywords = { "给", "苹果", "给老人", "救人", "救", "喂", "分你" },
    answer = "你肯把苹果分我一口，我这把老骨头就还撑得住。头三天，苹果最实在。",
  },
  {
    id = "gameplay_signal",
    tag = "gameplay",
    keywords = { "信号", "五段", "信号链", "通讯", "传话" },
    answer = "海上传话分五段，一段接一段。信号一变，相关的鱼群也跟着挪，眼睛别离了水面。",
  },
  {
    id = "gameplay_compendium",
    tag = "gameplay",
    keywords = { "图鉴", "成就", "收集", "图签", "百科" },
    answer = "暂停的时候能翻图鉴，鱼、鸟、气象、沉船、灯、异样都记在里面。见得多了，海就熟了。",
  },

  -- ===== 鱼 =====
  {
    id = "fish_general",
    tag = "fish",
    keywords = { "鱼" },
    answer = "海里的鱼分大小。小鱼稳当，大鱼难缠却值钱。先从小鱼练手。",
  },
  {
    id = "fish_nobite",
    tag = "fish",
    keywords = { "不上钩", "捕不到", "没鱼", "鱼不咬", "为什么没鱼", "空网", "钓不到" },
    answer = "饵不对、地方不对、时辰也不对，鱼就不肯来。换个水花密的地方，再等等。",
  },
  {
    id = "fish_sardine",
    tag = "fish",
    keywords = { "沙丁鱼", "小鱼", "沙丁" },
    answer = "沙丁鱼是常见的鱼获，价钱平实。把它投回海里，倒能把远处的大鱼引来。",
  },
  {
    id = "fish_tuna",
    tag = "fish",
    keywords = { "金枪鱼", "大鱼", "吞拿" },
    answer = "大鱼难捕，得先用沙丁鱼做诱饵把它引来。一口咬实了，卖价能顶一船小鱼。",
  },
  {
    id = "fish_school",
    tag = "fish",
    keywords = { "鱼群", "成群", "聚集", "鱼多" },
    answer = "水花翻得密、水鸟扎堆的地方，底下多半是鱼群。跟着水鸟走，准没错。",
  },

  -- ===== 鸟 =====
  {
    id = "bird_general",
    tag = "bird",
    keywords = { "水鸟", "海鸟", "鸟", "海鸥" },
    answer = "水鸟在哪盘旋，哪底下就有鱼。鸟贴着水面飞，那是天要变脸的兆头。",
  },
  {
    id = "bird_storm",
    tag = "bird",
    keywords = { "鸟飞低", "鸟低飞", "海鸥低飞", "鸟贴水面" },
    answer = "鸟压低了身子贴着浪飞，暴风就快到了。看见这个，趁早回港，别恋战。",
  },

  -- ===== 气象 =====
  {
    id = "weather_general",
    tag = "weather",
    keywords = { "风浪", "天气", "浪", "风", "海况" },
    answer = "浪平的地方停船，风起的地方绕开。风浪不挑人，只挑不懂避让的。",
  },
  {
    id = "weather_storm",
    tag = "weather",
    keywords = { "暴风", "雷暴", "暴雨", "风暴", "坏天气", "乌云" },
    answer = "远处乌云压着海面，那就是暴风的头。别迎上去，避其锋、等它过去。",
  },
  {
    id = "weather_water",
    tag = "weather",
    keywords = { "水花", "看水", "水纹", "读海", "水色" },
    answer = "看水花知鱼群，看水色知深浅。海不会喊你，可它处处都在说。",
  },

  -- ===== 沉船 / 暗流 / 礁 =====
  {
    id = "wreck_general",
    tag = "wreck",
    keywords = { "暗流", "浅礁", "沉船", "礁", "暗礁", "礁石" },
    answer = "暗流要绕，浅礁会咬住船底。沉船既有宝，也有吞人的险，靠近前先用透镜望。",
  },
  {
    id = "wreck_treasure",
    tag = "wreck",
    keywords = { "宝物", "宝藏", "沉船宝藏", "透镜宝物", "宝贝" },
    answer = "沉船肚里兴许压着宝，可别冒失闯。先用透镜看清，再决定下不下水。",
  },

  -- ===== 灯 =====
  {
    id = "lamp_general",
    tag = "lamp",
    keywords = { "灯", "灯塔", "海上灯", "灯号", "灯灭" },
    answer = "夜里有灯，那是给归人指路的。灯亮着你心安，灯要是灭了，就得自家留神。",
  },

  -- ===== 异常 =====
  {
    id = "anomaly_general",
    tag = "anomaly",
    keywords = { "异常", "奇怪", "怪事", "不对劲", "诡异", "反常" },
    answer = "海上有反常的东西，记下来就好，别追着深究。有些事，知道得太清反而不妙。",
  },

  -- ===== 世界观 / 老人 =====
  {
    id = "lore_elder",
    tag = "lore",
    keywords = { "你是谁", "老人", "身世", "你咋在这", "你怎么在这", "老头", "你谁", "什么人", "身份", "是谁" },
    answer = "船散了，人还在。海不记人过，只记得谁回来了。你我都是被海留下来的人。",
  },
  {
    id = "lore_sea",
    tag = "lore",
    keywords = { "这片海", "海", "世界", "故事", "背景", "读海", "这海" },
    answer = "这是片记性很好的海。你在这海上讨生活，先得懂它，它才肯让你活着回去。",
  },
  {
    id = "lore_map",
    tag = "lore",
    keywords = { "地图", "海多大", "世界多大", "map", "多大" },
    answer = "这海面两千八百八十米见方，说大不大，说小也不小，够你跑上一轮又一轮。",
  },
  {
    id = "lore_save",
    tag = "lore",
    keywords = { "救你", "救老人", "怎么救", "苹果救", "救活", "救他" },
    answer = "头三天你给我凑够三个苹果，我这把老命就还有救。往后日子，就另说了。",
  },
  {
    id = "lore_thanks",
    tag = "lore",
    keywords = { "谢谢", "感谢", "多谢", "谢了" },
    answer = "去吧。风大的时候，记得回来。",
  },
  {
    id = "lore_readwater",
    tag = "lore",
    keywords = { "读海", "怎么读海", "海的语言", "海说话" },
    answer = "先看水鸟，再看水花。鸟告诉你鱼在哪，水花告诉你海在想什么。久了，你也就听得懂了。",
  },

  -- ===== 元信息 / 兜底引导 =====
  {
    id = "meta_newrun",
    tag = "meta",
    keywords = { "重来", "重新开始", "周目", "新游戏", "再来", "下一轮", "一轮", "七天一轮", "之后" },
    answer = "七天是一轮。若你把老人救下了，下一轮的海，会不一样地对你说话。",
  },
  {
    id = "meta_help",
    tag = "meta",
    keywords = { "帮", "不会", "怎么玩", "新手", "教我", "不懂", "攻略" },
    answer = "先听我把开场的话听完，然后投饵、出海、看水鸟。剩下的，海会一点点教你。",
  },
  {
    id = "meta_greet",
    tag = "meta",
    keywords = { "你好", "在吗", "嗨", "hi", "在不在", "哈喽", "老人家" },
    answer = "你来了。海上风大，坐稳了再说。",
  },
}
