# 任务 A：海洋捕获锁定接口与捕食冷却

你在本电脑 A 执行本任务。先阅读本目录 `共同接口与边界.md`，再阅读项目 `AGENTS.md`。本轮工作量较小，只做下面两项，任务 B 同时在另一电脑开发。

## 目标

1. 提供鱼的捕获锁定与解除接口，供 B 在网落水时调用。锁定后的鱼不更新普通 AI、不移动、不被其他鱼捕食、不被第二次选择；对应功能海鸟立即消失。解除锁定后恢复原有行为，保持同一个鱼实体，不另生一条鱼。
2. 每条大鱼成功吃掉小鱼后进入 5 秒捕食冷却，作为已确认的圈1测试值。冷却中不能追猎或再吃下一条鱼，可以游荡、避障及受匹配诱饵吸引。冷却以既有海洋世界时间判断，暂停时停止；冻结和捕获锁定不执行 AI，不能把单鱼停止 AI 当作全世界停止计时。不增加昼夜时钟或独立饱食状态。

## 文件所有权

可修改的既有代码：

- `scripts/Ocean/Fish.lua`
- `scripts/Ocean/SeaRuntime.lua`
- `scripts/Ocean/World.lua`
- `scripts/Ocean/Config.lua`
- `scripts/Ocean/SurfaceSignals.lua`
- `scripts/Systems/EntityStateSystem.lua`

可修改的既有测试：`scripts/tests/SeaRuntimeTests.lua`、`SurfaceRiseTests.lua`、`SurfaceSignalsTests.lua`、`SeaStabilityTests.lua`。这些是完整路径的同目录文件，Windows 下大小写路径指向同一文件。

可新增：`scripts/tests/Circle1AFishLocksTests.lua`、`Circle1APredationCooldownTests.lua`、`tests/run_circle1_a.py`。新增辅助海洋代码必须使用 `scripts/Ocean/Circle1A*.lua` 命名，并在交付清单说明。

本任务专用输出：`outputs/circle1-a/`，验证报告、离线证据及交付说明放这里。不要改 B 的 `scripts/Gameplay/`、`scripts/Integration/`、`scripts/Game/Game.lua`、`scripts/config/gameplay.lua`，也不要改双方共用任务书、数据表、策划、公共文档和其他测试入口。

## 实现边界

- 严格实现共同接口文档的 `LockFishingTarget`、`UnlockFishingTarget`，并兼容既有公开方法；B 不直接写入鱼字段。
- `selectFishingTarget` 继续按合法网心、30 米抛网距离、8 米网半径选最近 0/1 条鱼，排除已锁定鱼。保留既有隐藏/冻结鱼的捕鱼资格及稳定等距选择；不新增鱼种偏好、陆地视线阻挡。
- 锁定属于短暂运行状态，不把活跃标记永久改成冻结，也不新造 `Captured` 世界实体。用现有实体 ID、世代与 owner token 防止重复捕获、陈旧解除及错误所有权。
- 直接调用 Fish.Update 与 EntityStateSystem 调度都必须遵守锁定门控；追猎目标和替换目标也排除锁定鱼。
- 锁定时暂停上浮进度，解除后继续原进度；不改上浮 2 秒测试值。海鸟仍不吃鱼，不改现有俯冲与水花参数。
- 普通取消通过解除锁定恢复鱼；移除、清鱼、换日、Runtime 重置清理相关锁。快照和恢复接口覆盖锁状态，以支持 B 的提交失败回滚。
- 冷却从真正成功移除猎物开始，只触发一次；捕食失败不启动冷却；不改变游速、转向、感知、价格或密度目标。
- 不实现自然补鱼、船惊鱼、诱饵聚集、新生鱼距大鱼限制或透镜取得路线。这些不属于本次任务。

## 验证与交付

先完整阅读 Lua scripting guide，按 AGENTS 要求阅读至少 3 个相关示例。使用已安装的 Lua 5.4 测试依赖，不因系统 PATH 无 Python 而放弃验证；运行时位置按本机实际配置发现，不硬编码另一电脑的用户名。

新增测试至少覆盖：最近单鱼选择与空网；同 token 重复加锁、不同 token 冲突；锁定鱼不更新 AI/上浮、不被吃、不被重复选；海鸟即时撤销；取消恢复同一实体；旧世代不影响新鱼；移除失败后快照恢复；重置/换日无残留；真正吃鱼触发 5 秒冷却、冷却中可吸引/避障、期满恢复追猎；暂停停止世界计时，冻结/锁定禁止 AI，恢复后按实际世界时间检查剩余冷却。

运行海洋行为、上浮/信号和持续航行回归，做 Lua 语法及 EmmyLua 类型检查。不得通过删除断言或降低诊断级别绕过规则。B 所有的旧集成测试若因新版规则出现旧预期，只记录，不修改它们。

涉及代码编辑后按项目政策检查 preview status，活着才刷新并取证；已停止的预览不自动启动。交付 `outputs/circle1-a/交付说明.md`，列出改动文件、接口、通过/失败/未验证项，以及实际预览状态；不把 B 捕鱼 UI 或双方真实联调写成已完成。不执行提交、推送或远端构建。

如必须改所有权清单外的文件或共同接口，先用中文说明具体必要性，等待重新分配；不要自行跨界修改。
