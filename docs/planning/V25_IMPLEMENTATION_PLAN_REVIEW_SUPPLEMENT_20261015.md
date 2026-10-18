# 《渔夫漂流记》V2.5 实施计划独立复核与补充稿

日期：2026-10-15  
任务性质：独立技术复核 / 实施细化 / 文档-only  
仓库：C:\codex\taptap-sea  
参考 HEAD：27e622688778e643cd28e99c2e7a0f0eee512e05  
复核对象：docs/planning/V25_IMPLEMENTATION_PLAN_20261015.md  
本文件用途：作为主文档的补充、纠偏与实施契约，不覆盖主文档，不代替用户后续明确裁决。

---

## 0. 使用方式与优先级

本文件用于解决一个问题：以后把 V2.5 任务交给 Codex 时，代理应当主要做“按既定边界实施”，而不是重新发明状态归属、事务、存档、失败处理或 Worktree 合并方式。

发生冲突时按以下优先级处理：

1. 用户在后续对话中的明确裁决。
2. 用户已经确认的 V2.5 产品规则。
3. docs/planning/team/01～08 的现行策划语义。
4. 本文件给出的技术实施契约。
5. 当前代码现状。

“当前代码现状”只能证明已有行为，不能反向覆盖策划；但当旧策划数值与新代码已经经过后续明确调整时，本批 V2.5 也不能顺手把代码改回旧值。

本文件严格使用三种确定性标记：

- 【CONFIRMED PRODUCT】：用户已经确认的产品行为。除非用户重新裁决，实施不得改变。
- 【PLAYTEST VALUE】：当前用于试玩的数值或时间阈值。可作为本轮实现默认值，但不应写成永久设定，必须保留可调性与实测记录。
- 【TECH RECOMMENDATION / CANDIDATE】：工程实现建议、模块名、字段名、接口形态、算法候选或 UI 接线候选。它不是永久策划；若实际代码证明存在更小、更安全的等价方案，可在不改变产品语义的前提下调整，并在完成报告中记录偏差。

另有 【TBD】。TBD 表示当前证据不足，Codex 不得自行拍板。

---

# 1. 复核结论

总体结论：

- 主文档的 R1～R10 产品方向基本完整。
- A/C 的底层工程能力可以继续细化到可执行级别。
- TBD-B-01 已正式关闭：本轮自动返航采用轻量逐障碍绕行；仅安全余量、卡住阈值、重试上限等尚未给出的具体工程数值继续作为工程 TBD，普通 Codex/Luna 不得自行拍板。
- 主文档目前最大的问题不是缺需求，而是部分“确定性等级”和“状态归属”写得过强，容易让后续 Codex 把候选技术方案当作永久策划。
- Integration 边界需要重写：Integration 可以编排事务，但根据现有 ARCHITECTURE_LAYOUT.md，不能持有跨帧 Gameplay 状态。自动返航的跨帧导航状态应归 Ocean；世界探索/打捞动作的跨帧事务状态应归 Gameplay。
- C 的世界内容事务不能直接复用 Loop:CompleteEventOperation()。该接口只负责检查/扣除事件体力，没有 reward/completed/rollback/exactly-once 事务能力。
- 当前 data/items.lua → scripts/data/items.lua 适配链对“记忆碎片作为普通 ItemDefinition”并不完整：scripts/data/items.lua 内部读了 protected，但 GetDefinition() 返回副本时没有带出 protected；canGive 也仅对白名单 apple/bait/sardine/tuna 开放。因此 V2.5 不应让 C 只加三条 treasure 数据后就宣称“不可丢弃且可给老人展示”已经完成。
- 当前旧策划仍出现船速 6/8/10 m/s、1800m 地图等旧值，而实际代码已经是 9/12/16 m/s、2880m 地图。本批 V2.5 禁止顺手按旧文档回退这些值。

建议主文档保留，新增本文件作为“执行前必读补充”。后续若要合并回主文档，应逐条采用本文件第 3 节的修改稿，不应整份覆盖。

---

# 2. 已核实的当前工程基线

以下均是参考 HEAD 与当前工作区代码事实，用来防止实施代理基于旧文档猜测。

## 2.1 海洋与移动

当前 scripts/Ocean/Config.lua：

- 船速：9 / 12 / 16 m/s。
- 最大转向：180°/s。
- 船碰撞半径：1.8m。
- Movement 目标到达半径：1.5m。
- 海洋子步上限：0.05s。
- 单帧最多模拟海洋时间：0.25s。
- 当前最大航速 16m/s × 180s 推导地图边长 2880m，halfSize=1440m。
- 港口锚点仍为 Config.ship.start=(0,0)。
- 正常返港空间判定半径：10m。

当前固定阻挡：

- 岛 1：(35,25)，半径 12，blocking=true。
- 岛 2：(-80,90)，半径 20，blocking=true。
- 固定木桶：(14,6)，半径 2；World:Init 当前明确以 blocking=true 创建。

注意：旧 planning/team/08 仍写“木桶等普通漂浮物不阻挡船”，与当前实现及后续真机反馈不一致。本批不得依据该旧句把固定木桶改回非阻挡。

World:moveEntity() 是最终碰撞权威，使用 swept circle 防止穿透。任何自动返航方案不能绕过它，也不能自行写 ship.position。

## 2.2 正常返港事务

Loop:ReturnToPort() 当前已经具备正确的产品事务边界：

- 重新读取真实船位和港口位置。
- 真实距离必须 <=10m。
- 必须通过 Ready()。
- 清理 movement target。
- 取消投掷选择。
- 设置 inPort=true。
- Pause("port")。
- 同步港内音效。
- 写现有返港消息。

它不会调用 ResetShipAtPort()，因此正常返港不是传送。

ResetShipAtPort() 只供强制返港、新日准备、新周目/恢复等已有流程使用。自动返航到达后必须调用 ReturnToPort()，不能自己设置 inPort，也不能调用 ResetShipAtPort() 模拟成功。

## 2.3 输入链

普通海面点击当前链路：

Ocean.Bootstrap:HandlePointer()
→ Integration.Scene 的 onSeaPointer
→ Bridge:OnSeaPointer()
→ 若未被消费，Bootstrap 直接调用 runtime.movement:SetTarget(position)。

因此手动点击取消自动返航不需要修改 Bootstrap。Integration 可以在 Bridge:OnSeaPointer() 中先取消自动导航，再 return false，让现有手动目标正常接管。

键盘轴输入由 Bootstrap 传入 Bridge:Update(dt, axisX, axisY)，再进入 Game.Update。自动返航的键盘取消也可以在 Bridge.Update 进入 Game.Update 之前处理，不需要改键盘采集层。

## 2.4 暂停与世界更新

Gameplay GameClock 是昼夜唯一权威。

Game.Game 每帧由 Gameplay UpdateSystem 调 Loop:Update；海洋模拟仍受 maxFrameSec=0.25 限制。

因此：

- 自动返航不能自己推进昼夜时钟。
- 自动返航的“卡住计时”若以后实现，不可用 raw dt 直接推导船实际模拟时间；掉帧时海洋只模拟最多 0.25s。
- 任何 world-content 计时也必须明确自己使用的是“Gameplay gameSeconds”“海洋模拟 seconds”还是“不受暂停的 real dt”，不能含糊写 Update(dt)。

## 2.5 当前存档结构

Persistence.Snapshot() 已保存：

- day / stamina / maxStamina / money / boatSpeedLevel。
- inventory / inventoryLevel / inventoryCapacity。
- recognizedLocations。
- treasures。
- story。
- elder。

Persistence.Restore() 对缺失的 treasures/story/elder 已有旧档迁移逻辑；validMap 允许这些 namespace 内嵌套 string/boolean/number/table。

这意味着 V2.5 的本周目世界内容状态可以优先放进现有 story / treasures namespace，不必为了三项固定内容立刻升级整个 schemaVersion。

但是必须新增对应 Validate；不能只利用 validMap“什么都能存”而不校验 completed/reward 的一致性。

正常保存点仍只有每日结算。本轮不能新增海上即时保存。

## 2.6 老人 / 宝物现状

当前：

- Loop:GetElderStatus() 仍返回 applesGiven。
- HUD 老人卡前三天显示“已给予老人苹果：X/3”。
- 老人卡标题仍是“拜访老人”。
- 老人卡 footer 仍有“聊天记录”和自己的“结束对话”。
- 外部老人切换按钮打开后显示“结束对话”，不是“收起”。
- 第 7 天 story modal 另有独立“结束对话”，不可误删。
- player.treasures 当前用于 scopeLens。
- Loop:GiveTreasureToElder(id) 目前只支持 scopeLens。
- HUD 宝物区域目前也只针对透镜生成摘要。

R4/R5/D5 因此都不是纯文案改动；至少需要改变公开读取/展示路径，且不能伤到第 7 天剧情按钮。

## 2.7 R6 当前结构风险

HUD 的 recordElderExchange() 当前由 UI 回调直接调用，逻辑是：

1. invokeLoop("GiveToElder" / "GiveTreasureToElder")。
2. 无论上一步真实结果如何，再调用 recordElderExchange(...)。

而 invokeLoop() 当前不向调用者返回“这次 Gameplay 操作是否成功”的结构化结果。

这意味着后续实现 R6 时，如果只改对白文本，有机会在失败路径追加伪成功对话。R6 必须增加“成功回执后才能追加 transcript”的接口约束。

## 2.8 当前知识/成就系统

KnowledgeSystem / AchievementSystem / ProfileStore 已经存在，并且 profile 属于跨周目数据。

V2.5 三个记忆碎片默认只是本周目 treasure ownership，不自动等价于：

- 图鉴知识解锁。
- 成就解锁。
- domain level。
- profile knowledgeLog。

除非后续正式内容表明确给某次“展示碎片”绑定已有 knowledgeId，否则 R6 不能自行调用 KnowledgeSystem:Grant，也不能新生成成就。

---

# 3. 对当前总控文档的逐条修订建议

以下不是直接覆盖，而是“问题 → 原因 → 建议修改稿”。

## M-01：附录写“R1–R10 除 B 算法外已冻结”过强

问题：

主文档同时存在：

- R3 在旧版中仅写作“本轮实施默认”（现已由最新用户裁决正式确认）。
- R5 外部按钮“收起”为建议。
- C 的动作世界时间语义在旧版主要来自技术章节（现已由最新用户裁决正式确认）。
- B 算法在旧版中为 TBD；最新裁决已关闭，采用轻量逐障碍绕行。

因此不能把所有 R1–R10 的所有细节统一称为“产品已冻结”。

建议修改稿：

> 产品行为层：R1、R2、R4、R5 已明确部分、R6 成功后知识回应语义、R8/R9 内容目标及 R10 自动返航玩家行为按用户确认执行。  
> PLAYTEST 数值：R8/R9 的 1s / 4s / 40 体力 / 5m 等继续作为测试基准，不升格为永久设定。  
> 已关闭的原 TBD：R3 固定为每个新周目第一次进入捕鱼选点时显示一次；R8/R9 的 4 秒动作期间世界和昼夜正常推进、现有统一暂停时动作计时冻结；R8/R9 首版采用动态情境按钮；自动返航采用轻量逐障碍绕行。  
> 技术/UX 候选仍只限于未被最新裁决覆盖的表现细节，例如 R5 外部按钮的具体显示文案。自动返航的安全余量、卡住阈值、重试上限等具体工程数值仍未定，不得由普通 Codex/Luna 自行补值。

## M-02：缺少“旧策划数值与当前代码不一致”的冻结声明

风险：

Codex 读 team/03、04、08 后可能把 6/8/10m/s、1800m 地图当成需修复项。

建议新增：

> V2.5 非数值回滚任务。当前正式运行基线使用 Ocean.Config 与 config/gameplay.lua 的 9/12/16m/s 船速及由 16×180 推导的 2880m 地图。本轮禁止根据旧策划副本把它们回退到 6/8/10 或 1800m。若未来要重新平衡，必须另开数值任务。

## M-03：TBD-UX-01 已关闭

最新用户裁决：

> 【CONFIRMED PRODUCT】捕鱼提示固定为每个新周目第一次进入捕鱼选点时显示一次。跨日与正常读档保留“已提示”状态；NewRun 重置。

实施要求：

- 状态必须进入 Gameplay 持久进度，不得只存在 HUD 内存。
- 推荐放入已有 story namespace，由专门 progress 接口读写。
- 只有真正成功进入 fishing selecting 时才置位；被拒绝、busy 或未进入选点态不得提前消耗本周目提示。
- 正常日结存档/读档恢复该状态。
- NewRun 初始化为未提示。
- 不新增海上即时保存。

## M-04：R6 只写“展示成功才追加”但没有成功回执契约

建议在 A 章节补：

> HUD 的 invokeLoop 或等价调用必须让调用方得到 result/reason。  
> recordElderExchange 只能在 result==true 后追加。  
> result==false、异常、stale item、老人不在、busy、受保护等路径不得追加玩家成功气泡，也不得读取旧 lastMessage 冒充本次回复。  
> 对话 append 应以本次返回结果/本次 message 为依据，不依赖“可能仍保留上一次反馈”的全局 lastMessage。

## M-05：三个记忆碎片不能仅靠 data/items.lua 自动获得现有物品能力

现状：

- scripts/data/items.lua 的 definitions 内部读取 protected。
- GetDefinition() 返回副本没有 protected。
- canGive 只对白名单四个基础物品开放。
- scopeLens 本来就不走普通 inventory。

建议修改稿：

> V2.5 默认不要把三个记忆碎片塞进普通 Inventory 以复用 item 菜单。它们继续属于 player.treasures 的独立宝物 ownership。  
> 如需显示名称/老人展示，优先建立 WorldContent/treasure definition 的轻量只读定义，而不是把它们伪装成普通船舱物品。  
> 若最终决定把碎片定义加入 data/items.lua，则 Integration 必须同时修复 Items.GetDefinition() 的 protected 透传、treasure 展示能力与对应测试；不能只加数据表。

这条是技术推荐，不改变“碎片不占普通船舱、不可售、不可丢弃、可展示”的产品语义。

## M-06：TBD-UX-02 已关闭

最新用户裁决：

> 【CONFIRMED PRODUCT】岛屿探索、海底宝藏打捞的 4 秒动作期间，不新增暂停：游戏世界和昼夜正常推进。若现有统一暂停已经生效，则动作计时随该暂停冻结。

实施要求：

- WorldContentActions 仍只接受显式 elapsed/actionSeconds，不自己创建第二套时钟。
- Integration/Loop 在未暂停时向动作推进现有 Gameplay 有效时间；统一暂停期间传入的有效动作时间应为 0。
- 探索/打捞本身不得新增 pause reason 来冻结世界。
- 该裁决只确定时间/暂停语义，不改变既有强返、Scene Stop、Load/NewRun 等中断规则。

## M-07：WorldContentActions 不能复用 CompleteEventOperation 作为 commit

原因：

CompleteEventOperation 当前只有“CanStart + ConsumeStamina”，没有：

- target identity。
- generation。
- reward。
- completed。
- rollback。
- duplicate receipt。
- stale callback。

建议明确：

> C 新动作使用独立 receipt/transaction，参考 Circle1B2Barrel 与 Actions 的事务模式，但不复用鱼锁或 pending catch 结构。  
> 体力、completed、reward 必须在同一 commit 边界内 exactly-once。  
> 取消发生在 commit 前：0 体力、0 reward、completed=false。  
> commit 期间异常：回滚到 begin 前 snapshot；回滚失败进入显式 blocked/rollback_pending，不允许继续领奖。

## M-08：自动返航跨帧状态不能由 Integration 持有

ARCHITECTURE_LAYOUT.md 明确：Integration 不应持有跨帧玩法状态。

主文档 §7.2 把 GetAutoReturnState / RequestAutoReturn 写在“Gameplay → HUD”下，容易诱导把自动导航状态放入 Loop。

建议改为：

> 自动导航的 path / waypoint / nav phase / replan 等跨帧状态属于 Ocean 船舶导航能力。  
> Integration 只做无状态/轻状态编排：玩家按返航按钮时读取距离与 nav state；近港调用 Loop:ReturnToPort，远港调用 Runtime 的 auto navigation 接口；到达事件出现时再调用 Loop:ReturnToPort。  
> Gameplay 不保存路线、waypoint、障碍快照或导航计时。

## M-09：自动返航 HUD 接口应从 Gameplay façade 改成 Integration adapter

建议最终 HUD 接口：

    ReturnActions:GetState()
    ReturnActions:Request()

其中 ReturnActions 由 Integration.Scene 构造，内部调用 Bridge。

HUD 不应：

- 自己计算 10m。
- 自己访问 Runtime。
- 自己读 AutoNavigation 内部 waypoint。
- 调用一个伪装成 Gameplay 状态的方法。

Bridge 可对外提供 TECH RECOMMENDATION：

    GetReturnActionState()
    RequestReturnAction()
    CancelAutoReturn(reason)

具体命名可调整，但责任归属不变。

## M-10：B 当前“允许修改 Movement”范围过宽

现有 Movement 已经有成熟的真实转向、target、swept collision 链。即使自动返航已确定采用轻量逐障碍绕行，也不能为了让该方案更容易实现而修改基础船舶动力学。

建议 B 默认边界改为：

允许：

- 新增 Ocean/AutoNavigation.lua 或等价模块。
- SeaRuntime.lua 的薄公共接口。
- B 专属测试。

默认只读：

- Movement.lua。
- World.lua。
- Bootstrap.lua。

只有经过专项证据证明“不能通过公共 target/collision 接口实现”时，才申请最小修改 Movement/World；不得先改后解释。

## M-11：TBD-B-01 已关闭；轻量逐障碍绕行正式采用

【TECH IMPLEMENTATION DECISION】本轮自动返航固定采用轻量逐障碍绕行：

- 默认直线驶向港口。
- 检测“船 → 当前目标”线段上的 blocking 圆形障碍。
- 每次只处理最近的阻挡障碍。
- 在障碍左右两侧生成包含船半径与安全余量的绕行 waypoint。
- 选择较短且可行的一侧。
- 绕过后重新检查当前位置 → 港口；遇到下一个阻挡障碍时重复上述过程。
- 保留现有船速、转向和 World:moveEntity 碰撞权威。
- 不修改基础船运动学。
- 不做完整 A*、Jumper 或通用导航框架。
- 两侧均不可行、路线不可达或连续卡住时安全停止，并提示玩家手动驶离障碍后重新启动自动返航。
- 规划与重试必须有界，禁止无限绕行、无限重算。

仍未给出的具体工程数值继续作为工程 TBD：

- 安全余量具体数值。
- 卡住判定具体阈值。
- 重试/重规划具体上限。
- 如实现需要数值化的 waypoint 偏移、循环/迭代上限等。

这些工程数值不得由普通 Codex/Luna 自行拍板，应由 B 总控/Sol 在实现前或专项验证中明确记录。

## M-12：B 的 solver 不能只验证“几何路径存在”

当前 Movement 有有限 180°/s 转向，并且 target 模式会持续前进。即使一条折线几何上不穿圆，真实船也可能在拐点因转向半径撞障碍。

因此 B 评审必须加入：

> 已定轻量逐障碍绕行的通过条件不是“算出 waypoint”，而是该路线能被当前真实 Movement 运动学执行。  
> 至少用 9/12/16m/s、180°/s 和真实 arrivalRadius/collision 进行路径执行验证。  
> 若方案需要通过改变 Movement 的基本转向行为才能成功，必须单独说明产品影响，不能作为无感技术细节。

因此即使本轮采用较简单的逐障碍绕行，也不能降低真实 Movement 执行验证要求。

## M-13：C 的 stable identity 需要区分内容 generation 与 fishing generation

SeaRuntime:GetFishingGeneration() 在 refreshOrdinaryFish() 时会递增，它本质服务鱼目标生命周期；固定世界内容在换日时并没有被重建。

因此：

> 不要把 fishingGeneration 的名字当作永久“世界内容 generation”接口。  
> WorldContent 应使用独立的 fixed-content/world identity，或由 Ocean 返回 target snapshot 中的内容 generation。  
> 新 Runtime/New World 时必须变化；普通鱼跨日刷新不应伪装成固定岛屿被重建。  
> 动作在换日/新周目/Load/Scene Stop 时仍应由 Gameplay 生命周期取消，因此 generation 与“动作是否允许跨日”是两个不同概念。

TECH RECOMMENDATION：沿用 fixed barrel 的 exact-id + generation 思路，扩展为内容 snapshot；不要保存 Ocean entity 引用。

## M-14：C 缺少 completed/reward 的持久化不变量

建议明确：

- island_01.completed=true ⇒ memory_island_01 owned=true。
- island_02.completed=true ⇒ memory_island_02 owned=true。
- underwater_treasure_01.completed=true ⇒ marked=true 且 memory_treasure_01 owned=true。
- reward owned 但对应 completed=false 对 V2.5 新状态视为非法，除非未来明确添加其他奖励来源。
- marked=true 可以 completed=false。
- 日结 snapshot 前必须通过 WorldContentProgress.Validate。
- Restore 后先 Validate，再 Initialize 缺失的 V2.5 namespace。

这样可以防止“奖励已给但 completed 丢失”导致二次收费/二次领奖。

## M-15：海底宝藏“标记后继续可见”需要只读 presentation adapter

marked 属 Gameplay，不能写回 Ocean 实体。

现有 SeaDraw 已经通过 isLocationRecognized 回调读取 Gameplay 的固定木桶识别状态，这提供了现成模式。

建议：

> Scene/SeaDraw 增加只读 world-content view callback。  
> Ocean 实体只保存 contentId、位置、layer 等空间事实。  
> SeaDraw 决定水下宝藏是否按 scope 可见；若 Gameplay 回调返回 marked=true，则允许绘制持续标记。  
> SeaDraw 不写 marked；Gameplay 不写 entity.visible。

标记图形、美术样式是表现层技术调优，不升格为策划。

## M-16：TBD-UX-03 已关闭

最新用户裁决：

> 【CONFIRMED PRODUCT】岛屿探索/海底宝藏打捞首版采用动态情境按钮。

具体行为：

- 靠近合法岛屿探索目标时显示“探索岛屿”。
- 靠近已满足前置条件的海底宝藏打捞目标时显示“打捞宝藏”。
- 探索动作进行中，同一入口变为对应取消操作。
- 打捞动作进行中，同一入口变为对应取消操作。
- 不新增永久常驻探索/打捞按钮。
- 不采用点击世界对象作为首版主入口。

按钮继续复用现有 action dock / 情境操作模式；具体视觉皮肤仍属于表现层技术实现。

## M-17：SeaRuntime 是 B 与 Integration 的真实共享热点，主文档未写交接

B 需要 SeaRuntime 挂自动导航；Integration 又需要 SeaRuntime 提供固定世界内容只读接口。

建议文件所有权改为阶段制：

- B 阶段：B 是 SeaRuntime.lua 唯一修改者。
- B 完成并形成清晰 HEAD 后，SeaRuntime 交还 Integration。
- C 阶段不碰 SeaRuntime，使用 fake runtime / adapter。
- Integration 在已合入 B 的 SeaRuntime 基础上追加 world-content 查询。
- 不允许 B 与 Integration 同时各自在 SeaRuntime 上继续开发。

## M-18：Integration 合并顺序缺少“冻结接口/回归门”

建议改成：

1. 建立 Integration 基线，记录 A/B/C 各 HEAD。
2. 合 A；先跑 UI/老人定向测试。
3. 合 B；先跑 Ocean/输入/港口定向测试。
4. 合 C；先跑 C 独立事务测试。
5. 此时禁止 A/B/C 再直接修改共享文件。
6. Integration 才开始 Loop/Bridge/Scene/Persistence/SeaRuntime/World/SeaDraw/HUD 接线。
7. 跑定向矩阵。
8. 跑全量 review / AB integration / sea tests。
9. 实机鼠标/键盘/触摸/画面验收。
10. 最终再决定 commit/push，不自动推 main。

---

# 4. 需求确定性重新分类

## 4.1 A：UI / 老人

| 项目 | 分类 | 实施含义 |
|---|---|---|
| 出航后隐藏“港口商店”入口 | CONFIRMED PRODUCT | HUD 海上不显示该入口；港内原商店能力保留 |
| 船舱打开时按钮文案切换为“收起船舱” | CONFIRMED PRODUCT | 不改变 inventory pause/待领取规则 |
| 首次捕鱼提示“每个新周目第一次进入捕鱼选点显示一次” | CONFIRMED PRODUCT | 跨日/正常读档保留；NewRun 重置 |
| 老人卡不显示苹果 X/3 | CONFIRMED PRODUCT | 后台 applesGiven 与救人判定保留 |
| 老人卡标题改“老人” | CONFIRMED PRODUCT | 仅 UI |
| 老人卡删除“聊天记录”和卡内“结束对话” | CONFIRMED PRODUCT | 第 7 天 story modal 的“结束对话”必须保留 |
| 外部老人 toggle 打开时改成“收起” | TECH CANDIDATE | 主文档本身已标“建议” |
| 成功给予/展示后出现相应知识回应 | CONFIRMED PRODUCT | 只在真正成功后追加；无自由问答 |
| 正式逐物品对白正文 | 内容 TBD | Codex 不自行创作 |

## 4.2 C：岛屿 / 海底宝藏

| 项目 | 分类 | 实施含义 |
|---|---|---|
| 两座固定现有岛各一次探索 | CONFIRMED PRODUCT | 每周目 exactly-once |
| 两岛分别给独立记忆碎片，无其他数值奖励 | CONFIRMED PRODUCT | reward ownership 独立 |
| 岛屿探索需要靠近岸边 | CONFIRMED PRODUCT | 不能用岛中心距离直接比较 |
| 岸边 5m | PLAYTEST VALUE | 保留可调；实现记录最终几何定义 |
| 探索 4s / 40 体力 | PLAYTEST VALUE | 取消/中断免费；成功时 commit |
| 固定海底宝藏一个 | CONFIRMED PRODUCT | 非随机刷新 |
| 必须通过透镜观察后才能标记 | CONFIRMED PRODUCT | scope 是空间事实 |
| 连续观察 1s | PLAYTEST VALUE | 离开 scope 未完成累计清零 |
| marked 跨日，关透镜仍可定位 | CONFIRMED PRODUCT | marked 在 Gameplay |
| 5m 内打捞 | PLAYTEST VALUE | 位置事实由 Ocean |
| 打捞 4s / 40 体力 | PLAYTEST VALUE | cancel free / exactly-once |
| 三个碎片不占普通船舱、不可售/丢、可展示老人 | CONFIRMED PRODUCT | 推荐走 treasures，不走 Inventory |
| 探索/打捞 4 秒期间世界与昼夜正常推进 | CONFIRMED PRODUCT | 不新增暂停；现有统一暂停时动作计时冻结 |
| 首版探索/打捞入口 | CONFIRMED PRODUCT | 动态情境按钮；“探索岛屿/打捞宝藏”，动作中同入口取消；无常驻按钮/世界点击主入口 |

## 4.3 B：自动返航

已确认产品规则：

- 距港 >10m 时可启动自动返航。
- <=10m 使用正式返港。
- 自动驾驶使用现有船速/升级，不给隐藏速度。
- 不传送。
- 不额外扣体力。
- 游戏时间正常推进。
- 必须规避所有 blocking 障碍。
- 再按返航可取消。
- 海面手动导航、键盘驾驶接管时取消。
- 打开船舱或进入暂停后取消，不在恢复后自动续航。
- 路线不可达或连续卡住时停止并提示。
- 首次真实进入港口 10m 后自动完成正式 ReturnToPort。
- 夜尽强制返港优先级更高。
- 不能自己写 inPort。

已定技术方案：

- 本轮采用轻量逐障碍绕行，不做完整 A* / Jumper / 通用导航框架。
- 默认直线向港口；检测船→目标线段上最近的 blocking 圆形障碍。
- 对最近障碍生成左右两侧、包含船半径和安全余量的 waypoint，选择较短且可行的一侧。
- 绕过后重新检查当前位置→港口。
- 真实船速、转向和 World 碰撞权威保持不变。
- 无可行侧、不可达或连续卡住时安全停止并提示玩家手动驶离后重试。
- 规划/重试必须有界。

仍属工程 TBD、普通 Codex/Luna 不得自行填写的具体数值：

- 安全余量。
- 卡住阈值。
- 重试/重规划上限。
- 其他实现中新增的数值化 waypoint 偏移或循环上限。

---

# 5. Workstream A 可执行实施规格

## 5.1 A 默认文件边界

A 唯一并行 owner：

- scripts/Gameplay/HUD.lua
- A 新增、只服务 A 的测试文件

条件允许：

- R3 已确认需要持久“本周目已提示”状态；若涉及共享 progress/Loop/Persistence，仍由 A 或 Integration 中的单一 owner 修改，避免并行抢文件。

A 默认不修改：

- Bridge.lua
- Scene.lua
- Persistence.lua
- SeaRuntime.lua
- World.lua
- Movement.lua
- C 的 WorldContent 模块

这样可以最大化减少后续合并冲突。

## 5.2 R1 港口商店

当前 refs.infoToggle 在海上仍显示。

最终产品行为：

- inPort=true：按现有信息面板规则显示“港口商店/收起信息”。
- inPort=false：港口商店入口本身隐藏，不仅仅 disabled。
- 不因隐藏入口而破坏船舱/老人卡的 infoLayer/cardHost。

验收必须同时覆盖：

- 出航瞬间隐藏。
- 返港后重新出现。
- 打开船舱不依赖港口商店入口恢复。

## 5.3 R2 船舱

按钮文案：

- inventoryOpen=false 且无 pending catch：船舱。
- inventoryOpen=true：收起船舱。
- pending catch：保留“船舱（收获待领）”或现有待领取强提示优先，不允许为了文案切换破坏“不能关闭待领取船舱”的契约。

点击行为仍只调用 SetInventoryOpen，不能由 HUD 直接 Resume/Pause clock。

## 5.4 R4/R5 老人卡

删除的是老人卡自身：

- 标题“拜访老人” → “老人”。
- header 的苹果 X/3 文本。
- footer 的“聊天记录”。
- footer 的卡内“结束对话”。

保留：

- 外部老人 toggle 作为进入/退出入口。
- 第 7 天 story modal 的 storyClose/“结束对话”。
- elderTranscript 内部数据如果 R6 仍需要当前对话流；“删除聊天记录按钮”不等于删除 transcript。
- applesGiven 后台状态和 Progress.RecordApple。

外部 toggle 打开态文案“收起”仍属 TECH CANDIDATE；未确认前不要把它写成产品永久规则。

## 5.5 R6 成功回执

建议把 HUD 本地 invokeLoop 改成既保持现有刷新行为，又返回：

    success:boolean
    reason:any
    optionalResult:any

所有需要追加 elder transcript 的按钮必须：

1. 保存本次 itemId/label。
2. 调 Gameplay。
3. 只有 success==true 才 append。
4. 使用本次返回 message 或明确本次结果。
5. 失败只显示错误，不 append 成功 exchange。

不得通过“loop.lastMessage 当前有文本”推断这次成功，因为 lastMessage 可能来自上一个操作。

## 5.6 R3 已确认的状态要求

- 【CONFIRMED PRODUCT】每个新周目第一次成功进入 fishing selecting 时显示一次捕鱼提示。
- 状态必须属于 Gameplay progress，不属于 HUD local state。
- 日结 snapshot 后跨日/正常读档恢复。
- NewRun 重置为未提示。
- 按钮被拒绝、动作 already busy 或没有真正进入选点态时不置位。
- 文案仅使用用户已确认文本，不自行扩写教程。
- 不新增单独即时保存。

---

# 6. Workstream B 可执行边界：架构与轻量绕行方案已冻结，工程数值待定

## 6.1 状态归属

自动返航是船舶导航能力。

跨帧状态属于 Ocean：

- phase。
- path / waypoint。
- planner result。
- blocker snapshot（如 solver 需要）。
- stuck / replan 计时（如 solver 需要）。
- terminal arrival/failure record。

Gameplay 不保存这些状态。

Integration 不长期保存第二份这些状态。

## 6.2 推荐模块

TECH RECOMMENDATION：

- 新增 scripts/Ocean/AutoNavigation.lua。
- SeaRuntime 持有一个 AutoNavigation 实例。
- AutoNavigation 只知道 Ocean 世界、Movement、目标位置/目标半径；不知道 PlayerState、stamina、Loop、inPort。

建议 Runtime 公开最小语义：

    StartAutoReturn(portPosition, portRadius)
    CancelAutoReturn(reason)
    GetAutoReturnState()
    ConsumeAutoReturnArrival()

函数名可调整。

ConsumeAutoReturnArrival 的目的：

- 到达事件只消费一次。
- Integration 每帧读取一次 terminal event。
- 读到 arrival 后调用 Loop:ReturnToPort。
- 下一帧不能再次生成同一 arrival。
- ReturnToPort 若异常拒绝，本次自动返航结束并显式失败，不无限重试事务。

## 6.3 Integration 对自动返航的无状态编排

Bridge:GetReturnActionState：

- inPort：按钮隐藏/无动作。
- 海上且 <=10m：mode=return。
- 海上 >10m 且 nav inactive：mode=auto_start。
- nav active：mode=auto_cancel。

Bridge:RequestReturnAction：

1. 若 nav active：CancelAutoReturn("cancelled_by_user")。
2. 否则重新读取 Loop:CanAccessPort。
3. near=true：直接 Loop:ReturnToPort。
4. near=false 且 reason=port_out_of_range：Runtime:StartAutoReturn(port,10)。
5. 其他空间读取失败：失败并提示，不猜位置。

Bridge.Update：

- keyboard axes 非零且 nav active：先取消，再把原 axes 传给 Game.Update。
- Game.Update 正常执行。
- 之后消费 AutoReturn arrival；高优先检查强返/paused/inPort 等状态后再决定是否调用 ReturnToPort。
- 不推进第二套时间。

Bridge:OnSeaPointer：

- 普通导航点击在交给 Bootstrap 之前取消 nav。
- return false，让原 Bootstrap 继续 SetTarget。
- 捕鱼/投掷专用指针协议保持现有优先级。

Bridge/Sync 或 state observer：

- 发现 clock paused 且 nav active：取消。
- inventory pause 因此同步取消。
- TogglePause 显式取消后再切 manual pause。
- Load/NewRun/Scene Stop/强返也必须取消。

## 6.4 Runtime ClearMovementTarget 的兼容边界

当前很多 Gameplay 动作会调用 Runtime:ClearMovementTarget。

B 需要明确“外部清 movement target 是否同时终止 AutoNavigation”。推荐：

- 公开 ClearMovementTarget 被外部调用时，auto nav 也进入 cancelled/overridden。
- AutoNavigation 自己清理 owned target 时使用内部专用方法，避免把自己误判为外部取消。

若 B 选择其他等价 ownership 机制，必须证明：

- 捕鱼开始清 target 后 auto nav 不会下一帧把 waypoint 塞回来。
- 木桶/探索/打捞接管时同样不会抢方向盘。
- 外部设置了新手动 target 后 cancel 不会把外部 target 一起清掉。

## 6.5 已定轻量逐障碍绕行契约

本轮不再比较完整 A* / Jumper / 通用导航框架，直接执行以下轻量方案：

1. 当前船位到港口默认走直线。
2. 检测该线段与所有 blocking 圆形障碍的阻挡关系。
3. 若有多个阻挡，只处理沿当前航段最近的一个。
4. 针对该障碍生成左右两个包含船半径与安全余量的绕行 waypoint 候选。
5. 丢弃不可行候选；若两侧都可行，选较短一侧。
6. 船完成绕行后，从真实当前位置重新检查到港口的直线。
7. 再遇阻挡则重复，直到进入真实 10m 港口范围或失败终止。
8. 两侧均不可行、不可达或连续卡住时，不升级为更复杂 solver；停止并提示玩家手动驶离障碍后重试。
9. 不改变现有 speed、turn rate、Movement steering 或 World:moveEntity 碰撞权威。
10. 规划与重试必须有界。

仍需 B 总控/Sol 明确的工程数值：

- safety margin。
- stuck threshold。
- retry/replan limit。
- 如实现确需的 waypoint offset / iteration limit。

这些数值在明确前禁止普通 Codex/Luna自行拍板。

## 6.6 轻量逐障碍绕行必须通过的证据

无论最终选哪个：

- 无障碍直达。
- 单岛挡直线。
- 两岛形成单侧可通路径。
- 多 blocker。
- 地图边缘。
- 起点接近 blocker。
- 9/12/16m/s。
- 初始船头背向目标。
- 混合帧率 1/60、1/30、0.1、0.25 和 raw dt>0.25。
- 真实 World:moveEntity 最终仍是碰撞权威。
- 不能靠持续碰撞 push 才完成路线。
- planner/update 有明确节点/迭代/重规划上限。
- 不可达有界失败。
- 连续卡住有界失败。
- 没有无限循环。
- 不通过修改基础船速/转向来“让算法通过”。

算法选择本身已经定稿；上述专项证据用于确认该轻量方案在真实 Movement 下可接受，并由 B 总控/Sol据此冻结安全余量、卡住阈值、重试上限等剩余工程数值。

---

# 7. Workstream C：世界内容底层实施契约

## 7.1 C 独立阶段文件

推荐 C 新增：

- Gameplay/WorldContentProgress.lua
- Gameplay/WorldContentActions.lua
- Gameplay/WorldContentDefinitions.lua（仅稳定 ID、类型、reward ID、工作显示名；不写正式剧情）
- C 专属 tests

C 独立阶段不得修改：

- HUD.lua。
- Loop.lua。
- Persistence.lua。
- SeaRuntime.lua。
- World.lua。
- Config.lua。
- SeaDraw.lua。

C 用 fake Runtime / fake spatial adapter 完成核心事务。

## 7.2 稳定定义

TECH RECOMMENDATION：

WorldContentDefinitions 至少描述：

    island_01
      kind = island
      rewardId = memory_island_01

    island_02
      kind = island
      rewardId = memory_island_02

    underwater_treasure_01
      kind = underwater_treasure
      rewardId = memory_treasure_01

这些是实现 ID，不是剧情名称。

三个 reward 默认保存在 player.treasures，不进入 Inventory。

工作显示名可暂用“记忆碎片 01/02/03”；正式碎片剧情名称/正文仍 TBD。

## 7.3 Progress 建议结构

TECH RECOMMENDATION：

    player.story.worldContentV25 = {
        island_01 = {
            completed = false
        },
        island_02 = {
            completed = false
        },
        underwater_treasure_01 = {
            marked = false,
            completed = false
        }
    }

    player.treasures.memory_island_01 = false
    player.treasures.memory_island_02 = false
    player.treasures.memory_treasure_01 = false

模块接口至少：

    Initialize(player)
    Validate(playerOrSnapshot)
    GetState(player, contentId)
    IsCompleted(player, contentId)
    IsMarked(player, contentId)
    Mark(player, contentId)
    CommitReward(player, contentId)

实现可换字段名，但必须保持：

- story 为本周目过程状态。
- treasures 为 ownership。
- 坐标不进入 Gameplay。
- Ocean entity 不进入 Gameplay。
- Initialize 对旧存档缺失字段补默认值。
- Validate 不修改状态。

## 7.4 不变量

Validate 至少检查：

- 所有 completed/marked 都是 boolean。
- 仅 underwater_treasure_01 允许 marked。
- island_01.completed → memory_island_01==true。
- island_02.completed → memory_island_02==true。
- underwater_treasure_01.completed → marked==true 且 memory_treasure_01==true。
- 若 reward 当前唯一来源就是对应 content，则 owned=true 但 completed=false 视为非法。
- 未知 content key 的处理必须明确；默认拒绝，不静默吞掉拼写错误。

## 7.5 WorldContentActions receipt

一个 action record 至少包含：

- token/actionId。
- loopGeneration。
- contentId。
- actionKind：explore / salvage。
- target identity/generation snapshot。
- state。
- elapsed。
- start-time progress/reward snapshot。
- result。
- cancel reason。
- rollback state（如需要）。

推荐状态：

- active。
- committing。
- rollback_pending。
- complete。
- cancelled。
- failed。

Begin 前：

1. 内容 ID/动作种类匹配。
2. 未 completed。
3. treasure salvage 必须 marked。
4. 空间 access=true。
5. player stamina >= 当前 PLAYTEST cost。
6. 没有其他互斥动作。
7. 保存 target exact identity/generation。
8. 清船移动目标/阻止移动由 Integration 接线完成，不在 C fake runtime 中硬编码。

动作中：

- 每次 Advance 前/边界处重新验证 loop generation 与 target。
- 空间是否必须持续保持有效：建议 true；若移动已被阻止，正常不会离开。
- 探索/打捞本身不新增暂停；未暂停时动作与游戏世界/昼夜正常推进。现有统一暂停生效时，传入动作的有效 elapsed 为 0，动作计时冻结。

Cancel：

- commit 前幂等。
- 0 扣费。
- 0 reward。
- completed 不变。
- 晚到 callback/重复 cancel 不可再 commit。

Commit：

推荐在完成边界才扣体力，避免提前预扣再退款：

1. 重新校验 action/token/generation/access/completed。
2. snapshot stamina/progress/reward。
3. ConsumeStamina。
4. 写 completed。
5. 写 reward ownership。
6. Validate。
7. 成功后封存 result。

任何一步异常：

- 恢复 stamina/progress/reward。
- 若 rollback 失败，留下 rollback_pending 并阻止同内容再次开始。
- 不得留下“扣体力但没碎片”或“碎片有了但 completed=false”。

## 7.6 PLAYTEST 参数注入

C 模块不要散落 40/4/5/1 常量。

建议定义明确 tuning 输入/配置：

- island interact distance：5m PLAYTEST。
- explore duration：4s PLAYTEST。
- explore cost：40 PLAYTEST。
- scope mark duration：1s PLAYTEST。
- salvage distance：5m PLAYTEST。
- salvage duration：4s PLAYTEST。
- salvage cost：40 PLAYTEST。

它们必须在注释/文档中继续标 PLAYTEST VALUE。

## 7.7 连续透镜观察

临时 observe accumulator 不需要存档。

逻辑：

- 未 marked 且目标真实在 scope 内：累计。
- scope 关闭 / 目标离开扇形 / world target stale：未完成累计归零。
- 达到 PLAYTEST 1s：Mark exactly-once，累计清理。
- marked 后不继续累计。
- 日结保存 marked。
- 读档恢复 marked，不恢复未满 1s 的 accumulator。

由于 accumulator 是短期动作状态，可属于 Gameplay WorldContentActions/observer 部分；空间判断必须由 Ocean 公共只读 query 返回。

## 7.8 海岸线距离

产品只确认“靠岸”，5m 为 PLAYTEST。

技术建议采用：

    edgeDistance = max(0, distance(shipCenter, islandCenter) - islandRadius)

不要直接比较 ship→island center <=5。

是否还要再减 ship.radius 属几何定义差异，当前未被产品单独裁决。建议继续采用“船的世界参考点（ship center）到海岸圆边界”的距离，与现有空间交互以船位置为参考点的惯例一致；若实机感觉不合理再调，而不是改 completed 规则。

## 7.9 海底宝藏坐标

最终坐标是 TECH TUNING，不是永久策划。

Integration 选点必须证明：

- 固定。
- 合法水域。
- 不与 blocking collider 重叠。
- 可真实航行抵达。
- 透镜扇形能覆盖。
- PLAYTEST 5m 打捞可达。
- 不生成在港口立即可见/误触的区域。
- 不依赖随机种子。

主文档“距港约60～100m”继续只保留候选参考，不升格。

---

# 8. Ocean 世界内容只读接口

这些由 Integration 在 B 完成 SeaRuntime 后统一接入。

## 8.1 fixed content identity

现有两个岛必须获得稳定 contentId：

- island_01。
- island_02。

World:Init 创建 fixedObjects 时要把 Config 的 contentId 传入 spawn。

海底宝藏创建一个固定 underwater entity：

- contentId=underwater_treasure_01。
- blocking=false。
- ordinaryFish=false。
- 不参与 daily clearOrdinaryFish。

不要依赖 fixedObjects 数组下标作为存档身份。

## 8.2 查询接口

TECH RECOMMENDATION：

    Runtime:GetWorldContent(contentId)

返回只读/复制 snapshot，例如：

    id
    contentId
    generation
    entityType
    layer
    position
    radius
    blocking

    Runtime:GetWorldContentAccess(contentId)

返回空间事实，例如：

    exists
    distance
    edgeDistance
    withinInteractionRange

这里的 interaction range 最好由调用方传入或由 content definition 明确，不让 Ocean 决定 Gameplay cost/规则。

    Runtime:IsWorldContentInScope(contentId)

只返回空间/可见性事实。

不要把 Gameplay marked 状态传进这个函数。

## 8.3 Scope

当前 World 的 isInsideScope 是内部函数。

Integration 可增加一个最小公共 wrapper 复用现有 20m/90°数学，避免 Gameplay/Bridge 复制角度计算。

不能：

- 由 Gameplay 自己重写一套 20m/90°判定。
- 因宝藏需求改变现有鱼的 scope 可见规则。
- 把 marked 写进 world.scopeEnabled。

## 8.4 generation

推荐新建 fixed-content/world generation，语义：

- New World / Runtime Init 时变化。
- 当前 World 内 ordinary fish daily refresh 不变化。
- content snapshot 带 generation。
- action receipt 同时记录 loopGeneration + contentGeneration + entity id/contentId。

这样 stale old-world action 无法提交到新世界，同时日结鱼刷新不会伪造“岛屿实体换代”。

---

# 9. Treasure presentation 与老人展示

## 9.1 宝物区域

最终 GetOwnedTreasures 或等价公开 façade 至少可表示：

- scopeLens。
- memory_island_01。
- memory_island_02。
- memory_treasure_01。

HUD 不遍历 player.treasures 内部实现字段后自行猜显示名。

Gameplay/definition 层返回只读 view model：

    id
    displayName
    owned
    showToElderAllowed
    protected

“protected”对独立 treasures 的含义是：无出售/丢弃/投掷入口，不需要走 Inventory protected flag。

## 9.2 老人展示

将当前只支持 scopeLens 的 GiveTreasureToElder 泛化为语义明确的：

    ShowTreasureToElder(treasureId)

或等价方法。

约束：

- 老人在场。
- elderOpen=true。
- treasure owned=true。
- 展示不消费。
- 重复展示不复制 treasure。
- 本次成功才返回当前本次回应。
- knowledgeId 只有内容表明确存在时才授予。
- 未有正式对白时只能使用已有通用 fallback，不自行写碎片故事。

## 9.3 Items adapter 旁路

默认推荐记忆碎片不进入普通 Items/Inventory，因此本轮可以不因为它们去修改 data/items.lua。

如果后续决定所有 treasure 都统一进 Items definition，则另列共享修改：

- data/items.lua。
- GeneratedData 同步。
- scripts/data/items.lua 的 protected 透传。
- treasure canGive/show 规则。
- sync_runtime_data.py --check。
- data migration tests。

不能半接入。

---

# 10. Presentation：marked 不复制到 Ocean

Scene 可向 SeaDraw 传一个只读回调，例如：

    getWorldContentView(contentId)
      → { marked=true/false, completed=true/false }

SeaDraw：

- 未 marked：水下宝藏仅在现有 scope 判定可见时画。
- marked：关闭 scope 后仍绘制一个持续可定位的 marker/outline。
- completed：按产品需要隐藏可打捞提示；是否保留“已打捞地点”标记可作为表现层候选，不要自行加奖励。

Ocean entity 不存 marked/completed。

Gameplay 不存 entity position。

marker 的具体颜色、图标、动画是 TECH PRESENTATION TUNING，不是永久产品规则。

---

# 11. Integration 最终接口契约

## 11.1 HUD adapter

建议 HUD.Create 最终增加一个可选 integrationActions 参数，而不是把 Bridge 整体注入 HUD。

至少可分两个窄 adapter：

ReturnActions：

    GetState()
    Request()

WorldContentActionsView：

    GetPrompt()
    Begin(contentId, actionKind)
    Cancel()
    GetActionState()
    GetOwnedTreasures()
    ShowTreasureToElder(id)

A 独立阶段不必提前创建这些 adapter；Integration 在 A 合入后一次接线。

## 11.2 Loop 接线

Integration 负责：

- 创建/持有 Gameplay.WorldContentActions。
- Loop.Ready 纳入 world-content active/rollback pending。
- Loop:IsMovementBlocked 纳入 world-content active。
- NewRun/Load/Close/强返时取消旧 action。
- Loop.Update 中推进该 action：未暂停时使用现有 Gameplay 有效时间；现有统一暂停期间 actionSeconds=0，不新增探索/打捞专用 pause reason。
- 暴露只读 progress/view methods。
- 不把 Ocean entity 放进 Loop/player。

## 11.3 Persistence 接线

Snapshot 前：

- Circle1B2Progress.Validate。
- WorldContentProgress.Validate。

Restore：

- 校验已有 V2.5 namespace。
- 老存档缺 namespace 时 Initialize 默认值。
- 不因仅增加 story/treasures 子键自动升级 schemaVersion。
- 若实现者发现现有 schema compatibility policy 要求 bump，必须停止并上报；不得自行改 key/version。

## 11.4 Scene

Scene 负责：

- 构造 HUD integration adapter。
- AutoReturn 与 world-content 的 UI wiring。
- SeaDraw marked 回调。
- Scene.Stop 取消 auto return 和 world-content action。
- 不持有第二份 progress/nav 状态。

---

# 12. 自动返航与其他动作的互斥

最终产品/技术边界：

- 手动海面导航：取消 auto return，同一点击继续成为普通导航。
- 键盘驾驶：取消 auto return，同一帧继续手动轴。
- 打开船舱：取消 auto return。
- 任意 pause 生效：auto return 不保留路线等待恢复；直接取消。
- 捕鱼/木桶/探索/打捞开始：先确保 auto return 结束。
- 强返：强返覆盖 auto return。
- auto return 取消不能清除已经由其他系统设置的新 target。
- world-content active：船移动 target 清除或移动输入被阻止；具体沿用 Loop:IsMovementBlocked/Game 清 target 的既有模式。
- 透镜开关本身不暂停，也不必自动取消 auto return。
- 自动返航途中如果海底目标真实连续处于 scope，可以按 R9 累计 marked；auto return 不应伪造 scope。

---

# 13. Worktree 最终文件所有权建议

## 13.1 A Worktree

默认可改：

- Gameplay/HUD.lua。
- A 新测试。

条件可改：

- R3 获确认后对应小型 progress 接口；如涉及共享 Loop/Persistence，建议留 Integration。

禁止：

- Bridge/Scene。
- SeaRuntime/Movement/World。
- C 模块。

## 13.2 B Worktree

默认可改：

- 新 AutoNavigation.lua。
- SeaRuntime.lua。
- B 专属测试。

默认只读：

- Movement.lua。
- World.lua。
- Bootstrap.lua。

若已定的轻量逐障碍绕行确实需要修改 Movement/World，必须先在 B 报告中说明“为什么 Runtime/Movement 公共 target + World 碰撞不足”，并由总控批准最小扩大；不得通过修改基础船运动学迁就算法。

禁止：

- HUD/Loop/Persistence。
- C 世界内容。

## 13.3 C Worktree

可改：

- 新 WorldContentProgress.lua。
- 新 WorldContentActions.lua。
- 新 WorldContentDefinitions.lua。
- C 专属 fake-runtime tests。

禁止：

- HUD。
- Loop。
- Persistence。
- SeaRuntime。
- World/Config/SeaDraw。
- B 导航。

## 13.4 Integration Worktree

开始条件：

- A/B/C 各自形成可指认 HEAD。
- B SeaRuntime 所有权已交回。
- 不再允许 A/B/C 同时改共享接线文件。

Integration 单一 owner：

- Gameplay/Loop.lua。
- Gameplay/Persistence.lua。
- Integration/Bridge.lua。
- Integration/Scene.lua。
- Ocean/SeaRuntime.lua（承接 B HEAD 后）。
- Ocean/Config.lua。
- Ocean/World.lua。
- Ocean/SeaDraw.lua。
- Gameplay/HUD.lua（承接 A HEAD 后的 B/C 接口 wiring）。
- 需要的 Integration tests。

Movement.lua 仍默认不属于 Integration；只有 B 针对轻量逐障碍绕行已获得明确批准的最小修改，才可先在 B 阶段完成并合入。

---

# 14. 合并顺序和停止线

推荐：

### Gate 0：基线

记录：

    WORKTREE
    BRANCH
    BASE_HEAD
    CURRENT_HEAD
    DIRTY_BEFORE
    ALLOWED_FILES
    FORBIDDEN_FILES

不得 reset/clean/stash/checkout 覆盖现有工作。

### Gate 1：A

- 合 A。
- 跑 HUD/老人定向。
- 不开始 B/C wiring。

### Gate 2：B

- 轻量逐障碍绕行方案已定，不再允许实现代理替换成完整 A* / Jumper / 通用导航框架。
- 安全余量、卡住阈值、重试上限等具体工程数值必须先由 B 总控/Sol 明确并记录；普通 Codex/Luna 不得自行补值。
- 定向测试通过后再合；合后 SeaRuntime owner 交 Integration。

### Gate 3：C

- 合 C 纯模块和测试。
- C 不带真实 Runtime/World 接线。

### Gate 4：Integration

统一修改共享文件。

原 TBD-UX-01、TBD-UX-02、TBD-UX-03、TBD-B-01 均已关闭，不再作为 Integration 阻塞项。

若 B 的安全余量、卡住阈值、重试上限等剩余工程数值尚未由 B 总控/Sol 明确，则自动返航部分仍报告 BLOCKED；Integration 不得让普通 Codex/Luna用“合理默认值”补齐。

### Gate 5：回归

定向通过后才跑全量。

### Gate 6：实机

必须真实鼠标/键盘/触摸/画面验证；自动测试不替代。

---

# 15. 详细测试矩阵

## 15.1 A 定向

至少新增/更新：

- 港内港口商店入口存在。
- Depart 后同帧隐藏。
- ReturnToPort 后恢复。
- 船舱关闭态“船舱”。
- 打开态“收起船舱”。
- pending catch 不允许错误收起。
- 老人卡无 X/3。
- 后台 applesGiven 仍增长。
- 老人卡标题“老人”。
- 老人卡无聊天记录/卡内结束对话。
- story modal 仍有“结束对话”。
- 给予成功才 append transcript。
- 给予失败不 append。
- 透镜展示成功才 append。
- 重复展示不消费。
- 无 ElderQA。

建议回归现有：

- Circle1B2UITests。
- Circle1B3SevenDaysTests。
- GameLoopUISpec。
- Circle1HUDReviewTests。
- Circle1B7CardLayoutTests。
- ABIntegrationTests 中 UI 场景部分。

## 15.2 B 专项

轻量逐障碍绕行已经定稿；测试只验证产品/运动学结果，不把内部 waypoint 坐标写成脆弱的固定快照。

功能：

- start/cancel 幂等。
- 近港不启动远程 nav。
- 远港启动。
- manual pointer cancel。
- keyboard cancel。
- pause/inventory cancel。
- exclusive action cancel。
- forced return override。
- arrival event exactly-once。
- Loop ReturnToPort exactly-once。
- no stamina change。
- clock 正常推进。
- target ownership 不抢外部手动目标。

路径：

- 无障碍。
- 单岛。
- 多岛。
- 边界。
- 不可达。
- 卡住。
- 9/12/16。
- 不同初始 heading。
- 混合 dt。
- 有界搜索。

建议回归：

- SeaRuntimeTests。
- SeaStabilityTests。
- Circle1A3InputTests。
- Circle1A3PortTests。
- Circle1A3StabilityTests。
- Circle1ABMergeFrameBudgetTests。
- ABIntegrationTests。

## 15.3 C 独立单测

Progress：

- Initialize 旧 player。
- Validate 正常状态。
- 非 boolean 拒绝。
- completed/reward 不一致拒绝。
- treasure completed 未 marked 拒绝。
- new run fresh state。

Action：

- explore begin。
- salvage 未 marked 拒绝。
- completed 重开拒绝。
- stamina < cost 拒绝。
- cancel before completion 免费。
- duplicate cancel 幂等。
- complete exactly-once。
- duplicate completion 不重复收费/reward。
- target generation stale。
- loop generation stale。
- access 失效。
- commit exception rollback。
- rollback failure 显式 blocked。
- reward 已有/状态异常 fail-closed。
- observe <1s 离 scope 归零。
- observe 达阈值 mark once。
- marked 后不重复累计。

这些测试用 fake Runtime，不依赖真实岛坐标。

## 15.4 Integration 世界内容

真实 Ocean：

- island_01/02 都有 contentId。
- query snapshot read-only/copy。
- daily fish refresh 不改变 fixed content identity。
- new Runtime 改 generation。
- 两岛 shore edgeDistance 正确，大岛不因中心远而不可交互。
- underwater target 合法、固定、非 blocking、非 ordinaryFish。
- scope 真实覆盖能触发观察。
- marked 后 scope off 仍有 marker。
- completed 后不再出现可打捞 action。
- 三个 treasures 在宝物 view。
- 老人展示不消费。

生命周期：

- day settlement save/restore。
- skip save 时遵循现有“当天未保存可能丢失”语义。
- Load 覆盖旧 run 时旧 action stale。
- NewRun 全部 reset。
- Scene Stop 无残留 action。
- 强返取消 action。
- late callback 不污染新 generation。

## 15.5 推荐命令

文档不要求当前立即运行；实现阶段可用现有入口：

    python tests/run_circle1_review.py --phase final --suite Circle1B2UITests --suite Circle1B3SevenDaysTests --suite GameLoopUISpec --suite Circle1HUDReviewTests

    python tests/run_ab_integration.py

    python tests/run_sea_tests.py

需要时：

    python tests/run_circle1_review.py --phase final --suite <new-suite>

如果修改根 data/items.lua / data/fish.lua：

    python tests/sync_runtime_data.py
    python tests/sync_runtime_data.py --check

未修改 data 时不要为了本任务无意义重写 GeneratedData。

---

# 16. Integration 实机验收清单

以下必须人工/真机验证，不因 Lua 测试通过而删：

UI：

1. 港内能找到港口商店。
2. 出航后港口商店入口立即消失。
3. 船舱打开后按钮能明确收起；待领取状态不会被错误关闭。
4. 老人卡精简后仍能正常给予/展示。
5. 第 7 天剧情“结束对话”仍存在。
6. 苹果进度不泄露，救人判定仍正确。

Auto Return：

7. 远海可以启动/取消。
8. 海面点击同次输入立即接管。
9. 键盘同帧接管。
10. 打开船舱/暂停后不恢复旧返航路线。
11. 对当前真实岛/木桶不会持续顶墙。
12. 路线无解/持续卡住时安全停。
13. 真实进入 10m 后正式返港一次。
14. 不传送、不额外扣体力。
15. 游戏昼夜继续正常推进。
16. 夜尽与到港竞态时强返优先。

World Content：

17. 两座现有岛都能通过真实航行靠近并获得探索资格。
18. 取消探索不扣体力/不领奖。
19. 完成后只得到对应碎片。
20. 海底宝藏不打开透镜时不应被提前当作已标记。
21. 连续观察达到 PLAYTEST 阈值后才标记。
22. 中断未满阈值重新累计。
23. 标记后关闭透镜仍能定位。
24. 靠近后可打捞；取消免费。
25. 完成后不重复奖励。
26. 三碎片不占船舱。
27. 三碎片无出售/丢弃入口。
28. 给老人展示不消费，失败不伪造对话。
29. 日结→重启/Load 后 V2.5 状态正确。
30. NewRun 后三内容全部恢复未完成状态。

---

# 17. Diagnostics 建议

仅记录状态边界，不每帧刷屏。

AutoReturn：

- start。
- plan_success / plan_failure。
- cancel + reason。
- replan（算法定稿后）。
- stuck/failure。
- arrival_ready。
- arrival_consumed。
- return_rejected。

WorldContent：

- begin/rejected。
- cancel。
- commit_started。
- commit_completed。
- commit_failed。
- rollback_started/completed/failed。
- mark_started/marked/reset。
- stale_action。

字段只记 scalar：

- contentId。
- actionId。
- loopGeneration。
- contentGeneration。
- actionKind。
- reason。
- elapsed。
- cost。
- marked/completed。
- nav routing meta（按已定轻量逐障碍方案；具体工程数值由 B 总控/Sol定稿后记录）。

不要把 player snapshot、完整 path table、World entity table 打进日志。

---

# 18. 原 4 个 TBD 已关闭；剩余工程数值

## CLOSED-B-01：自动返航方案

已正式采用轻量逐障碍绕行：直线向港口、检测最近 blocking 圆障碍、左右生成安全 waypoint、选较短可行侧、绕过后重新检查；不做完整 A* / Jumper / 通用导航框架。

仍未给出的安全余量、卡住阈值、重试/重规划上限等属于工程 TBD，必须由 B 总控/Sol明确，普通 Codex/Luna 不得自行拍板。

## CLOSED-UX-01：R3 捕鱼提示频率

每个新周目第一次进入捕鱼选点时显示一次；跨日/正常读档保留；NewRun 重置。

## CLOSED-UX-02：探索/打捞时间政策

4 秒动作期间世界和昼夜正常推进；不新增动作专用暂停。现有统一暂停发生时，动作计时随暂停冻结。

## CLOSED-UX-03：探索/打捞首版入口

采用动态情境按钮：合法目标附近显示“探索岛屿”或“打捞宝藏”，动作中同一入口变为对应取消操作；不新增永久常驻按钮，不以点击世界对象作为首版主入口。

因此原 4 个 TBD 已全部关闭。当前仍需外部技术决策的只有自动返航尚未给出的具体工程数值；其他内容 TBD（如正式剧情/对白正文）仍按原文边界处理。

---

# 19. 给后续 Codex 的执行约束

后续 Codex 收到本批任务时，必须先报告：

    TASK
    WORKTREE
    BRANCH
    BASE_HEAD
    CURRENT_HEAD
    DIRTY_BEFORE
    ALLOWED_FILES
    FORBIDDEN_FILES
    DEPENDENCIES
    OPEN_TBD

执行中：

- 不把 PLAYTEST VALUE 写成“最终平衡值”。
- 不把 TECH RECOMMENDATION 写成“用户已确认”。
- 不自行关闭 TBD。
- 不因为旧 team 文档数字不同而回退当前运行参数。
- 不让 Integration 持有第二份 Gameplay/Ocean 跨帧真相。
- 不为方便测试直接写 player/story/entity 内部字段绕过接口。
- 不复用 fish-specific lock 作为世界内容锁。
- 不通过删除旧测试断言让新实现变绿。
- 不自动 commit/push/main merge，除非当次任务明确授权。
- 若需要扩大允许文件，停止该部分并报告，不默许跨 Worktree 抢共享文件。

完成报告除了测试结果，还必须单列：

- 哪些 CONFIRMED PRODUCT 已实现。
- 哪些 PLAYTEST VALUE 实际使用了什么值。
- 哪些 TECH RECOMMENDATION 采用/偏离。
- 哪些 TBD 仍未解决。
- 取消路径。
- 失败回滚。
- exactly-once。
- Save/Load/NewRun。
- stale generation。
- 手工验收未完成项。

---

# 20. 本次独立复核建议的主文档最小合并项

如果不想把本补充稿整份合回主文档，至少应把以下 10 条合进去：

1. 增加三类确定性标签定义，修正“R1–R10 全冻结”的过强表述。
2. 明确当前 9/12/16m/s、2880m 为 V2.5 运行基线，本轮不回退。
3. R3 已由用户确认：每个新周目第一次进入捕鱼选点时显示一次；跨日/正常读档保留，NewRun 重置。
4. R6 增加“Gameplay 成功回执后才能 append transcript”。
5. AutoReturn 跨帧状态归 Ocean，不归 Integration/Gameplay。
6. AutoReturn HUD 接口改成 Integration adapter。
7. AutoReturn 已确定采用轻量逐障碍绕行，不做完整 A* / Jumper / 通用导航；安全余量、卡住阈值、重试上限等具体工程数值继续由 B 总控/Sol冻结。
8. C 动作使用独立 receipt，不复用 CompleteEventOperation。
9. C 动作时间语义已确认：4 秒动作期间世界/昼夜正常推进，现有统一暂停时动作计时冻结；C core 仍接收显式 elapsed，不创建第二套时钟。
10. SeaRuntime 加入阶段所有权交接：B 完成后交 Integration，C 不碰真实 Runtime。

做到这十条后，主计划会显著降低 Codex “重新脑补设计”与并行冲突的风险。