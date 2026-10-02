# 可行性方案与双人分工（WorkBuddy × Codex）

- 日期：2026-10-02（Jam 第 2 天，剩余约 19 天）
- 依据：《涌现航海小游戏》一句话概念与核心循环 + 第一版具体参数表 + 《第一版设计符合性审查与核心循环拆解.md》
- 结论先行：**可行。参数表已经是实现级规格，骨架代码就绪，引擎文档/示例齐全。最大风险不在工作量，在双人双 AI 协作冲突——用「代码/数据目录隔离 + 单写者」化解。**

---

## 1. 可行性判断

| 维度 | 评估 | 依据 |
|---|---|---|
| 设计完备度 | ✅ 高 | 参数表已到实现粒度（距离/速度/时长/价格全部有数），可直接转配置 |
| 技术栈匹配度 | ✅ 高 | 2D 俯视海面 + NanoVG 绘图 + urhox-libs/UI，参数表的正交镜头/遮罩/水花都是 2D 能力范围 |
| 工作量 | ✅ 可承受 | 系统层约 10 个模块，估 1500~2500 行 Lua；19 天单人+AI 可完成，前提是里程碑纪律 |
| 最大不确定性 | 🟡 两处 | ① 海面信号（上轮审查 R1 硬缺口）的表现层实现与调参；② Fish FSM 手感（Sardine 回避强度需 Monte Carlo/实测） |
| 协作风险 | 🟡 高 → 可控 | 一方是无开发经验新人 + Codex；不做代码分工，只做「代码 vs 数据」分工 |

**分工总原则：代码全归你（WorkBuddy），数据和内容全归对方（Codex）。新人不写一行 `scripts/` 里的代码——他的产出（数值、事件、文案）本身就是玩法，而且天然不会和你冲突。**

---

## 2. 架构分层与模块清单

```text
scripts/
├── Main.lua              # [你] 入口、输入、模块接线、主循环
└── Ocean/
    ├── Config.lua        # [你] 全局调参常量（镜头/时钟/船速/价格等）
    ├── State.lua         # [你] 玩家状态、体力、money、Inventory、周目
    ├── Clock.lua         # [你] 新增：昼夜时钟、pause reason、夜晚处罚
    ├── Boat.lua          # [你] 新增：移动、转向、镜头 dead-zone、边界推回
    ├── World.lua         # [你] 新增：World Entity 注册、固定/临时对象、生成与冻结
    ├── Fish.lua          # [你] 新增：FSM（Wander/Attracted/Flee/Chase/Avoid）、感知
    ├── Action.lua        # [你] 新增：捕鱼/打捞/投放/交互距离检测、体力结算
    ├── Port.lua          # [你] 新增：返港、商店、每日结算、周目重置
    ├── Save.lua          # [你] 新增：每日自动存档、周目存档字段
    ├── Draw.lua          # [你] 表现层（含海面信号渲染，对方可提需求）
    └── HUD.lua           # [你] HUD（文案从 data/ui_text.lua 读取）
data/                    # [对方] 全部内容与数值，纯数据表，无逻辑
├── items.lua             # Apple/Bait/Sardine/Tuna/宝藏参数
├── fish.lua              # 鱼种参数（速度/感知/FSM 配置）
├── events.lua            # 约 10 个事件：触发条件、描述文本、选项、结果
├── locations.lua         # 地点定义（轮廓/识别文本/宝藏归属）
├── upgrades.lua          # 体力/船舱/船速/透视镜价格表
├── oldman.lua            # 老人对话与教学提示文本
└── ui_text.lua           # HUD 与弹窗文案
```

- 参数表中的 A/B 模块标注（「A负责距离检测」「B保存识别状态」等）按上表归并：**所有带逻辑的模块归你**；对方通过 data 文件提供这些模块消费的内容。
- `State.lua` 读 `data/*.lua` 只依赖 schema，不依赖具体数值——这是隔离的关键。

### 2.1 架构归一决议（2026-10-02 增补）

远端提交 `1e0d8c8`（B 经 Codex 实现，越界但产出合格）经 A 审查后**收编采纳**为基础设施层。映射如下：

| 原 Ocean/ 规划 | 归一后落点 |
|---|---|
| World.lua（实体注册/生成/冻结） | `scripts/Game/World.lua` + `Entities/EntityFactory.lua` 承担；**待补**：`direction/rotation`、`active/frozen` 字段（现仅有 `alive`）、120/150m 双阈值调度、生成约束 |
| Fish.lua 的 FSM 部分 | 用 `scripts/FSM/StateMachine.lua` 实例化 Sardine/Tuna 四状态（Wander/Attracted/Flee/Chase）+ 优先级：障碍/边界 > 危险/追猎 > 吸引 > Wander |
| Boat / Clock / Action / Port / Save | 仍由 A 实现，经 `Game.World:AddSystem()` 挂载——System 调度机制即这些模块的挂载点 |
| `Game/Game.lua` | 保留为协调层；Clock 的 pause reason 需扩展其 `wasPaused` 单一判断为多来源 |
| Config.lua / data/ 三表 | 不变（`1e0d8c8` 未触碰） |

流程决议（先例记录）：**本次特赦不追责，规则不变**——B 后续对 `scripts/` 的任何改动必须先以提案文档形式落在 `docs/`，经 A 审查后由 A 或 A 授权实施；直接用 AI 修改 🔴 核心文件的行为不再放行。

---

## 3. 文件所有权（冲突防火墙）

| 区域 | 写者 | 对方（Codex）权限 |
|---|---|---|
| `scripts/**`（全部代码） | 仅你 | 🔴 只读，禁止任何修改 |
| `data/**`（新建） | 仅对方 | 🟢 自由编辑，但必须符合你发布的 schema |
| `docs/` 内容类文档 | 对方可新增事件/世界观文档 | 不得改 PROJECT_STRUCTURE / TEAM_FILE_BOUNDARIES |
| `assets/` | 各自添加，替换前确认 | 新增自由 |
| `Config.lua` | 仅你 | 🔴 不碰；需要改数值时走 data 或向你提 |
| `.project/`、引擎配置 | 仅你 | 🔴 不碰 |

补充三条硬规则（写进给对方的 Codex 提示词）：
1. **单写者**：任何文件同一时段只有一个修改者，改共享文件先在群里说一声。
2. **Git 纪律**：对方只提交 `data/**` 和 `docs/**` 路径（`git add data docs`），提交信息写清改了哪个表；你负责合并与验收。禁止 `git add -A`、禁止 force push、禁止改别人的提交。
3. **schema 变更单向流动**：对方发现数据字段不够用 → 提需求 → 你改 schema 和加载代码 → 对方再填。对方永远不自己改加载逻辑来"适配"数据。

---

## 4. 先定契约，再动手（第 2~3 天你交付的三份 schema）

对方开工的前提是你先发布数据格式。建议直接在 `docs/` 放一页 `DATA_SCHEMA.md`，每张表给一个填好的示例行：

| Schema | 关键字段（示例） | 消费方 |
|---|---|---|
| `items.lua` | `{ id, name, category, buy, sell, heal, worldEffect, worldDuration }` | Action / Port / Fish |
| `fish.lua` | `{ id, speeds={wander,attracted,flee,chase}, turnRate, sense={attract,danger,prey}, avoid={predict,turnInterval,deviation}, despawn }` | Fish |
| `events.lua` | `{ id, day gating=none(第一版), trigger={nearLocation/proximity}, observeText, options={ cost=40, resultText, rewards } }` | Action / Save |

参数表里已有的数值（Sardine 4/5/7 m/s、Tuna 5/6/8、感知 18/12/30/36m 等）由对方原样抄入 `fish.lua`——这既是他的第一个任务，也是一次格式培训。

---

## 5. 里程碑（对齐 21 天 Jam，今天 D2）

| 里程碑 | 天数 | 你（WorkBuddy） | 对方（Codex） | 验收闸口 |
|---|---|---|---|---|
| **M0 单人闭环骨架** | D2~D3 | 船移动+镜头 dead-zone+昼夜时钟+HUD 雏形；发布三份 schema + DATA_SCHEMA.md | 装好 Codex 与 git；按 schema 抄入 items/fish 第一批数据 | 能开船出海、看到天黑、HUD 数字正确 |
| **M1 核心行动** | D4~D6 | 体力/Action（捕鱼 40、抛收 4s、空网也扣）/商店/背包/港口交互 | events.lua 填 3 个事件（1 免费 2 收费）；oldman.lua 两条教学提示 | 从出航到卖鱼赚钱的完整一天，每日结算+存档可跑 |
| **M2 生态与读海** ⚠️ | D7~D11 | Fish FSM + 感知半径 + **海面信号渲染（P1 硬缺口：Attracted=聚集涟漪 / Flee=散开水花 / Chase=白色尾迹）** + Debug 面板（显示水下/FSM/感知圆） | locations.lua 全部地点；events.lua 补到 10 个 | Debug 模式下验证：不显示水下也能凭水花/涟漪区分「平静/有鱼/有追逐」 |
| **M3 知识层与内容** | D12~D14 | 地点轮廓(80m)/识别(20m)/识别存档、打捞、宝藏、透视镜、老人交互 | 数值平衡表核算（对照 2100~2300 毛收入目标）；全部文案过一遍 | 存档字段完整；周目重置后世界一致 |
| **M4 平衡调参** | D15~D17 | 对照平衡目标实测：空网率、Tuna 占比 25~30%、日收入 100~150 | 用 Codex 建简单 Monte Carlo 表（或表格手算）复核经济曲线 | 一周目 25~40 分钟可通关；BALANCE_TARGET 达标 |
| **M5 二周目与交付** | D18~D20 | 周目重置流程、二周目验证（Day1 直取 Tuna）、整体换皮前的最终构建 | 二周目事件新结果文本（约 5 条）；截图与提交材料 | 双周目全流程无报错；构建通过并提交 |

- **M2 是全场最高风险段**（FSM 手感 + 表现层），给了 5 天；若 Sardine 回避过强（N1 存疑），在 `fish.lua` 里调 `avoid` 参数即可——数据在对方手里，你不用改代码，这就是数据驱动的红利。
- 功能裁剪顺序（若进度落后）：先砍透视镜三阶 → 再砍事件到 6 个 → 夜晚遮罩简化。**海面信号和存档永远不砍**——一个是核心循环的输入，一个是知识层的载体。

---

## 6. 给对方的 Codex 提示词模板（直接复制给他）

```text
你是本项目的数据编辑助手。硬性规则：
1. 你只能创建或修改 data/ 和 docs/ 目录下的文件，绝不触碰 scripts/、
   .project/、Config.lua 或任何 .lua 代码逻辑文件。
2. 所有数据必须符合 docs/DATA_SCHEMA.md 里的字段和格式，不改字段名、
   不新增字段；需要新字段时停下来问人。
3. 数值改动必须注明来源（策划参数表第 X 行 / 平衡目标表）。
4. 完成后输出改动文件清单，格式：文件名 + 改了哪些行 + 为什么。
5. 不确定就问，不要猜格式，不要"顺手优化"别的文件。
```

---

## 7. 风险与对策

| # | 风险 | 对策 |
|---|---|---|
| 1 | 新人用 Codex 改坏代码/改乱格式 | 目录隔离 + 只许 `git add data docs`；schema 单向流动；你每日合并前 `git diff --stat` 扫一眼路径 |
| 2 | 双 AI 口径不一（WorkBuddy 与 Codex 各理解各的） | 一切以 DATA_SCHEMA.md + 参数表为准；对方 AI 的每个任务附带「来源行号」 |
| 3 | M2 FSM 手感不达标 | Debug 面板（感知圆/FSM 状态）提前到 D7 做；参数全部走 fish.lua 可热调 |
| 4 | 海面信号表现力不足（NanoVG 简单图形） | 先用涟漪圆环/水花点/白色尾迹三类基础图形；上轮审查已确认这是符合性硬前提，宁简勿无 |
| 5 | 对方进度停滞（无经验） | 他的任务全是"填表"，第一天就有产出（抄 fish 参数）；验收标准是字段合法，不是写代码 |
| 6 | 中途退出丢当天进度（设计如此） | 在弹窗文案里明示「离港后进度将在每日结算时保存」，避免玩家误以为是 bug |

---

## 8. 与现有团队文档的衔接

- `TEAM_FILE_BOUNDARIES.md`：本方案是它在「2 人实现」场景下的细化，角色映射 A=你（主创/核心代码）、B=对方（数据/内容）；原 C/D 职能并入 B。
- `TASK_BOARD.md`：建议将 TASK-004「最小可玩航海流程」拆为 M0~M1 两个任务指派给你，新增 TASK-005「数据层与内容填充」指派给对方。看板更新由你确认后执行。
