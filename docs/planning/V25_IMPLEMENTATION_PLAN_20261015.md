# V2.5 需求 1–10 实施总控计划（2026-10-15）

> 状态：**已明确的产品行为冻结；A/C 可进入实施准备；B 自动返航算法待独立 Sol 复核合入。**
>
> 本文区分三种确定性：**用户明确确认的产品行为**、标为 **PLAYTEST VALUE** 的首轮测试参数、以及标为“建议／推荐／候选”的技术实现方案。只有第一类属于不可由开发自行改写的产品结论；测试参数允许在实机验证后调整，技术建议允许在不改变产品语义和验收标准的前提下优化。不得因为本文用于执行而把“建议值”误升格为永久正式策划。
>
> 本文是本轮 1–10 需求的增量实施合同，不替代完整策划。未在本文改动的规则继续以现有策划文档及用户后续明确确认事项为准。
>
> 参考代码基线：`27e622688778e643cd28e99c2e7a0f0eee512e05`（`main`）。
>
> 编写时本地根工作区存在与本任务无关的未提交美术/规则改动；本文只新增本文件，不授权覆盖、清理、回滚或顺手修复这些改动。各开发 Worktree 启动时必须重新记录实际基线 HEAD 与 dirty 状态。

## 0. 权威顺序与执行原则

本轮发生冲突时按以下顺序判断：

1. 本文记录的 2026-10-15 用户明确确认事项。
2. V2.5 最新策划增量与《游戏道具总表》等已确认规则。
3. `docs/planning/team/` 中未被后续确认推翻的规则。
4. 现有代码行为只代表实现现状，不得反向覆盖最新策划。

实施遵守现有 `TEAM_FILE_BOUNDARIES.md` 与 `ARCHITECTURE_LAYOUT.md`：

当前 V2.5 运行基线必须保持：
- 船速：9 / 12 / 16 m/s；
- 地图：2880m；
- 固定木桶：blocking=true。

禁止依据旧策划副本把它们回退为 6 / 8 / 10 m/s、1800m 或木桶非阻挡；本轮需求没有授权这些回退。

- Gameplay 持有玩家体力、奖励、动作事务、跨日玩法进度。
- Ocean 持有海洋实体、位置、碰撞、距离、可见性和导航空间事实。
- Integration 只负责装配、转发与事务编排，不持有第二份跨帧玩法状态。
- HUD 只通过公开接口触发玩法，不直接写 Ocean 实体或复制玩法状态。
- 同一文件同一时段只有一个明确修改者。
- 不为本轮需求引入完整 ECS、通用 NavMesh、大型依赖或无关架构重构。

## 1. 本轮最终产品需求

### R1 出航后隐藏港口商店

- 港内允许显示“港口商店”入口和商店卡。
- 点击出航、`inPort=false` 后，“港口商店”入口直接隐藏。
- 海上不得保留一个点开后无实际港口功能的商店入口。
### R2 船舱按钮开合文案

- 船舱关闭：按钮显示“船舱”。
- 船舱打开：同一按钮显示“收起船舱”。
- 物品操作子菜单自身的“返回”语义保持独立，不用“返回”替代整舱收起。

### R3 首次捕鱼一次性提示

- 【CONFIRMED PRODUCT】每个新周目第一次**成功进入捕鱼选点状态**时显示一次。
- 跨日/正常读档保留已提示状态；NewRun 重置。
- 提示文字：
  - “点击附近海面下网”
- 提示使用轻量气泡，不打开阻挡式模态框。
- 提示不增加二次确认；流程仍是：捕鱼 → 点击合法海面 → 下网。
- 提示状态跨日保留、同周目不重复；新周目重置。
- 可以复用当前约 5 秒气泡显示机制，不新增必须由策划确认的持续时间。

### R4 老人苹果计数仅后台保留

- 删除老人界面的“已给予老人苹果：X/3”等可见进度文字。
- `applesGiven` 后台累计、前三日累计 3 苹果、第 4 天判定、相关成就/状态均保持原逻辑。
- 不因隐藏 UI 修改救人条件或消费规则。

### R5 老人界面精简

- 老人卡标题由“拜访老人”改为“老人”。
- 删除**老人卡自己的**“聊天记录”按钮。
- 删除**老人卡自己的**“结束对话”按钮。
- 外部老人入口：关闭时“拜访老人”，打开时建议显示“收起”。
- 不得全局删除“结束对话”：第 7 天纸条/剧情模态框仍使用该按钮，必须保留。
- 不删除 `elderTranscript` 或对话气泡数据结构；需求 R6 继续使用它。

### R6 老人知识改为物品给予/展示触发

- 不保留“和老人对话”“提问”“自由问答”等通用主动问答入口。
- 现有 ElderQA 已删除，不得恢复。
- 主动信息来源统一为：
  - 食物等可给予物品 → “给予”；
  - 鱼、鱼饵、宝物、透镜、记忆碎片等 → “展示”。
- 展示物品不消耗；食物给予按既有物品规则消费。
- 成功交互后以对话气泡形式展示“玩家动作 + 老人回答”。
- 只有 Gameplay 本次 Give/Show 调用返回**明确 success**后，HUD 才能 append transcript / 成功气泡；不得仅凭“没有抛异常”“按钮已点击”或 UI 本地推测当作成功。
- 失败不得追加伪成功对白，也不得先写成功气泡再报错。
- 知识若配置为首次获得，只记录一次；物品仍允许再次展示并获得正常对白。
- 具体逐物品老人对白由独立表格后补；Codex 不得自行编写新剧情正文。
### R7 返港按钮与 R10 合并

R7 不单独开发为“远离港口时完全没有返港相关入口”，而与自动返航合并：

- 港内：显示“出航”。
- 海上且距港 >10m：显示“自动返航”。
- 自动返航进行中：显示“取消返航”。
- 海上且距港 ≤10m、非自动返航：显示“返港”。
- 自动返航进入港口 ≤10m 后：自动调用正式返港事务完成返港，不要求玩家再点一次。
- 普通手动返港仍使用既有 10m 准入判定。

### R8 岛屿一次性探索

已确认首版：

- 当前两座固定岛均可探索：
  - `island_01`
  - `island_02`
- 每座岛每周目成功探索一次。
- 交互判定为“距岛岸 ≤5m”，不是距岛中心 ≤5m。
- 推荐空间计算口径：
  - `distance(ship, island.center) - island.radius - ship.radius <= 5m`
- 【CONFIRMED PRODUCT】靠近合法目标时通过动态情境按钮显示“探索岛屿”；不新增永久常驻探索按钮，也不以点击世界对象作为首版主入口。
- 动作进行中同一动态入口切换为对应取消操作。
- 探索动作 4 秒（PLAYTEST VALUE）。
- 【CONFIRMED PRODUCT】这 4 秒期间游戏世界与昼夜时间继续正常推进；现有统一暂停发生时，动作计时随暂停冻结。
- 成功成本 40 体力（PLAYTEST VALUE）。
- 开始前体力不足 40 则拒绝，不预扣。
- 取消/中断：不扣体力、不发奖励、不标记完成。
- 成功后分别获得：
  - `memory_island_01`
  - `memory_island_02`
- 不额外发木材、矿石、金币、补给或随机资源。
- 完成状态跨日保留，新周目重置。
- 不为探索增加即时保存；沿用正常日结保存规则。

### R9 透镜标记海底宝藏并打捞

首版只放 1 个固定海底宝藏，但实现结构应支持以后扩展多个：

- 内容 ID：`underwater_treasure_01`
- 奖励：`memory_treasure_01`
- 宝藏开局即存在于固定合法水域，不随机刷新。
- 透镜继续沿用 20m 长、总角度 90°前向扇形。
- 宝藏连续处于透镜有效观察范围 1 秒（PLAYTEST VALUE）后完成标记。
- 中途移出透镜有效范围，当前连续观察计时归零。
- 一旦标记成功，本周目关闭透镜后仍保留可见标识。
- 已标记宝藏靠近 ≤5m 时，通过与探索共用的动态情境入口显示“打捞宝藏”；不新增永久常驻打捞按钮，也不以点击世界对象作为首版主入口。
- 动作进行中同一动态入口切换为对应取消操作。
- 打捞动作 4 秒（PLAYTEST VALUE）。
- 【CONFIRMED PRODUCT】这 4 秒期间游戏世界与昼夜时间继续正常推进；现有统一暂停发生时，动作计时随暂停冻结。
- 成功成本 40 体力（PLAYTEST VALUE）。
- 取消/中断打捞：不扣体力、不发奖励，已完成的 `marked` 不丢失。
- 成功后：
  - `completed=true`
  - 获得 `memory_treasure_01`
  - 不再显示可重复打捞入口。
- 标记与完成状态跨日保留，新周目重置。
- 打捞可以复用捕鱼的部分视觉/计时表现，但不得复用鱼锁、鱼 AI、空网、船舱待领取等捕鱼事务。

### R10 自动返航

产品行为与本轮 solver 方向已经明确；具体未给出的工程数值仍不得由普通开发代理自行脑补。

- 【TECH DECISION】本轮采用轻量逐障碍绕行，不做完整 A* / Jumper / 通用导航框架。
- 默认直线驶向港口；检测当前船→目标线段上的 blocking 圆形障碍。
- 每次只处理最近的阻挡障碍；在障碍左右两侧生成带船半径和安全余量的绕行 waypoint，选择较短且可行的一侧。
- 绕过当前障碍后重新检查当前位置→港口；如遇下一个障碍再重复。
- 保留现有船速、转向与 World 碰撞权威；不得修改基础船舶操控来迁就 solver。
- 不要求解决所有复杂封闭/迷宫场景。
- 两侧均不可行、路线不可达或连续卡住时停止并提示玩家手动驶离障碍后重新启动自动返航。
- 玩家手动接管后可再次点击自动返航重新规划。
- 规划/重试必须有界，不得无限绕行或无限重算。
- 海上距港 >10m 可启动“自动返航”。
- 船使用当前实际船速真实航行，不传送。
- 世界时间正常推进，不因自动返航暂停。
- 自动返航本身不额外消耗体力。
- 需要绕开岛屿及其他实际阻挡船只的障碍物。
- 再点击“取消返航”：立即取消导航，船保留当前位置。
- 玩家手动点击海面导航或使用键盘驾驶：取消自动返航并交还控制。
- 打开船舱或进入手动暂停：**直接取消自动返航**，不是仅暂停后继续。
- 路线不可达或连续卡住：停止自动返航并给出明确提示，不无限撞障碍或无限重规划。
- 自动驶入港口有效范围（≤10m）后：自动调用既有正式返港事务完成返港。
- 不允许自动返航直接写 `inPort=true` 绕过 `ReturnToPort()` 的正式判定。
- 夜尽强制返港优先级高于自动返航；进入强返流程时取消自动返航。
- 开始捕鱼、木桶检查、岛屿探索、海底打捞等需要独占船只控制的动作前，必须结束自动返航，避免控制争用。

> **B 工程参数边界：** solver 方向已关闭 TBD-B-01；圆形可见图、采样图、Grid A*/Jumper 不再是本轮自由候选。凡本文件与独立复核补充稿未给出具体数值的安全余量、卡住判定阈值、重试次数等，普通 Luna/Codex 不得自行拍板；由 B 总控依据复核稿和实际代码提出、记录并受有界失败行为约束。

## 2. D1–D5 已确认决策

| 决策 | 冻结结果 |
|---|---|
| D1 | 当前两座固定岛都可探索 |
| D2 | 第一版固定海底宝藏 1 个；系统支持以后扩展 |
| D3 | 探索/打捞均先用 40 体力 + 4 秒 PLAYTEST VALUE |
| D4 | 岛屿和海底宝藏第一版都只奖励记忆碎片 |
| D5 | 记忆碎片作为正式宝物显示，可向老人展示 |

### 记忆碎片持有规则

三个首版碎片：

- `memory_island_01`
- `memory_island_02`
- `memory_treasure_01`

统一规则：

- 默认 ownership 放在 `player.treasures`，显示在“宝物 · 不占船舱格”区域。
- 不进入普通 Inventory，不占普通船舱容量。
- 不可出售。
- 不可丢弃。
- 不得仅向 `data/items.lua` 增加三条普通 ItemDefinition 就宣称完成；当前 Items adapter 对 `protected` / `canGive` 链仍有缺口，须按独立复核补充稿处理。
- 可向老人展示，展示不消耗。
- 具体展示对白后补，未填内容不得由开发自行创作。
- 圈2再接图鉴和收集成就；第一版获得碎片不自动解锁成就。
- 跨日保留，新周目重置。
## 3. 总体技术边界

### 3.1 不建立万能动作框架

本轮不得为了捕鱼、木桶、探索、打捞“统一”而大规模重构现有动作系统。

允许复用：

- 4 秒计时表现；
- 取消输入模式；
- 统一反馈组件；
- 部分动画/水花/收网表现。

不得错误复用：

- 捕鱼目标锁；
- 鱼 AI；
- 空网逻辑；
- 鱼实体移除事务；
- 满船舱待领取。

建议保持：

```text
FishingAction        # 现有捕鱼事务
BarrelAction         # 现有木桶事务
WorldContentActions  # 新增探索/打捞事务
```

### 3.2 世界内容状态归 Gameplay

推荐持久化关系（字段名可在不改变语义的前提下调整）：

```lua
player.story.worldContent = {
  island_01 = { completed = true },
  island_02 = { completed = true },
  underwater_treasure_01 = {
    marked = true,
    completed = true,
  },
}

player.treasures = {
  scopeLens = true,
  memory_island_01 = true,
  memory_island_02 = true,
  memory_treasure_01 = true,
}
```

- `marked/completed/reward ownership` 是 Gameplay 进度。
- Ocean 不保存第二份 `marked` 真值。
- Ocean 只提供位置、碰撞、距离、透镜覆盖等空间事实。
- 现有 Persistence 的递归 map 结构可承载嵌套状态，第一目标是不升级 Save Schema。
- 新状态仍必须有专门 Validate；不能因为底层 map 接受 table 就完全不校验业务合法性。

### 3.3 World Generation / stale action

探索和打捞开始时必须绑定稳定内容身份与当前世界身份。

至少记录：

- `contentId`
- world/runtime generation 或等价稳定身份
- 动作类型
- 开始时必要快照

完成前再次核对；读档、新周目、World Reset 后，旧动作不能对新世界同名对象提交奖励。

### 3.4 exactly-once

探索/打捞成功提交必须保证：

- 体力只扣一次；
- completed 只写一次；
- reward ownership 只写一次；
- 任一步失败时不得留下“扣体力但没奖励”或“奖励已给又再次收费”的半状态。
## 4. Workstream A — UI / 老人交互（建议 Luna High 总控）

### 4.1 负责范围

A 负责 R1–R6。

主要所有权：

- `scripts/Gameplay/HUD.lua`
- A 所需的少量 `scripts/Gameplay/Loop.lua` 公共方法
- 新增 UI hint / elder dialogue 数据接口（如需要）
- A 专属测试

B/C 不得并行修改 `HUD.lua` 或 A 已声明占用的 `Loop.lua` 段落。

### 4.2 R3 提示状态

推荐通过 Gameplay 状态保存“本周目已显示”，不要只放 HUD 内存。

允许实现为：

```text
player.story.uiHints.fishingSelectionShown = true
```

或等价结构。

约束：

- HUD 不直接裸写 player 字段；通过 Gameplay 公共方法或专门 progress 模块完成。
- 日结存档后第二天/重启读档不重复提示。
- 新周目恢复未提示状态。

### 4.3 老人对话数据接口

建议建立数据驱动查询：

```text
itemId
+ action: give | show
+ optional state
→ playerLine
→ elderLine
→ optional knowledgeId
```

第一版要求：

- 当前已有物品、透镜及三个记忆碎片都能走统一查询接口。
- 缺正式对白时允许保留**现有代码已有**的通用反馈作为临时 fallback。
- 不得把 fallback 当成正式文案验收完成。
- 不得自行创作病因、世界观、碎片故事或老人新知识正文。

### 4.4 A 必须保留的现有能力

- `elderTranscript` 对话气泡流。
- 第 7 天纸条剧情的“结束对话”按钮。
- 给予苹果后台累计与消费事务。
- 鱼、鱼饵、透镜等展示不消费。
- 现有忙碌/暂停/待领取等拒绝边界。

### 4.5 A 验收

至少覆盖：

1. 港内看得到港口商店，出航立即隐藏。
2. 船舱按钮“船舱 ↔ 收起船舱”正确切换。
3. 每周目第一次捕鱼选点显示一次提示；同周目第二次不显示；新周目恢复。
4. 老人卡不出现苹果 X/3。
5. 老人卡标题是“老人”。
6. 老人卡没有“聊天记录”和自己的“结束对话”。
7. 第 7 天剧情仍能找到并点击“结束对话”。
8. 展示成功才追加成功气泡；展示失败不伪造成功。
9. 重复展示不重复消耗；苹果给予仍正常消耗/计数。
10. 不恢复 ElderQA 或任何自由问答入口。
## 5. Workstream B — 自动返航（建议 Sol High 总控）

### 5.1 当前可冻结部分

B 只负责自动航行底层能力，不负责 HUD。

推荐新增独立模块：

`scripts/Ocean/AutoNavigation.lua`

候选公开能力：

```lua
StartAutoReturn(portPosition)
CancelAutoReturn(reason)
GetAutoReturnState()
Update(...)
```

最终函数签名可由 Sol 调整，但语义必须保持：

- 状态可查询；
- 启动/取消幂等；
- 不直接完成 Gameplay 返港事务；
- 到达港口范围只发出“可完成返港”的结果，由 Integration 调既有 `ReturnToPort()`。

### 5.2 B 文件权限与状态归属

默认允许：

- `scripts/Ocean/AutoNavigation.lua`（新增，持有自动返航跨帧 path/waypoint/replan/stuck 状态）
- `scripts/Ocean/SeaRuntime.lua`（仅薄接口接入）
- 必要的 Ocean 导航测试

默认只读：

- `scripts/Ocean/Movement.lua`
- `scripts/Ocean/World.lua`

不得修改船运动学、现有转向/速度或 World 碰撞规则来迁就 solver；若实现确实证明必须修改默认只读文件，B 总控先报告具体缺口再决定，不允许普通子代理自行扩大范围。

SeaRuntime 只暴露窄接口；Bridge/Gameplay/Integration 不保存 path、waypoint、replan、stuck 等第二份自动导航状态。

B 不修改：

- `Gameplay/HUD.lua`
- 老人/物品逻辑
- 探索/记忆碎片事务
- Integration UI 接线

### 5.3 B 技术结论

TBD-B-01 已关闭：采用 R10 定义的轻量逐障碍绕行。

仍须由 B 总控明确并记录但不得由普通开发代理自由选择的工程参数包括：

- 船半径之外的具体安全余量；
- 卡住定义与阈值；
- 重试/重规划上限；
- 世界边界与两侧不可行的失败判定；
- 性能预算。

这些参数必须有界，并服务于“失败即安全停止并提示”的已确认行为。

## 6. Workstream C — 世界探索 / 记忆碎片（建议 Sol High 总控 + Luna 子代理）

### 6.1 负责范围

C 负责 R8、R9，以及 D5 的宝物持有能力。

建议新增：

- `scripts/Gameplay/WorldContentProgress.lua`
- `scripts/Gameplay/WorldContentActions.lua`
- 必要的纯内容定义模块
- C 专属单元测试

C 在独立 Worktree 中使用 fake Runtime / adapter 把事务做完整。C 不碰真实 `SeaRuntime.lua`，也不并行修改 B 使用的 Movement/World 导航热点。固定世界内容需要独立 fixed-content/world generation，不能直接借用 fishingGeneration。

### 6.2 WorldContentProgress

负责：

- `marked`
- `completed`
- 记忆碎片 ownership
- 初始化
- Validate
- 新周目默认值
- exactly-once 提交规则

不得：

- 保存 Ocean 实体对象引用；
- 保存第二份坐标真值；
- 自己执行海洋碰撞查询。

### 6.3 WorldContentActions

必须使用独立 receipt / transaction，不得直接复用 `CompleteEventOperation()` 作为探索/打捞完成事务。

至少支持等价能力：

```text
Explore(island)
Salvage(underwaterTreasure)
Cancel()
Advance(explicitElapsed)
```

语义：

- C core 只接受调用方显式传入的 elapsed，不自行选择 real dt / Gameplay dt / Ocean substep，也不自行决定暂停政策。
- Integration/Gameplay 调度负责落实已确认产品规则：世界/昼夜正常推进；统一暂停时动作 elapsed 冻结。
- Begin 前验证距离、状态、体力、动作互斥。
- receipt 至少绑定 action/token、contentId、独立 fixed-content/world generation、开始快照与提交状态。
- 不得直接复用 fishingGeneration 充当 fixed-content/world generation。
- 取消免费。
- failure 必须可回滚。
- 成功提交必须保证 stamina + completed + reward ownership exactly-once。
- stale generation 必须拒绝旧 receipt 对新世界提交。
### 6.4 透镜连续观察

观察累计属于 Gameplay 临时动作/观察状态，空间事实来自 Ocean。

推荐流程：

```text
Ocean: 当前目标在透镜有效扇形内？
        ↓
Gameplay 累计连续观察时间
        ↓
达到 1.0s
        ↓
worldContent[treasure].marked = true
```

- 未达到 1 秒就离开范围：累计归零。
- marked 后不需要继续透镜覆盖。
- marked 跨日保存。
- 不把 1 秒累计值本身作为必须保存的日中进度。

### 6.5 稳定内容 ID

Integration 最终必须为现有两个固定岛显式赋予稳定 `contentId`：

- `island_01`
- `island_02`

不得长期依赖“fixedObjects 第 1 个/第 2 个”的数组顺序作为存档身份。

海底宝藏：

- `underwater_treasure_01`

奖励：

- `memory_island_01`
- `memory_island_02`
- `memory_treasure_01`

### 6.6 首版海底宝藏位置

精确坐标属于实现期空间调参，不要求用户再决策，但必须满足：

- 固定、确定性；
- 合法水域；
- 可航行到达；
- 不与岛/木桶/港口碰撞；
- 建议距港约 60–100m；
- 透镜发现和 5m 打捞都能稳定验收。

Integration 记录最终坐标及可达性测试证据，不把建议区间误写成策划硬规则。

### 6.7 C 验收

至少覆盖：

1. 两岛均能在岸边 5m 范围出现探索资格。
2. 大岛不会因中心距离判定而永远无法探索。
3. 每岛每周目只成功领奖一次。
4. 取消探索 0 扣费、0 奖励、0 completed。
5. 体力不足 40 无法开始。
6. 宝藏透镜连续 1 秒才 marked。
7. 观察中断会清零未完成累计。
8. marked 后关闭透镜仍可进入后续流程。
9. 5m 内可打捞；取消免费。
10. completed 后不重复显示打捞/不重复领奖。
11. 日结后状态可恢复。
12. 新周目重置岛、宝藏、碎片 ownership。
13. stale world / reset 中断旧动作，不污染新世界。
14. 三个碎片均不占普通船舱。
15. 三个碎片不可售、不可丢弃，可展示给老人。
## 7. 公共接口契约（Integration 使用）

本节定义语义；具体函数名若与现有接口冲突可小幅调整，但不得改变责任归属。

### 7.1 Ocean → Gameplay 空间查询

建议提供只读能力：

```text
GetWorldContent(contentId)
  → stable identity / type / position / radius / layer 的只读快照

GetWorldContentAccess(contentId)
  → distance / edgeDistance / interactable 等空间事实

IsWorldContentInScope(contentId)
  → boolean

GetWorldGeneration()
  → 稳定世界身份
```

要求：

- 返回 copy/read-only snapshot，不向 Gameplay 暴露可写实体。
- Ocean 不写 Gameplay 的 marked/completed/reward。

### 7.2 Gameplay → HUD

最终 Loop/公开 façade 至少能表达：

```text
GetAutoReturnState()
RequestAutoReturn()
CancelAutoReturn()

GetWorldContentPrompt()
BeginWorldContentAction(contentId, action)
CancelWorldContentAction()
GetWorldContentActionState()

GetOwnedTreasures()
GiveOrShowTreasureToElder(treasureId)
```

HUD 不根据坐标自己算 5m/10m，不直接读写 player.story 的内部表。

### 7.3 Gameplay → Presentation

宝物区域需要从“仅透镜摘要”扩展为正式宝物列表，至少支持：

- 望远镜透镜
- 记忆碎片 01
- 记忆碎片 02
- 记忆碎片 03

显示名称可使用上述工作名；剧情正文另行补充。

## 8. Worktree 文件所有权与合并策略

### 8.1 A

A 是本轮 `Gameplay/HUD.lua` 的唯一并行修改者。

可修改：

- `Gameplay/HUD.lua`
- A 所需的最小 `Gameplay/Loop.lua`
- A 新增模块与 A 测试

### 8.2 B

B 不碰 HUD/老人/探索事务。

重点：

- AutoNavigation 新模块
- Movement / SeaRuntime
- Sol 批准的 World 小改
- B 测试

### 8.3 C

C 优先新增独立 Gameplay 模块和测试。

C 不并行修改：

- `Gameplay/HUD.lua`
- `Ocean/Movement.lua`
- B 已占用的导航代码段
### 8.4 Integration

Integration 从 A 结果作为公共 UI/Loop 基础，再接 B/C。

Integration 是以下共享接线文件的最终单一修改者：

- `Gameplay/Loop.lua`
- `Integration/Bridge.lua`
- `Integration/Scene.lua`
- `Gameplay/Persistence.lua`（如需挂 WorldContent Validate）
- `Ocean/Config.lua`
- `Ocean/World.lua`
- `Ocean/SeaDraw.lua`
- A 已完成后的 `Gameplay/HUD.lua` B/C 接口接线

推荐合入顺序：

1. A
2. B 底层导航模块
3. C 世界内容 Gameplay 模块
4. Integration 接线
5. 定向测试
6. 全量回归
7. 实机画面/操作验收

不得让 B/C 为了“方便验证 UI”提前各自改一份 HUD。

## 9. 输入与动作互斥

统一原则：

- 自动返航跨帧状态归 `Ocean/AutoNavigation`；SeaRuntime 只暴露窄接口；Bridge 只编排，Gameplay/Integration 不保存 path/waypoint/replan 等第二份状态。
- 手动点击海面导航/键盘驾驶 → 取消自动返航。
- 打开船舱 → 取消自动返航。
- 手动暂停 → 取消自动返航。
- 夜尽强返 → 取消自动返航，强返接管。
- 开始捕鱼/木桶/探索/打捞前 → 自动返航必须结束。
- 世界内容动作进行中 → 船移动目标清除或输入被阻止，沿用既有动作互斥模型。
- 透镜开关本身不暂停世界。
- 自动返航途中允许透镜继续工作；如目标真实连续处于透镜范围 1 秒，可完成 marked。
- marked 不等于自动开始打捞，仍需玩家靠近并主动点击“打捞”。

## 10. 持久化边界

当前规则：

- 正常自动保存仍只在每日结算。
- 本轮不新增海上即时存档。
- 中途退出可能丢失当天尚未日结的探索/标记/打捞进度，这是现有规则的一部分。
- 跨日需要保留：
  - 两岛 completed
  - 宝藏 marked/completed
  - 三个记忆碎片 ownership
  - 捕鱼首次提示 shown
- 新周目需要重置上述本周目状态。
- 圈2知识日志/成就的跨周目存储不由本轮碎片自动触发。

## 11. 统一测试矩阵

### UI / 老人

- 商店港内可见、海上隐藏。
- 船舱开合文案正确。
- 捕鱼提示周目内 exactly-once。
- 老人苹果计数不可见但后台判定不变。
- 老人卡 footer 精简不影响第 7 天剧情。
- 展示成功/失败对话一致。

### 自动返航

B Sol 方案落地后至少覆盖：

- 直线无障碍返航。
- 单岛阻挡绕行。
- 多障碍组合。
- 港口恰好 10m 边界。
- 再点击取消。
- 海面手动导航取消。
- 键盘接管取消。
- 船舱打开取消。
- 手动暂停取消。
- 路线不可达停止并提示。
- 连续卡住停止并提示。
- 夜尽强返抢占。
- 到港自动调用正式 ReturnToPort。
- 不传送、不额外扣体力、世界时间正常推进。
### 世界探索 / 宝藏

- 两岛空间资格。
- 岸边距离边界。
- 4 秒计时与统一暂停。
- 40 体力资格与成功扣费。
- 取消/异常回滚。
- reward exactly-once。
- 透镜 1 秒连续观察。
- 中断观察归零。
- marked 跨日。
- 打捞 5m 边界。
- stale generation。
- 读档/新周目。
- 宝物栏显示与老人展示。

### 回归

至少关注现有：

- `Circle1A3InputTests`
- `Circle1A3PortTests`
- `Circle1B3SpatialTests`
- `Circle1B2ScopeTests`
- `Circle1B2UITests`
- `Circle1B3SevenDaysTests`
- `Circle1BFishingFlowTests`
- `PersistenceRegressionSpec`
- `GameLoopUISpec`
- `Circle1HUDReviewTests`

新增测试不得通过删除旧断言来“适配”新实现；只有已明确被本需求替换的 UI 契约可以同步更新。

## 12. 明确禁止项

本轮不得顺带加入：

- 随机岛屿奖励。
- 木材/矿石/金币/补给作为 R8/R9 额外奖励。
- 随机海底宝藏刷新。
- 宝藏概率掉落。
- 新打捞小游戏。
- 透镜电量、冷却、费用。
- 自动返航传送。
- 自动返航时停。
- 重型通用导航框架，除非 Sol 证明现有轻量方案不可行并单独申请。
- 圈2图鉴/成就的正式判定。
- 新 NPC、特殊生物、天气、沉船因果链。
- ElderQA / 自由问答恢复。
- 为缺失对白自行编故事。
- 因本任务修改正式鱼价、升级价格、救人条件或昼夜数值。

## 13. 尚未阻塞实施的内容缺口

以下允许后补，不阻塞 A/C 工程能力：

- 三个记忆碎片的剧情正文。
- 逐物品老人正式对白。
- 圈2图鉴条目正文。
- 圈2记忆碎片收集成就的具体条件/文案。
- 后续更多岛屿/沉船/礁石内容。

实现必须保留“内容为空 ≠ 开发可自行补写”的边界。

## 14. 唯一主要待合入技术结论

自动返航 Sol 复核结果需要补进本文 B 章节，至少包含：

1. 最终寻路算法。
2. 算法不用其他候选的原因。
3. 障碍安全余量。
4. 路线节点生成方式。
5. 卡住判定。
6. 重规划策略。
7. 不可达失败行为。
8. 性能预算。
9. 最小修改文件。
10. B 专属测试。
## 15. Codex 各总控启动要求

每个 Worktree 启动时必须报告：

```text
TASK:
WORKTREE:
BRANCH:
BASE_HEAD:
CURRENT_HEAD:
DIRTY_BEFORE:
ALLOWED_FILES:
FORBIDDEN_FILES:
DEPENDENCIES:
```

执行要求：

- 总控先只读核实实际 HEAD 与相关代码，不把本文行号当作永恒事实。
- Luna 子代理可以并联只读分析、测试设计或互不重叠的新模块。
- 同一文件不得由多个子代理同时编辑。
- 发现需要修改允许范围外文件时停止该部分并上报，不自行扩大范围。
- 不 reset / clean / stash / checkout 覆盖他人工作。
- 不自动合入 main。
- 是否 commit/push 按项目 AGENTS.md 与用户当次授权执行。
- 自动测试通过不等于最终画面验收通过。

## 16. Integration 最终验收

自动回归之外，必须真实验证至少：

1. 出航后右下角没有港口商店。
2. 船舱按钮确实能收起。
3. 第一次捕鱼提示只出现一次。
4. 老人界面精简后仍能连续展示多件物品并看到对话。
5. 苹果救人后台计数有效但 UI 不泄露进度。
6. 海上远离港口显示自动返航；可取消。
7. 自动返航能实际绕过现有岛屿，不出现持续顶墙。
8. 自动返航进入 10m 自动完成返港。
9. 两座岛均能真实靠近并探索。
10. 透镜真实照到目标 1 秒后才标记。
11. 关透镜后标记保留。
12. 靠近标记后打捞流程可完成。
13. 三个记忆碎片出现在宝物区域。
14. 三个碎片能展示给老人且不被消费。
15. 日结→读档后状态正确；新周目正确重置。

## 17. 完成报告模板

```text
【TASK】
Branch / Worktree / HEAD:

【范围】
实际修改文件：
未修改的禁止文件：

【实现】
完成项：
明确未完成项：

【测试】
定向测试：
回归测试：
失败测试：
实机/画面验收：

【状态安全】
取消：
失败回滚：
重复执行：
读档/新周目：
world generation / stale action：

【偏差】
与本计划不同之处：
原因：
是否需要用户决策：

【Git】
是否 commit：
是否 push：
目标分支：
```

---

## 附录 A：当前状态快照

- 产品 R1–R10：除 B 算法内部技术参数外已冻结。
- D1–D5：已冻结。
- A：可直接生成开发任务单。
- C：可直接生成开发任务单。
- B：产品行为已冻结；等待 Sol 自动返航架构复核后生成最终开发任务单。
- Integration：可先按本文准备，待 B 接口确定后冻结最终接线任务。

**禁止事项：本文中的“推荐接口名”“推荐字段名”不是允许开发偏离语义的借口；若实现环境存在命名冲突，可调整名称，但状态归属、产品行为、失败边界和验收标准不得自行改变。**
