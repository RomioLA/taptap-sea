# 本地状态归属与统一调度实施记录

2026-10-02。正式实施目录：C:\codex\taptap-sea。本文件仅用于本地交接，不同步到共享提交目录。

## 约定核对

共享提交 ed294f6 的 AGENTS.md 与 ARCHITECTURE_LAYOUT.md 已对应队友确认的四项要求：仅写职责约定而非实施进度；Integration 不持有玩法状态；Gameplay 经 World:AddSystem 注册；两个 World 通过扩展机制共用注册表。本轮不修改这两份约定。

## 本轮实际实施

1. Gameplay.Actions 持有捕鱼令牌、待处理动作和投放目标。捕鱼记录只保存目标 ID 与世界代次，不持有可变海洋实体；这些临时状态不进入存档。Integration.Bridge 仅保留模块与回调引用，通过 Gameplay 方法操作玩法状态，通过 Ocean 公开方法处理海洋状态。
2. 玩家资源回滚、暂停切换、地点识别和消息更新归 Gameplay；鱼实体的快照、恢复、移除和行为清理由 Ocean.SeaRuntime 提供公开接口。Integration 不直接写玩家字段、鱼实体或世界注册表。场景装配和界面布局仍留在 Integration。
3. Gameplay.UpdateSystem 经 World:AddSystem(system, "frame") 注册。Game 发起 World 每帧调度，随后同步暂停并调用海洋模拟；鱼 FSM 使用同一个 World 的 simulation 调度。默认 AddSystem/Update cadence 为 simulation，保留海洋接口兼容。
4. 昼夜每帧使用完整 dt，只更新一次；海洋保留每帧0.25秒限制和0.05秒子步。每帧玩法判定和暂停同步先于海洋模拟。海洋暂停或 dt=0 不跳过必要的玩法状态判定。Runtime 重置后将 Gameplay System 注册到当前 World，不保留陈旧注册表。
5. Gameplay 单独演示入口也通过 World/System 更新；Debug 跳转仅调用 RefreshClockStatus 处理边界，不额外推进昼夜。

## 修改文件及原因

| 文件 | 改动位置 | 原因 |
|---|---|---|
| scripts/Gameplay/Actions.lua | 新增全文 | 将跨帧捕鱼与投放状态从 Integration 移入玩法模块 |
| scripts/Gameplay/UpdateSystem.lua | 新增全文 | 提供 World 注册的每帧玩法 System |
| scripts/Gameplay/Loop.lua | ResetState、Update/RefreshClockStatus，以及新增公开操作接口 | 负责动作状态生命周期、回滚、暂停、地点识别与消息；状态观察装配移入 Gameplay |
| scripts/Integration/Bridge.lua | 构造、投放、捕鱼、暂停、地点识别与读档方法 | 移除自持状态和越界写入，转为公开接口调用 |
| scripts/Integration/Scene.lua | 第157、212行 | 通过 SetMessage 写玩法消息 |
| scripts/Ocean/SeaRuntime.lua | Init、第149～203行的捕鱼公开接口 | 海洋侧负责实体恢复与行为维护；用世界代次阻止重置后 ID 复用误捕 |
| scripts/Game/World.lua | Init、AddSystem、Update | 同一个调度器区分 frame 与 simulation，注册去重并禁止静默改变调度类型 |
| scripts/Game/Game.lua | Init、GetWorld、Update | 注册 Gameplay System，去除整局入口直接调用 Loop.Update，重置后复用当前 World |
| scripts/Gameplay/Bootstrap.lua | 第5～6、17～18、27行 | 独立玩法入口也使用 World/System |
| scripts/Gameplay/Debug.lua | 第57行 | 跳转后的边界判定不调用额外周期更新 |
| scripts/tests/ABIntegrationTests.lua | 捕鱼收费失败注入检查 | 注入点迁到 Gameplay，保留原行为断言 |
| scripts/tests/ArchitectureIntegrationTests.lua | Reset 注册断言与新增4项检查 | 验证状态归属、完整帧计时、重置 ID 复用与部分移除失败后 FSM 恢复 |
| docs/STATE_SCHEDULER_INTERNAL.md | 新增全文 | 本地实施与验证交接 |

函数位置为本轮修改范围；没有将工作区原有未提交改动算作本轮实施。完整源文件指纹差异见 .tmp/state-scheduler-refactor/source-audit.json。

## 最终验证与边界

- 11项架构集成检查通过：.tmp/architecture-integration/validation.json。
- 9套既有回归通过：海洋行为53、长航3、场景接线8、A/B事务29、玩法20、界面模拟6、存档84、经济21、商店15；另有15项数据接口兼容检查及55个Lua文件语法检查通过。证据：.tmp/data-migration-preparation/migration-validation.json。
- Lua语言服务器0 Error：.tmp/data-migration-preparation/migration-lsp.json。
- Maker本地 preview prepare 成功，新增 Actions/UpdateSystem 与相关修改模块进入资源清单，准备目录与本地源码逐字节一致。证据：.tmp/state-scheduler-refactor/source-audit.json。
- 预览为 stopped、process_alive=false，未重启。真实窗口画面、操作与云功能仍待运行验收；离线准备和模拟测试不能替代该验收。历史 DDS/DLL 环境错误未处理。
- 数据表、Config、PlayerState、Persistence 和玩法数值保持本轮开始时的指纹；未新增存档字段，未采纳过程稿新规则。
- C:\codex\taptap-sea-push 保持干净，HEAD仍为 ed294f6；共享文档指纹未变。本轮程序未复制、暂存、提交、push或远端build。

本记录接续 ARCHITECTURE_INTEGRATION_INTERNAL.md 的前一轮骨架接入记录。后续程序交付须单独确认文件范围并走 Maker 提交流程。

## Ocean 接口边界收尾

本地复核指出 Bridge 仍通过 ship/world/movement 访问海洋内部对象。本次仅在 C:\codex\taptap-sea 收尾，未修改共享约定或提交目录。

| 文件 | 改动位置 | 原因 |
|---|---|---|
| scripts/Ocean/SeaRuntime.lua | 第115～136行 | 增加 GetShipPosition、IsPositionFree、ClearMovementTarget、RejectDroppedItem；船位返回副本，拒绝投放清理归海洋侧 |
| scripts/Integration/Bridge.lua | 第50、73、83、120、175、204、219行 | 改用上述公开接口，移除对 runtime.ship/world/movement 的直接访问 |
| scripts/tests/ArchitectureIntegrationTests.lua | 第199行起新增检查 | 屏蔽海洋内部对象后验证 Bridge 的投放拒绝、地点识别和重置；验证船位副本与拒绝清理不会移除船 |
| docs/STATE_SCHEDULER_INTERNAL.md | 本节 | 记录接口边界收尾与实际检查 |

最新检查：12项架构检查、9套既有回归、15项数据接口检查与55个Lua文件语法检查通过；Lua语言服务器0 Error。证据路径同上，已刷新为收尾版本。预览仍停止，未启动真实窗口；上节资源准备记录属于此前的状态/调度批次，本次没有重新准备或声称真实运行通过。提交目录仍干净、HEAD为ed294f6；未提交、push或远端build。
