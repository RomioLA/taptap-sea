# A_NUMERIC_SUPPLEMENT_02 = PARTIAL

第二次数值补充已更新现有A-owned配置与算法，自动检查通过；尚不存在的4秒完整捕鱼动作/CompleteFishing、海上调查、港口和地点识别流程按用户第16条保留为集成契约，不扩展B-owned实现。因此总体PARTIAL不是自动测试失败。

项目：`C:\codex\taptap-sea`，渔夫漂流记，本地ID `m_009f`，Maker App `6fb01c73-66b3-4356-b987-3669be7f8a44`。doctor身份核验通过，未重新init/改绑定，未push。

## Authoritative 配置与20项核验

`scripts/Ocean/Config.lua` 的 camera/fishing/interaction/world，及 `scripts/Ocean/FishData.lua` 的物种字段是唯一执行参数来源；新实施参数为 `V1_IMPLEMENTATION_VALUE`。无旧camera.viewWidth或debug.revealRadius副本；视口宽由高度与aspect计算。20/4继续标记 `BALANCE_TARGET`。

| # | 参数/规则 | 最终值与字段 | 本轮状态 |
|---|---|---|---|
| 1 | 可视世界高度 | Config.camera.viewHeight=45m | Lua执行PASS；等价正交全高，不是半高 |
| 2 | 16:9可视宽 | 45×16/9=80m | Lua投影/逆变换PASS；横竖屏均保持高度45 |
| 3 | 最大抛网距离 | Config.fishing.maxCastDistance=30m | 从当前船检测；30包含、超过拒绝 |
| 4 | 网覆盖半径 | Config.fishing.netRadius=8m | 8包含、8.001排除；旧显式radius必须等于集中配置 |
| 5 | 单网结果 | Config.fishing.maxCatchCount=1 | selectFishingTarget返回最近有效鱼或nil，选择不直接移除 |
| 6 | 完整捕鱼动作 | Config.fishing.durationSec=4s；世界继续 | 配置/契约；未新增动作状态机或CompleteFishing。手动模拟4s时间与临时物年龄继续PASS，不等于真实4s动作验收 |
| 7 | 海上调查/打捞操作 | Config.interaction.operateDistance=5m | 契约，≤5允许执行；可见不扣体力，B决定动作体力 |
| 8 | 港口有效区域 | Config.interaction.portDistance=10m | 契约，≤10进入/交互，不要求精确点碰撞 |
| 9 | 投放最大距离 | Config.interaction.maxThrowDistance=12m | Runtime.spawnDroppedItem实际验证；12包含、12.001拒绝，无生成副作用 |
| 10 | 地点轮廓/正式识别 | Config.interaction.outlineDistance=80m、recognitionDistance=20m | 契约；>80无明确轮廓，20<d≤80未知轮廓，d≤20调用markRecognized(locationId)，B保存 |
| 11 | 沙丁鱼Avoid预判 | FishData.sardine.avoidMargin=4m | 边缘/障碍净间距4m，最高优先级，边界回归PASS |
| 12 | 金枪鱼Avoid预判 | FishData.tuna.avoidMargin=6m | 同上，提前6m；边界回归PASS |
| 13 | 初次区域生成距当前船 | FishData.sardine.minShipSpawnDistance=15m | 多seed实际生成与Runtime新区域回归PASS |
| 14 | 金枪鱼距当前船 | FishData.tuna.minShipSpawnDistance=30m | 与出发点排除同时成立PASS，生成后AI仍可游近 |
| 15 | 当日金枪鱼出发点排除 | FishData.tuna.minSpawnDistance=200m | 保留，30/200联合验证PASS |
| 16 | 透视镜局部揭示 | Config.interaction.revealRadius=20m | Runtime.revealWithScope调用固定20；20包含/外部排除PASS |
| 17 | 透视只改变visibility | 通用World.revealUnderwater仍为底层生命周期工具 | 隐藏仍可盲捕；reveal不改FSM/位置/生成/权限，PASS |
| 18 | 不恢复2条/网 | 单实体目标返回 | PASS；无批量捕获动作 |
| 19 | 不恢复240/48 | 局部期望密度20/4 | PASS；无总量/即时补满/每日捕鱼硬限 |
| 20 | 配置唯一来源 | Config/FishData | PASS；B应读这些字段，不另抄30/8/20等到gameplay config |

遵守引擎文档 `engine-docs/gotchas/camera.md`：orthoSize表示全高度，NDC乘半高；本项目无Camera组件，使用已有2D投影的viewHeight作为等价参数。SeaDraw的波浪/图形像素比例与SeaDebug视域fallback均改为从该高度派生，没有残留宽100常量。

## 鱼数值与FSM

沙丁鱼4/5/7m/s、220°/s、小鱼效应18m、危险12m保持；金枪鱼5/6/8m/s、90°/s、猎物30m、BIG36m、捕食1.5m、丢失2s保持；活动120/150滞回、TTL20s、船6/8/10、地图10×180均未改。

本次第10条明确优先级覆盖此前Attracted>Chase：**Avoid > 危险Flee/Chase > Attracted > Wander**。有活猎物或2s追猎记忆时优先Chase，无追猎目标才响应BIG诱饵。回归已从旧诱饵优先改为最新追猎优先；诱饵36m与普通猎物30m仍独立，避障继续最高。

区域生成API新增最后参数currentShipPosition，Runtime始终传当前船；低层省略时兼容按departure作为起点。生成时同时排除船15/30与当天出发点200，不把这些距离设成AI移动屏障。相同day/region seed及当前船输入可复现；不同进入位置可能影响合法初始候选，不再声称只有seed决定最终放置。无法在当前区域满足限制时允许少生成，不强制贴脸填足数量。

## B接线接口与尚待落地契约

已经真实通过Lua回归的世界接口：

```lua
runtime:canCastNet(center) -- 当前船到合法水面<=30m
local target, reason = runtime:selectFishingTarget(center, nil,
    {species={sardine=true,tuna=true}}) -- 固定网半径8m；最多单实体或nil
local drop, dropReason = runtime:spawnDroppedItem(payload, position) -- 先验证<=12m
runtime:revealWithScope(center, durationSec) -- 固定20m，duration由合法调用方提供
```

合法空网是target=nil且无拒绝reason，动作仍正常完成；超距/非合法水面则返回拒绝reason，不能确认动作。鱼数量不影响动作确认。通用queryEntitiesInRadius允许任意查询半径，它不是抛网确认或多鱼捕获；通用World.spawnDroppedItem仅是可信世界构造工具，玩家Drop必须经Runtime验证接口，B只有确认生成后才完成自己的物品事务。

还只是契约，未新增功能：

- 4秒完整动作由A世界动作层在正式接线时实现，B只负责体力/库存等事务。接口支持CompleteFishing(0)/CompleteFishing(1)；0为空网正常完成，1仅移除一个仍有效的目标；动作世界/GameClock继续，不自动pause。当前selectFishingTarget只负责合法确认与选择，不假称完整收网/自动移除已实现。
- 尚无动作快照token，当前确认从实际船位置测距，不允许调用方自由填写起点绕过。未来完整动作层应在合法确认时绑定不可替换的船起点/动作上下文，完成时验证目标和最多一个结果；不得重复完成或以任意origin绕过30m。
- 海上操作≤5m、港口≤10m、地点80/20m分层及markRecognized(locationId)没有执行流程；B提供正式实体/地点ID和回调、保存识别状态，A按集中距离检测。识别回调应只在未知→识别变化时通知，不因每帧/重新打开UI重复保存。
- 透视镜物品取得/观察点权限由B/主循环管理；A的20m显示不授权交互、不发物品。水下隐藏不禁止盲捕。

## 自动检查、preview与真实运行边界

当前Lua5.4行为 **53/53 PASS**，所有脚本语法 **21/21 PASS**，稳定性 **3/3 PASS**，实际EmmyLua **ERROR=0、缺失诊断=0**。生成、移动、FSM、时间、拒绝/选择、visibility函数均实际执行，未用静态文字替代运行测试。稳定性包含4 seed×180模拟秒、同日返回9次不补鱼和20次每日重建。

本轮没有原生窗口运行；preview status为stopped/process_alive=false，按策略未重启。前轮原生烟测与航行是历史证据，不证明当前第二补充的视觉/硬件/新接口已原生验收。DDS/DLL维持独立ENVIRONMENT_RUNTIME_ISSUE，未处理、未下载或绕过。

当前证据：`screenshots/sea-v1-logic-tests.json`、`sea-v1-stability-tests.json`、`sea-v1-lsp.json`；20项机器核查和源码指纹为 `sea-v1-supplement02-acceptance.json`。

## 修改文件与工作区

业务/适配：Ocean/Config.lua、FishData.lua、Movement.lua、Bootstrap.lua、SpawnStrategy.lua、SeaRuntime.lua、Fish.lua、SeaDraw.lua、SeaDebug.lua。测试：tests/SeaRuntimeTests.lua。文档：本报告及现有数值/决策/集成/验收报告。上述路径均位于项目scripts或docs下，旧证据保留。

共享Main、AGENTS、.project、.maker-mcp、依赖和B-owned模块未修改；既有.gitignore改动保留。所有新增模块/报告仍保留本地未提交状态，无commit/push/远端build。当前新增配置和世界接口完成，契约功能不越界扩展。
