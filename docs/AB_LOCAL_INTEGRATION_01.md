# TAPTAP-SEA-AB-OFFLINE-INTEGRATION-01

AB_LOCAL_INTEGRATION = PARTIAL

离线合并、自动验收与文件保护审计通过。正式 Main 已接入 A 海面与 B Game Loop。原生预览到达集成入口与首帧，官方 run/check 返回 FAIL；保留两项环境错误以及人工验收空缺，整体不宣称实机 PASS。

## 交接与现场保护

- 实际 cwd：`C:\codex\taptap-sea`；项目：渔夫漂流记。
- 本地 project_id：`m_009f`；Maker binding：`6fb01c73-66b3-4356-b987-3669be7f8a44`。它们是不同层级的正确身份，本轮未改绑定。
- B 包：`D:\SillyTavern-Data\taptap-sea-transfer\B_TO_A_GAME_LOOP_V1_20261002_125151_787571`。HANDOFF 的 B 来源、项目、B_MODULE_ACCEPTANCE=PASS、166975 字节 patch 已核对；二次 SHA256 回读一致，无同步中临时文件。
- patch SHA256：`708f4583296325ad5a036605bdcbcd60763cfa244939a4001fbd008b7bddf179`。
- patch 为 20 个 B 新文件，含 Gameplay、Tests、B 的 config/data 和 3 份文档；没有 A Ocean/Main 或受保护工程文件。
- B parent `1e0d8c885cff36d28b2a83cd6a958a1600ed1c97` 是交接包声明的基线候选，未冒称 A 已拥有该 parent；纯新增 patch 的只读 stat/summary/check 均通过。

## 用户要求的十四项结果

| 项目 | 结果 |
|---|---|
| 1. A 合并前 SHA | checkpoint `7dfc7d6eaa5d2246057a42cebc6b4458a17e0636`；任务开始 HEAD `3baeb5bf5c5075e0a1da81fab143a8f0c88449b8` |
| 2. B 原 commit SHA | `f69ec1d09cc98ec5da999acf50bb24a5ca166162` |
| 3. 合并后 HEAD | `799415aa22074b086cb34cf0da9bb0da28132ce0`；仅 checkpoint 和 git am 已提交，后续接线仍在工作区 |
| 4. 是否冲突 | 无；`git am --3way` 成功 |
| 5. 冲突文件/处理 | 无；未使用整批 ours/theirs，B 作者 `RomioLA <romiosteam1@gmail.com>` 已保留 |
| 6. A 自动验收 | 行为 53/53、UI/event 8/8、render contract 8/8、long sail 3/3、完整语法 43/43、严格 LSP 0 Error/无缺失诊断 |
| 7. B 自动验收 | 规则 20/20、UI mock 6/6、存档 84/84、数值经济 21/21、库存 15/15、quota audit PASS；runner语法 23/23（原 B 15，加共享 Tests 内 A/AB 8）；LSP 10/10、0 Error、43 Warning |
| 8. AB 自动验收 | 29/29 PASS；覆盖附件至少 12 项以及边界、幂等、故障回滚、raw dt、UI/停止生命周期 |
| 9. 原生 preview | 30 秒限时命令；session `e9854ef3-634d-4901-a6ad-40e599e21cda`；Integration.Scene、bootstrap ready 与 first frame 日志存在；run/check 原始结果均 FAIL，预览目前已停止 |
| 10. 待人工 | HUD/太阳/海面像素与遮挡、背包/老人/特殊事件暂停、WASD/方向键/鼠标、Debug/水下、出航时钟、正式云存档；触摸 `MANUAL_TOUCH_PENDING` |
| 11. SKIPPED_NEEDS_DECISION | 附件列明的十个未定稿事项继续保留，见下文；未擅自补全流程 |
| 12. ENVIRONMENT_RUNTIME_ISSUE | `Cube/Day/DaySpecularHDR.dds`、`themis_x64.dll`；未下载随机 DLL、伪造 DDS 或修改 Runtime |
| 13. 工作区 | main；接线/测试/报告未提交；原有 .gitignore dirty 保留、未改字节；无未合并路径，diff --check PASS |
| 14. 未 push | 已确认；也未 fetch/pull、远端 build、PR/MR、reset --hard、git clean |

## 已接入的边界

`Main → Integration.Scene.Start → UI.Init/单一 root → FusedScene.Start(ownsUI=false, debugUI=false, uiFactory=...)`。B Loop/HUD 在 Ocean 注册事件前创建，Ocean.HUD.Create 不执行。A 仍拥有同一个 Update/输入/NanoVGRender 事件入口及原 SeaDraw/Draw；没有重画太阳、船、鱼、岛屿。

B Clock 是暂停及日夜权威。背包、老人、港口、特殊事件等 pause reasons 同步到 runtime.paused；HUD 操作后立即同步，指针入口再次同步。Space 与 A Debug Pause 使用 B 的 manual reason；R/Debug Reset 使用 NewRun。B 时钟接收原始 dt，A 保留自身碰撞限帧，runtime.time 只用于模拟和绘画。

海面点击沿用原航行，同时选择投放世界坐标。B 仍只交出 itemId/category/worldEffect/lifetimeSec；Bridge 在 B dropInFlight 期间调用 A spawnDroppedItem，以 A 集中配置校验 12m。无选择、非法或超距均拒绝且保留物品；无效新选择清掉旧目标。apple/bait 的 ATTRACT_SMALL_FISH、sardine 的 ATTRACT_BIG_FISH、tuna 的 NONE，以及 20s 寿命均经过真实 A/B 交接测试。

捕鱼接口是短提交事务：先 B CanStartAction('fishing') 与 HasSpace，再 A 的 30m/8m/最多1条查询，完成时 B 扣40并加包、A 移除鱼。opaque token 的重复完成重放原结果，不重复扣费、加包或移鱼；空网扣40。提交失败有回滚，取消/暂停/失活目标不收费。**这不是完整4秒动作**；当前没有新增正式捕鱼按钮或自动等4秒。未来动作完成后使用这组提交接口；若未来要跨4秒保留 token，需在正式动作设计中处理重新查询、位移与取消。

新日只从 B 保存成功的 onNewDay 触发普通动态世界刷新；保存失败和重复回调不重复刷新。seed 关系为 A 集中 base seed + day - 1；固定实体与船不删除。读档恢复 B 航速后刷新普通动态世界，NewRun 清普通鱼/临时物/导航/投放目标及 B 识别状态。A 按现有20m配置调用 RecognizeLocation，B 保存本周目识别表。普通鱼、坐标与 World/FSM 逐实体状态不入 B 快照。

## 明天与 B 的接口

| 调用 | 用途 |
|---|---|
| `Integration.Scene.Start(options)` | 初始化一次 UI，接 FusedScene；返回 `sea.bridge/loop/hud/uiRoot`；Main 已接好，无需另启 B Bootstrap/UI |
| `options.store`，`options.loadSaved=true` | 注入经过验证的 B 存档适配器并显式读档；默认离线 store 拒绝读写且 UI 提示未连云，不伪造保存成功 |
| `bridge:SetDropTarget(position)` + `loop:DropItem(index)` | A 的明确坐标选择 + B 库存投放请求 |
| `bridge:BeginFishing(center)` | 返回 opaque token 或 nil/reason；空网也有 token |
| `bridge:CompleteFishing(token)` / `CancelFishing(token)` | 成功返回 true,'caught',itemId 或 true,'empty'；不要直接传 catch count 给该实例的 Loop |
| `bridge:RecognizeLocation(id, position)` | A 距离判断后写 B 本周目识别状态；不创建地点实体 |
| `loop:ConfirmSettlement()` / `bridge:NewRun()` / `bridge:LoadSaved(callback)` | B 权威日结、新周目、读档，通过 Bridge 生命周期钩子处理 A |
| `sea:Stop()` | 幂等拆除 Ocean 5 个订阅、B HUD、NVG 与唯一 UI；不要再创建第二个 Update 驱动 |

共享文件范围：Main 仅换 require/启动停止；Ocean.Bootstrap 增加 simulationUpdate、beforePointer、onSeaPointer 与 tools.stop 钩子；SeaDebug 增加 onPause/onReset 可选回调。默认 A 独立路径的8项适配测试仍通过。其余 A 源码 SHA256 与 checkpoint 前一致，尤其 FusedScene、SeaDraw、Draw、World、Movement、Fish、SpawnStrategy 与集中配置未变。

本轮没有新增或调整玩法调参数值。世界单位仍为1 world unit = 1m；A 参数在 Ocean.Config/FishData，B 参数在 config.gameplay/data.items。Scene 的 62%/620 logical pixels 等是临时 HUD 布局实现值，保存在 Scene.lua，仍需真实分辨率验收。

## 保留事项与验证限制

SKIPPED_NEEDS_DECISION：全屏45m或有效海域45m; 岛屿视觉与碰撞轮廓对应; 船鱼最终视觉尺寸; 船上下航行最终朝向; 完整4秒抛网动作; 正式打捞流程; 正式港口流程; 地点实体完整流程; 透视镜正式物品流程; 船舱升级价格后续设计（既有B集中价格本轮未改）。已存在的 B 扩容交易测试仍照原集中配置验收，未借此修改价格。

原生 run 的两项 ERROR 都是独立环境资源/DLL问题，未阻断本轮 Integration.Scene 和首帧日志。check 在限时停止后明确返回：`Preview is stopped; retained evidence is historical and cannot prove current source correctness.`。这些日志与过程状态不证明 HUD 像素或输入操作。CLI 不支持实机截图/游戏断言，本轮没有人为点击或触摸证据。

本地 preview 正常准备官方 engine-startup/engine-res/urhox-libs 资源，并使用 loopback 提供项目文件；这不属于 Git fetch/pull 或 Maker remote build。没有手工替换 Runtime、下载第三方 DLL 或伪造资源。

离线场景默认不调用云服务，日结保存会明确失败并保持 B 的结算暂停；自动测试注入可控存档回调验证成功、失败、重试和新日刷新。真实用户云写入/恢复尚待后续验证，没有额外本地正式存档点。

诊断环境修正限于 B 的 LSP 测试脚本：取消空 resources-path，使用安装的标准库，并在依赖打开后重分析。未降低 severity。B HUD 和3份B测试只补类型说明；新 Bridge/AB测试也补了类型源头。未改 B 核心 Gameplay 规则。最初3个 AB 失败是夹具索引/按钮返回值/港口读档前提，修正后29项通过；错误没有通过放宽玩法断言掩盖。

## 证据

- `screenshots/ab-local-integration-acceptance.json`：整体验收、29条AB结果、14项交付信息。
- `screenshots/ab-local-integration-audit.json`：SHA、受保护文件、A变更白名单、Git现场。
- `screenshots/ab-integration-tests.json`、`ab-b-final-tests.txt`、`ab-b-final-lsp.json`：AB与B结果。
- `screenshots/sea-v1-logic-tests.json`、`sea-fusion-adapter-tests.json`、`sea-fusion-render-qa.json`、`sea-v1-stability-tests.json`、`sea-v1-lsp.json`：A结果。
- `screenshots/ab-native-run.json`、`ab-native-check.json`、`ab-native-logs*.json`、`ab-native-source-hashes.json`：本轮原生结果。9个关键脚本的准备副本SHA与当前工作区完全一致。
- 离线 PNG 仍为测试岛/鱼 fixture 的 SeaDraw 捕获，不含 B HUD，不能替代当前正式场景或实机截图。

本轮仅本地 checkpoint 与 git am。NO_PUSH / NO_FETCH_PULL / NO_REMOTE_BUILD / NO_PR_MR。
