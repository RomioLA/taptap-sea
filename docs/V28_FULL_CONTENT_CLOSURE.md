# V2.8 完整版补充施工记录（2026-10-20）

本轮依据：`渔夫漂流记_V2.8_最终合并封板版.xlsx`（21 个工作表，全部 visible）。
权威顺序：《V2.8最终封板》＞ 当前主正文 Sheet ＞《V2.7审查闭环》＞《V2.8已确认增量》＞ 历史修改记录。

本文只记录本轮实际发生的变更、判定与证据边界；不重复策划原文，不替代策划。

## 一、剩余候选内容的判定：PRODUCT_DECISION_REQUIRED

本轮任务书要求把 01～12 候选中"尚未正式施工"的六项纳入 V2.8 完整版：

| 任务书编号 | 名称 |
|---|---|
| 01 | 沸腾虾群 |
| 02 | 双生珊瑚礁 |
| 04 | 海鸟孤桩 |
| 07 | 浅滩生锈铁锚 |
| 09 | 幽光水母群 / 夜光海火 |
| 11 | 雾中提灯舢板 |

**结论：这六项在权威策划中不存在，本轮不实现，标记 PRODUCT_DECISION_REQUIRED。**

### 证据（全库检索，零命中）

检索范围与结果：

- 封板工作簿 21 个工作表全文（openpyxl，data_only=True）：`沸腾` `双生` `孤桩` `铁锚` `幽光` `舢板` `海火` 全部 0 命中。
- 仓库 `docs/planning/team/` 8 页正式正文 + `docs/planning/CONTROL.md`：0 命中。
- 全库 `.md/.txt/.json/.lua/.csv/.tsv/.py`（排除 `.git/`、>20MB 文件）：0 命中。
- 全部 13 个 `.xlsx/.docx/.zip` 的内部 XML：0 命中。
- `git log --all -S"<关键词>"` 全历史：0 命中。

对照：已实现六项的关键词在权威源中高频命中（`虾群` 13 次、`珊瑚礁` 22 次、`海鸟` 348 次，
`浮藻`/`巨骨`/`海眼`/`破渔网` 均有专条坐标表）。六项剩余候选关键词为 0，形成决定性反差。

### 不存在"01～12 候选清单"

工作簿实际编号体系与任务书编号无对应关系：

- `系统规则` 世界坐标总表编号 **1～15**（1–4 既有节点、5–7 礁石、8–13 第一批、14–15 第二批）。
- `游戏道具总表` 给海上对象挂模块号：`03` `05` `06` `08` `10` `12`。

编号 `01/02/04/07/09/11` 在任何表中都不存在，既非被删条目，也非待填槽位。

### 四条独立禁令直接命中

1. **禁止新增内容批次** — `V2.8最终封板` 施工/顺序栏：`不得自行新增第三批/新系统`；
   `V2.8已确认增量` V28-11：`不授权执行者新增第三批或改W-05`。
   封板已把 V2.8 海上内容穷尽定义为两批 15 个海上节点（`进度与待决策` A104）。
   再加六项即事实上的第三批。
2. **禁止自造生产坐标与奖励** — `系统规则` A100：
   `若没有已经确认的正式实例，不由开发自行创建生产坐标或奖励。`
   02/07 若落地必须新造坐标，正是本句禁止的行为。
3. **候选内容不得转正为规则** — `规则表` C05 夜间发光生物：`候选内容；不可形成正式规则`。
   这是 09 幽光水母群/夜光海火的直接上位条目。
4. **虾类明确未批准** — `剧情与事件` B78：虾`候选；分圈TBD`；
   `数值与物品`：`不新增鲜虾肉/特制鱼饵等功能性消耗品`；
   `游戏道具总表`/`P2候选方案` 均标 `P2候选｜未采用`。

任务书自身也写明"遇到无法解决的单项：记录 → 跳过 → 继续"，并禁止执行者自创大型新系统，
因此正确动作是记录后跳过，而不是停工或自行立项。

### 待用户决策

若要把这六项纳入 V2.8，需要先由策划补齐（或明确授权）：

1. 每项的正式 contentId、世界坐标、半径、layer、blocking。
2. 交互方式与门禁（是否 0 体力观察 / 4 秒事务 / 探海镜标记）。
3. 是否有产出；若有，产出物 id、售价、归类（普通船舱 / 独立道具栏）。
4. 存档字段与周目语义（是否一次性、是否随 NewRun 重置）。
5. 与既有规则的边界（尤其 06 是 `rusty_key` 本周目唯一来源、海眼不刷鱼、近港 200m 无大鱼）。

## 二、本轮实际完成

### 1. Preview 故障修复（真实根因两层）

**根因 A（项目侧，已修复）**：`scripts/tests/Circle1B5EcoArtRenderTests.lua.meta`
的 uuid 字符串里混入一个裸 CR（`"GCvLOzdOwlunI4UiN1gGQA\r"`），不是合法 JSON。
ProjectBuilder 每轮 prepare 都报
`meta 解析失败: Invalid control character at: line 2 column 34 (char 35)`
并跳过该资源。已提交到 git 的这个坏文件是稳定可复现的缺陷。
修复后 prepare 的 meta 警告由 2 条降为 0。

**根因 B（外部，未修复也不应修复）**：失败会话 `8cd6170b` 的 prepare.log 显示
`[WARN] 警告: 加载远端来源 'engine-res' 失败`，而 `engine` 与 `official-res` 均成功。
maker.js 在 stdout 匹配到 `加载远端来源.*失败` 就整体判 `Public source index download failed`。
该 source 的 CDN 端点经多次 curl 验证均返回 200（`stable.json` / `1.31.35/manifest-f8c7bb8e.json`），
本地 manifest 缓存也完好，说明这是**远端索引下载的瞬时失败**，不是项目缺陷。
同一项目随后两次 prepare/start 均成功导入 `engine-res` 1068 个文件。

结论：不修改项目配置、不删除公共缓存、不重装 Runtime。

### 2. 浮藻假岛 80m 岛影接线缺口（V2.8 已封板表现的实现缺陷，已修复）

策划（`系统规则` A96 / 15 浮藻假岛）：`80m 显岛影轮廓、20m 识破为浮藻层`。

`kelp_mirage_01` 登记在 `underwater` 层（水下货箱需探海镜 1s 标记），但 `SeaDraw`
的海面分支只按 `isVisible` 绘制水下实体——无探海镜时 `isVisible` 恒为 false，
**80m 岛影轮廓永远不会出现**；同分支把 `recognized` 硬编码为 `false`，
20m 识破后也不会改画藻层。

已用运行时探针确认：`kelp.layer = "underwater"`，`world:isVisible(kelp) = false`（无探海镜）。

修复（`scripts/Ocean/SeaDraw.lua`）：

- 新增 `v28SurfaceIllusion(entity)`：海面假象按 `Config.interaction.outlineDistance`(80m)
  绘制，不依赖探海镜可见性；>80m 不绘制。
- 从 `isLocationRecognized` 读取 `recognized` 并传入 `drawV28Node`，
  使 20m 识破后按藻层轮廓（`visualRadius * 0.55`）绘制。
- 删除从未被调用的死函数 `v28BottleVisible`（漂流瓶显隐实际走 `runtime.GetV28Picked`）。

新增 `V28ContentTests` 用例守护：层/视觉半径 14m/20m 识破距离/80m 边界。

### 3. 施工中误删并已恢复的本地改动

本轮施工中执行 `rm -rf scripts/Tests`（意图删除大小写重复目录）时，因 Windows 文件系统
大小写不敏感，实际删除了 `scripts/tests` 的内容。已立即 `git checkout --` 恢复，
并额外从 Maker prepare 副本恢复了两个**上一轮遗留的未提交测试改动**：

- `scripts/tests/Circle1B2BarrelTests.lua`
- `scripts/tests/Circle1ABMergeFrameBudgetTests.lua`

两者均已恢复到覆盖前的内容（maker prepare 副本时间戳 2026-10-19 02:54 / 03:01），
且**未纳入本轮任何 commit**，符合"保护上一轮遗留工作"的要求。
`scripts/Gameplay/Circle1B2Barrel.lua` 与 `HUDPresentation.lua` 全程未被触碰。

## 三、测试与验收

| 项目 | 结果 |
|---|---|
| `tests/run_world_content.py` | 16 套件 / **323 tests** / 0 skipped / 全部通过 |
| `tests/run_sea_view_regression.py` | 75 套件 / **70 通过** / 语法 176 文件 0 失败 |
| 海景失败项 | `AutoNavigationTests`、`Circle1HUDReviewTests`、`OceanImageCatalogTests`、`SeaDayNightCycleTests`、`ShipScareTests` —— 与本轮改动前的基线**完全一致**，非本轮引入 |
| `git diff --check` | 通过 |
| Preview prepare | 通过（meta 警告 0、`engine-res` 1068 文件导入成功） |
| Preview start | 通过（`state=running`，进入首帧） |
| `本地测试.cmd` | 通过（refresh → `状态：running`） |
| Lua fatal | 无（runtime.log 仅 2 条引擎级既有 ERROR：`DaySpecularHDR.dds`、`themis_x64.dll`，与项目代码无关） |

## 四、存档兼容与 NewRun

- 本轮未新增任何存档字段，未改 `V28Progress` / `WorldContentProgress` 契约。
- V2.7 旧档缺 V2.8 字段仍由 `Initialize` 补 `false` / 未持有，不判坏档。
- NewRun 语义不变（`V28ContentTests` 与 `Circle1C1EmergenceTests` 的 5 轮 NewRun 用例通过）。

## 五、GUI_PENDING（仍需实机人工验收）

本轮预览已进入首帧并稳定运行，但以下仍无法自动判定：

1. 浮藻假岛 80m 岛影轮廓的实际观感与辨识度，以及 20m 识破为藻层的视觉转折是否可读。
2. 13 个海上节点在 D1/D2 近海的可见密度（占位几何）。
3. 探海镜 1 秒标记/识别的可读性。
4. 海眼 60m/90m 聚鱼观感与外缘下网体验。
5. 破渔网双分支模态框在窄屏按钮坞中的排版。
6. 巨骨慢气泡与大鱼水花的区分度。
7. 4 秒打捞进度、取消按钮与夜尽中断的实际表现。
8. W-08 三枚记忆的实际弹出与排版。

## 六、本轮未做（按策划边界）

- 未实现 01/02/04/07/09/11 六项（见第一节，PRODUCT_DECISION_REQUIRED）。
- 未制作正式美术：仍用 NanoVG 占位几何，正式资源替换只需改 `drawV28Node` / 假象绘制。
- 未新增第三批内容、未改 W-05 救活结局正文、未新增任何系统或道具。
