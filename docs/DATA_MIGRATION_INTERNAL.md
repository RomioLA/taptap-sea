# 物品与鱼类数据迁移内部工程报告

2026-10-02，Asia/Hong_Kong。内部程序接入报告；不复制到 push 审查目录。

## 实际完成与目录隔离

最终完整版仍为 `C:\codex\taptap-sea`，HEAD 保持 `799415a`，所有 A/B 既有提交和未提交成果保留。本阶段仅对四个原有数据入口进行授权接入；没有更换入口、架构、玩法、引擎或项目设置。

完整目录新增根 `data/items.lua`、`data/fish.lua`，从真实远端定稿表逐字复用。源文件分别48/52行，数值、注释、字段和顺序未改。`docs/DATA_SCHEMA.md` 161行从远端原字节复用，未修改契约。

独立目录 `C:\codex\taptap-sea-push` 最终 HEAD 为当前已核实远端 main `29f84acd9bba8ebee3901fa5c25b3b5a39432e74`。工作期间远端仅新增两份规划文档更新，检查无重叠后仅在独立目录 fetch/快进到该既有提交。完整版未fetch/pull/merge/rebase/reset，也没有复制远端程序架构覆盖本地成果。

对外唯一差异为新增 `docs/DATA_MIGRATION_REVIEW.md`，没有数据差异。完整版的任何程序、生成模块、测试和本内部报告都没有复制过去。没有暂存、commit、push或远端构建。

## 数据加载与 Maker 分发的最小实现

Maker 0.0.36 的健康校验代码要求 build.asset_dirs 只能包含 assets/scripts；官方本地 prepare 也明确拒绝其他目录。虽然一般引擎 schema 支持资源根列表，在当前 Maker 工作流中直接加 `../data` 会失败。因此本阶段没有修改 `.project/settings.json` 或 resources 配置。

根 data 是唯一可编辑来源，`tests/sync_runtime_data.py` 只复制两张已批准的表，并生成带“不可手工编辑”和源SHA-256头部的 `scripts/GeneratedData/Items.lua`、`Fish.lua`。没有改数据结构或数值。生成目录只是 Maker 资源输入副本，不是第二份人工维护参数表。

原 require 入口保留：`Ocean.Config`、`Ocean.FishData`、`config.gameplay`、`data.items`。这些入口静态 require 生成模块，保持现有返回字段和查询接口。

| 程序文件 | 本阶段实际行变化（最终文件行号） | 原因 |
|---|---|---|
| `scripts/Ocean/Config.lua` | 3～9、42；最终76行 | 从鱼表读共享活动/冻结半径；两种鱼范围不一致时明确拒绝，避免静默选错；船速、地图等派生计算不改 |
| `scripts/Ocean/FishData.lua` | 2～39；最终39行 | 将定稿鱼字段映射回旧字段；视觉/关系/密度/换向与颜色引用留代码侧 |
| `scripts/config/gameplay.lua` | 3～9、35；最终59行 | 每日商店库存从物品表生成，其他未定稿参数保留 |
| `scripts/data/items.lua` | 3、22～39；最终71行 | 定稿物品字段映射为旧定义；GetDefinition函数与独立副本行为保留，仅因前文缩短移动到44～69行 |

| 新文件 | 新增行 | 原因 |
|---|---|---|
| `data/items.lua` | 1～48 | 复用4物品定稿纯数据源，与远端字节一致 |
| `data/fish.lua` | 1～52 | 复用2鱼定稿纯数据源，与远端字节一致 |
| `scripts/GeneratedData/Items.lua` | 1～51 | 3行生成头加原表，进入Maker脚本资源根 |
| `scripts/GeneratedData/Fish.lua` | 1～55 | 同上，唯一来源为根data鱼表 |
| `tests/sync_runtime_data.py` | 1～56 | 两表确定性同步、只读检查与拒绝覆盖非生成文件 |
| `tests/run_data_migration.py` | 1～119 | 兼容、源表实际加载、陈旧副本、隔离变化和原回归验证 |
| `docs/DATA_SCHEMA.md` | 1～161 | 定稿依据，仅复制不改 |
| `docs/DATA_MIGRATION_REVIEW.md` | 1～63 | 对外逐文件差异清单，与push报告相同字节 |
| `docs/DATA_MIGRATION_INTERNAL.md` | 1～89 | 内部接入、验证与操作说明 |

删除文件：无。历史测试源码、截图证据、Main/HUD/Bootstrap、配置和依赖均未改。本地临时证据在 `.tmp/data-migration-preparation/`，不进入审查交付。

## 保留的映射和语义

物品 `buy/sell/heal/worldEffect/worldDuration` 映射到 `buyPrice/sellPrice/heal/worldEffect/lifetimeSec`；无sell/heal时旧接口仍输出0，源数据仍省略字段。shopStockPerDay生成原dailyStock。canEat由已有heal字段是否存在决定，四种物品的canGive规则继续留代码中，未擅自添加权限字段或UI行为。

鱼的speeds映射到原wander/attracted/flee/chaseSpeed，turnRate到turnDegPerSec，sense/avoid/predation/spawn映射到旧字段；ai映射世界共享120/150。两表同ID、原itemDropped值原样保留，接入检查与现有捕获species->物品ID路径一致。没有修改契约中不同文字说明；不因它们的书面差异阻止现有值的兼容接入。

原返回字段和数值全集与迁移前快照一致；鱼color仍与Config.fish保持同一张table，查询仍返回新副本；未知物品仍nil；默认航速6、max10、地图1800/半长900保持。未定义的新鱼视觉/关系或不同投放ID需要另开程序/契约任务；本阶段不扩充物种或物品。

缺少规范的 initial/stamina/clock/inventory/upgrades/debug/persistence、船、世界、镜头、捕鱼、交互与视觉参数继续留原配置。密度20/4、换向2～4秒、关系与视觉字段仍遵守既有契约的代码侧边界。事件占位不复制进完整版、不扩充玩法。

## 实际验证

- `tests/run_data_migration.py`：15项接入/兼容检查通过，47个Lua文件语法通过。
- 海洋53项、稳定性3组、场景适配8项、A/B集成29项全部通过。
- 原GameLoop20、UI mock6、Persistence84、NumericEconomy21、ShopStock15全部通过。复用原测试，证据写独立.tmp，没有覆盖历史screenshots。Mock没有被当作真机验证。
- 实际EmmyLua：45个scripts文件均收到诊断，Error=0、缺失诊断=0。动态物种表标注table<string,table>，没有关闭或降级诊断、没有修改消费者来掩盖错误。
- 源表隔离编辑测试：修改fixture中的价格、库存、鱼速、活动范围后，生成模块真实加载到旧接口；源改副本未同步时--check拒绝；重复生成无改动。没有改生产源数值或伪造来源。
- 官方 `preview prepare --target-dir C:\codex\taptap-sea --json` 成功，最终manifest包含GeneratedData/Items.lua与Fish.lua，均有default和#blocking组；四入口加两生成模块与最终源码逐字一致。
- 最终官方本地准备的49个项目资源不等于49项玩法验收。manifest证明分发引用，Lua测试证明接口加载；没有启动停止的Runtime，没有真机/远端加载验收。
- `preview status`始终stopped/process_alive=false，未refresh或start。历史状态中的DDS/DLL环境错误未处理或绕过。

证据：`migration-validation.json`、`migration-lsp.json`、`manifest-verification.json`、`final-isolation-verification.json`（均在上述.tmp目录）。

## 数据编辑后的必要同步步骤

本阶段已同步，用户现在不需要手工搬数据。今后批准的根data编辑完成后，程序任务执行：

```powershell
python tests/sync_runtime_data.py
python tests/sync_runtime_data.py --check
python tests/run_data_migration.py
```

当前实际验证使用的Python为 `C:\Users\80739\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`，复用项目已有Lupa cp312。同步脚本自身只需要Python标准库。

同步后按Maker政策检查preview status，活着才refresh并取证，停止时不重启。正式构建/提交前必须做--check；Maker CLI目前没有本项目的自动同步钩子，本阶段不修改CLI或用户配置。因此直接修改根data后跳过同步，会让包继续消费旧生成副本；不能承诺任意后续编辑自动生效。

数据助手只改data/docs；复制/生成程序资源由获授权程序任务执行，不将这条同步步骤扩展为数据助手拥有scripts修改权。生成器固定只处理两表，不会把占位events或缺规范参数加入运行时。

## 后续提交范围与剩余限制

负责人数据交付白名单只有 `docs/DATA_MIGRATION_REVIEW.md`。已有root data无需再提交重复字节；内部程序接线只能另行审查，不能把完整项目现有历史改动混入。

真正提交仍从 `C:\codex\taptap-sea-push` 按Maker状态/next_action与maker_build_current_directory执行。该流程会提交、push并构建；本次没有实际调用，也没有普通Git push。

本阶段完成的是已有物品/鱼类的本地接入与隔离准备。其他未定稿表、事件扩展、原生窗口与远端/真机验收不在本阶段已完成范围。itemDropped文档遗漏、跨表ID说明与将来逐物种活动范围仍由负责人维护，不擅自更改定稿字段或生成新格式。
