# C 实施 / 测试最终报告

【TASK】
TAPTAP-V25-WORK-C-EXPLORATION-IMPLEMENT-01

结论：C职责内的独立Gameplay core和fake adapter验证完成，等待Integration接线。没有运行真实GUI或远端构建。

【GIT】
- Worktree: `C:\codex\taptap-sea-worktrees\WORK-C-EXPLORATION`
- Branch: `feat/20261015-v25-exploration-c`
- Base HEAD: `27e622688778e643cd28e99c2e7a0f0eee512e05`
- Final HEAD: `27e622688778e643cd28e99c2e7a0f0eee512e05`
- Dirty before: 任务初始clean；本次续接已有未跟踪的 `WorldContentProgress.lua`。
- Dirty after: 仅C新增源码、测试、交接文档与JSON证据；既有tracked文件和暂存区无差异。未重建Worktree。

【实现】
- R8: `island_01/02`各周目一次，adapter实时表面距离<=5m，4s后成功扣40，只给对应memory。
- R9: 固定 `underwater_treasure_01` 的观察/marked/salvage core；有透镜且连续有效scope 1s标记，离开清零，标记不自动开始打捞。4s/40成本，仅成功收费。
- D5: 三个直接 `player.treasures.memory_*` ownership，无普通ItemDefinition/Inventory写入。老人展示适配交A/Integration。
- Progress: Initialize/Validate、marked/completed一致性、单目标快照/恢复/提交。岛屿不要求marked。拒绝畸形及completed/reward不一致状态。
- Actions: 独立token/receipt、begin快照、commit状态和结果、取消/失败/回滚、动态context prompt查询；显式 `Advance(explicitElapsed)`，不选择dt。
- Persistence: 现有map序列化可完整往返三碎片和marked/completed，跨日保存测试通过。共享Persistence未接新Validate，需Integration在保存/读取边界接入；Save Schema未升级。
- Stale-world: session generation + runtime identity +独立fixed-content generation +玩家/容器身份+本地epoch。新周目/读取/世界重置/替换Runtime后拒绝旧提交。鱼日刷新代际独立。

【新增/修改文件】
所有交付文件均为新增：
- `scripts/Gameplay/WorldContentProgress.lua`
- `scripts/Gameplay/WorldContentActions.lua`
- `scripts/tests/WorldContentTests.lua`
- `tests/run_world_content.py`
- `docs/V25_WORK_C_INTEGRATION.md`
- `docs/V25_WORK_C_REPORT_20261016.md`
- `outputs/world-content/results.json`（完整测试证据）
- `outputs/circle1-b2/lsp-result.json`（诊断证据）

【Gameplay API】
完整参数、返回值、失败原因、所有权契约见 `V25_WORK_C_INTEGRATION.md`。

- `WorldContentProgress.Initialize/Validate(player) -> bool,reason?`
- `GetState/Snapshot(player,contentId) -> copy|nil,reason?`
- `Mark/Commit(player,contentId)`、`Restore(player,contentId,snapshot) -> bool,reason?`
- `WorldContentActions.New(adapter) -> service|nil,reason?`
- `service:BeginExplore/BeginSalvage(contentId) -> token|nil,reason?`
- `service:Advance(explicitElapsed) / Cancel(token?,reason?) / Invalidate(reason?) -> bool,reason?`
- `GetReceipt(token)` / `GetActionState()` / `GetObservationState()`：独立副本。
- `GetWorldContentPrompt() -> prompt|nil,reason?`；一个动态begin/cancel入口。
- `GetOwnedTreasures() -> memory ID数组|nil,reason?`。

【留给 Integration 的接口】
- adapter: `GetContext() -> {player,sessionGeneration,runtimeIdentity,fixedContentGeneration}`；生命周期变更前Invalidate，成功LoadSaved/NewRun后更新sessionGeneration。
- Ocean: 两岛稳定contentId，固定宝藏实体及位置，独立固定内容代际。
- Ocean: `GetWorldContentAccess(contentId) -> {contentId,entityId,generation,surfaceGap}`；复用Ocean空间规则计算岸边距离。
- Ocean: `IsWorldContentInScope(contentId) -> bool|nil,reason`；公开既有scope扇区谓词，不用isVisible做授权。
- 调度: 唯一Gameplay帧链传显式elapsed，动作期间继续世界/昼夜，统一Pause传0；不放入Ocean子步。
- 保存: Snapshot/Restore边界调用WorldContent Validate，新建/载入成功后Initialize。
- A UI: 动态情境按钮、宝物列表及老人展示，补齐Items adapter protected/canGive适配；不把memory当普通库存。
- B: 开始动作前由Integration通过B公开API结束自动导航。

【测试】

| suite | 通过项 |
|---|---:|
| WorldContentTests（定向） | 60 |
| PersistenceRegressionSpec | 84 |
| Circle1B2ScopeTests | 5 |
| Circle1B3SpatialTests | 6 |
| Circle1B2Barrel/Progress/Throw/UI double | 32 |
| Circle1BFishingFlow / PendingCatch | 33 |
| Circle1B3SevenDays | 2 |
| 合计 | 222 |

11 suites，0失败、0跳过。主代理最终独立执行runner并审查新增断言；修正测试遍历顺序依赖，并对测试名加唯一性检查，completed-only/reward-only半写失败分别覆盖。

新增两个Gameplay模块LSP：0 Error / 0 Warning。已有全量扫描脚本覆盖36个文件；全量仍23 Error/128 Warning，均位于未修改的既有文件，涉及引擎声明缺失等，不能宣称全项目LSP通过。诊断脚本未包含测试文件，测试Lua由Lua5.4实际加载执行验证。

复跑命令及预期输出见交接文档。完整JSON含每个module suite的用例结果；原Persistence脚本只输出84项完成标记，保留该标记和计数，不虚构逐项明细。

【事务安全】
- Cancel: Begin不收费，部分计时取消也不收费；宝藏marked保留。
- Exactly-once: 重新检查完成/ownership，再一次提交40体力+完成+对应奖励。两个service竞争同一目标，只允许第一个收费完成。
- Rollback: 覆盖扣费返回false/throw/扣费后失败，进度返回false/throw/半写/假成功；恢复提交前状态，动作期间其它体力消耗保留。
- Repeated call: 重复完成/Advance不重复收费；返回快照不能篡改receipt；提交期间重入Begin/Advance/Cancel返回busy。
- Load/NewRun/Reset: 测试真实Persistence恢复和Player.Reset配合fake adapter身份变化；包括同generation换Runtime、World代际变化、GetReceipt/GetActionState提前识别、提交中Reset保持新玩家体力。

【明确未实现】
- HUD: 未改；最终动态“探索岛屿”/“打捞宝藏”/取消入口待Integration。
- 最终空间接线: 未改真实SeaRuntime、Ocean World/Config或Movement；宝藏坐标、实体、scope公开查询待Integration。
- 碎片正文: 未编写。
- 老人对白/实际展示: 未编写/未接线。
- Circle2: 未实现。
- 自动返航: 未实现/未修改B逻辑。

【发现的问题】
- Worktree无 `.maker-mcp/config.json`，本地preview status按项目规则检查后返回FAIL；未启动GUI或复制宿主配置。UI/真实空间及世界时钟联动验收尚无证据。
- 既有Persistence只调用Circle1B2 Validate，新worldContent invariants须由Integration补接；已有普通map保存能力不是自动验证证明。
- 当前岛缺稳定contentId、scope资格谓词未公开；缺口已列接口需求。
- Items adapter protected/canGive链路仍待A补齐，未用普通ItemDefinition替代宝物ownership。
- 修正Progress把worldContent=false吞成缺省值的漏洞；现在Initialize安全拒绝，不修复/覆盖畸形存档。

【偏差】
与最新裁决无产品偏差。按授权使用fake adapter完成C core；最终Ocean/HUD/Persistence生命周期接线是明示的Integration工作。已核对基线船速9/12/16、地图2880m、固定木桶blocking=true，未修改。

【Git动作】
Commit: 无。
Push: 无。
Merge: 无。
远端构建: 无。
