# 渔夫漂流记目录与职责约定

本文规定目录职责、状态归属与调度要求，不描述实施进度。下列目录图是职责划分，不作为仓库文件清单；具体实现须单独审查验收。

## 策划依据

2026-10-02 策划工作簿 Sheet1「阿木策划记录」作为 V1 基线。Sheet5、Sheet6 是未定过程稿，后续整理为 V2 后再确认。目录扩展不构成对候选数值、老人救法、宝藏内容或捕鱼规则的实现授权。

## 目录职责约定

```text
scripts/
├── Main.lua               # Maker 生命周期、场景接线
├── Game/
│   ├── Game.lua           # 发起整局更新与暂停同步
│   └── World.lua          # Entity 注册、生命周期、System 调度
├── Entities/
│   └── EntityFactory.lua  # 创建轻量 Entity 数据对象
├── FSM/
│   └── StateMachine.lua   # enter/update/exit 与状态切换
├── Systems/
│   └── EntityStateSystem.lua # 带 FSM 的对象更新
├── Ocean/                 # 海洋世界、船鱼行为、生成、查询与绘制
├── Gameplay/              # 玩家体力、背包、交易、升级、昼夜与保存
├── Integration/           # 场景装配、输入转发、跨模块事务编排
└── GeneratedData/         # 由根 data/ 同步生成的运行时资源副本
data/                      # 策划可编辑的纯数据源
docs/                      # 数据契约、架构约定和交付说明
```

Game、Entities、FSM、Systems 应承担通用骨架职责。Ocean 应承接海洋能力；Gameplay 应集中玩家规则，Integration 应连接两侧接口。不引入完整 ECS 或重型继承，不为尚未确认的功能建立空模块。

## 两个 World 的扩展关系

保留 `Game/World.lua` 与 `Ocean/World.lua` 两个模块名，引用时应明确写出 `Game.World` 与 `Ocean.World`。Game.World 应负责通用实体注册、生命周期与 System 调度；Ocean.World 应通过模块委托或浅层扩展复用同一实例的实体集合、ID 索引和调度器，只增加海洋碰撞、空间查询、临时物生命周期与揭示能力。不得建立第二套注册表或调度器；需要兼容海洋调用时应提供公开适配方法。

## 状态归属与 Integration 边界

玩家体力、库存、昼夜、保存及捕鱼事务记录、待处理动作、投放目标等玩法状态应归 Gameplay；海洋实体与空间状态应归 Ocean/World。临时动作状态不据此新增存档字段。

Integration 只能做装配、转发与事务编排：调用 Gameplay 完成玩法状态修改或回滚，调用 Ocean/World 完成实体修改或恢复。不得持有跨帧玩法状态、捕鱼令牌表或待处理目标，不得直接写玩家字段、实体索引或对象集合。允许持有模块引用、回调、界面布局信息，以及一次同步调用内的临时变量；它们不能成为第二份玩法状态。

Game 应使用 Gameplay 持有的玩家状态和时钟，不另建副本。换日与重置时应从当前 Runtime 获取 World，避免保留旧世界引用。

## 统一调度要求

Gameplay 的周期更新须封装为 System，经 `World:AddSystem` 注册，由同一个 World 调度器执行；Game 应发起整局更新，Integration 应转发到 Game，不得在调度链之外重复调用 Gameplay.Update。

调度须区分每帧更新与海洋子步更新：Gameplay 每帧使用完整帧时间，昼夜时钟只推进一次；海洋模拟应保留步长与帧时间限制，EntityStateSystem 应在海洋子步中更新鱼 FSM。不得把昼夜计时放入每个海洋子步，也不得因海洋停止更新而跳过玩法层必要的暂停与强制返港判定。Gameplay 判定与暂停同步须先于本帧海洋模拟。

正式场景应只有一条整局更新链、一个 UI 根。Ocean/Config.lua 应保留海洋参数接口，Ocean/State.lua 等演示模块不得与正式场景同时运行。Draw 应读取状态，HUD 应通过公开接口操作游戏；输入与绘制适配可由场景层承接，Main 应保持生命周期与接线职责。

## 数据编辑边界

允许修改根目录 data/ 下仅含数据表和注释的 .lua 文件；禁止函数、逻辑和 require。字段与格式遵守 docs/DATA_SCHEMA.md，不新增字段，缺契约先确认；数值变更注明策划参数表行号或平衡目标来源。

数据助手仅创建或修改 data/、docs/；不修改 scripts/、.project/、Config.lua 或程序逻辑。架构约定不扩大数据编辑权限。其他参数表缺少契约时不得迁移。

数据接入应遵守 Maker 项目配置的资源目录。需要运行时副本时，应由程序工具从根 data/ 同步到 scripts/GeneratedData/，不得手工编辑副本；程序任务须提供同步与一致性检查工具，检查通过后再预览或构建。此职责约定不证明副本目录或工具已存在。

## 程序验收要求

须检查对象身份与 ID 稳定、完整帧计时与海洋子步不混用、更新不重复、暂停与冻结、新日清理、同日状态保留、捕鱼失败回滚、重置后的世界引用，以及 Integration 不持有玩法状态或越界写状态。实施进度与自动检查、真实运行验收结果应另存对应交付记录，不写入本约定。
