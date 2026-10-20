# V2.8 Closure Fix 施工记录（2026-10-20）

本轮是 `TAPTAP-V28-FULL-CONTENT-CLOSURE-01` 的补充任务单，目标不是增加代码量，
而是证明「玩家真的看得到、点得到、丢得掉、投放不会串类型、场景真的画出来、
事务失败不会吞物品」。

前置基线：`c932245`，`run_world_content` 323/323 PASS，`sea_view_regression` 70/75
（5 个 suite 在 V2.8 施工前基线已失败）。

## 一、修复清单

### P0 隐形软锁：V2.8 story dialog 被 HUD 白名单过滤

**症状**：`Loop` 在 `v28_note` / `v28_result` 路径上已经 `clock:Pause("story")`，
但 HUD 取 `GetStoryDialog()` 后按 `kind` 白名单过滤，列表只有
`paper / elder / elder_fate / teaching / apple_basket / memory_fragment`。
结果：世界暂停、玩家看不到也关不掉。

**定性证据**：HUD 的标题映射（`storyTitle`）里早已为 `v28_note` / `v28_result`
写好了分支，说明这是白名单漏项，不是未实现。

**修复**：白名单补入两种 kind。

### P1 独立道具栏无玩家入口（原审查未列，本轮施工中发现）

**症状**：`treasurePanel` 挂在 `refs.drawer` 下，而 `refs.drawer` 在 refresh 里被
`SetVisible(false)` 写死（保留只为满足 `Circle1B3SceneUITests` / `Circle1B7CardLayoutTests`
的节点位置契约）。因此「记忆与探海镜」卡片以及所有独立道具栏内容**玩家完全看不到**。

**修复**：
- 卡片迁到常驻 `cardHost`，与背包/商店/老人三卡同级；按持有状态显隐（空卡不占版面）。
- 新增每件物品的可点击行：`重读/查看` + `给老人` + `丢弃`。
- `丢弃` 按策划置灰，但点击路径仍走 `Loop:DiscardV28Treasure` 给出明确原因
  （不用置灰代替反馈）。
- 新增 `Loop:GetV28TreasureActions()`（逐件动作视图）与 `Loop:DiscardV28Treasure()`。

### P1 投放 / 丢弃串类型

**症状**：`GetThrowCandidates` 用 `category ~= "treasure" and not protected` 推断可投放，
于是 `worldEffect=NONE` 的普通交易品（珠宝 / 珊瑚枝 / 深海珍珠 / 海底金属货箱）
自动进入底部【投放】。`BeginThrowItem` 与 `ThrowItemAtShip` 同样绕过列表直接放行。

**修复**：新增 `Items.CanWorldDrop` 显式白名单（`apple / bait / sardine / tuna`），
未知物品默认不可投放——V2.9 新增物品不会重蹈覆辙。三个入口统一使用该表。

背包【丢弃】对非生态物改为**直接销毁腾格**（不产生 WorldDrop、不需要海面坐标），
不再因缺少 `dropReceiver` 而回滚。

### P1 海眼物品类型判断

**症状**：旧逻辑用 `payload.worldEffect == "NONE"` 推断「大鱼」，而珠宝 / 珊瑚枝 /
深海珍珠 / 货箱的 `worldEffect` **也是 NONE** → 普通交易品会被当作大鱼处理。

**修复**：新增 `Items.VortexRole` 显式身份表：

| itemId | role | 含义 |
|---|---|---|
| apple | small | 吸引小鱼 |
| bait | small | 吸引小鱼 |
| sardine | big | 吸引大鱼 |
| tuna | pearl | 本周目首次置换深海珍珠 |
| 其它 | nil | 海眼不接受 |

`Bridge.receiveVortexDrop` 改为三态返回（`nil` = 不归海眼管 / `true` = 已处理 /
`false` = 归海眼管但拒绝）。

### P2 破渔网 B 分支 2 鱼原子性

**症状**：逐条生成，某条找不到合法位置就 `break`，只要 `spawned > 0` 就整体返回成功
→ 可能只放出 1 条却判定分支完成、钥匙已发。

**修复**：两阶段——先为全部 `count` 个个体预找合法位置（并保证同批间距），
任何一个失败就整体失败（`fish_release_no_space`）且不生成任何鱼；
全部确认后再统一生成。

### P2 海眼珍珠事务原子性

**症状**：旧流程先 `ClaimVortexPearl` 提交状态，再 `HandleVortexDrop`；
后者失败只记日志不回滚 → 「鱼被消耗 + 珍珠已发 + claim=true」的半完成态，
且后续再投大鱼会落进「已领过」分支。

**修复**：先探针确认海眼后置表现可执行，再提交珍珠/claim；
拒绝时终止整个投放并让 `DropItem` 回滚，不再掉进普通 WorldDrop。

> 注：修复过程中发现 `receiveDrop` 原先把「海眼拒绝」当成「不归海眼管」，
> 从而落到普通掉落分支——这正是「吞鱼不产珍珠」的直接成因。已用三态返回值修正。

### P1 浮藻假岛三阶段表现（上一轮已修，本轮补测试）

上一轮 `655e214` 已修 `SeaDraw` 的 80m 岛影与 20m 识破。本轮补的验证见下节。

## 二、测试

新增 `scripts/tests/V28ClosureFixTests.lua`（19 项），用 in-memory widget double
构造**真实 HUD**，不再用 `loop:GetStoryDialog()` 单点断言代替 HUD 可见性。

覆盖要点：

- P0：拾漂流瓶（`v28_note`）与沉船打捞成功（`v28_result`）后，断言 HUD 里
  `storyDialogText` 可见且正文精确一致 → 点「结束对话」→ 断言 story pause 释放、
  无残留弹窗；另加一条遍历两种 kind 的白名单守护。
- P1：8 种物品分两批断言投放候选只含生态物；珠宝丢弃腾格且 `dropReceiver` 调用 0 次；
  苹果仍走 WorldDrop。
- P1：`VortexRole` 白名单；珠宝在投放入口即被拒（`item_not_throwable`）；
  真 tuna 仍换到珍珠。
- P1：`GetV28TreasureActions` 三动作契约；HUD 里点「重读」打开残页并可见、
  关闭后 pause 释放且不消耗；钥匙「查看」给正文；丢弃被拒且有原因。
- P2：真 runtime 下分支 B 放出恰好 2 条 Flee 沙丁鱼；容量 1/2 时整体失败且 0 生成；
  2/2 时成功。
- P2：珍珠写入失败 → 投放被拒、claim 保持 false、tuna 不被吞。

### 结果

| 项目 | 基线 | 本轮 |
|---|---|---|
| `run_world_content` | 323/323 | **342/342 PASS, 0 skipped** |
| `sea_view_regression` | 70/75 | **71/76** |
| 失败 suite | AutoNavigation / Circle1HUDReview / OceanImageCatalog / SeaDayNightCycle / ShipScare | 同上，**逐条 check 名一致** |
| 语法检查 | 176 文件 0 失败 | 177 文件 0 失败 |

失败集合与基线**逐条一致**（已用脚本比对 `check` 名称列表，`SAME: True`），
判定 `BASELINE_EXISTING`，非本轮引入。`Circle1HUDReviewTests` 因本轮改了 HUD，
已单独比对：失败项名与基线完全相同。

## 三、Maker Preview / GUI

- `preview prepare`：通过，`meta 解析失败` 警告 0 条（上一轮 `f658501` 修复持续有效）。
- `preview start` / `本地测试.cmd`：通过，`state=running`。
- 最新 reload（reload 4，04:05）已加载本轮全部新代码，进入首帧
  （`[SeaV1] first frame rendered`），`Lua error` / `stack traceback` 计数 **0**。
- 已核对 reload 的 `source/` 副本确实包含本轮改动（`GetV28TreasureActions` 在 HUD、
  `Items.VortexRole` 在 Bridge）。

**GUI_PENDING**：以下 15 项仍需有窗口环境时人工确认，本机工具无法自动判定画面：

1. 拾漂流瓶后正文弹窗真实可见。
2. 关闭弹窗后世界恢复。
3. 沉船成功结果弹窗真实可见。
4. 破网结果弹窗真实可见。
5. 货箱结果弹窗真实可见。
6. 航海残页能从道具栏重新打开。
7. 生锈钥匙可查看 / 给老人。
8. V2.8 交易品不出现在【投放】。
9. V2.8 交易品【丢弃】直接腾格。
10. 80m 左右可以看到浮藻假岛未知岛影。
11. 20m 内切换成浮藻。
12. 探海镜进一步发现水下货箱。
13. 海眼只接受正确生态投放物。
14. 海眼首次 tuna 换珍珠。
15. W-08 实际弹出保持正常。

## 四、Git

| commit | 内容 |
|---|---|
| `9f0709a` | fix(v2.8): close HUD dialog and independent-bar item action paths |
| `5db3315` | fix(v2.8): harden world drop and vortex item typing |
| `87a76d2` | fix(v2.8): harden net release atomicity for the two-fish branch |
| `9ee0482` | test(v2.8): cover real HUD and presentation closure |

上一轮 4 个 V2.8 提交（`12888a9` `f6d86e8` `6878a6e` `98572cf`）与
本轮前置的 `f658501` `655e214` `2d7451c` `c932245` 全部保留，未 rewrite history。

未提交、按指令保护的上一轮 V2.7 遗留工作（本轮**未触碰**）：
`scripts/Gameplay/Circle1B2Barrel.lua`、`scripts/Gameplay/HUDPresentation.lua`、
`scripts/tests/Circle1ABMergeFrameBudgetTests.lua`、`scripts/tests/Circle1B2BarrelTests.lua`。

`git diff --check`：通过。
`PUSH_STATUS`：NOT_PUSHED。

## 五、未完成

01 / 02 / 04 / 07 / 09 / 11 六项剩余候选仍未实现——上一轮已核实它们在封板工作簿与
全部权威策划源中零命中，属 `PRODUCT_DECISION_REQUIRED`，需策划补齐后才能施工。
详见 `docs/V28_FULL_CONTENT_CLOSURE.md` 第一节。

---

# 第二轮独立审查修复（2026-10-20，截止前最终施工）

前置 HEAD `6618f3a`。本轮不再新建工具或基础设施，只关闭真实玩家入口缺口、
归因 5 个红 suite、并把 V2.7/V2.8 的海上内容做成“能被发现”。

## 一、P1/P2 入口缺口

| 编号 | 症状 | 根因 | 修复 |
|---|---|---|---|
| P1-01 | 苹果 / 鱼饵 / 沙丁鱼 / 金枪鱼从背包点【丢弃】**全部丢不掉** | `DropItem` 用 `Items.CanWorldDrop` 当判据，四个生态物都走 WorldDrop；背包丢弃没有海面坐标 → 正式 Bridge 一律回滚 | 判据改为“本次是否真有投放选点”。无选点 = 销毁腾格；有选点 = 交接世界。鱼饵保留船边投饵语义，为那一次交接临时补船位选点并在结束后恢复 |
| P1-02 | 独立道具栏【给老人】点一次无反应 | HUD 直接调 `ShowV28TreasureToElder`，而 Loop 要求老人对话已打开 | 先 `SetElderOpen(true)`，成功后再展示（不消耗），与背包物品同一路径 |
| P2-01 | 苹果/小鱼投海眼只得到通用“已交接投放请求” | `HandleVortexDrop` 只返回一个表，调用点却解包 `(handled, result)` → `result` 恒 nil，两个专属分支永不命中 | 按真实返回值接收，四种投放各有专属反馈 |
| P2-02 | 不可丢弃物品“回调里有原因，但按钮永远点不到” | 真实引擎 `SetDisabled(true)` 拦截点击，原因只写在回调里 | 改为「禁用按钮 + 同屏原因文字」 |
| P2-03 | 破网两鱼：第二条生成失败时第一条留在世界 | 只 `return false`，未清理已生成个体 | 记录已生成 id，失败时统一 `world:remove` 并清 behaviors |
| P2-04 | 浮藻 80m 只验证逻辑条件，没验证真的画了 | — | 补真实 `SeaDraw.Scene` 绘制级用例（80m 内有填充 / 超过 80m 零填充 / 20m 识破后换藻层配色） |

## 二、红 suite 归因

| suite | 定性 | 处理 |
|---|---|---|
| AutoNavigationTests | **REAL_BUG** | 见下节 |
| Circle1HUDReviewTests | STALE_TEST | 物品菜单已改名「使用/给老人/丢弃」，fixture 仍点 `button("给予")`，模糊匹配命中了老人卡的「给予 ▸」分类键。改为精确「给老人」 |
| SeaDayNightCycleTests | STALE_TEST | 正式规则 60/30（`config/gameplay.lua`），套件硬编码 120/60 并把它写成“既有配置”。改为从 GameClock 取 DAY_SEC/NIGHT_SEC |
| ShipScareTests | STALE_TEST | 鱼感知 0.2s 节流（`Fish.perceptionIntervalSec`，由 Circle1B5FishPerceptionTests 守护）。旧断言要求下一帧即 Flee。改为推进一个感知窗口后断言真实契约 |
| OceanImageCatalogTests | STALE_TEST（假阴性） | 纹理 flag 断言只列 `waterpaper`/`sea_surface` 前缀，漏了同为重复纹理的 `sea_ripple_overlay`。改为按 catalog 的 `repeatTexture` 判定 |

## 三、AutoNavigation 真实 bug

**症状**：船在岛边（或港口回港走廊上）点自动返航，直接 `no_viable_detour`。

**根因（两层）**：
1. 六座**实体阻挡**变体岛全部挤在港口 70m 内，木桶距港 15.2m 且 r2+8m 裕度 = 11.8m。
   船一起航就可能已经在**邻障碍**的 8m 裕度圈内，于是两条切线航段都被判“切入裕度圈”。
2. 起点、障碍、港口三点共线时两条切线平行，`tangentLineIntersection` 返回 nil，
   一个候选都产不出来。

**修复（`Ocean/AutoNavigation.lua`）**：
- `effectiveMargin()`：裕度圈已包含起点的障碍，只保留**硬碰撞圈**（radius + shipRadius）。
  硬圈在任何情况下都不放宽，因此不会让船能撞上障碍。
- `generateCandidates()`：切线法产不出候选时，回退到裕度圈上的两个侧向点；
  `candidateValid()` 照旧做完整裕度/世界边界校验。

**布点（`Ocean/Config.lua`）**：六岛从 70m 簇散到 60~135m 四象限，
间距保持 ≥ r_i+r_j+4m；木桶 14,6 → 34,10（仍在出港第一屏可见，`ClipPolygon=48`，
且不再压在回港走廊上）。

**证据**：48 个 departure × level × heading 组合全部抵达、碰撞 0 次
（修复前 24 个直接起航失败）；全图 20m 网格可行起点从 95/955 不可达降到 4 个共线退化点，
且这 4 点已被共线回退覆盖。

## 四、可发现性（许愿式优化，共 1 轮）

- `reef_vis_02/03` 从 110,-80 / 160,-115 外移到 150,-92 / 200,-140，
  三块礁石形成可读的东南向链条，而不是同一片水域里的三个重叠点。
- **线索文案改为与实际方位一致**（指向错方向的线索比没有线索更糟）：
  - `reef_vis_01`「西北方向」→「北边」（island_02 实际正北 36m）
  - `reef_vis_02` 羽毛「东南」→「东北」（它引导的礁石链在东北）
  - `reef_vis_03`「再往东南望去，一座海岛」→「再往西北望去」（礁石群实际西北 118m，
    旧文案指向空海）

未移动：island_01/02、水下宝藏、木板、沉船、两个漂流瓶、巨骨、海眼、破网、浮藻假岛。
所有封板规则（近港禁大鱼、海眼半径、破网互斥、浮藻钥匙链）不受影响。

## 五、结果

| 项目 | 本轮前 | 本轮后 |
|---|---|---|
| `run_sea_view_regression` | 71/76（5 红） | **76/76 PASS** |
| `run_world_content` | 342/342 | **344/344 PASS, 0 skipped** |
| Lua 语法 | 177 文件 0 失败 | 177 文件 0 失败 |
| LSP 错误 | 20（基线） | 20（同集合，行号偏移） |
| Maker Preview | 曾进入首帧 | **进入首帧**（`[SeaV1] first frame rendered`），无新增 Lua fatal |

Preview 日志里仅有的两条 ERROR 是既有引擎资源缺失
（`Cube/Day/DaySpecularHDR.dds`、`themis_x64.dll`），非本轮引入。

## 六、仍需人工判断

`GUI_ACCEPTANCE=HUMAN_REQUIRED`。以下只能真人看画面/手感：
- 六岛散开后近港是否仍然“有东西可看”而不是空旷；
- 三条礁石线索链的实际可读性（文案已对齐方位，但节奏与密度需要眼睛）；
- 海眼/巨骨/浮藻假岛在正常航行中是否真的会被注意到；
- 丢弃/投放两个入口在真实触摸下是否不再混淆。
