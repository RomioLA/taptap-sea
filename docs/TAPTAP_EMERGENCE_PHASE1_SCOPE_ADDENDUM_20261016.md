# TAPTAP Emergence Phase 1 范围补充（2026-10-16）

本文件记录用户在 2026-10-16 对 `TAPTAP-EMERGENCE-CONFIRMED-SCOPE-FREEZE-20261016` 中通勤鸟群位置与有效观察条件的最新明确裁决。仅补充下列规则；冻结文档其他范围和禁止项继续有效。

## `flock_commute` 到 `island_02` 的方向提示

- `sourceContentId = "island_02"`，鸟群数量为 3。
- 每次出现时，提示方向重新计算为玩家当前位置指向 `island_02` 中心。
- 鸟群只在玩家尚未进入 `island_02` 的正式识别范围时提供方向提示；正式识别后不再新增此假设的证据。
- 表现位置可由玩家当前视野边缘与上述方向派生；不配置固定鸟类航线或新增世界地点，也不改变岛屿位置。
- 鸟群整体朝 `island_02` 飞过，不俯冲、不围绕鱼群盘旋。
- Evidence 记录当次岛屿相对于玩家的 bearing，不使用鸟群表现位置计算 bearing。
- 线索不得生成、移动或自动识别岛屿，也不得传送玩家或发放额外奖励。

`H-isle-bearing-01` 仍遵循冻结文档的 3 个不同游戏日、bearing spread ≤30°、同日去重和只通过 `KnowledgeSystem:Grant("K-isl-1")` 的规则。
