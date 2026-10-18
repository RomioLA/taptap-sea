# Sea Runtime V1 A — 数值补充实施与 B 集成契约

当前已应用第二次数值补充，最新20项核查与PARTIAL契约边界见 `A_NUMERIC_SUPPLEMENT_02.md`。项目：渔夫漂流记，cwd `C:\codex\taptap-sea`，本地 ID `m_009f`，Maker App `6fb01c73-66b3-4356-b987-3669be7f8a44`。未改身份文件、共享入口或 B 模块，未 push。

## 1. A-owned 数值与配置位置

统一 **1 world unit = 1 meter**，声明在 `scripts/Ocean/Config.lua` 的 `units`；坐标 `{x,y}` 为米，速度米/秒，转向配置度/秒、实体 rotation 弧度。屏幕换算只负责投影，不缩放玩法单位。`camera.viewHeight=45` 为固定全高45米；16:9宽80米，宽度随aspect自然变化，不定义世界尺度。旧装饰场景的屏幕比例字段兼容保留，不参与 Sea Runtime 世界算法。

以下用户实施值标记 `V1_IMPLEMENTATION_VALUE`。未指定的碰撞体尺寸、视觉/Debug、模拟步长等现有配置保持；镜头全高45米已标记V1_IMPLEMENTATION_VALUE，不保留旧固定宽度配置。

| 配置文件/字段 | 当前实施值 |
|---|---|
| `Ocean.Config.ship.speedByLevel` / `defaultLevel` | Level1=6.0、Level2=8.0、Level3=10.0 m/s；默认1。`speed`兼容别名从默认等级派生，`maxSpeed`从等级表最大值派生 |
| `Config.ship.turnDegPerSec` / `arrivalRadius` | 180°/s；距离≤1.5m抵达 |
| `Config.world.travelSec` / `mapSize` / `halfSize` | 180s；maxSpeed×travelSec=1800m；半长900m；同一mapSize供方形长宽使用，无第二份独立1800常量 |
| `Config.world.visualPadding` / `pushSpeed` / `pushSec` | 100m；3.0m/s；0.3s。海面连续填满边界外取景区域 |
| `Config.camera.minX/maxX/minY/maxY/followSec` | viewHeight=45m；宽度=45×aspect；横35%～65%，纵45%～75%，平滑0.15s |
| `Config.world.temporaryLifetimeSec` | 20s；通用worldEffect仅SMALL/BIG/NONE三种；不按具体itemId驱动AI |
| `Config.world.activateRadius/freezeRadius` | 120m激活，离开150m冻结；双阈值；同日返回保留状态 |
| `Ocean.FishData.sardine` | wanderSpeed=4、attractedSpeed=5、fleeSpeed=7 m/s；turnDegPerSec=220；wanderMinSec=2/wanderMaxSec=4；fleeJitterSec=0.4/fleeJitterDeg=25；attractRadius=18m、dangerRadius=12m |
| `Ocean.FishData.tuna` | wanderSpeed=5、attractedSpeed=6、chaseSpeed=8 m/s；turnDegPerSec=90；preyRadius=30m、attractRadius=36m、eatRadius=1.5m、lostPreySec=2；minSpawnDistance=200m |
| `FishData.*.targetActiveCount/densityStatus` | 20/4；`BALANCE_TARGET`，初次区域生成的期望密度参考，不是实时补满或每日配额 |

船航行不消耗体力，A没有价格、购买、扣款或体力状态。B消费等级接口即可：初始化 `SeaBootstrap.Start({shipLevel=2,...})` 或 `Runtime.New({shipLevel=2,...})`，运行中 `runtime:SetShipLevel(3)` 返回10；非法等级报错且不修改当前能力，Reset保留当前等级。低层 `Movement:SetSpeed` 仍可在0～maxSpeed间设能力速度。

## 2. 密度与旧总量

旧240/48全地图总量逻辑未实现且无可运行分支。区域策略按活动圆面积把20/4转换为初始期望数量，再可复现随机取整、查找合法位置。此计算不是捕获配额、硬上限或目标鱼获概率；捕获、捕食、离开返回不会触发补满。只在新区域首次初始化/新一天重建生成，起点200m内允许没有新生金枪鱼。Debug显示“density reference”，避免把实际数/目标数误读为完成配额。

## 3. 金枪鱼核验

`preyRadius=30` 与 `attractRadius=36` 分别读取普通活沙丁鱼与BIG worldEffect，不互相覆盖；`attractedSpeed=6.0`。保持 Wander5 < Attracted6 < Chase8，90°/s小于沙丁鱼220°/s，本次第10条覆盖旧优先级：Chase优先于Attracted，Avoid仍最高。捕食成功真正remove，失去猎物后按2s回Wander；沙丁鱼危险感知12m明显小于猎物感知30m。

## 4. 世界侧捕鱼接口：最多一个目标

```lua
local target = runtime:selectFishingTarget(center, nil,
    {species={sardine=true,tuna=true}})
-- target 是最近有效鱼或 nil；查询包含隐藏/冻结存活鱼，不因可见性排除。
-- 此方法不移除鱼、不扣体力、不加库存；B只处理这一个目标。
if target and runtime.world:get(target.id) == target then
    -- B完成自己的动作/事务并重新验证后，最多移除此一个ID。
    runtime.world:remove(target.id, "caught")
end
```

`queryEntitiesInRadius`仍返回完整候选集，供感知、Debug和交互使用；它不是一次捕获结果。`selectFishingTarget`在候选集上按到抛网中心的距离选单目标，等距时按实体顺序稳定选择；支持字段/集合/谓词filter。第二次补充已指定网半径8m、最大抛网距离30m；从当前船检测合法水面，旧显式radius只能等于集中Config值8。范围内只有非鱼/无有效鱼/目标已移除时返回nil，即0条，允许动作继续完成。A没有一次网批量捕获实现；每日clear/refresh批量清理仅属生命周期，不计为捕获。

## 5. B负责的动作与经济契约

完整捕鱼动作仍未实现；按第二次补充A未来负责世界动作/CompleteFishing(0/1)，B仅负责体力/库存等事务。动作约4s，世界时间持续运行，不自动调用A暂停或GameClock暂停；空网也完成动作，扣40 stamina由B负责。航行0 stamina、船等级购买和金币扣除同样由B管理。B应在捕获时重新验证目标未removed、仍符合动作有效性；目标已失效则实际结果0，而非补选多鱼或阻止动作完成。

没有新增dailyFishingLimit、每日捕鱼计数器或3/6次硬上限。以下只记录 `BALANCE_TARGET`，没有编码为spawn quota、强制掉落/选择概率或次数限制：

- 前期约3次有效捕鱼/日，后期约5～6次。
- 7日一周目约30次有效机会，经济模拟参考21沙丁鱼/9金枪鱼。
- 二周目约24～26次，金枪鱼占60%～70%。

增长依赖船速、体力、食物、玩家知识和减少空网。上述结果需B整合后再观察，A不强制鱼获结构。

透视镜仍由B的固定世界位置/取得规则管理，A不新增二周目自动发放；`world:revealUnderwater`只改变显示。隐藏鱼仍可被世界查询/单目标选择/AI感知，reveal不修改交互权限或鱼行为。一周目后期发现、二周目凭现实知识Day1去已知位置取得，按集成契约记录。

## 6. 本轮验证与边界

最新结果见 `A_MODULE_ACCEPTANCE.md`、`screenshots/sea-v1-supplement02-acceptance.json`。本轮执行53项自动行为测试、所有当前Lua语法检查、3组持续稳定性、实际EmmyLua静态检查。首次数值补充新增7项，第二次再新增8项；回归覆盖各级真实1秒位移、切级/Reset/非法级、镜头取景与米制独立、最近单目标/过滤/隐藏冻结/空网/移除、8次独立捕获不设3/6上限。

预览已stopped，按本地预览策略未自动重启；共享Main本轮无改动。上一轮38项真实引擎/180秒原生航行证据为历史，不代表新增等级/捕鱼选择/第二次距离接口已过本轮原生实机验收。真实硬件输入、视觉与B捕鱼表现仍待人工/集成验证。DDS与DLL维持独立 `ENVIRONMENT_RUNTIME_ISSUE`，未处理、未下载、未绕过。
