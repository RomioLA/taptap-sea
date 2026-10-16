# 七天周目、NG+ 与海景昼夜循环交付

项目：`C:\codex\taptap-sea`；2026-10-04 HKT。

## 范围与盘点

已完整阅读项目策划 01–08、根目录 AGENTS.md、外部旧核对方案及 Issue #1 最新评论。以项目内策划和本轮要求为准。开工前 WorkBuddy 待命、无活动冻结；主代理已发布开工及冻结留言。工作区原有大量修改保留，任务前副本见 `before/`。

原实现已有日结异步请求协调器、失败重试/明确放弃、初始存档、NG+ 普通状态重置和纸条已读持久化；本轮复用这些实现。原实现缺少七天上限和最后一天流程边界，主海景太阳固定、没有跟随玩法时钟的月亮路径。

## 实际改动（14 个源码/测试文件）

| 文件 | 本轮改动 |
| --- | --- |
| `scripts/config/gameplay.lua` | 明确 `totalDays=7`。 |
| `scripts/Gameplay/Loop.lua` | 第7天纸条先读后结算；终日保存保持 day=7，阻止第8天、体力恢复和新日刷新；运行态 `IsRunEndPending()` 边界暂停玩法，沿用 NewRun；保留异步请求/代际保护和重试快照。 |
| `scripts/Gameplay/Persistence.lua` | 保存与读档拒绝超出1–7的日期；失败读档保留当前状态，不静默截断旧档。 |
| `scripts/Gameplay/HUD.lua` | 纸条优先显示；终日结算、失败与放弃提示；第6天进入第7天仍显示普通新日流程。 |
| `scripts/Gameplay/GameClock.lua` | `GetState()` 提供当前阶段 `duration` 和归一化 `progress`。 |
| `scripts/Integration/Scene.lua` | 在已检查成功的 `pcall` 返回值上补一行类型收窄注解；保持运行逻辑。修改前已在 Issue 追加冻结并保存原文件副本。 |
| `scripts/Ocean/Draw.lua`、`SeaViewArt.lua`、`SeaDraw.lua` | 现有主海景接入同一个 GameClock。太阳白天、月亮夜间从右侧东方升起向左侧西方移动，沿现有投影海平线升落；轻量晨午暮颜色过渡，保留夜幕和无时钟背景。 |
| `scripts/tests/GameLoopSpec.lua`、`Circle1B3SevenDaysTests.lua` | 更新合法七天边界和真实 HUD 纸条→终日日结→新周目验证。 |
| `scripts/tests/SevenDaysRunTests.lua`、`SeaDayNightCycleTests.lua` | 新增异步幂等、NG+、时钟归一化、时长变化、暂停和渲染只读测试。 |
| `tests/run_seven_days_cycle.py` | 复用已有隔离运行器/NanoVG记录器的本地综合回归入口。 |

未改 `Circle1B2Progress.lua`、`Circle1B2ProgressTests.lua`、`SeaAtmosphere.lua`、引擎库、生成副本或其他既有修改。任务增量见 [task-only.diff](task-only.diff)，文件哈希见 [changed-files.json](changed-files.json)；该增量相对开工副本，不是整个脏工作区相对 Git HEAD 的差异。

## 验证

- 综合本地回归：**101 个 Lua 文件语法通过；43 套 Lua suites、383 项 suite 检查通过；另5个 player specs通过**，失败0。见 [final/regression.json](final/regression.json)。
- 项目 CI 入口 `tests/run_circle1_b.py`：101文件语法、10套/80项通过，失败0、跳过0。见 [final/ci/regression-result.json](final/ci/regression-result.json)。这只是本地运行 CI 入口，不代表新的 GitHub Actions 运行。
- 既有 `scripts/tests/Circle1B3Run.py --suite all`：101文件语法、21套通过，失败0、跳过0。见 [final/b3/regression-result.json](final/b3/regression-result.json)。
- 最终全量 EmmyLua 静态检查没有新增错误；仍有3条开工前已有的 `assign-type-mismatch`：`Circle1B3SceneUITests.lua:92,93`、`Circle1B3ClockAsyncTests.lua:74`。没有修无关测试。见 [final/lsp-after-scene-annotation.json](final/lsp-after-scene-annotation.json)。

静态复核中曾稳定报告 `Integration/Scene.lua:223` 的 `pcall` 返回类型收窄错误，受控 before 文本覆盖时未报告该项；没有足够开工哈希证据归因。该入口已按成功返回契约补类型注解。修正前报告保留在 [final/lsp-confirmation.json](final/lsp-confirmation.json)，受控对照见 [final/lsp-controlled-baseline.json](final/lsp-controlled-baseline.json)。

- 对本轮涉及的已跟踪文件执行 `git diff --check`，通过；仅有既有 CRLF 转换提示。
- 已生成并阅读实际 SeaDraw 离线渲染六帧：[昼夜循环拼图](evidence/day-night-cycle-20261003T180622Z-1791050782967247900/day-night-cycle-contact-sheet.png)。这是离线 NanoVG 记录器渲染，不是本机引擎截图或 HUD 验收。
- 每批后检查 Maker 本地预览。最后 `state=stopped`、`process_alive=false`，按要求没有启动或刷新。见 [maker-preview-final.json](maker-preview-final.json)。原生引擎和真实云存档未验证；状态返回的旧会话错误不作为本轮新增错误。

新七天测试覆盖：正常/强制终日、纸条必读且一次/周目、重试同快照、重复/迟到回调、显式放弃保留旧档、第6→7天可玩、day8拒绝且当前状态不变、NG+重置及初始保存重试、终局后Update不重入。

NG+核验重置金钱、体力与上限、速度/背包升级、背包物品、识别地点、透镜、普通宝藏、本轮纸条/老人/剧情进度、动态海洋和商店库存；重开初始状态仍走现有保存流程，没有隐藏数值加成。图鉴/成就没有现有可用系统及持久化契约，因此未新增或宣称跨周目保留。

海景测试覆盖 GameClock.GetState 和 Bootstrap 实际传入的原始 GameClock、昼/夜时长改变后的相同阶段进度、两端完整路径、暂停后的位置和颜色冻结、渲染不修改游戏状态。`nvg-resolution-mode` skill 未在本机发现；沿用项目规定的逻辑像素模式和既有 NanoVGRender 管线。

## 未完成项与契约限制

1. 具体结局、条件、阈值、文案、奖励和老人命运规则仍待设计。没有实现 WorkBuddy 的三结局方案，没有新增 Ending 或持久化字段。
2. Schema v1 没有区分“第7天进行中”和“第7天已终日结算”的持久化标记。`runEndPending` 仅运行态；读终日保存会恢复可玩的第7天，已有 `paperShown` 保留且不重复触发纸条。跨进程恢复终局边界需要先确认持久化契约；本轮停在最小接口，没有把纸条已读冒充周目完成。
3. 不等待正在进行的保存只能忽略本地迟到回调，现有云接口没有取消/条件写入能力；远端请求仍可能稍后更新云档。提示已说明此限制。失败后明确放弃不发新写入、不伪报成功。
4. 旧实现可能生成的 day>7 存档现在会被明确拒绝，不会覆盖当前状态；旧档迁移策略需另行确认。

## 重现

本机系统 Python 不可用，复用 Codex bundled Python；Lupa 2.6 仅安装于本任务 `outputs/seven-days-cycle/deps`。依赖目录读取权限需本机授权运行，不改系统 Python、PATH 或 ACL。

```powershell
& 'C:/Users/80739/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' 'tests/run_seven_days_cycle.py'
& 'C:/Program Files/nodejs/node.exe' 'C:/Users/80739/.taptap-maker/mcp-runtime/0.0.36/dist/maker.js' preview status --target-dir 'C:/codex/taptap-sea' --json
```

主代理已在 Issue #1 发布收工汇报，解除本轮开工留言和追加 Scene 留言所声明的全部冻结；Codex 当前无活动冻结。

本轮未提交、推送、切分支、远端构建或发布。
