# B 数值与经济更新

第二次补充已增加每日商店库存；最新BALANCE_TARGET与A世界参数以 `GAME_LOOP_V1_B_SUPPLEMENT_02.md` 为准，以下保留第一次补充的实现与测试背景。

B_NUMERIC_UPDATE = PASS（B模块范围，2026-10-02）。

正式目录 `C:\codex\taptap-sea`；渔夫漂流记；本地 m_009f；Maker App 6fb01c73-66b3-4356-b987-3669be7f8a44。

本轮仅更新 B 配置、规则、接口、HUD与测试。没有改 A、共享入口、Bootstrap、项目配置或依赖；没有 push、远端构建或 GUI 操作。

## 唯一运行时来源

`scripts/config/gameplay.lua`：

| 配置 | 最终值 |
|---|---|
| initial | maxStamina100、stamina100、money100、day1；apple与bait各1 |
| stamina | fishing40、salvage40、eventOperation40、sailing0 |
| clock | 白天120s、夜晚60s、宽限30s、每秒罚1、强制比例0.5 |
| inventory | 5→10→15→20，不堆叠 |
| drop | lifetimeSec20 |
| location | recognitionDistance20，世界侧负责检测 |
| debug | 倍率1/5/20、体力步长20、金钱步长100 |
| persistence | key sea_game_loop_v1、schemaVersion1 |
| upgrades.stamina | maxima100/160/200；prices400/600 |
| upgrades.inventory | prices300/600/900；容量只引用inventory.capacities |
| upgrades.boatSpeed | metersPerSec6/8/10；prices350/750；B不应用movement |

以上新增确认值属于 V1_IMPLEMENTATION_VALUE。体力/船舱/航速升级成本分别1000/1800/1100，合计3900；合计只用于测试，不增加额外购买规则。

`scripts/data/items.lua`：商店、Inventory、HUD及投放都读取此表，无第二份物品价格。

| id | category | buy | sell | heal | worldEffect | lifetimeSec |
|---|---|---:|---:|---:|---|---:|
| apple | food | 30 | 0 | 20 | ATTRACT_SMALL_FISH | 20 |
| bait | bait | 20 | 0 | 0 | ATTRACT_SMALL_FISH | 20 |
| sardine | fish | 无 | 70 | 10 | ATTRACT_BIG_FISH | 20 |
| tuna | fish | 无 | 120 | 20 | NONE | 20 |

物品均可赠送；苹果给老人不恢复体力。treasure/misc仅保留分类框架。生命周期从gameplay.drop读取。

## 接口契约

- PlayerState体力接口：CanConsumeStamina/ConsumeStamina/RestoreStamina；上限约束不变。
- 港口购买：Loop:UpgradeStamina/UpgradeInventory/UpgradeBoatSpeed。忙碌、海上、余额不足或满级时拒绝且不扣钱。购买不新增自动存档点。
- 体力升级按上限差值同时增加当前体力，保留升级前缺口；GetStaminaLevel由maxStamina推导，不建立第二份等级状态。
- boatSpeedLevel初始1，通过每日快照保存并暴露给A；A用gameplay.upgrades.boatSpeed.metersPerSec[level]应用真实船速。快照只保存等级，不保存速度或坐标。
- schema v1增量兼容：旧快照没有boatSpeedLevel时恢复为1；已存在但类型/范围非法时安全拒绝。原库存校验及失败恰好一次契约保留。新周目全部升级重置，未添加任何跨周目知识或物品继承。
- 完整捕鱼：开始时CanStartAction("fishing")；动作确实成立且完成后CompleteFishing(catchCount)，catchCount只能是0或1。0空网也扣40；取消/未成立不调用。成功捕获物品由A另调用Inventory:Add，B不决定鱼种。每个完成动作由A通知一次，不把失败物品入包当作免费捕鱼。
- 免费事件判断：InspectEvent("observation"/"discovery"/"dialogue"/"information"/"elder_dialogue")不扣体力、不产出奖励、不保存。
- 实际高消耗事件：开始前CanStartEventOperation；玩家确认且动作完成后CompleteEventOperation扣40。允许special_event暂停期间调用，拒绝其他暂停、背包/老人界面、港口、耗尽或忙碌状态。不构造事件系统、奖励表或生成器。
- dropReceiver接收itemId/category/worldEffect/lifetimeSec；A集成层提供真实世界坐标，交接成功返回true才移除。
- onNewDay在结算保存成功后通知A刷新动态世界；resetDynamicWorld在新周目通知A清空。自动保存仍仅每日结算，海上没有手动保存API。

## BALANCE_TARGET（仅设计与测试参考）

- 世界每天180s，7天基础21min；完整一周目25～40min；平均每天约1min事件/暂停开销，不延长昼夜。
- 40体力非捕鱼事件综合价值约100～150金币等价物，不一定是金币；玩家选择付费应有收益，由内容侧设计，B不伪造奖励。
- 前期约3次有效捕鱼/日，后期5～6次；来自体力、食物及玩家效率，不设置dailyFishingLimit。
- 一周目约30次有效捕鱼，参考21沙丁鱼+9金枪鱼=2550卖鱼收入，不作为结算条件。
- 两苹果30×2=60买到40体力；额外网沙丁鱼净现金+10、金枪鱼+60。食物须在消耗后吃，不能突破当前体力上限。
- 7天出现5～7个值得付费操作的机会，选择3～5个；不强制每天一个。
- 事件池9～10个，一周目遇5～6、二周目遇7～8，其中2～3重复/功能性、4～5新增或新结果。没有新建完整Event System。
- 二周目24～26次捕鱼、金枪鱼60%～70%是知识收益目标，不是强制掉率；所有gameplay仍重置，不自动赠送透视镜。

抛网半径/距离、事件掉落表、宝藏价格、通关金币阈值、最终触发概率均未定。没有实现1600累计收入通关要求。

## 自动验收

执行 scripts/Tests/run_game_loop.py 与 scripts/Tests/check_game_loop_lsp.py。新增 NumericEconomySpec覆盖用户18项要求及原子拒绝、升级持久化/旧档兼容/新周目、体力动作数学与经济参考；UI mock新增三类升级按钮购买/价格刷新。原20组规则及84项存档回归继续执行。

最终结果：NumericEconomySpec 21/21、原规则20/20、UI mock5/5、存档回归84/84、Lua5.4语法14个文件全部通过。LSP覆盖10/10运行模块、0 Error、44 Warning（含原有类型/回调警告）；完整诊断在 `.tmp/game-loop-lsp-result.json`。原26项模块验收继续满足；真实云和像素画面未作为mock的PASS证据。

源码检查：玩法数值均来自上述config/data；价格与容量无第二份运行时权威源；业务代码无dailyFishingLimit、鱼获比例配额或金币通关阈值。测试中的确定预期数字与UI布局尺寸不属于散落玩法硬编码。

真实船速、空网/捕获结果、世界暂停、事件奖励、坐标、每日鱼刷新以及真实云/画面仍须A接线与实机验收。
