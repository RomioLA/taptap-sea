最新第二次数值补充、20项核查及契约边界见 [A_NUMERIC_SUPPLEMENT_02.md](A_NUMERIC_SUPPLEMENT_02.md)。本页原生证据为前轮记录。

# Sea Runtime V1 — 本地交付与集成说明

> 后续用户要求直接融合现有美术：Main 现已正式调用 Ocean.FusedScene，Draw 复用太阳/船鱼/岛屿画法；此前“恢复 Main、仅 Config 永久修改”的叙述为历史状态。当前改动和验收以 [SEA_ART_FUSION.md](SEA_ART_FUSION.md) 为准。

任务：`TAPTAP-JAM-SEA-RUNTIME-V1-A`。日期：2026-10-02。

## RESULT：PARTIAL

实现及逻辑验收完成，最新数值补充已按1 world unit=1 meter、船等级6/8/10和单目标捕鱼选择更新，用户实施参数标记V1_IMPLEMENTATION_VALUE。Maker本地窗口执行真实引擎逻辑测试、指针转换/移动、合成事件、Debug绘制、Reset及脚本连续航行。本轮A模块自动验收与完整人工实机验收分别记录，最新结果见 `A_MODULE_ACCEPTANCE.md`。完整预览仍有两项独立ENVIRONMENT_RUNTIME_ISSUE，实际设备操作和画面仍待人工验证。

## 项目身份和文件边界

- 实际 cwd：`C:\codex\taptap-sea`。
- `.project/project.json`：`project_id=m_009f`，`taptap_publish.title=渔夫漂流记`。
- doctor 的 `project.projectId`：`6fb01c73-66b3-4356-b987-3669be7f8a44`，projectRoot 与 cwd 相同。
- 本地 ID 与 Maker App UUID 按用户最终规则分别核验；旧项目身份已废止。
- 未修改 AGENTS.md、.gitignore、.project/project.json、.maker-mcp/config.json、依赖/包管理配置；没有 init/clone、移动/删除项目。
- `.gitignore` 在本轮实施前已有修改，当前继续保留；它不是本次新增修改。
- 共享 `scripts/Main.lua` 仅在 preview 时追加临时注册，最终恢复原始字节。原始/恢复 SHA256：`45dfcaba2a0f31975db4998debdd5929416ac6f249c5cf113b0e422ec0be6f68`。最终入口 diff 为零。
- 没有 branch、commit、push、PR/MR、Maker 远端 build/submit。所有内容保留为本地修改。
- 未触及 B 的 PlayerState、物品数据、背包、港口、经济、结算、存档、老人或 Gameplay HUD。

## 已完成的实施步骤

1. 阅读附件、项目规则、Lua 指南/脚手架/相关示例，执行 doctor 并核验当前身份。
2. 扩展现有 Ocean.Config，保留旧装饰场景字段，新增集中配置和独立 FishData。
3. 建立 World：唯一 ID、固定/动态/临时对象、spawn/remove、空间查询、生命周期、overlap 和显示层。
4. 建立船移动和镜头：鼠标/触摸目标、键盘轴输入、有限转向、抵达判定、固定可见宽度和 dead-zone。
5. 实现连续海面、扫掠圆碰撞、岛屿阻挡、边界内推和漂浮物非阻挡。
6. 实现独立鱼实体及 Wander/Attracted/Flee/Avoid/Chase FSM、隐形感知和真实捕食。
7. 封装 day/region seed 生成策略、局部目标密度、冻结滞回和新一天重建接口。
8. 建立独立 Bootstrap、绘制模块和可折叠 Sea Debug；准备 B 的接口。
9. 运行 Lua 5.4/类型诊断/真实引擎烟测，修正持续向外按键会抵消推回的问题；恢复共享入口并整理证据。

## 新增及修改文件

唯一永久修改的既有玩法文件：`scripts/Ocean/Config.lua`。

新增：

- `scripts/Ocean/Math.lua`：数学、可复现独立 RNG。
- `scripts/Ocean/World.lua`：实体存储、碰撞、查询、临时对象、显示、生命周期。
- `scripts/Ocean/Movement.lua`：船、输入目标、镜头、坐标转换。
- `scripts/Ocean/FishData.lua`：物种参数。
- `scripts/Ocean/Fish.lua`：鱼 FSM 与感知/追逐/逃跑。
- `scripts/Ocean/SpawnStrategy.lua`：可替换区域生成。
- `scripts/Ocean/SeaRuntime.lua`：更新调度与每日普通鱼接口。
- `scripts/Ocean/SeaDraw.lua`：海面/对象/调试圆绘制。
- `scripts/Ocean/SeaDebug.lua`：开发面板及实体标签。
- `scripts/Ocean/Bootstrap.lua`：独立引擎事件注册和清理。
- `scripts/SeaPreviewEntry.lua`：独立预览入口，可选真实引擎烟测。
- `scripts/tests/SeaRuntimeTests.lua`、`scripts/tests/SeaEngineSmoke.lua`：行为测试与引擎烟测。
- `tests/run_sea_tests.py`、`tests/check_sea_lsp.py`：测试和真实 EmmyLua 诊断收集器。
- 本文及 `screenshots/sea-v1-*.json`：验收证据。

没有新增外部素材。海面、船、岛屿、鱼和 Debug 使用程序化 NanoVG 图形，文本使用现有 UI；没有在 scripts 存放图片，也没有建立新的 assets 体系。旧 Main/State/Draw/HUD 保留。

## 世界单位及集中参数

按最新用户补充统一：**1 world unit = 1 meter**。Ocean.Config.units声明米制；camera.viewHeight=45表示正交等价全高45米，宽度随aspect派生（16:9为80米），不定义世界尺度。逻辑平面x向右、y向上，屏幕投影翻转y；横竖屏均保持取景全高45米。

用户指定实施值标记 `V1_IMPLEMENTATION_VALUE`，20/4密度标记 `BALANCE_TARGET`，未指定的现有视觉/Debug调试值保留 `V1_PROVISIONAL_TUNING`；集中在 `Ocean.Config` / `Ocean.FishData`。UI 的像素布局和程序化图形轮廓比例不属于 world-unit 玩法参数。

| 配置 | 关键值 |
|---|---|
| Config.ship | speedByLevel=6/8/10，默认level1，maxSpeed由等级表派生=10，turn=180°/s，arrival=1.5，radius=1.8，start=(0,0) |
| Config.world | travelSec=180，mapSize=maxSpeed×travelSec=1800，halfSize=mapSize/2；方形地图 |
| 边界/碰撞 | 海面填充整个视口、向边界外连续延伸；visualPadding=100；pushSpeed=3，pushSec=0.3；扫掠圆阻挡 |
| 生命周期/生成 | temporaryLifetime=20，activate=120，freeze=150，regionSize=120，seed=271828，spawnAttempts=1000 |
| 更新/数值 | maxStep=0.05，maxFrame=0.25，epsilon=0.000001；暂停停止模拟 |
| Config.camera | viewHeight=45米，width=45×aspect；anchor=(50%,60%)；dead-zone x=35%..65%，y=45%..75%；followSec=0.15 |
| Config.debug | enabled=true；水下/state/perception/activity 默认 false；spawnOffset=12，baitOffset=8，refreshSec=0.25 |
| FishData.sardine | 局部目标20；Wander=4、Attracted=5、Flee=7；turn=220°/s；wander2..4s；jitter每0.4s±25°；danger12、attract18、avoid4、radius0.6 |
| FishData.tuna | 局部目标4；Wander=5、Chase=8、Attracted=6.0；BIG感知36；turn=90°/s；wander2..4s；prey30、eat1.5、lostPrey2s；首次出生距出发点≥200；avoid6、radius1.1；attractionStatus=V1_IMPLEMENTATION_VALUE |
| Config.visual / FishData 视觉字段 | 海面/船/岛/漂浮物/鱼颜色、船长宽、鱼绘制长度、波浪间隔/长度/速度 |

边界反馈期间会移除向碰撞法线外的输入分量，保留切向及向内移动，然后施加内推，避免持续外推输入抵消反馈。海面渲染不按 playable map 裁切，因此边界外仍持续显示海，不存在视觉海面终止边。

## 局部鱼密度和生命周期

没有实现 240/48 全地图固定总量。区域初始数量按目标密度与区域面积换算、可复现随机取整，再随机生成合法独立实体。只在当天首次进入未初始化区域或显式新一天刷新生成。捕获、捕食、clear 后不会补满；清空仍保留当天区域标记。

同一天离开后仍保存每条鱼的位置/状态。初生鱼冻结，进入120激活，离开150冻结，不因可见性改变 AI。新一天移除全部普通鱼、临时物品与 reveal，清空区域标记；固定岛屿/漂浮物和船对象保留。不会自行推进日历、搬动船或结算。

**测量口径：100 个 day seeds，新区域首次初始化后的快照平均；不是整天捕食后的稳态承诺，也不是人工看到的画面计数。**

| 场景 | 沙丁鱼 | 金枪鱼 |
|---|---:|---:|
| 出发点半径120 | 19.35 | 0 |
| 距离出发点较远的 (400,400)，半径120 | 19.28 | 3.94 |
| 同一远处区域实际运行完整 AI | 19.28 | 3.94 |
| 同一区域16:9宽80米/高45米，开启Debug几何可见（最新快照） | 1.16 | 0.13 |
| 默认隐藏状态真实水下鱼可见数 | 0 | 0 |

实际游玩会因移动、捕食、捕获、吸引偏离上述数量。活跃半径120显著大于16:9宽80米的视口，所以“运行的鱼数”不等于“屏幕内可见的鱼数”。

## 验证及限制

- Lua 5.4全部脚本语法检查通过，最新53/53行为测试通过。覆盖原有移动、镜头、碰撞、FSM、捕食、生命周期与密度，以及正式36/6.0配置的BIG吸引边界及30/8抛网、12投放、15/30出生排除、20揭示、效应过滤、实际转向位移、本次Chase高于Attracted、Avoid优先和诱饵过期后回到Chase。16种子持续捕食耗时8.5～11.6秒、均值10.046875秒；回调移除不残留的100次回归也继续通过。正式BIG测试使用集中配置，不再注入替代数值。
- 使用临时 `.tmp/sea-test-deps` 的 pinned `lupa==2.6` Lua 5.4，未修改项目依赖配置。
- 已安装的原生 EmmyLua LS 实际启动并收集全部 scripts 的 diagnostics；在所有依赖打开后重新分析，ERROR=0。报告保留原始诊断、配置和缺失列表，没有用禁用诊断制造 PASS。
- doctor 身份正确。Maker 自己的 Python/LSP doctor 仍显示 Python missing；测试使用 Codex bundled Python，类型检查使用已安装原生 LS，没有改 PATH 或重装全局工具。
- 上一轮Maker CLI 0.0.36 使用显式 target-dir 本地 `preview run`。本轮预览已停止，未重启；新增等级/单目标选择接口没有本轮原生实机证据。真实日志包含 bootstrap ready、first frame rendered、引擎内逻辑 PASS、pointer conversion + movement PASS、underwater + labels + perception frame PASS、reset PASS。
- Maker `preview check/run` 仍为 FAIL：`Could not find resource Cube/Day/DaySpecularHDR.dds`、`Can not load themis_x64.dll`。这两条在先前场景也存在，不能假装是干净预览，也没有修改资源配置来绕过。
- 原生截图和游戏输入/断言自动化 unsupported。引擎内调用输入处理 API 不等价于真实鼠标/触摸硬件验收；成功调用绘制不等价于人工视觉确认。相关项目标记 UNDETERMINED，等待人工验收。

证据：`screenshots/sea-v1-logic-tests.json`、`sea-v1-lsp.json`、`sea-v1-doctor.json`、`sea-v1-preview-log-round1.json`、`sea-v1-preview-engine-smoke.json`、`sea-v1-preview-final.json`。恢复后的33项引擎测试及触摸/鼠标订阅结果在 `sea-v1-preview-events-final.json`；逐项审计见 `docs/SEA_RUNTIME_V1_ACCEPTANCE.md`。测试构造鼠标事件遗漏X/Y导致的早期失败日志保留为 `sea-v1-preview-event-before.json`，已补齐并复验，不改引擎库。

## 已决设计与独立验收事项

1. **D1/D2已解除待决状态。** 正式 `attractRadius=36`、`attractedSpeed=6.0`、`attractionStatus=V1_IMPLEMENTATION_VALUE`；第二次补充已覆盖为Chase高于Attracted。当前没有SKIPPED_NEEDS_DECISION玩法项。
2. **ENVIRONMENT_RUNTIME_ISSUE与人工实机验证独立列示。** 用户明确本轮不处理DDS/DLL资源问题；未下载第三方DLL、伪造资源或修改Runtime。它们不计入本轮自动模块验收，完整实机验收仍需人工确认。

没有 SHARED_FILE_CHANGE_REQUIRED。

## 明天 B 的正式接线方式

共享入口当前不会默认进入 Sea V1。明天在正式启动流程增加：

```lua
local SeaBootstrap = require("Ocean.Bootstrap")
local sea
function Start()
    sea = SeaBootstrap.Start() -- 独立场景，默认创建开发 UI
end
function Stop()
    if sea then sea:Stop(); sea = nil end
end
```

初始化顺序：先加载 B 的物品/config及当前出发点/daySeed，再初始化世界与船、Movement，再注册更新/输入/NanoVGRender，最后建立 Sea Debug。不要同时启动旧 Main 的事件/渲染和两个 UI.SetRoot。

若已有正式共享 UI：先由主入口 UI.Init，再调用 `SeaBootstrap.Start({ ownsUI=false, debugUI=false, daySeed=..., departure={x=...,y=...} })`；这样不会替换 HUD 根节点或关闭 B 的 UI。也可直接 `require("Ocean.SeaRuntime").New(options)`，由主循环自行 Update 和主渲染调用 SeaDraw.Scene。

接口均为实例冒号方法，世界位置为 `{x=number,y=number}`，entity.rotation 为弧度：

```lua
local runtime = sea.runtime
runtime:spawnDroppedItem({itemId="...", category="...", worldEffect="ATTRACT_SMALL_FISH", lifetimeSec=20}, position)
runtime:SetShipLevel(2) -- A读取等级能力，B管理购买
local fish = runtime:selectFishingTarget(center, nil, {species={sardine=true,tuna=true}})
if fish then runtime.world:remove(fish.id, "caught") end -- B完成动作/事务并再次验证后最多移除这一条
runtime:refreshOrdinaryFish(daySeed, departure) -- B 负责日历/出港定位和调用顺序
runtime.world:revealUnderwater(center, radius, durationSec) -- 仅显示权限
runtime.world.onOverlap = function(entity, ship) end -- 测试漂浮物经过事件
```

查询包含隐藏及 frozen 的存活实体；绝不自动扣体力、加库存或结算。filter 可为字段表、字段集合或谓词。每日接口的 departure 只定义出生排除范围，B 如需换船位置，应先定位船并同步镜头，再刷新。

开发快捷键：F3面板、U水下、H状态、P感知圆、J活跃标签、1沙丁鱼、2金枪鱼、C清普通鱼、B小鱼吸引测试对象、Space暂停、R重置。发布时关闭 Config.debug.enabled，正式 UI 建议使用 ownsUI=false/debugUI=false。

## 当前工作区

保持本地修改，未提交。Main 已恢复；Config 为永久修改，新增模块/测试/报告未跟踪；原有 .gitignore 修改保留。所有 own preview run 按测试时限停止，没有保留 Sea V1 后台窗口。无需恢复身份配置或环境配置。

## 持续模拟测试补充（2026-10-02）

在用户要求继续后，新增独立稳定性测试：4个种子各180秒跨区域航行、180秒同日返回9次不补鱼、20次每日重建。三组全部通过，全部scripts实际LSP检查ERROR=0。没有更改业务逻辑、配置值、共享入口或项目身份；该阶段未定大鱼吸引参数当时留空；已被后续数值补充解除。

该航线720个时间快照中：120单位内平均16.02条沙丁鱼/1.41条金枪鱼，完整AI平均19.59/1.97（含120/150滞回），Debug视口几何数量平均2.24/0.18。起点200单位金枪鱼生成排除、捕食及迁移会使数量偏离目标，无即时补满。详细条件/边界见 `SEA_RUNTIME_V1_ACCEPTANCE.md`，原始结果见 `screenshots/sea-v1-stability-tests.json`。模拟通过不等于真实窗口性能或实际硬件输入验收，整体RESULT仍为PARTIAL。

## 原生持续运行与审计修复补充（2026-10-02）

并联审计发现并修复了重叠回调同步remove对象后留下无效overlaps键的问题，新增100次连续回调移除回归先失败后通过。最新34/34逻辑及真实引擎回归通过，子代理确认修复有效。

新独立原生测试入口由临时Main require接入，真实窗口完成180.007秒航行、四个路点、10,609次Update/NanoVGRender及Debug开关和临时对象清理，没有新增Lua错误。共享Main结束后恢复原始字节，最终无diff；两条原有Runtime资源错误仍使CLI最终FAIL，完整人工验收未完成。日志和结果：`screenshots/sea-v1-native-voyage-logs.json`、`sea-v1-native-voyage-run.json`。详细统计和证据边界见逐项验收报告。
