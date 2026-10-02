# B 第二次数值补充与 A 接口契约

B_NUMERIC_SUPPLEMENT_02 = PASS（B模块范围，2026-10-02）。

目录：C:\codex\taptap-sea；渔夫漂流记；Maker App 6fb01c73-66b3-4356-b987-3669be7f8a44。

## 最小实现变更

唯一库存配置 `scripts/config/gameplay.lua` 的 `shop.dailyStock = { apple = 2, bait = 2 }`。
原物品价格仍只来自 `scripts/data/items.lua`；本轮未修改任何物品数值或升级经济。

Loop保存当天剩余库存，提供GetShopStock(itemId)。Buy只在Inventory添加成功且扣款后消耗一个库存。售罄、背包满、缺钱、海上、忙碌均不扣钱/库存。HUD显示剩余库存，售罄按钮禁用。库存不是背包持有/食用限制，其他合法来源的苹果仍能持有与使用。

仅ResetState、BeginNewDay首次应用及成功恢复每日结算快照时补满。返港/再出航、开关对话/背包、非法读档和保存重试均不重复补货。BeginNewDay应用后保存失败时库存已属于下一天，但结算锁禁止购买；重试不重复推进天数或补货。

Persistence与schema均未修改：已有唯一正常存档点是每日结算后、下一天开始且港口尚未交易的快照，该时刻库存必为配置满值，成功恢复该快照重建库存即可。不是“加载当前日中状态却补货”：读档本来就同时回退钱/背包/天数到同一日初快照；没有额外日中存档。如果未来允许日中存档，需同时保存库存，不能沿用本推导。

未新增cumulativeSaleRevenue：当前没有独立统计模块；新增持久统计会扩大本轮范围。累计销售收入仅作为人工/经济模拟观测指标，不用剩余钱包衡量赚钱表现。

## A 新世界参数（契约，B 不实现距离/渲染）

| A参数 | B约定 |
|---|---|
| 完整捕鱼表现约4秒 | 开始CanStartAction("fishing")，动作不申请GameClock暂停；A继续传dt，完成一次调用CompleteFishing(0/1)，只扣一次40，空网同样扣；4秒不额外扣体力 |
| 木桶/残骸实际交互5m | A检测真实距离；查看/发现用InspectEvent免费；玩家确认实际操作，CanStartEventOperation检查，完成调用CompleteEventOperation扣40 |
| 最大投放12m | A验证worldPosition并接受交接后返回true，B才删物品；拒绝/异常保留Inventory。payload仍是itemId/category/worldEffect/lifetimeSec，无坐标 |
| 地点80m未知轮廓、20m正式识别 | A绘制/测距；B保持PlayerState:IsRecognized/MarkRecognized、当前周目存档及新周目清空 |
| 透视镜揭示半径20m | 仅记录契约；没有具体透视镜物品定义，不向B业务代码添加20m、不实现mask/visibility/interaction |

A仍负责真实boatSpeedLevel→速度应用、世界暂停、每日动态刷新和新周目世界重置。Bootstrap、入口及A代码均未变。

## 最新 BALANCE_TARGET（覆盖上次数值补充中的同类目标）

- 一周目：赚钱并学习读海。累计卖出收入约1600金币，仅观察目标；不是通关/失败/Day7判定。升级与补给属于正常支出，不能以最终wallet代替累计收入。
- 40体力事件价值中心约120金币等价物，合理范围100～150；可为物品/知识/线索/能力/未来收益。没有全局eventReward=120。
- 7天高消耗事件机会约6个，实际处理3～5；不固定每天1个。
- V1内容池约10事件；二周目约8，其中约3重复/功能性、约5新的或进入新结果。只是内容生产/体验目标，没有运行时数量限制或生成系统。
- 一周目约30次理论高消耗行动容量，其中3～5用于事件并有少量空网，成功鱼获约23～26条，金枪鱼25%～30%。不设置day门槛鱼种掉率。
- 二周目成功鱼获约24～26条，金枪鱼60%～70%，来自现实玩家知识，不添加隐藏概率/收入加成。
- 初始体力100/金币100、升级100→160→200、5→10→15→20、船速6→8→10及所有价格保持上次确认值。每天商店2苹果只提供40体力，非食用次数或捕鱼次数上限。
- 新周目money/stamina/升级/Inventory/地点识别/透视镜/鱼/宝藏等gameplay全部重置，不自动赠送透视镜。
- 白天120s、夜晚60s、7天基础21min、完整周目25～40min等原时长目标保持。

没有实现dailyFishingLimit、newGamePlusTunaBonus、newGamePlusIncomeMultiplier、newGamePlusCatchRate、固定事件配额、目标鱼获比例、1600金币通关判断。原21沙丁鱼+9金枪鱼=2550的算术测试保留为经济参考样本，不再代表最新成功鱼获目标。

## 验证与边界

新增ShopStockSpec 15组：两种商品初始库存/买2拒3/次日补货、售罄不扣钱、背包满/缺钱/海上/忙碌不扣库存、返港不补货、其他来源与吃超过2苹果、投放拒绝、捕鱼4秒不停表/空网只扣40、日初读档、新周目、非法读档、结算失败重试。
UI mock新增两种商品售罄禁用与新一天刷新；runner新增源码配额审计。

最终实际结果：SHOP_STOCK_SPEC_PASS 15；NUMERIC_ECONOMY_SPEC_PASS 21；GAME_LOOP_SPEC_PASS 20；GAME_LOOP_UI_MOCK_PASS 6；PERSISTENCE_REGRESSION_PASS 84；Lua5.4语法15文件通过；BALANCE_RUNTIME_QUOTA_AUDIT_PASS；LSP 10/10运行模块、0 Error、44 Warning，与上一轮数量相同。两个测试runner退出码均0。未用mock结果代替实机验收。

实际工作区仍为本地未提交状态，git status显示docs交接文档与scripts/Gameplay、Tests、config、data为untracked；git diff --name-only为空（并不表示这些新增文件无内容变更）。预览state=stopped、process_alive=false，未启动或刷新；无commit/push。

本轮不改PlayerState、Inventory、Persistence、Economy、Bootstrap、A、共享入口、Maker配置、依赖；未push。仅增补gameplay配置、Loop库存、HUD展示、测试与文档。
