# DATA_SCHEMA — 数据层契约（定稿 v1.0）

- 发布人：A（核心代码负责人）；发布日期：2026-10-02。
- 阅读对象：B（数据/内容负责人，Codex 辅助）。
- 用途：`data/` 目录所有数据表的唯一格式依据。**本文件由 A 维护；B 发现字段不够用时提需求，不得自行改字段名或新增字段。**

---

## 0. 总规则

### 与远端数据接口的兼容约定

根 `data/` 为可编辑纯数据源；`tests/sync_runtime_data.py` 生成 `scripts/GeneratedData/` 运行时副本，可用 `--check` 验证一致性。`scripts/data/items.lua` 是 Gameplay 的 `GetDefinition` 适配接口，不能用远端同名纯数组覆盖。此次对比远端物品/鱼表与根数据内容一致，不额外建立 `scripts/data/fish.lua` 或另一份数据源。下列 v1 数值表不表示新版策划已经完整实现；新增或变更规则仍需逐条核对当前确认稿。

1. `data/` 是**纯数据**：只有 Lua 表和注释，不写函数、不写逻辑、不 require 其他文件。
2. 字段名、类型、枚举值必须与本文件完全一致；不确定就停下问 A。
3. 每条数据的注释里注明**来源**：策划参数表的行名，或平衡目标表（例：`-- 来源：参数表「Sardine物品」`）。
4. 数值单位：距离/速度 = 米、米/秒；时间 = 秒；角度 = 度；钱 = coins；体力 = stamina。
5. 「没有该功能」一律用 `nil`（省略字段），不要填 0 或 -1 之类的魔法值。
6. 提交前过一遍第 7 节自检清单。

---

## 1. `data/items.lua` — 物品表

### 字段定义

| 字段 | 类型 | 必填 | 说明 | 约束 |
|---|---|---|---|---|
| `id` | string | ✅ | 唯一标识，全小写 | 不与鱼 id 冲突 |
| `name` | string | ✅ | HUD/弹窗显示名 | |
| `category` | enum | ✅ | `fish` / `food` / `bait` / `treasure` / `misc` | **不用 category 驱动鱼 AI**，仅分类 |
| `buy` | number | 商店物品 | 商店进价 | 非商店物品省略 |
| `sell` | number | 可出售物品 | 卖出价 | 不可出售省略 |
| `heal` | number | 可食用 | 食用恢复体力 | 由代码 clamp 到 maxStamina |
| `worldEffect` | enum | ✅ | `ATTRACT_SMALL_FISH` / `ATTRACT_BIG_FISH` / `NONE` | 投海后的生态作用 |
| `worldDuration` | number | ✅ | 投海后存在秒数 | v1 统一 20 |
| `shopStockPerDay` | number | 商店物品 | 每日可购买数量，新一天补回 | 非商店物品省略 |
| `protected` | boolean | 关键物品 | `true`=关键物品：**不可丢弃、不可投掷、不可出售**（整体出售自动跳过并保留在船舱，代码给明确解释、不消耗物品）；使用与交给在场老人是否允许由内容卡决定 | 省略=普通物品；v1 基准表暂无条目，圈2 事件内容卡新增关键剧情道具时置 `true`（依据 03 页关键物品保护规则、05 页"关键剧情物品暂不可卖掉或丢弃"） |
| `description` | string | 建议 | 一句话描述（老人/弹窗用） | |

### 基准数据（已按参数表录入 `data/items.lua`，B 负责后续校对与扩充宝藏条目）

| id | category | buy | sell | heal | worldEffect | worldDuration | shopStock | 来源 |
|---|---|---|---|---|---|---|---|---|
| apple | food | 30 | — | 20 | ATTRACT_SMALL_FISH | 20 | 2 | 「Apple」「Apple商店库存」 |
| bait | bait | 20 | — | — | ATTRACT_SMALL_FISH | 20 | 2 | 「Bait」「Bait商店库存」 |
| sardine | fish | — | 70 | 10 | ATTRACT_BIG_FISH | 20 | — | 「Sardine物品」 |
| tuna | fish | — | 120 | 20 | NONE | 20 | — | 「Tuna物品」 |

注意两条隐性规则（写代码时会消费）：
- Sardine 的 `worldEffect=ATTRACT_BIG_FISH`：**捕获的小鱼投海就是大鱼诱饵**，这是食物链进背包的关键。
- Apple 给老人不产生体力收益（老人交互代码处理，数据层不需要额外字段）。

### 宝藏条目（category=treasure）

不设统一售价。每个宝藏单独定义 `sell` 或能力字段；第一条宝藏等 M3 任务下发后添加，格式届时在本文档追加。

---

## 2. `data/fish.lua` — 鱼种表

### 字段定义

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | ✅ | 唯一标识；被捕获后生成同 id 的物品（items.lua 里必须存在） |
| `name` | string | ✅ | 显示名 |
| `speeds.wander` | number | ✅ | 游荡速度 m/s |
| `speeds.attracted` | number | 有吸引响应 | 被诱饵吸引时的移动速度 |
| `speeds.flee` | number | 被捕食者 | 逃跑速度 |
| `speeds.chase` | number | 捕食者 | 追猎速度 |
| `turnRate` | number | ✅ | 转向速率 °/s |
| `attractedBy` | enum | 有吸引响应 | 响应哪种 `worldEffect`（与 items 的枚举对应） |
| `sense.attract` | number | 有吸引响应 | 感知吸引源半径 m |
| `sense.danger` | number | 被捕食者 | 感知危险（捕食者）半径 m |
| `sense.prey` | number | 捕食者 | 感知活体猎物半径 m |
| `avoid.predict` | number | ✅ | 避障预判距离 m |
| `avoid.steerInterval` | number | 被捕食者 | 逃跑偏转间隔秒 |
| `avoid.steerDeviation` | number | 被捕食者 | 每次偏转最大角度（±°），最终方向仍须远离危险 |
| `predation.contact` | number | 捕食者 | 咬住猎物的接触距离 m |
| `predation.loseTargetAfter` | number | 捕食者 | 丢失猎物多少秒后回 Wander |
| `spawn.minDistFromBoat` | number | ✅ | 生成瞬间离船最小距离 m（仅约束生成瞬间） |
| `spawn.minDistFromDayStart` | number | 可选 | 离当天出发点最小距离 m |
| `ai.fullRange` / `ai.freezeRange` | number | ✅ | 完整 AI 半径 / 冻结半径（双阈值防抖） |

### 基准数据（已按参数表录入 `data/fish.lua`）

| 字段 | sardine | tuna | 来源 |
|---|---|---|---|
| speeds | w4 / a5 / f7 / — | w5 / a6 / — / c8 | 「Sardine移动」「Tuna移动」，保持 5<6<8 |
| turnRate | 220 | 90 | 同上 |
| attractedBy | ATTRACT_SMALL_FISH | ATTRACT_BIG_FISH | 「Sardine感知」「Tuna大鱼诱饵感知」 |
| sense | attract 18 / danger 12 | attract 36 / prey 30 | 危险感知故意短：30>12 使 Tuna 先发现 Sardine |
| avoid | predict 4 / 每 0.4s ±25° | predict 6 | 「Sardine逃跑」「Tuna避障」 |
| predation | — | contact 1.5 / lose 2 | 「捕食」 |
| spawn | 离船≥15 | 离船≥30、离出发点≥200 | 「区域生成防贴脸」「Tuna新日生成限制」 |
| ai | 120 / 150 | 120 / 150 | 「离屏对象」 |

**不在本表的鱼相关参数**（属代码侧 Config.lua，A 负责）：Wander 换向区间 2~4s、区域目标密度 20 Sardine / 4 Tuna、普通鱼每日刷新规则。

---

## 3. `data/events.lua` — 事件表

### 字段定义

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | ✅ | 唯一标识 |
| `name` | string | ✅ | 显示名 |
| `trigger.type` | enum | ✅ | v1 仅 `proximity` |
| `trigger.pos` | {x,y} | ✅ | 世界坐标（米），1800×1800 地图内 |
| `trigger.radius` | number | ✅ | 进入该半径触发**免费**观察（发现本身不处罚玩家） |
| `observeText` | string | ✅ | 观察描述——玩家据此推测是否值得花体力 |
| `options[]` | table | ✅ | 至少含一个「离开」选项 |
| `options[].text` | string | ✅ | 选项文案 |
| `options[].staminaCost` | number | ✅ | 0 = 免费；实际操作类通常 40 |
| `options[].interactRadius` | number | 实操选项 | 执行该选项需要的靠近距离 m |
| `options[].resultText` | string | 有结果时 | 执行后的结果描述 |
| `options[].reward` | table | 实操选项 | `{ money=, items={id,...}, flag= }`，至少一项非空 |
| `once` | boolean | ✅ | 处理成功后是否永久消失（同周目） |
| `ngPlusResult` | table | 二周目内容 | 二周目新结果，M5 阶段填写，v1 留空 |

### 硬性设计约束（来自策划案，验收时会检查）

1. **reward 必须非空**：花 40 不能"什么都没有"——钱、物品、能力、flag（后续剧情钥匙）至少给一样。
2. 触发与观察**免费**；只有玩家主动选择实操选项才扣体力。
3. 事件结果不要写成固定掉率；文本要给玩家"可倒推的因果"。
4. 总事件池 v1 约 10 个，共用同一事件池（一二周目不分开建表）。

### 示例条目（格式示范，坐标为占位，正式坐标由 A 结合世界布局给出）

```lua
{
  id = "driftwood_barrel",
  name = "漂流木桶",
  trigger = { type = "proximity", pos = { x = 400, y = 300 }, radius = 30 },
  observeText = "海面上漂着一只半沉的木桶，隐约能看见里面的东西。",
  options = {
    { text = "靠近打捞", staminaCost = 40, interactRadius = 5,
      resultText = "你把木桶捞上船，里面有几份用得上的东西。",
      reward = { items = { "bait", "apple" } } },
    { text = "离开", staminaCost = 0 },
  },
  once = true,
},
```

---

## 4. `scripts/data/narrative.lua` — 剧情叙事表（Q-006 命运链，2026-10-05 新增）

- **数据链口径**：与 events 同款**单表链**——B 直接编辑本文件，无根 `data/` 基准、无 sync 生成（纯文案无数值生成逻辑，不走 fish/items 双表链）。
- **加载代码由 A 维护**（剧情接入时提供）；B1 阶段 B 只录数据。

### 分组结构（顶层四组，勿改名）

| 组 | 内容 | 对应策划 |
|---|---|---|
| `hints` | 苹果条件的玩家感知线索（老人或环境提示，引导玩家注意到"给苹果"这件事） | 05 页 §苹果条件 |
| `symptoms` | 老人病征线索（第 4 天判定前的状态描写） | 05 页 §病征 |
| `branchDialogues` | 第 4~7 天按 applesGiven/decision 分支的老人对白 | 05 页 §分支对白 |
| `endings` | 两种结局正文（`saved` / `dead`），多段 lines | 05 页 §两种结局 |

### 字段定义（按组）

```lua
return {
  hints = {
    { id = "hint_apple_1", day = 1, speaker = "elder",
      text = "……" },
  },
  symptoms = {
    { id = "symptom_1", day = 4, speaker = "elder",
      text = "……" },
  },
  branchDialogues = {
    { id = "branch_d4_low", day = 4, applesGiven = 1, speaker = "elder",
      text = "……" },
  },
  endings = {
    saved = { lines = { "段1", "段2" } },
    dead  = { lines = { "段1", "段2" } },
  },
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | ✅ | 组内唯一，全小写下划线 |
| `day` | number | hints/symptoms/branch ✅ | 关联天数 1~7 |
| `applesGiven` | number | branchDialogues ✅ | 该分支对应的累计苹果数（0~3） |
| `speaker` | string | ✅ | v1 仅 `elder`，预留扩展 |
| `text` | string | 除 endings 外 ✅ | 单段正文 |
| `lines` | table | endings ✅ | 结局多段正文，按序展示 |

### 硬性设计约束（来自策划案与用户裁决，验收会检查）

1. **病因不得擅加**：病征只写状态描写，不得出现病名、药物或其他救援因果（Q-006 边界）。
2. **纸条不录本表**：第 7 天纸条已有定稿（05 页原文），由既有 storyDialog 通道承载，避免双源。
3. 苹果判定硬约束（3 苹果、第 4 天判定）由代码保证，文案不得改写数值口径。
4. 文案给玩家"可倒推的因果"：线索要能让玩家在二周目凭知识改变行为。
5. 每条数据带来源注释（同总规则）。

## 5. `scripts/data/content.lua` — 世界固定内容表

本表是 fixed content 的唯一 authored 数据来源，必须是纯 Lua 数据：只有表和注释，不写函数、不写逻辑、不 `require`。

顶层 `fixed` 是稳定顺序数组；本轮正式记录仅有 `island_01`、`island_02`、`underwater_treasure_01`。所有坐标和关系属于世界定义，NewRun 不重写、不随机化。

| 字段 | 类型 | 必填 | 说明 | 约束 |
|---|---|---|---|---|
| `contentId` | string | ✅ | 固定内容稳定身份 | 同表唯一 |
| `entityType` | string | ✅ | 内容实体类型 | `island`、`treasure`、`wreck`、`reef`、`coral`；后 3 种本轮仅为 capability/fixture，不新增正式实例 |
| `kind` | string | ✅ | 世界实体 kind | 当前 fixed content 为 `fixed` |
| `position` | `{x:number,y:number}` | 有条件 | authored 世界位置 | 与 `at` 互斥；NewRun 前后不变 |
| `radius` | number | ✅ | 内容范围半径，米 | `>= 0` |
| `layer` | string | ✅ | 海面或水下层 | `surface` / `underwater` |
| `blocking` | boolean | ✅ | 是否阻挡航行 | 必须保持既有 V2.6 行为 |
| `actionKind` | string | 有条件 | 现有 Gameplay 操作类型 | 当前正式值为 `explore` / `salvage` |
| `rewardId` | string | 有条件 | 现有直接 ownership 奖励字段 | 不扩展正式奖励体系；三枚 memory 不进入 Inventory |
| `markable` | boolean | 有条件 | 是否支持 Mark | 只有明确支持标记的内容才为 true |
| `at` | table | 有条件 | 宝藏容器关系 | 仅用于 `entityType=treasure`；`at.kind` 只允许 `island` / `wreck`；`at.contentId` 指定已注册且类型匹配的固定容器 |
| `localOffset` | `{x:number,y:number}` | 有条件 | 相对容器中心的 authored 偏移，米 | 仅使用偏移时必须显式提供；省略表示容器中心；禁止运行时随机偏移 |
| `keyRequired` | string | 可选 | 打捞所需 key ID | 无钥匙时必须在开始打捞前拒绝，不扣体力、不开始动作 |
| `consumeKey` | boolean | 有条件 | 成功后是否消耗 key | 配置 `keyRequired` 时必填；不得有默认值；未配置 `keyRequired` 时省略 |
| `revealMethod` | string | 有条件 | key source 的发现方式 | 仅允许 `lens`；复用现有 scope 连续 1 秒 Mark，不新增计时器 |

`position` 与 `at` 必须且只能配置一个；`localOffset` 只能与 `at` 同用。`at` 不得创建或移动容器；容器必须先以匹配的 `contentId` 和 `entityType` 注册。偏移是 authored 的 x/y 相对位移，省略时宝藏位于容器中心，运行时不得随机生成或改写位置。Key source 的获取必须另有显式 action，并同时写明 `kind`、`duration`、`staminaCost`；Mark 只表示发现位置，不表示取得 key。珊瑚/礁石只注册和查询，可参与常规 location/scope 查询；不自动产生掉落、售价、heal、材料价值或鱼群吸引效果。

本轮 `underwater_treasure_01` 必须保留绝对位置、`keyRequired=nil` 和现有 V2.6 流程。不得新增正式沉船、宝藏、reef、coral、key source 或奖励。

## 6. 变更流程

1. B 发现缺字段/缺表 → 在群里说明「哪张表、哪个字段、为什么、来源哪条设计」。
2. A 修改本文件与加载代码 → 发布新版本号。
3. B 再填数据。**B 不得通过改 `scripts/` 来"适配"自己的数据。**

## 7. B 提交前自检清单

- [ ] 只改了 `data/` 和 `docs/` 下的文件（`git diff --stat` 确认）
- [ ] 字段名与本文档逐字一致；没有新增字段
- [ ] 每条数据有来源注释
- [ ] 枚举值拼写正确（`ATTRACT_SMALL_FISH` 不是 `attract_small_fish`）
- [ ] Lua 表能通过 `lua -e "loadfile('data/items.lua')"` 类语法检查（或让 Codex 做语法自检）
- [ ] 事件 reward 非空；实操选项 staminaCost 已填
- [ ] narrative 表四组键齐全（hints/symptoms/branchDialogues/endings），endings 含 saved 与 dead 两键
- [ ] 提交信息写明：改了哪张表、动了几条数据
