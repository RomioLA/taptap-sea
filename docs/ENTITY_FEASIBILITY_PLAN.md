# 《实体系统 M2 实施前审计指令》

## 任务性质

这是一次 **只读架构审计**。

禁止修改任何代码、数据、文档、配置、测试文件。

目标不是开始实现，而是确认当前项目能否按照：

> 《实体系统可行性方案（核心循环锚定版）》  
> FEASIBILITY_PLAN.md  
> DATA_SCHEMA.md v1.0

进入 M2 实体系统实施。

---

## 一、先确认工作区

输出：

1. 当前 branch
2. HEAD commit
3. git status -uall
4. 是否存在未提交修改
5. 当前测试入口
6. 当前 `Game/World/FSM/Systems/EntityFactory` 实际目录与文件

如果工作区不是 clean：

- 不要修改
- 明确列出冲突
- 停止实施，仅继续完成只读审计

---

# 二、架构现状侦察

重点检查以下模块：

```text
Game.World
EntityFactory
FSM
Systems
Clock
Inventory
Location
Port
Boat
WorldDrop
Events
data/
```

回答：

### 1. EntityFactory

确认：

- 当前 `kind` 机制如何注册实体
- 创建实体需要哪些字段
- 是否已经支持静态世界对象
- 是否已经存在 WorldDrop 可复用路径
- 是否存在重复 EntityFactory / Entity 创建入口

### 2. World

确认：

- Entity 生命周期在哪里管理
- update / destroy / spawn 的实际入口
- 是否已经有统一实体查询
- 是否可以支持 `drift / wreck / lighthouse / treasure / bird`

### 3. FSM

确认：

当前鱼类 FSM 的实际状态：

```text
Wander
Attracted
Flee
Chase
```

分别由哪个模块负责。

特别确认：

- Sardine Flee 是否已经存在
- Tuna Chase 是否已经存在
- 状态切换是否与表现层耦合
- 是否存在重复状态判断

### 4. Systems

确认：

哪些 System 已经存在：

```text
FishSystem
WorldDropSystem
LocationSystem
EventSystem
ClockSystem
BoatSystem
InventorySystem
```

以及：

- 海鸟应该进入哪个 System
- 漂流物是否可以复用 WorldDropSystem
- 沉船/灯塔是否需要独立 System
- 是否存在不必要的新 Manager / Service / Controller 层

原则：

> 不新增 Manager / Service / Controller Facade。

---

# 三、核对实体系统三层循环

严格按照：

```text
读海
↓
押注
↓
知识
```

检查当前架构落点。

输出一张表：

| 实体      | 当前实现 | 目标层   | 是否需要新代码 | 归属 System |
| ------- | ---- | ----- | ------- | --------- |
| Sardine |      | 押注    |         |           |
| Tuna    |      | 押注    |         |           |
| Bait    |      | 押注    |         |           |
| Apple   |      | 押注/知识 |         |           |
| 海鸟      |      | 读海    |         |           |
| 漂流物     |      | 押注    |         |           |
| 沉船      |      | 知识    |         |           |
| 灯塔      |      | 读海    |         |           |
| 宝藏      |      | 知识    |         |           |
| 老人      |      | 知识    |         |           |
| 透视镜     |      | 知识    |         |           |

如果发现某个实体无法合理归入三层：

> 标记为 ARCHITECTURE_CONFLICT

不得自行扩展玩法。

---

# 四、重点审计 R1：FSM → 水面信号

检查当前代码是否能够实现：

```text
Wander
    ↓
无明显水面信号

Attracted
    ↓
聚集涟漪

Flee
    ↓
白色散开水花
    ↓
上浮剪影 2 秒

Chase
    ↓
白色尾迹线

海鸟发现目标
    ↓
俯冲 / 盘旋
```

重点确认：

### T1

Flee 前 2 秒上浮是否可以在当前 FSM 上实现。

### T4

海鸟是否能够读取：

```text
Fish.state == Flee
AND distance(bird, fish) <= 15m
```

而不修改鱼的核心 FSM。

### T5

海鸟：

```text
Cruise 6~9m/s
发现 Flee 目标
→ Dive / Circle
→ 8~12 秒
→ 返回 Cruise
```

是否可以作为独立行为实现。

输出：

> R1 = PASS / BLOCKED

若 BLOCKED：

只指出最小阻塞点，不改架构。

---

# 五、核对 18 条 TBD

读取当前代码和 data 表，逐条判断：

```text
T1 ~ T18
```

状态只能使用：

- EXISTING
- READY
- NEED_DATA
- NEED_CODE
- ARCHITECTURE_BLOCKED
- DEFERRED

禁止自行改变设计。

特别标记：

```text
T1 逃跑上浮
T4 海鸟发现 Flee
T9 船靠近是否惊扰
T10 捕鱼效率升级
```

其中 T10 暂定：

```text
v1 DEFERRED
```

除非发现现有代码已经依赖该机制。

---

# 六、检查数据层

确认是否已经存在：

```text
scripts/data/fish.lua
scripts/data/items.lua
scripts/data/events.lua
scripts/data/upgrades.lua
```

并判断：

```text
scripts/data/worldobjects.lua
scripts/data/birds.lua
scripts/data/oldman.lua
```

是否应该新增。

要求输出：

### worldobjects.lua

最小字段建议：

```text
id
kind
position
category
interaction_radius
outline_radius
identify_radius
state
```

### birds.lua

最小字段：

```text
id
kind
cruise_speed
dive_speed
detection_radius
circle_duration
```

### oldman.lua

最小字段：

```text
item_type
feedback_text
knowledge_text
```

如果当前 DATA_SCHEMA 有冲突：

> 不修改 DATA_SCHEMA。

只报告冲突字段。

---

# 七、检查“统一 40 体力”原则

确认以下操作当前是否统一：

```text
捕鱼 = 40
打捞 = 40
事件操作 = 40
```

确认是否存在：

- 某个系统偷偷降低成本
- 捕鱼升级入口
- 事件特殊折扣
- 物品消耗导致实际成本变化

输出：

```text
OPPORTUNITY_COST = PASS / CONFLICT
```

T10 不允许自行实现。

---

# 八、检查二期内容隔离

确认以下内容没有进入 v1 主流程：

```text
鲸鱼
美人鱼
夜间生物
捕鱼效率升级
船只惊扰
漂流物↔沉船对应生成
结构物聚鱼
```

允许存在：

```text
events.lua TODO
docs TODO
```

但不得进入运行时逻辑。

---

# 九、最终输出

只输出以下结构：

## 1. 当前架构结论

```text
READY / READY_WITH_BLOCKERS / BLOCKED
```

## 2. 当前实体系统结构图

```text
Game
 └─ World
     ├─ EntityFactory
     ├─ ...
```

## 3. R1 验证

```text
PASS / BLOCKED
```

## 4. T1~T18 状态表

## 5. 需要新增的最小文件

## 6. 需要修改的现有文件

## 7. 不应该修改的文件

## 8. 架构风险

只列真正阻塞实施的问题。

## 9. 推荐下一步

给出：

```text
Step 1
Step 2
Step 3
...
```

每个 Step 必须满足：

- 单一目的
- 可独立测试
- 可独立 commit
- 修改范围明确
- 不扩大需求

---

## 十、硬性规则

1. 本任务只读。
2. 禁止修改代码。
3. 禁止修改 data。
4. 禁止修改 DATA_SCHEMA。
5. 禁止新增 Manager / Service / Controller。
6. 禁止自行实现 T10。
7. 禁止提前实现鲸鱼、美人鱼、夜间生物。
8. 禁止为了实现实体而重构现有架构。
9. 禁止改变 40 体力统一机会成本。
10. 如果发现架构问题，先报告，不自行修复。

最终目标：

> 不是“把所有实体做出来”，而是确认当前架构能够以最小增量承载实体系统，并为下一轮实施建立可验收的 Step 清单。
