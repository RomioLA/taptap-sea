# 任务看板（第一版）

- 项目：2026 TapTap 聚光灯 21 天游戏创作挑战，4 人 AI GameJam。
- 建立日期：2026-10-01。
- 需求标题 ASK-000 对应看板任务 TASK-000；后续统一使用 TASK-XXX。
- A 负责协调和验收；同一文件只安排一个修改者。

## 1. 初始看板

按任务要求记录初始状态，不能把本表误认为全部任务已获得开发许可。

| ID | 任务 | 负责人 | 类型 | 状态 |
|---|---|---|---|---|
| TASK-000 | 项目基线初始化 | A | 技术 | 进行中 |
| TASK-001 | 游戏核心循环设计 | B | 策划 | 未开始 |
| TASK-002 | 视觉风格与素材规范 | C | 美术 | 未开始 |
| TASK-003 | 世界观与萨迦设定 | D | 内容 | 未开始 |
| TASK-004 | 最小可玩航海流程 | A+AI | 程序 | 未开始 |

## 2. 当前交付状态

TASK-000 已提交五份文档及技术检查结果，当前进入 **待验收**。这是“文档/技术材料已交付”，不是 A 已完成验收。

| ID | 任务 | 负责人 | 类型 | 当前状态 |
|---|---|---|---|---|
| TASK-000 | 项目基线初始化 | A | 技术 | 待验收 |
| TASK-001 | 游戏核心循环设计 | B | 策划 | 未开始 |
| TASK-002 | 视觉风格与素材规范 | C | 美术 | 未开始 |
| TASK-003 | 世界观与萨迦设定 | D | 内容 | 未开始 |
| TASK-004 | 最小可玩航海流程 | A+AI | 程序 | 未开始 |

初始表保留为建立时快照；日常跟踪以“当前交付状态”表为准。除 A 明确发出任务外，不自动推进其他任务。

## 3. 统一状态

| 状态 | 含义 | 谁确认 |
|---|---|---|
| 未开始 | 尚未实施；任务列在看板不等于已授权 | A 分配后才能开始 |
| 进行中 | 范围与修改者已明确，正在执行 | 负责人报告，按交接顺序更新 |
| 待验收 | 已提交改动、测试和风险，等待验收 | 实施者可建议，A 协调登记 |
| 已验收 | 验收标准已经核对通过 | A |
| 稳定版 | A 确认可作为团队共同开发基线 | A |
| 阻塞 | 依赖、冲突、接口或测试问题使任务无法继续 | 负责人说明原因，A 决定解除 |

不得新增“完成/已完成”等替代状态，不得由 AI 自行标记“已验收/稳定版”。

## 4. TASK-000 提交记录

### 交付内容

- [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md)：真实目录、职责差异、require 与运行时关系、状态/全局说明。
- [TEAM_FILE_BOUNDARIES.md](TEAM_FILE_BOUNDARIES.md)：A/B/C/D 所有权、保护等级、Config 限制、跨模块和停止线。
- 本看板：初始任务、状态约定、提交与验收记录。
- [GAME_DIRECTION.md](GAME_DIRECTION.md)：暂定航海与涌现事件方向，只记录不实现。
- [AI_RULES.md](AI_RULES.md)：AI 能力/禁区、任务模板、测试和报告格式。

### 技术检查

| 项目 | 实际结果 / 限制 |
|---|---|
| 五个现有 Lua 文件 | 已完整只读检查，不为优化而重构 |
| 模块依赖 | Main 加载 Config/State/Draw/HUD；后三者均依赖 Config；Draw/HUD 接收 Main 的状态实例，无五模块循环依赖 |
| 全局与公共状态 | Main 有 7 个全局函数，无新增全局数据；共享 local state 的四字段读写已记录 |
| 启动与显示 | 本次使用既有 UrhoXRuntime 实际启动，真实截图确认标题、飞鸟、海浪、鱼群、船只、小岛和按钮显示 |
| 带截图验证 | 完成 140 帧；原始 FAIL / exit 1，唯一报告错误是截图帧 120 的 `Frame time spike: 3703.24ms (threshold: 500ms)`；Lua/资源错误为 0，缺失资源为空 |
| 独立启动验证 | 不带截图，以相同 500ms 阈值运行 120 帧：原始 PASS / exit 0；Lua、资源、引擎错误均为 0，缺失资源为空 |
| 配置与代码一致性 | 开始时记录五 Lua 与 settings.json/project.json 的 SHA-256；交付前已复核，七个文件内容均完全一致 |
| 构建 | 本次未修改 Lua，不重新构建，不刷新项目设置；保留原官方构建结果 |
| 操作验收 | 代码路径已核实；未进行真机触摸或逐项自动输入测试，待 A 在 Preview 手动验收 |

### 测试证据

```text
screenshots/
├── TASK-000-validation.json             # 首次带截图验证，保留原始 FAIL
├── TASK-000-runtime.txt
├── TASK-000-baseline.png                # 内部视觉检查，不作为宣传素材
├── TASK-000-startup-validation.json      # 独立启动验证 PASS
└── TASK-000-startup-runtime.txt
```

本次测试未升级/重装运行时、不写源码或项目设置、不创建服务器。运行时正常产生的缓存/本地诊断日志不是团队代码改动；没有主动修改或删除既有日志。

检查来源：代码审查为只读工作；启动和截图结果来自本次另行运行的既有 UrhoXRuntime 及上列原始报告，校验来自任务开始和交付前的 SHA-256 对比。当前设置的 `@runtime.multiplayer.enabled` 已只读核对为 false；未为测试切换模式。

### 可复核的内容基线

以下七个文件任务前后 SHA-256 完全一致；只是记录校验值，不修改或展示配置内容。

| 文件 | SHA-256 |
|---|---|
| `scripts/Main.lua` | `91074422bb7be03efd785b236f703e003929ab87628b33bcbe1b1a39904604b6` |
| `scripts/Ocean/Config.lua` | `d497e239ddf672c169193e3da99d55fd144bc0731cba0174a10c187d14da4425` |
| `scripts/Ocean/State.lua` | `cad0479f47b03db4544ecca8da97be5a913c4da4f8685fbe18ba812360b6814a` |
| `scripts/Ocean/Draw.lua` | `bdb5a1339c9eecc8c0699a810747f3342c7e3348fe1779e0d6b98c74c28ce1a3` |
| `scripts/Ocean/HUD.lua` | `e5e282261c1ca0f6f8a0dfe597d877392005f02e912a26402a084ece4676e6ef` |
| `.project/settings.json` | `25cf26bf3c26c51d3d93d09895918e18b0363adf8b547bb10e7065b712dbc2a8` |
| `.project/project.json` | `bb20aea2fdd71c961edc833361ee3c6728b3ffc9d8fe04d394f9b7c242b7dba5` |

## 5. 最终验收清单

### 已提供技术/文档证据

- [x] 已检查 Main、Config、State、Draw、HUD。
- [x] 已记录真实加载依赖和运行时对象关系。
- [x] 启动验证通过，现有画面可显示。
- [x] 五份指定文档已建立。
- [x] A/B/C/D 责任、可以修改和禁止修改的区域已明确写出。
- [x] Main/State 标记为核心文件；Draw/HUD 为公共表现文件。
- [x] Config 只限静态配置，不成为万能文件。
- [x] 跨模块任务标注、A 协调和单一修改者规则已写明。
- [x] 不实施未来完整玩法，不建立大量占位架构。
- [x] 不更换引擎/技术栈，不修改 Lua 或项目关键设置，不删除已有代码。

### 等待 A / 团队确认

- [ ] A 在 Preview 确认项目启动与基础动画正常。
- [ ] A 验证 A/D、方向键、海面点击、屏幕按钮、空格暂停/继续、R 重置；需要触摸设备时另行真机检查。
- [ ] A/B/C/D 阅读并确认自己能改、不能改的文件及停改求助规则。
- [ ] A 确认配置字段授权与共享 docs/data 的交接方式。

## 6. 2026-10-02 任务更新（双人实现分工）

依据 `docs/FEASIBILITY_PLAN.md`，实现人力调整为 2 人：A（WorkBuddy，核心代码）+ B（数据/内容，Codex 辅助）。TASK-004 按里程碑拆分，新增数据层任务。本表为增量快照，日常跟踪以本表为准。

| ID | 任务 | 负责人 | 类型 | 状态 | 说明 |
|---|---|---|---|---|---|
| TASK-006 | 数据契约 DATA_SCHEMA.md 定稿（items/fish/events 三份 schema + data/ 三表基准数据预填） | A | 技术 | 待验收 | 已交付 `docs/DATA_SCHEMA.md`、`scripts/data/items.lua`、`scripts/data/fish.lua`、`scripts/data/events.lua`（items/fish 按参数表预填，events 含 1 条格式示范） |
| TASK-004a | M0 单人闭环骨架：船移动/镜头 dead-zone/昼夜时钟/HUD 雏形 | A+AI | 程序 | 未开始 | 原 TASK-004 前半；闸口=能开船出海、看到天黑、HUD 数字正确 |
| TASK-004b | M1 核心行动：体力/捕鱼/商店/背包/港口/每日结算存档 | A+AI | 程序 | 未开始 | 原 TASK-004 后半；闸口=完整一天经济闭环；依赖 TASK-006 schema |
| TASK-005 | 数据层与内容填充：data/ 七表（items/fish/events/locations/upgrades/oldman/ui_text） | B（Codex 辅助） | 内容 | 未开始 | 首个任务=校对 A 预填的 items/fish 基准行 + 补齐约 10 个事件；格式契约=DATA_SCHEMA.md；只许修改 `scripts/data/` 与 `docs/`，禁止触碰 `scripts/` |
| TASK-007 | 架构提案验收：远端提交 1e0d8c8（Game/World/FSM/Entities/Systems 骨架） | B 提交，A 验收 | 程序 | 待验收 | 静态审查已通过（无策划规则落地，纯通用骨架，~145 行）；**缺运行验证**：A 在 Preview 确认启动与既有画面正常；验收通过后按 FEASIBILITY_PLAN §2.1 收编为基础设施层 |
| TASK-007N | 边界先例登记 | A | 流程 | 已决议 | 1e0d8c8 越界修改 🔴 核心文件，本次特赦收编、不追责；先例已写入 FEASIBILITY_PLAN §2.1——此后 B 改 `scripts/` 必须先走 docs/ 提案 + A 审查 |
| TASK-008 | 程序接入提案验收：目录分层 Ocean/+Gameplay/+Integration/（远端 2569cd4，AGENTS.md + docs/ARCHITECTURE_LAYOUT.md） | B 提案，A 审查 | 流程 | 待验收 | 提案本身边界合规（仅改 docs 与自建 AGENTS.md）；A 审查意见：①采纳三层职责划分，Integration 只做装配/转发/事务编排、不得持有任何状态；②Gameplay 模块须以 System 注册进 Game.World（单一更新链）；③**修正文档失实**：AGENTS.md 以"现有"描述的 SeaRuntime、Ocean/World.lua、GeneratedData/、tests/sync_runtime_data.py 在共享 main 上均不存在，须改为"计划引入"或先落地基础设施；④Ocean/World.lua 与 Game/World.lua 命名冲突，建议改名或写明扩展机制 |

原 TASK-001（核心循环设计）、TASK-002（视觉规范）、TASK-003（世界观设定）保留，C/D 职能当前并入 B；推进由 A 明确发出任务后开始。
- [ ] A 核对全部最终验收条件，将 TASK-000 标为“已验收”；必要时再确认“稳定版”。

“原有功能未破坏”的证据包括源码未变、启动/画面回归；不因此代替人工操作验收。全部条件确认后才算 TASK-000 正式完成。

## 6. 本次不做的事

不开发完整航海循环；不实现事件系统、涌现事件、资源、船舱、存档或日志；不重构；不修改项目设置；不删除、重命名或覆盖现有成员文件；不把建议目录全部建好。

**交付 TASK-000 后停止。TASK-001/002/003/004 等待 A 下一步指令。**
