最新第二次数值补充结果为 **A_NUMERIC_SUPPLEMENT_02=PARTIAL**，现有自动检查53/53通过，完整动作/港口/地点为契约；见 `A_NUMERIC_SUPPLEMENT_02.md`。以下继续保留前轮历史阶段，不作为当前完整功能PASS。

# 最新数值补充验收说明

当前米制、船等级、单目标选择及45项自动测试见 `SEA_RUNTIME_V1_VALUES.md` / `A_MODULE_ACCEPTANCE.md`。以下表格和原生记录保留为数值补充前的历史验收；旧视口单位定义与V1_PROVISIONAL_TUNING标签已被最新规则覆盖。

# Sea Runtime V1 — 逐项验收审计

2026-10-02按当前源代码和实际证据核验。完整人工实机验收仍为PARTIAL；本轮用户明确将DDS/DLL列为独立ENVIRONMENT_RUNTIME_ISSUE，A模块自动范围的最终结果另见 `A_MODULE_ACCEPTANCE.md`。不把自动逻辑/合成事件/绘制调用等同于硬件输入或视觉验收。

`screenshots/sea-v1-logic-tests.json`：当前Lua5.4共38/38通过，包含正式BIG参数和重叠回调移除回归。`screenshots/sea-v1-lsp.json`：实际全脚本诊断。早期33/34项与留空参数的记录保留为以下历史阶段记录，不代表最新配置；本轮38项真实引擎烟测和航行证据在 `screenshots/sea-v1-a-module-native-logs.json`。

| 原验收编号 | 要求 | 当前证据 | 结论及缺口 |
|---|---|---|---|
| 1 | Maker正常运行/preview | 最新bootstrap、首帧、38项引擎测试、180秒脚本航行；check仍报两条Runtime资源错误 | 完整预览PARTIAL；ENVIRONMENT_RUNTIME_ISSUE按本轮规则独立列示 |
| 2 | 鼠标/触摸点击移动 | 点击转换与位移测试；真实TouchBegin目标、MouseButtonDown订阅烟测 | 合成游戏事件通过；实际设备操作未验收 |
| 3 | WASD/方向键 | Bootstrap轮询八个键；轴输入/斜向/取消点击目标测试 | 逻辑通过；实际按键未验收 |
| 4 | 镜头dead-zone | viewport/anchor/inverse/deadzone/smooth-follow测试 | 逻辑通过；实际画面待人工确认 |
| 5 | 不越界，边界外仍是海 | 四边界/持续外推内推测试；SeaDraw全视口海面不按地图裁切 | 碰撞通过；边缘画面未截图验收 |
| 6 | 大型障碍阻挡/推回 | World扫掠圆防穿透，Movement内推；swept-island及push测试 | 逻辑通过 |
| 7 | 小漂浮物不阻挡 | 3秒直线经过漂浮物，位移18、overlap一次 | 通过 |
| 8 | 默认水下鱼不可见 | isVisible测试、隐藏仍可查询测试、真实首帧hidden=true | 逻辑/引擎状态通过；截图未验收 |
| 9 | Debug显示水下鱼 | 真实Debug水下/标签/感知圆帧绘制成功，visibility不改AI轨迹 | 绘制调用通过；人工视觉未验收 |
| 10 | 沙丁鱼Wander | 状态、速度及2..4秒方向间隔测试 | 通过 |
| 11 | SMALL effect吸引沙丁鱼 | effect-based attraction测试和真实场景诱饵 | 通过 |
| 12 | 金枪鱼感知并追逐 | predator-first、实时目标追踪、16种子持续模拟 | 通过 |
| 13 | 沙丁鱼靠近后逃跑 | danger优先、每帧away分量、jitter界限及16种子模拟 | 通过 |
| 14 | 真正吃掉沙丁鱼 | 初始接触移除+两鱼持续运动捕获；ID/查询/behavior/数量移除断言 | 通过；16种子捕获耗时8.5..11.6秒 |
| 15 | 大鱼感知大于小鱼危险 | FishData配置30>12及测试断言 | 通过 |
| 16 | 冻结并恢复 | 120/150滞回、冻结期间位置/state不变、恢复同一实体 | 通过 |
| 17 | 每日普通鱼重建接口 | 清鱼/临时物/reveal/区域标记，保留固定物/船；daily-refresh测试 | 通过；未新增日历或结算 |
| 18 | 暂定数值集中 | Config.ship/world/camera/debug/visual及FishData；派生地图、区域密度算法；BIG正式36/6.0 | 通过；D1/D2已决，两项仍为V1_PROVISIONAL_TUNING |

## 补充规则审计

- cwd、title、本地ID和Maker binding全部符合最终身份修正。未要求本地ID等于Maker UUID。
- Main按原始字节恢复，SHA256 `45dfcaba2a0f31975db4998debdd5929416ac6f249c5cf113b0e422ec0be6f68`；没有永久共享入口接线。Bootstrap独立注册和Stop清理；B的顺序/接口见主报告。
- 未修改AGENTS/.project/.maker-mcp/依赖配置；保留实施前的.gitignore改动。没有branch、commit、push、PR、远端build或关机操作。
- viewport宽100 world units；mapSize=10×180；没有240/48全图总量。区域只首次生成/每日重建；捕食/捕获后不会即时补鱼。
- 100 day seed快照平均：起点19.35/0；远处活跃区19.32/3.99；16:9 Debug视口2.23/0.50；默认隐藏可见0。
- D1/D2已按最新用户答复写入36/6.0，解除SKIPPED_NEEDS_DECISION；决策状态见 `SEA_RUNTIME_V1_DECISIONS.md`。以下更早阶段中的留空记载为历史记录。

## 未通过完整验收的原因

两条Runtime错误：`Could not find resource Cube/Day/DaySpecularHDR.dds`、`Can not load themis_x64.dll`。在之前场景及所有本轮预览均存在，尚未有用户确认的官方资源修复流程。

继续诊断安装包后确认：Runtime build.json版本为 `20260923-1717-bf3316f`，engine_res_tag为 `maker_validate_window.0923`；本地zip的SHA256与Maker安装记录一致，8个压缩条目中不含themis_x64.dll，当前安装目录也没有该文件。因此没有证据表明重复安装同一个包能解决DLL错误，不进行盲目重装。DDS没有单独压缩条目，但可能在资源pak内，单凭zip文件名不能断言pak内容缺失。项目scripts没有引用这两个名字，错误发生在Sea模块加载前。只读诊断证据在 `screenshots/sea-v1-runtime-resource-audit.json`。

Maker CLI 0.0.36 明确screenshots_supported=false、游戏输入/断言自动化unsupported；本会话无原生窗口控制工具。不能把进程存活、成功执行nvg调用或合成事件当作实际图像及硬件输入证明。以上缺口需人工验收或工具/运行环境能力变化后继续。

第一次新事件烟测遗漏合成鼠标payload的X/Y字段，导致现有UI处理器报错；已按UI文档补齐，并使用Variant字段值复验。该轮失败日志保留在 `screenshots/sea-v1-preview-event-before.json`；最终事件烟测仅剩上述两条原有Runtime资源错误，没有Lua失败或stack traceback。没有修改urhox-libs。

## 2026-10-02 09:14（香港时间）修复复查

用户要求确认是否修好后，重新核验身份和环境，并运行新一轮本地Sea烟测，未依赖旧session的错误作结论。新session：`9cbe502b-eb83-480f-b9ea-2772bfc19d39`；本轮09:14:39再次报告缺少DaySpecularHDR.dds和themis_x64.dll，09:14:49记录33/33逻辑通过、指针移动通过、TouchBegin目标/MouseButtonDown订阅通过、Debug帧及Reset通过。当前Runtime仍为 `20260923-1717-bf3316f`。因此实现可运行，但干净预览及人工验收阻塞尚未解除。

新证据：`screenshots/sea-v1-repair-recheck.json`。本轮没有更改玩法代码、身份绑定、依赖配置或留空参数；共享Main只用于临时烟测并在本轮结束恢复。没有push或关机。

## 2026-10-02 持续模拟验证

用户确认可在疑似官方Runtime问题未解决时继续开发/测试。本轮新增独立 `scripts/tests/SeaStabilityTests.lua` 与 `tests/run_sea_stability.py`；未改玩法代码、共享入口、身份或依赖配置。Lua 5.4三组稳定性测试全部通过，全部scripts的EmmyLua诊断ERROR=0、缺失诊断文件0。证据：`screenshots/sea-v1-stability-tests.json`、`screenshots/sea-v1-lsp.json`。

- 四个day seed各运行180秒模拟航行，从(400,400)沿200单位边长的开放海域方形路线返回，交替使用1/60、1/30、0.1秒帧间隔。每条路线均完成；逐秒核验实体ID/索引/behavior一致、有限坐标、可玩范围与障碍约束、计数一致和镜头有限值。全部累计720次人口快照，1,601,744次冻结帧检查；观察到97次捕食真实移除。期间投放的三轮小鱼吸引对象与短暂reveal全部按期清除，固定对象保留同一实例。
- 已初始化路线清空普通鱼后连续180秒航行，9次返回；区域标记保持，同日没有补鱼。
- 连续20次每日重建、每次再模拟10秒；上一日鱼/behavior、临时对象和reveal清除，固定对象和船保持同一实例，索引没有残留。

| 该航线的时间采样平均 | 沙丁鱼 | 金枪鱼 |
|---|---:|---:|
| 玩家120单位内 | 16.02 | 1.41 |
| 完整AI运行（含120/150滞回区） | 19.59 | 1.97 |
| 16:9、宽100单位Debug视口内的几何数量 | 2.24 | 0.18 |

这是特定四种子航线的时间平均，包含距当天出发点200单位内金枪鱼首次生成禁区、捕食和迁移，不能推广为全地图稳态密度，也不要求每帧补满20/4。每秒快照采样峰值为存活实体171、冻结鱼150，既不是全帧绝对峰值，也不是配置上限；被冻结鱼保留状态属于预期行为。冻结断言核对的是更新前后仍冻结的鱼之位置/state，不涵盖行为内部计时器。Debug视口数量按镜头投影采样，不是实测截图。默认无reveal/Debug时水下鱼可见数量仍为0。

本轮运行约19.8秒墙钟时间，覆盖720秒主航线模拟及额外返回/每日重建模拟；不是180秒真实窗口帧率测试。现有preview保持stopped，没有自动重启；本轮未生成新窗口证据。两条Runtime资源错误仍保留为环境问题，完整视觉和硬件输入验收仍为PARTIAL。

用户授权并联后，GPT-6 Luna + Max子代理只读复核新增测试和报告，未发现推翻通过结论的缺陷；报告按复核意见明确了每秒采样峰值与冻结断言的范围。

## 2026-10-02 生命周期修复与真实窗口持续航行

第二次GPT-6 Luna + Max审计发现 `World:updateLifecycle` 的真实缺陷：onOverlap回调同步remove实体后，原代码仍写回overlaps[id]=true，导致已移除对象的无效标记持续积累。新增连续100次回调拾取测试先复现唯一失败（34项中的1项），再以回调后检查entity.removed的最小修复通过34/34。失败证据保留在 `screenshots/sea-v1-overlap-regression-before.json`；修复后证据是当前 `sea-v1-logic-tests.json`。子代理只读复核了修复，未发现副作用。没有添加正式背包/拾取玩法，回归只调用既有通用回调和remove接口。

新增原生航行探针 `scripts/tests/SeaNativeVoyage.lua`、独立入口 `scripts/tests/SeaNativeVoyageEntry.lua`。正式Bootstrap仍不自动加载测试。第一次默认沙箱启动因CLI写用户缓存operation.lock而EPERM，尚未进入Runtime；已保留启动失败证据，并按既有本地预览授权使用宿主权限运行，没有修改环境。首个运行session `f59fb845-681e-4726-bd8f-8666182bedbb` 因审计发现上述缺陷主动停止，不能计作三分钟验收；中断证据 `sea-v1-native-voyage-interrupted.json`。

修复后新session `bc53ca61-928b-40f2-835a-b7e8385a8512`，reload=0：

- 09:53:09记录真实引擎逻辑34/34通过并开始航行，09:56:09记录NativeVoyage PASS。
- 真实Update/NanoVGRender驱动180.007秒模拟与raw timestep累计，更新/绘制各10,609次，180个人口快照；约三分钟真实日志时间。四个路点全部完成，45秒开启四种Debug绘制、135秒关闭，没有新增Lua错误或stack traceback。
- 通用索引/behavior/碰撞范围断言通过；固定对象保持同一实例；三轮临时诱饵和reveal全部清除。目标由测试脚本指定，不是硬件鼠标/触摸/键盘验收；Render回调通过也不代表截图视觉验收或GPU帧率保证。
- 该单种子航线120单位内时间平均沙丁鱼13.5722/金枪鱼2.0389，完整AI合计19.8389；每秒采样实体峰值159。与多种子初始化快照及其他帧间隔结果的统计口径不同，不用于固定数量补满或正式调参。
- 最终stopped、process_alive=false。Main在测试中临时替换为一行require("tests.SeaNativeVoyageEntry")，结束后按原始字节恢复；SHA256仍为 `45dfcaba2a0f31975db4998debdd5929416ac6f249c5cf113b0e422ec0be6f68`，最终共享入口无diff。

完整本轮日志 `screenshots/sea-v1-native-voyage-logs.json`（truncated=false）和CLI最终结果 `sea-v1-native-voyage-run.json`。CLI最终仍为FAIL，因为09:52:56再次记录同样两条DDS/DLL资源错误；不将Sea断言PASS替代干净preview。整体RESULT仍为PARTIAL，人工视觉/硬件输入及Runtime资源修复未确认。不push，不关机，不改身份/依赖配置。

## 最新A模块自动验收（D1/D2已决定）

用户已正式指定BIG感知36、速度6.0，两项保持V1_PROVISIONAL_TUNING；Attracted仍优先于Chase。按用户将DDS/DLL独立归为ENVIRONMENT_RUNTIME_ISSUE的新规则，**A_MODULE_ACCEPTANCE=PASS**：38项逻辑/引擎回归、21文件语法、实际静态ERROR=0、3组稳定性及180.011秒原生事件脚本航行全部通过，完整当前日志无其他运行错误。源码指纹及12项自动门槛见 `screenshots/sea-v1-a-module-acceptance.json`；详细五项交付报告为 `A_MODULE_ACCEPTANCE.md`。实际设备操作与视觉仍待人工，官方CLI原始FAIL结果保留，没有绕过环境问题。
