# V2.7 圈1 实施记录（2026-10-18）

本轮依据：`渔夫漂流记_V2.7_完整修订版_最终裁决_文案回审.xlsx`。
权威顺序：修订后正文 / 《V2.6圈1封板补充》最新 S 项 / 《V2.7审查闭环》 > A/B 历史修改原因说明。

本文只记录本轮实际落地的代码变更与验收边界；不重复策划原文，不替代策划。

## 一、已落地的 V2.7 规则

| 规则 | 落点 | 说明 |
|---|---|---|
| 老人只要活着就始终同行（港口+海上） | `Gameplay/Circle1B2Progress.lua` `IsElderPresent`；`Gameplay/HUD.lua` 老人入口显隐 | 入口不再限定港口；离世后仍显示，点击只给拒绝语 |
| D1 首次出航一次性教学（停船投饵 + 晚归） | `Gameplay/Loop.lua` `Depart` → `TryShowContextTeaching("basic")` | 顶部轻提示，不暂停、不进模态队列 |
| D2 起首次真实看到海鸟时教学，未看到顺延 | `Loop:ProcessContextTeaching` → `Runtime:HasSurfaceSignalInView("bird")` + `SeaPresentation.State` | 复用 SeaDraw 的鸟类绘制准入范围；超出范围时顺延；shown 跨日保留 |
| D3 起首次真实看到水花时教学，未看到顺延 | 同上，参数使用水花绘制边界 | 复用 SeaDraw 的水花绘制准入范围；海鸟优先于水花 |
| 三条教学 shown 独立存档 | `Progress.IsTeachingShown` / `MarkTeachingShown` | `basicTeachingShown` / `birdTeachingShown` / `splashTeachingShown`，NewRun 重置 |
| D1~D3 成功交付并消耗的苹果 ≥3 救活 | `Loop:GiveToElder` + `Progress.RecordApple` | 吃/投海/丢弃/仅持有均不计；D4 起不再累加 |
| D3 日结 → D4 唯一一次判定并写入同日结快照 | `Loop:BeginNewDay` → `Progress.OnDayStarted` → `Persistence.Snapshot` | 判定先于快照；D4 无出航也判定 |
| D4 救活/未救各一次结果模态 | `Loop:OpenDay4ElderFate` | 救活明确「状态转好」，不暴露 3 苹果条件 |
| 未救 D6 日初苹果篮回想 | `Loop:TryOpenAppleBasketRecall` | 一次性；只随下一检查点保存 |
| 救活 D4~D7 每天一条进阶教学 | `Loop:TryShowAdvancedTeaching` | 每天首次出航触发；`advancedTeachingDay` 记录 |
| W-15 多段自动时间提醒整组废止 | `Loop:Update`（删除黄昏自动文案） | 保留太阳/月亮/天空与 HUD 时间；夜尽仍强返 |
| 玩家侧统一「探海镜」 | `HUD` / `HUDPresentation` / `Circle1B2Barrel` / `Achievements` / `data/achievements.lua` | 技术字段 `scopeLens` 保留不改名 |
| 探海镜换日重置开关、NewRun 重置持有 | `Loop:BeginNewDay` / `Loop:ResetState` | 返港不强制关闭 |
| 独立底部【投放】按钮 + 合并同类列表 | `HUD` `refs.beginThrow` / `throwPickerPanel`；`Loop:OpenThrowPicker` / `GetThrowCandidates` | 列表为空只给顶部轻提示「船舱里没有可以投放的物品。」，不弹模态 |
| 物品固定三操作「使用／给老人／丢弃」 | `HUD` 物品菜单；`Loop:UseItem/DropItem/GiveToElder` | 不置灰、不隐藏；每个拒绝都有自然语言原因 |
| Esc 优先取消选点，无选点才全局暂停 | `Integration/Scene.lua` `cancelPendingSelection` | 覆盖捕鱼选点 / 投放列表 / 投放选点 |
| NewRun 二次确认 | `HUD` `requestNewRun` + `newRunConfirmBody` | 结局页 / 港口 / 入口屏共用；确认后才覆盖存档 |
| D7 纸条 → 结局 → 终局保存；完结档锁玩法 | 既有实现 + `OpenDayEntryStory` | 已完结读档直接回结局页，禁止出航/日结 |
| D7 不进入 D8 | 既有 `maxDay` 校验 + 读档拒绝 day>7 | 本轮补回归断言 |

## 二、文案裁决与仍待确认的内容

- **W-05 救活结局正文**：2026-10-19 用户确认采用现版「改变结局｜有人同行」；旧稿「安稳」不再作为候选。
- **W-08 三枚记忆碎片正文**：方向已纠正为「主角自己的童年记忆」，具体三段待文案方回填；未自行新写环境记忆。
- **W-08 技术接入与数据契约**：`scripts/data/memory_fragments.lua` 按现有 reward ID 记录 `contentId`、主题、内部工作标题及可回填的 `playerTitle` / `body`。内部工作标题只供定位，不显示给玩家；当前正式标题和正文均未回填。领奖成功后仅在开始时未持有且当前 `player.treasures[rewardId] == true`、正文含非空白字符时，复用现有剧情模态；正文缺失或空白时不弹模态，保留原领奖 ActionToast。模态期间暂不交付该 toast，关闭后按现有 ack 链消费；不新增存档标记。

  | reward ID | fixed content ID | 主题 | 内部工作标题 |
  |---|---|---|---|
  | `memory_island_01` | `island_01` | 陪伴/安心 | 有人牵着我的手 |
  | `memory_island_02` | `island_02` | 勇气/成长 | 第一次自己走远 |
  | `memory_treasure_01` | `underwater_treasure_01` | 温暖/归属 | 那盏还亮着的灯 |
- 老人固定表现位立绘/动画、D1~D3 逐日疲倦与收苹果「眼睛一亮」的具体时长：由美术与试玩确定，本轮未新增资源。

## 三、验收边界

- 原实施轮自动回归：`tests/run_sea_view_regression.py`，73 套件 / 68 通过。
  未通过的 5 项为**本轮之前已存在**的历史失败（美术分层、自动导航绕障、图像 catalog、昼夜配置基线、ShipScare 行为），与本轮改动无因果关系，未在本轮强行修改。
- 2026-10-19 定向回归：世界内容相关 15 suites / 277 tests、`V27Circle1Tests` 18/18、`SeaPresentationTests` 4/4 通过；其中 `Circle1B2UITests` 8/8；CRLF-aware `git diff --check` 通过。未重跑全量回归。
- 最新已有全量回归记录为 74 套件、整体 FAIL（AutoNavigationTests、OceanImageCatalogTests、SeaDayNightCycleTests、ShipScareTests 4 项失败）；该记录早于当前 V2.7 测试文件最后修改。Maker 引擎和视觉验收未运行。
- 需 GUI/真机人工确认：D1 教学提示可读性、D4 结果排版、D6 回想、D7 结局页与 NewRun 二次确认、投放列表布局、老人入口在海上按钮坞的拥挤程度。

## 四、相关测试

- 新增 `scripts/Tests/V27Circle1Tests.lua`（当前 18 项）：覆盖 D1/D2/D3 教学触发、视口绘制准入与顺延、海鸟优先、教学跨日保留与 NewRun 重置、老人海上同行与赠礼、D4 判定与结果模态、D4 后苹果不再计数、D6 回想、D4~D7 进阶教学、投放列表与空列表提示、三操作拒绝反馈、探海镜换日/NewRun 语义、终局锁玩法、D8 不可达。
- `Circle1B2UITests` 补充固定三操作、不可用时显示自然语言原因、busy/捕鱼期间门禁的回归覆盖。
- `WorldContentTests` 补充 W-08 reward/content 映射、正文缺省不弹空模态、首次领取复用剧情模态、同帧故事冲突延后，以及 toast 只交付一次的覆盖。
- 同步更新因 V2.7 变更而过时的旧契约：`Circle1B2ProgressTests`、`Circle1B3ClockAsyncTests`、`Circle1B2BarrelTests`、`Circle1B3SceneUITests`、`Circle1B3SevenDaysTests`、`Circle1BRunLifecycleTests`、`SevenDaysRunTests`、`Circle1B2UITests`、`Circle1HUDReviewTests`、`Circle1B7CardLayoutTests`、`GameLoopUISpec`。
