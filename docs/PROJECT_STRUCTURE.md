# 项目结构与技术基线（第一版）

- 项目：2026 TapTap 聚光灯 21 天游戏创作挑战，4 人 AI GameJam。
- 任务：TASK-000（需求标题为 ASK-000，任务看板统一使用 TASK-000）。
- 检查日期：2026-10-01。
- 范围：完整只读检查现有五个 Lua 文件；不重构、不增加玩法、不修改项目设置。
- 当前技术栈：UrhoX + Lua；2D 场景使用 NanoVG 绘图，文字与按钮使用 `urhox-libs/UI`。

## 1. 当前目录树

### 玩法源码树

```text
scripts/
├── Main.lua
└── Ocean/
    ├── Config.lua
    ├── State.lua
    ├── Draw.lua
    └── HUD.lua
```

### 基线任务新增文档及实际附属文件

```text
项目根/
├── scripts/
│   ├── .luarc.json                  # 既有诊断配置，本次不修改
│   ├── Main.lua
│   ├── Main.lua.meta                # 既有元数据，本次不修改
│   └── Ocean/
│       ├── Config.lua
│       ├── Config.lua.meta
│       ├── State.lua
│       ├── State.lua.meta
│       ├── Draw.lua
│       ├── Draw.lua.meta
│       ├── HUD.lua
│       └── HUD.lua.meta
├── assets/                          # 已存在，检查时为空
├── docs/                            # 本任务新增
│   ├── PROJECT_STRUCTURE.md
│   ├── TEAM_FILE_BOUNDARIES.md
│   ├── TASK_BOARD.md
│   ├── GAME_DIRECTION.md
│   └── AI_RULES.md
└── screenshots/                     # 已有验证输出目录，非玩法源码
```

`data/` 尚未建立。引擎文档、示例、库、工具、构建产物及内部目录不是团队玩法源码，不应当作成员自由修改区域；本次不在这些目录中建立架构。

## 2. 五个文件的实际职责

“可以修改”指适合放在该文件中的变更种类，不代表所有成员都获得修改权限。具体权限以 [TEAM_FILE_BOUNDARIES.md](TEAM_FILE_BOUNDARIES.md) 为准。

| 文件 | 实际职责 | 可以修改（受所有权约束） | 不应该负责 |
|---|---|---|---|
| `scripts/Main.lua` | 入口、生命周期、输入、流程调度、绘图帧与尺寸管理 | 输入过滤、事件接线、模块调用、启动/停止流程 | 具体造型绘制、事件内容、完整游戏规则、素材制作 |
| `scripts/Ocean/Config.lua` | 标题、纵向层次、船只参数、鸟鱼静态绘图配置 | 已定义字段的常量、参数、静态数据；由 A 分配字段 | 玩家运行状态、事件执行逻辑、UI 构建、移动更新、资源运行管理、存档、AI 行为 |
| `scripts/Ocean/State.lua` | 状态创建/重置/暂停、目标位置限制、时间推进、船位平滑 | 核心运行数据、状态变化方法、明确批准的小型规则 | UI 绘制、素材加载、故事正文、界面文案 |
| `scripts/Ocean/Draw.lua` | 程序化海洋画面和时间驱动的视觉动画 | 造型、颜色、视觉动画、画面层次；由 A 接入 C 的视觉需求 | 核心游戏规则、奖励结算、状态写入、任务/事件执行 |
| `scripts/Ocean/HUD.lua` | 标题、按钮、状态文案、按钮动作封装与刷新 | UI 布局与样式、按钮调用已确认的状态接口 | 核心规则实现、状态字段直接写入、奖励/资源计算、航行系统 |

### 必须记录的职责差异

- `Main.lua` 不只是入口：还管理 NanoVG 帧、DPR 换算、持续方向键轮询、点击范围过滤和 UI 遮挡检查。
- `State.lua` 目前只有四个状态数据字段，并未维护飞鸟、鱼群、海浪、小岛等实体列表。
- `Draw.lua` 既画图，也即时计算视觉动画；鸟鱼游动不代表已经有追踪、涌现或探索规则。
- `HUD.lua` 不是纯只读界面：它调用状态方法，并把暂停/重置闭包交给 Main 的键盘路径复用。
- `Config.lua` 是部分静态配置，不是全部参数中心。点击海面范围在 Main，时间步上限和平滑系数在 State，多数造型与颜色在 Draw，UI 样式/文字在 HUD。

以上差异只记录，不为符合表格而改代码。

## 3. 实际模块依赖（require）

```text
Main.lua
├── require Ocean.Config
├── require Ocean.State ──→ Ocean.Config
├── require Ocean.Draw  ──→ Ocean.Config
├── require Ocean.HUD
│   ├──→ Ocean.Config
│   └──→ urhox-libs/UI
└── require urhox-libs/UI

Ocean.Config：不 require 其他模块
```

- 指定五个模块的加载依赖无环，没有明显循环依赖。
- `Draw` 和 `HUD` 都没有 `require("Ocean.State")`，而是接收 Main 传入的同一个状态对象。
- `State` 不调用 Draw/HUD，也不 require Main。
- 未把引擎 UI 库内部依赖纳入本次项目审查结论。

## 4. 运行时调用与对象传递

下图中的 `Main.Start`、`Main.HandleOceanUpdate` 等只是文件归属标记，不是可调用的 Main 模块接口。实际不存在 `Main` 模块表：Start/Stop 和事件处理函数是全局函数，`MoveToScreenPoint` 是 Main.lua 内的 local 函数；详见第 7 节。

```text
Main 顶层加载
 └── State.New() → Init() → state（Main 的模块级 local）

Main.Start()
 ├── 设置窗口标题、鼠标模式与光标
 ├── 创建 NanoVG 上下文并设置绘制顺序
 ├── UI.Init(...)
 ├── HUD.Create(state)
 │    ├── 创建 UI 树 → UI.SetRoot(root)
 │    └── 返回 { togglePause, reset, refresh } 闭包表
 └── 订阅 Update / NanoVGRender / KeyDown / MouseButtonDown / TouchBegin

Update
 └── Main.HandleOceanUpdate → state:Update(dt, direction)

NanoVGRender
 └── Main.HandleOceanRender
      └── nvgBeginFrame → Draw.Scene(ctx, w, h, state) → nvgEndFrame

空格 / R
 └── Main.HandleOceanKeyDown → hud.togglePause() / hud.reset()
      └── HUD 闭包 → state 方法 → Refresh() 更新 UI 文字

HUD 左右按钮
 └── state:MoveBy(-1 / 1) → state:SetTarget(...)

鼠标左键 / TouchBegin
 └── Main.MoveToScreenPoint → state:SetTarget(...)
```

不要把它简写为 `State → Draw`：实际是 Main 更新 State，并分别把状态对象传给 Draw/HUD；State 不直接调用它们。

### 启动与清理

`State.New()` 在 Main 文件加载时执行，而非在 `Start()` 内执行。NanoVG 上下文创建失败时，Start 提前返回，不继续初始化 HUD 和订阅事件。

`Stop()` 取消订阅、删除绘图上下文、关闭 UI，并清空 `hud`。当前不会重置 `state`、`firstFrame`、`lastWidth/lastHeight` 或恢复标题/鼠标属性。若未来要求同一脚本环境内 Stop→Start 重启，A 需确认保留还是重建状态；本次不修改这一行为。

## 5. 输入如何进入状态

| 输入 | 当前实际行为 |
|---|---|
| A / 左方向键 | 每帧方向减 1；同侧两键一起按不重复叠加 |
| D / 右方向键 | 每帧方向加 1；左右同时按抵消 |
| 空格 | 忽略重复 KeyDown；经 HUD 闭包切换暂停并刷新文字 |
| R | 经 HUD 闭包重置状态与文字；暂停中也可恢复初始运行状态 |
| 屏幕左右按钮 | 单次点击将目标位置按 `buttonStep` 步进，不是按住连续移动 |
| 左键按下 / TouchBegin | 通过海面范围和 UI 遮挡过滤后，设置目标横向比例 |

点击/触摸必须未暂停、宽高有效、`y / height` 在 `[0.36, 0.76]`、指针不在 UI 上。目标为 `x / width`，再由 State 限制到 `[0.18, 0.82]`。当前无拖动、上下移动或触摸移动处理。

State 更新先判断暂停；有效步长为 `clamp(dt, 0, 0.05)`，推进动画时间；按 `speed × direction × step` 更新目标，实际船位用 `1 - exp(-9 × step)` 平滑靠近目标。松开方向键后仍会靠近已有目标。`time` 是裁剪后累积的动画时间，不应直接当成现实时间或存档时间。

## 6. 状态对象及读写契约

| 字段 | 初始值 | 实际直接写入入口 | 模块外读取 |
|---|---|---|---|
| `time` | `0` | `Init`、`Reset`、`Update` | Draw |
| `paused` | `false` | `Init`、`Reset`、`TogglePause` | Main 输入过滤、HUD 文案刷新 |
| `boatX` | `Config.boat.initialX`（当前 0.5） | `Init`、`Reset`、`Update` | Draw 船只横坐标 |
| `targetX` | 同上 | `Init`、`Reset`、`SetTarget` | Main 的目标位置日志 |

- `MoveBy` 和 `Update` 通过 `SetTarget` 间接修改目标。
- Main/HUD 当前都通过方法修改状态，没有直接对四个字段赋值。
- State 的 `__index` 和方法属于模块/元表，不是额外的玩法数据。
- 鸟鱼配置、UI 控件、NanoVG 上下文不属于 State 的运行数据。

**协作约定：新增状态写入必须由 A 确认并集中通过状态接口进行；Draw 保持只读。** 当前 Lua 表并未强制只读或私有封装，保护依赖协作约定。

### Draw 怎样读取 State

`Draw.Scene` 读取 `state.time` 和 `state.boatX`，不读取 `paused/targetX`，不写状态、不调用状态方法。暂停通过不再推进 time/boatX，使视觉运动停止。

实际绘制顺序为：背景 → 海面 → 鸟 → 鱼和泡纹 → 船 → 岛 → 箭头。参考图的顺序是纵向层次，不等于全部渲染调用顺序。

### HUD 怎样读取和修改 State

`HUD.Create(state)` 的闭包保留状态引用：

- 暂停动作：`state:TogglePause()` → `Refresh()`。
- 重置动作：`state:Reset()` → `Refresh()`。
- 左右按钮：`state:MoveBy(direction)`。
- `Refresh()` 读取 `paused`，更新按钮与状态文字；不写 State。

HUD 无每帧状态刷新或订阅机制；返回的 `hud.refresh` 当前未被 Main 使用。如果将来其他模块直接调用暂停/重置方法，A 必须同步安排 UI 刷新，不能假设文案会自动变化。

## 7. 全局与局部变量

### 项目定义的全局函数

仅 Main 定义以下 7 个全局函数，供引擎启动/停止和按字符串名订阅事件使用：

`Start`、`Stop`、`HandleOceanUpdate`、`HandleOceanRender`、`HandleOceanMouseDown`、`HandleOceanTouchBegin`、`HandleOceanKeyDown`。

新成员不得随意新增同名全局函数。五个文件没有新增全局数据变量。

### 模块级 local

| 文件 | 模块级局部数据/模块引用 |
|---|---|
| Main | `UI`、`Config`、`State`、`Draw`、`HUD`、`oceanContext`、`state`、`hud`、`lastWidth`、`lastHeight`、`firstFrame`；局部函数 `MoveToScreenPoint` |
| Config | `Config` 静态表 |
| State | `Config`、`State` 模块表 |
| Draw | `Config`、`Draw` 模块表和局部绘图辅助函数 |
| HUD | `UI`、`Config`、`HUD` 模块表；`Create` 内的控件、root 和动作闭包是函数局部变量 |

`state` 是 Main 的 local，不是全局变量；传入 Draw/HUD 后是共享引用。`function State:Update(...)`、`Draw.Scene(...)`、`HUD.Create(...)` 赋值在 local 模块表上，不是全局函数。

代码引用 `graphics`、`input`、NanoVG API、事件 API、枚举及 Lua 标准库等外部全局。Main 改写既有引擎对象的标题和鼠标属性，并未新建项目全局数据。

## 8. 不应继续膨胀的公共文件

- **Main / State**：核心文件，默认仅 A 修改；入口不收纳具体绘图，状态模块不收纳 UI 或故事正文。
- **Draw / HUD**：公共表现文件，由 A 协调单一修改者；不因为视觉或按钮需求就堆入完整规则。
- **Config**：只允许配置、参数、静态数据；禁止演变为配置 + 玩家状态 + 事件逻辑 + UI + 移动 + 资源 + 存档 + AI 的万能文件。

当前五文件总计约 805 行，最大单文件 Draw 约 348 行，规模小，本次没有必须拆分的证据。仅当实际新增需求形成清晰独立职责时，A 再批准一个小模块，不提前建复杂框架。

## 9. 新功能与未来目录建议（本次不创建）

| 需求 | 建议放置 | 接入要求 |
|---|---|---|
| 策划数值、静态关系、事件/生物/地点等数据 | 未来 `data/events/`、`items/`、`locations/`、`creatures/` | A 先确认字段、ID、格式和加载方式；没有读取接口时只是提案数据 |
| 世界观、对白、萨迦、事件正文 | `docs/`；未来 `data/lore/`、`dialogue/`、`saga/`、`events/` | B 管规则，D 管正文；同文件顺序交接，不并发修改 |
| 船只、海洋、生物、岛屿、环境、UI、特效素材 | 未来 `assets/ship/`、`ocean/`、`creatures/`、`island/`、`environment/`、`ui/`、`vfx/` | C 提交素材用途，A 接入；当前 Draw 为程序化绘图，添加图片不会自动显示 |
| 实际批准的小型功能代码 | `scripts/` 中职责明确的单个模块；海洋相关可归入 `scripts/Ocean/` | A 分配文件与接口，再进行入口/状态接线 |

`data/` 目前不存在且五个模块没有数据加载器，不承诺新建数据会自动进入游戏。也不为这些建议目录创建 Manager/Service 等占位系统。

## 10. 本次验证和限制

- 本次只读检查了五个 Lua 文件，游戏源码和项目设置均以任务开始时校验值为基线。
- 首次带截图的 140 帧验证成功启动并产出真实画面，报告原始为 FAIL：仅截图帧发生 `Frame time spike: 3703.24ms (threshold: 500ms)`；Lua 错误为 0，资源错误为 0，缺失资源为空。没有隐瞒这一原始结果，也没有通过调大阈值伪装通过。
- 随后以相同 500ms 阈值、不带截图独立验证 120 帧：原始 PASS / exit 0，Lua、资源、引擎错误均为 0，缺失资源为空。结果已核对并记录在 [TASK_BOARD.md](TASK_BOARD.md)，验证证据在既有 `screenshots/` 下。
- 截图检查确认五层画面、标题、操作按钮显示；不把单张图当成对全部运动轨迹、按键或真机触摸的验收。
- 本次没有修改 Lua，故不触发源码修改后的重构/重新构建工作流，也不调用可能刷新项目配置的构建工具。原项目保留此前官方构建结果。
- A 的人工 Preview 检查、权限确认与正式验收仍待执行；AI 不自行标记“已验收”或“稳定版”。

四人边界见 [TEAM_FILE_BOUNDARIES.md](TEAM_FILE_BOUNDARIES.md)，任务格式见 [AI_RULES.md](AI_RULES.md)。
