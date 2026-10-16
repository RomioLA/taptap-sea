# 本地骨架接入与分批交付记录

日期：2026-10-02。仅供本地完整版交接，不同步至提交目录。

## 本轮结果

保留现有玩法和数据值，接入已确认的 Game、Entities、FSM、Systems 轻量骨架。Ocean 的实体集合复用 Game.World；鱼行为通过共享 FSM/System 调度，保留原有子步长。Integration.Bridge 将原更新顺序委托 Game，并在捕鱼失败回滚时恢复 alive 状态。

本轮未改变 Main、Config、玩法参数、数据表、UI 或已有玩法规则。旧演示文件保留。策划 Sheet1 为 V1 基线，Sheet5、Sheet6 未定内容不据此实现。本次完成的是骨架接入，不是完整玩法内容验收。

## 本地改动文件清单

| 文件 | 改动位置 | 原因 |
|---|---|---|
| AGENTS.md | 末尾项目级约定整节 | 固定目录职责、数据边界与分批交付范围 |
| docs/ARCHITECTURE_LAYOUT.md | 新增全文，第1～49行 | 给队友审查目录与职责约定 |
| scripts/Game/Game.lua | 新增全文 | 协调原 Gameplay/Runtime 更新，不复制玩家状态和时钟 |
| scripts/Game/World.lua | 新增全文 | 单一 Entity 注册、索引与 System 调度 |
| scripts/Entities/EntityFactory.lua | 新增全文 | 创建轻量对象，保持海洋 ID 前缀与对象身份 |
| scripts/FSM/StateMachine.lua | 新增全文 | 统一状态切换与 enter/update/exit |
| scripts/Systems/EntityStateSystem.lua | 新增全文 | 只自动更新存活、活跃、未冻结对象 |
| scripts/Ocean/World.lua | 第4～77行 | 类型声明与共享注册表接入；保留旧方法兼容 |
| scripts/Ocean/Fish.lua | 第5、25、32～43、119～120、446行附近 | 将原鱼行为挂到共享 FSM，保留原行为算法 |
| scripts/Ocean/SeaRuntime.lua | 第9、21、177行附近 | 注册 System，并替换原逐鱼自动更新入口 |
| scripts/Ocean/Movement.lua | 第12行 | 补充船实体 ID 类型声明，无运行逻辑变化 |
| scripts/Integration/Bridge.lua | 第7、155、189～206、295、307行附近 | 委托 Game 更新，回滚恢复 alive |
| scripts/tests/ArchitectureIntegrationTests.lua | 新增全文 | 验证共享对象、唯一更新、暂停冻结、Reset 和 FSM |
| tests/run_architecture_integration.py | 新增全文 | 运行上述集成检查，证据输出至 .tmp |
| docs/ARCHITECTURE_INTEGRATION_INTERNAL.md | 新增全文 | 本地实施、证据与交付边界记录 |

行号以本轮最终文件为准；“附近”包括所在函数中的替换位置。原有工作区改动保留，不能将整个 git diff 视为本轮修改。

## 实际验证

- 原有数据/接口兼容检查15项通过；9套海洋、A/B、玩法、存档、经济、商店测试通过。见 .tmp/data-migration-preparation/migration-validation.json。
- 新增骨架集成检查7项通过。见 .tmp/architecture-integration/validation.json。
- Lua 语言服务器0 Error。见 .tmp/data-migration-preparation/migration-lsp.json。
- Maker 本地 preview prepare 成功；五个骨架模块进入资源清单，准备目录脚本与本地逐字节一致。见 .tmp/architecture-integration/source-audit.json。仅离线准备，没有启动游戏或触发远端构建。
- 预览状态 stopped、process_alive=false，未重启。原有 DDS/DLL 环境错误保留；真实画面、操作、云功能和远端版本未验证。
- 对原有源码指纹核对，本轮只修改 AGENTS、Bridge、Fish、Movement（注释）、SeaRuntime、Ocean.World，其余原有源码保持本轮开始时的内容。

## 提交目录边界

C:\codex\taptap-sea-push 这轮仅更新 AGENTS.md 的项目约定（第1120～1138行）并新增 docs/ARCHITECTURE_LAYOUT.md（第1～49行）。全目录文件指纹验证只有这两个文件变化；原有 docs/DATA_MIGRATION_REVIEW.md 未变且不列入本轮交付。

共享交付白名单：AGENTS.md、docs/ARCHITECTURE_LAYOUT.md。禁止一键提交整个目录。程序、测试、内部报告未复制到该目录；未暂存、提交、push、远端 build。后续程序交付必须单独确认范围，并遵循 Maker 提交流程。

同步前 AGENTS 备份与文件指纹见 .tmp/architecture-integration/push-AGENTS-before.md、push-docs-sync.json。两边仓库原有内容与历史提交均未回滚。
