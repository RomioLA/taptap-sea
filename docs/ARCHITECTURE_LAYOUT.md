# 渔夫漂流记目录与职责约定

本批仅同步 AGENTS.md 项目级约定和本说明；程序接入另批验收交付。本说明是目录职责约定，不表示共享版本已经实现全部玩法。

## 策划依据

2026-10-02 策划工作簿 Sheet1「阿木策划记录」作为 V1 基线。Sheet5、Sheet6 是未定过程稿，后续整理为 V2 后再确认。目录扩展不构成对候选数值、老人救法、宝藏内容或捕鱼规则的实现授权。

## 保留骨架，按职责增加模块

```text
scripts/
├── Main.lua               # Maker 生命周期、场景接线
├── Game/
│   ├── Game.lua           # 协调整局更新与暂停同步
│   └── World.lua          # Entity 注册、生命周期、System 调度
├── Entities/
│   └── EntityFactory.lua  # 创建轻量 Entity 数据对象
├── FSM/
│   └── StateMachine.lua   # enter/update/exit 与状态切换
├── Systems/
│   └── EntityStateSystem.lua # 带 FSM 的对象更新
├── Ocean/                 # 海洋世界、船鱼行为、生成、查询与绘制
├── Gameplay/              # 玩家体力、背包、交易、升级、昼夜与保存
├── Integration/           # 场景装配、输入转发、跨模块事务
└── GeneratedData/         # 由根 data/ 同步生成的运行时资源副本
data/                      # 策划可编辑的纯数据源
docs/                      # 数据契约、架构约定和交付说明
```

原有 Game、Entities、FSM、Systems 继续承担通用骨架职责。Ocean 按海洋玩法扩展；Gameplay 集中玩家规则，Integration 连接两侧接口。不引入完整 ECS 或重型继承，不为尚未确认的功能建立空模块。

Ocean/World 在 Game/World 的同一个运行实例上扩展碰撞、空间查询和临时物生命周期，只有一套 Entity 集合与 ID 索引。海洋旧接口通过兼容方法保留。FSM 自动更新统一由 EntityStateSystem 调度，保留海洋现有子步长，避免同一条鱼重复更新。

Game 使用 Gameplay 的玩家状态和时钟，不再复制一份。Integration 负责鱼获入包、投放确认、新日通知等事务，整局更新委托 Game。重置后从当前 Runtime 取 World，避免引用旧世界。

Ocean/Config.lua 保留现有海洋参数接口；Ocean/State.lua 等演示模块保留兼容。正式场景只启动一条更新链、一个 UI 根。Draw 读取状态，HUD 通过公开接口操作游戏；具体输入与绘制适配可由场景层承接，Main 保持接线职责。

## 数据编辑边界

允许修改根目录 data/ 下仅含数据表和注释的 .lua 文件；禁止函数、逻辑和 require。字段与格式遵守 docs/DATA_SCHEMA.md，不新增字段，缺契约先确认；数值变更注明策划参数表行号或平衡目标来源。

数据助手仅创建或修改 data/、docs/；不修改 scripts/、.project/、Config.lua 或程序逻辑。本批架构约定同步不扩大数据编辑权限。其他参数表缺少契约时暂不迁移。

Maker 资源根为 assets/scripts。GeneratedData 是程序任务生成的运行时副本，不手工编辑；程序接入任务同步后检查数据一致性，再进行独立验收与交付。

## 后续程序验收

检查对象身份与 ID 稳定、更新不重复、暂停与冻结、新日清理、同日状态保留、捕鱼失败回滚、重置后的世界引用。自动检查与真实运行验收分别记录，未验收的玩法不写成已完成。
