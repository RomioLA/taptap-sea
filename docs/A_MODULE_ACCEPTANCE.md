# Sea Runtime V1 — A 数值补充验收

> 最新画面融合已按用户要求永久接入 Main；下面数值验收和 native 证据是融合前记录。当前入口、原画面复用与最新自动结果见 [SEA_ART_FUSION.md](SEA_ART_FUSION.md) 和 `screenshots/sea-fusion-acceptance.json`。完整捕鱼动作等契约边界保持。

**现有模块自动检查 PASS；A_NUMERIC_SUPPLEMENT_02 = PARTIAL。** 后者包含尚未实现、按用户指示仅保留契约的动作/地点/港口功能，最新20项报告为 `A_NUMERIC_SUPPLEMENT_02.md`。

本轮以用户数值补充为准，完整配置表与七项核查见 `SEA_RUNTIME_V1_VALUES.md`。自动验收覆盖当前纯Lua行为/语法、稳定性和静态检查；本轮未重启已停止的预览，前轮原生烟测与180秒航行仅作为历史证据。最新机器证据为 `screenshots/sea-v1-supplement02-acceptance.json`。

## 1. 自动测试

当前53/53行为回归（两次数值补充分别新增7和8项）、21/21 Lua语法、3/3稳定性全部通过；实际EmmyLua静态错误0、缺失诊断0。最终数目与源码指纹见机器证据。53项覆盖等级6/8/10的实际1秒位移、动态切级/Reset保留/非法级不变、镜头取景与米制位移独立、最近单鱼/过滤/隐藏冻结/空网/已移除排除、8次独立捕获不受3/6限制。原有移动/碰撞/FSM/36吸引与30猎物区分/生命周期/同日不补鱼回归继续执行。

## 2. 待人工实机与 B 集成验证

真实鼠标/触摸/键盘、镜头dead-zone与边界推回、Debug及BIG吸引画面仍待确认；新增等级切换/单目标选择需要集成后原生验证。抛网半径8m与最大距离30m已确定并实现验证，仍待原生操作验收。4秒A世界动作/CompleteFishing尚未实现，仅为契约；世界不暂停，空网40体力由B负责。

## 3. ENVIRONMENT_RUNTIME_ISSUE

`Cube/Day/DaySpecularHDR.dds`、`themis_x64.dll`保留前轮错误证据；官方前轮preview结果仍FAIL。本轮没有重新运行预览或诊断/修复这两项，没有下载DLL、伪造资源或修改Runtime。

## 4. B 的正式集成接口

`require("Ocean.Bootstrap")` → `SeaBootstrap.Start(options)` → `sea:Stop()`。B已有UI时先UI.Init，再Start({ownsUI=false,debugUI=false,shipLevel=...,daySeed=...,departure=...})。A初始化世界/船/Movement、区域，再注册更新/输入/绘制。共享Main没有永久接线。

- `runtime:SetShipLevel(level)`：只设置6/8/10速度能力，B负责购买金币；航行不扣体力。
- `runtime:selectFishingTarget(center, nil, filter)`：验证当前船30m，固定网半径8m，最近有效鱼或nil，不移除、不扣体力、不加库存。B完成动作/事务并再次验证后 `runtime.world:remove(target.id,"caught")`，最多一个目标；nil允许动作完成。
- `runtime:queryEntitiesInRadius(...)`：仍提供完整候选集，供AI/Debug/交互使用，不直接算捕获结果。
- `runtime:spawnDroppedItem(payload,position)`：按worldEffect，不按具体itemId；验证12m，默认20秒；失败返回nil/reason。
- `runtime:refreshOrdinaryFish(daySeed,departure)`：B负责日历与出港位置，不自动移船/结算。
- `runtime:revealWithScope(center,durationSec)`：固定20m，仅显示，不改变AI/交互权限或发放道具。
- `runtime.world.onOverlap`：非阻挡对象经过回调，可同步移除。

## 5. 工作区

cwd=C:\codex\taptap-sea，title=渔夫漂流记，local project_id=m_009f，Maker App=6fb01c73-66b3-4356-b987-3669be7f8a44，doctor核验通过。共享Main本轮未改；AGENTS、.project、.maker-mcp、依赖和B模块未改。原有.gitignore修改保留，新模块/测试/报告仍在本地，未提交、未push、未远端build；preview stopped。米制与实施参数的配置在Ocean.Config/FishData；BALANCE_TARGET未编码为捕获次数/日配额或鱼获结构概率。
