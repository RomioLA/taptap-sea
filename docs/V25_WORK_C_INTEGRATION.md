# V2.5 C 世界探索交接契约

范围：R8 两岛探索、R9 单个固定宝藏、D5 三枚记忆 ownership。C 提供独立 Gameplay core 与 fake adapter 测试。最终场景接线由 Integration 完成。

## 数据与状态所有权

- `player.story.worldContent.island_01/02 = { completed = boolean }`。
- `player.story.worldContent.underwater_treasure_01 = { marked = boolean, completed = boolean }`。
- `player.treasures.memory_island_01`、`memory_island_02`、`memory_treasure_01` 为直接 boolean 字段。
- 每项 `completed == 对应 ownership`；宝藏 completed 还要求 marked。畸形/不一致存档拒绝，不自动补发或重新收费。
- 三枚记忆不进入 Inventory。空间、实体和扇区规则归 Ocean；receipt、临时观察和动作计时归 Gameplay，不写存档。
- duration=4s、cost=40 stamina、observation=1s 是代码中注明的 PLAYTEST VALUE。

## Progress API

模块 `Gameplay.WorldContentProgress`，以下函数均以 `player` 为第一参数。

| 函数 | 参数 | 返回 |
|---|---|---|
| `Initialize` | player | bool, reason?；兼容无 worldContent 的旧快照，补缺失记录/false ownership |
| `Validate` | player / 保存快照 | bool, reason?；纯校验，含现有 Circle1B2 校验 |
| `GetState` | player, contentId | 独立状态副本或 nil, reason |
| `Mark` | player, contentId | bool, reason?；仅宝藏可 marked，幂等 |
| `Snapshot` | player, contentId | 单目标快照或 nil, reason |
| `Restore` | player, contentId, snapshot | bool, reason?；恢复有效快照，当前状态须通过 Validate |
| `Commit` | player, contentId | bool, committed/already_completed/reason；只写进度与 ownership |

`Commit` 是内部进度能力，不是收费事务入口。玩家操作必须由 Actions 的独立 receipt 包裹；Integration 不直接调用它奖励玩家。半写入异常的回滚由 Actions 用提交前捕获的字段/容器执行，不依赖此时可能失败的 Validate。

主要失败原因：`invalid_player_state`、`invalid_world_content_progress`、`invalid_content_id`、`invalid_content_progress`、`invalid_content_progress_field`、`invalid_content_completed`、`invalid_content_marked`、`invalid_memory_ownership`、`completed_content_not_marked`、`content_reward_completion_mismatch`、`content_not_markable`、`content_not_marked`、`invalid_progress_snapshot`；另可传播 Circle1B2 校验原因。

## Actions API

`local service, reason = require("Gameplay.WorldContentActions").New(adapter)`。

| 方法 | 参数 | 返回/含义 |
|---|---|---|
| `BeginExplore` | island_01 / island_02 | token 或 nil, reason；不提前扣费 |
| `BeginSalvage` | underwater_treasure_01 | token 或 nil, reason；须 marked |
| `Advance` | explicitElapsed，有限非负秒 | bool, reason；唯一时间输入，同时推进观察和当前动作 |
| `Cancel` | token?，reason? | bool, reason；缺 token 用当前动作，重复取消幂等 |
| `Invalidate` | reason? | bool, reason?；生命周期变更前废弃旧动作、清观察计时 |
| `GetReceipt` | token | receipt 副本或 nil, reason |
| `GetActionState` | 无 | 当前 receipt 副本或 nil |
| `GetObservationState` | 无 | `{contentId, elapsed, duration}` 副本 |
| `GetWorldContentPrompt` | 无 | 一个动态 context prompt 或 nil, reason |
| `GetOwnedTreasures` | 无 | 三个 memory reward ID 中已拥有者的有序数组，或 nil, reason |

receipt 绑定唯一 token、contentId、actionKind、entityId、fixedContentGeneration、sessionGeneration、局部 epoch 及 begin 快照；服务内部还绑定 runtime 身份和玩家/进度容器身份。公开副本不可改写内部事务。

状态：`active -> completed/cancelled/failed`；提交状态：`pending -> committing -> committed/rolled_back`。`result`、`cancelReason`、`failureReason`、`rollback` 留存可查询。重复 Advance 不会重放终态。不存在独立、可绕过 4 秒的公开 Complete。

提交重新检查体力、进度、实时 gap、实体与世界身份。成功必须同时满足 stamina -40、completed=true、ownership=true。异常/false 返回恢复提交前的体力与该内容进度/ownership，保留动作开始后其它正常体力变化。若 Player.Reset/Load 已替换容器，仅恢复旧容器，不覆盖新玩家体力。事务同步执行，不 yield；adapter 查询必须纯读且不驱动重入更新。

常见原因：`already_completed`、`content_reward_completion_mismatch`（已有孤立 reward 或 completed，0 收费）、`insufficient_stamina`、`content_not_marked`、`out_of_range`、`content_unavailable`、`content_identity_mismatch`、`stale_generation`、`action_active`、`action_finalized`、`unknown_token`、`busy`、`invalid_elapsed`、`invalid_context`、`invalid_surface_gap`、`adapter_error`、`commit_exception`、`commit_consistency_failed`。适配器的查询失败和玩家扣费返回可传播具体原因。

## Integration 必须提供的 adapter

三项均为同步、无副作用查询，不缓存旧 Runtime/World。

```lua
adapter:GetContext()
-- -> {
--   player = 当前 PlayerState,
--   sessionGeneration = Gameplay 生命周期身份（整数或非空字符串）,
--   runtimeIdentity = 当前 runtime 对象或唯一身份,
--   fixedContentGeneration = 独立固定内容世界代际（整数或非空字符串）,
-- }

adapter:GetWorldContentAccess(contentId)
-- -> {contentId, entityId, generation, surfaceGap} 或 nil, reason
-- generation 必须等于当前 fixedContentGeneration。
-- surfaceGap 是 Ocean 算出的船与目标表面距离，单位米，<=5 合法；不要返回岛中心距离。

adapter:IsWorldContentInScope(contentId)
-- -> true/false 或 nil, reason
-- 使用当前船位/朝向/真实scope开关，复用约20m、总角90度的既有扇区谓词。
```

生命周期接线：LoadSaved/NewRun 前 `Invalidate("stale_generation")`；成功替换状态后更新 sessionGeneration。World Reset 后 fixedContentGeneration 必须变化；Runtime replacement 即使数字 generation 相同，runtimeIdentity 也必须变化。自动容器/身份检查是额外防护，不代替接线义务。日更鱼群只改变 fishingGeneration 不应使固定内容动作失效。禁止以 fishingGeneration 填 fixedContentGeneration。

时间接线：最终唯一 Gameplay 帧调度层按已确认产品规则调用 `Advance(explicitElapsed)`。4 秒期间世界和昼夜继续推进；统一 Pause 时传 0，动作与观察累计冻结。core 不选择 real/raw/gameplay/ocean dt。不要从 Ocean 子步或第二条 update 链重复调用。

保存接线：保留现有 Save Schema；在 Snapshot 入口与 Restore 验证边界调用 `WorldContentProgress.Validate`，新建/成功载入玩家后调用 `Initialize`。当前 C 未改共享 Persistence/PlayerState/Loop，现有通用 map 序列化可往返字段，但不会自动验证这些新 invariants。测试必须显式调用校验，不将这项 Integration 缺口宣称已接好。

## Ocean 需要补的窄接口（C 未实现）

- 两岛增加稳定 contentId，固定 `underwater_treasure_01` 合法水域实体从 NewRun 即存在；最终位置由 Integration 调试确定。
- 独立 `GetFixedContentGeneration()`（或等价命名）：新 World 改变；鱼群刷新不改变。已有 fixedBarrelGeneration 可作为实现参考。
- `GetWorldContentAccess(contentId)`：核对实体身份并返回上述快照及实时 surfaceGap。Ocean 统一计算岛岸/船半径距离，不把几何公式复制进 Gameplay。
- `IsWorldContentInScope(contentId)`：公开既有 scope 几何谓词；不能以包含 debug/reveal 的 isVisible 代替资格查询。
- 查询缺目标、世界未就绪、generation/identity不符、scope关闭时应失败关闭；不在 Ocean 保存 marked/completed。

## UI / B / A 接线

动态 prompt 文案为“探索岛屿”/“打捞宝藏”，活动时为“取消探索”/“取消打捞”。无合法目标返回 nil；多个合法目标使用 island_01、island_02、treasure 的稳定优先顺序。按钮将 prompt 的 contentId/actionKind 交给 Begin，取消使用 token；每次 Begin 重新校验。

A/Integration 用 `GetOwnedTreasures` 接宝物展示与老人“展示”入口，展示不消耗 ownership。当前 Items adapter 的 protected/canGive 链路缺口仍需 A 补齐；不要把三枚记忆转成普通库存定义，也不要通过 Inventory 的出售/丢弃路径处理宝物。碎片正文/老人对白不在 C 范围。

开始动作前，Integration 通过 B 的公开 API 结束自动导航；C core 不持有或修改导航状态。HUD、真实 SeaRuntime、Movement、自动返航与最终空间接线均留待各自所有者。

## 验收清单

- [x] R8：两岛各首次成功、对应碎片、重复拒绝、adapter提供的5m边界。
- [x] R9：连续scope1s、离开清零、marked持久、未marked拒绝、salvage完成/取消。
- [x] D5：三个直接 ownership key、Inventory不变、跨日保存、新周目重置。
- [x] 事务：begin零扣费、体力不足拒绝、完成一次扣40、cancel零收费、已有reward/completed拒绝。
- [x] 故障：扣费/进度阶段false与异常、半写回滚、提交前快照、重复/重入、返回快照不可篡改。
- [x] stale：Load/NewRun/World Reset/runtime replacement、同名实体/相同generation复用、鱼日刷新独立。
- [x] 兼容：Persistence、Circle1B2 scope/barrel、Spatial、fishing、seven-day。
- [ ] Integration 手工/UI 验证：动态按钮、世界/昼夜推进、统一Pause、老人展示及最终空间。

前七项为 core/fake 测试范围；最后一项须在 Integration 接线后验收。运行基线保持船速9/12/16、地图2880m、固定木桶 blocking=true。

2026-10-16 最终证据：`outputs/world-content/results.json`，11 suites、222项，0失败/跳过；其中WorldContent 60项。两个新增Gameplay模块LSP均0 Error/Warning；完整扫描旧文件仍有23 Error，详见 `outputs/circle1-b2/lsp-result.json`。本Worktree缺 `.maker-mcp/config.json`，preview status返回FAIL，未启动GUI。

复跑（PowerShell，当前本机已安装的Python3.12与Lupa，不安装/复制依赖）：

```powershell
& 'C:/Users/Administrator.DESKTOP-NS4I6RF/AppData/Roaming/uv/python/cpython-3.12.10-windows-x86_64-none/python.exe' 'C:/codex/taptap-sea-worktrees/WORK-C-EXPLORATION/tests/run_world_content.py' --lupa-root 'C:/codex/taptap-sea/.tmp/game-loop-test-runtime'
```

预期控制台 `passed=true`、`testCount=222`、`skippedCount=0`；完整结果默认写入C Worktree的 `outputs/world-content/results.json`。其他机器使用匹配Python版本的已安装 `lupa.lua54`，并以 `--lupa-root` 指定包目录。
