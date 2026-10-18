# 原画面与 Sea Runtime 融合

> 后续按原任务逐项复核的整体结论为 PARTIAL：全屏投影45m与有效水域30.6m需区分，岛屿视觉与圆形碰撞存在偏差，展示图含测试fixture且原生画面未复验。自动检查PASS的证据范围保持；完整说明见 [SEA_ART_PROMPT_CONFORMANCE_REPORT.md](SEA_ART_PROMPT_CONFORMANCE_REPORT.md)。

2026-10-02，按用户最新要求直接把运行时融入现有 Main。此前报告中“Main 恢复、无永久接线”描述的是数值补充验收时的历史状态，本轮已被用户明确要求的正式融合取代。未提交、未 push、未远端 build。

## 画面与行为

用户截图中的素材实际上来自现有 `Ocean.Draw` 的 NanoVG 矢量绘图，未找到与截图对应的独立图片。复用原 Background/Sea/Bird/Boat/Fish/Island 绘图，保留太阳、光晕、云、飞鸟、海浪、光束、船舱/旗帜/烟囱、鱼眼/鳍/尾和棕榈岛。FishData 使用 Config.fish 的原橙色/浅绿配色。没有另画船鱼、没有生成图片或新增素材目录。

SeaDraw 负责投影真实世界实体，调用 Draw 的 SceneBackdrop / WorldBoat / WorldFish / WorldIsland；原装饰 Scene 仍兼容。船保留直立的侧视造型，水平镜像朝向；鱼按真实方向转动。浮物、临时物品、诱饵效果、目标标记和 Debug 沿用 A 的补充绘制。水中对象裁剪在海面以下，天空与太阳独立保留；绘制不修改世界实体或 AI。

HUD 和 State 文件保持原始字节。SceneState 将 HUD 的左右、暂停、重置绑定到真实 Runtime。鼠标/触摸点击海面设置世界目标，天空点击不航行，UI 命中不穿透。原标题与底部按钮保留，新增“海上调试”，默认收起调试面板；F3 开关面板，U 开关水下显示。

普通鱼默认隐藏，显示只服从 World:isVisible / 望远镜 / Debug；没有为了填满旧画面加入静态假鱼。岛屿按真实地图位置绘制，不把原装饰岛作为新碰撞对象加入正式地图。相机仍全高45米、16:9宽80米，船鱼的绘制尺寸沿用现有集中配置。本轮未改变生成密度、世界尺度、速度、碰撞、FSM 或 B 的业务数据。

## 入口与 B 接口

`scripts/Main.lua` 现在只 require Ocean.FusedScene，并在 Start/Stop 调用 FusedScene.Start()/sea:Stop()。事件、模拟、输入、绘图仍由 Ocean.Bootstrap 管理；Main 不堆放玩法逻辑。

默认 standalone 入口：`require("Ocean.FusedScene").Start(options)`。它初始化 UI → 原 HUD → 挂载 Debug → 注册 Runtime 更新/输入/绘图。

B 接管 UI 时：先 UI.Init，再 `require("Ocean.Bootstrap").Start({ownsUI=false,debugUI=false,shipLevel=...,daySeed=...,departure=...})`；若想保留融合层，可传 `FusedScene.Start({ownsUI=false,uiFactory=function(runtime,sea) ... end})`。工厂须返回 refresh(dt) 和 handleKey(key)，由 B 负责根 UI。SceneState.New(runtime,onReset) 可独立复用旧 HUD；Debug.Create(runtime,{parent=existingRoot,panelVisible=false}) 只追加，不替换既有根。

已有 runtime 捕获候选、丢弃、显示、新一天等接口不变。完整4秒捕鱼动作/CompleteFishing、港口/地点识别等仍保持之前的契约边界，本轮不扩展。

## 验证口径

最终融合自动验收 PASS：53/53 运行时、8/8 UI/事件接线、8/8 绘图契约、3/3 长航稳定性；25/25 Lua 语法通过，Maker 过滤规则后的实际 EmmyLua error=0，missingDiagnostics=0。旧 HUD/State 与 Config/World/Movement/Fish/Math/SpawnStrategy/SeaRuntime 源码哈希均与数值补充验收一致。`git diff --check` 通过。原始 LSP 诊断和 Maker 过滤结果均保留在 sea-v1-lsp.json。

机器结果见 `screenshots/sea-fusion-acceptance.json`。运行时行为、长航稳定性、实际 EmmyLua 诊断，加上新 UI/事件适配与真实 Lua 绘图捕获验收分别执行。离线 PNG/SVG 是捕获真实 SeaDraw.Scene 调用的美术预览；包含测试专用近处岛鱼，不代表正式出生分布，也不代表 Maker 原生截图。正式 Config.fixedObjects、默认隐鱼和生成规则没有被测试 fixture 改写。

当前 native preview 为 stopped；本轮未恢复窗口，实机触摸/显示与性能尚待复验。Cube/Day/DaySpecularHDR.dds 和 themis_x64.dll 保持独立 ENVIRONMENT_RUNTIME_ISSUE，未处理、下载、伪造或绕过。

## 工作区边界

cwd=C:\codex\taptap-sea；title=渔夫漂流记；local ID=m_009f；Maker binding=6fb01c73-66b3-4356-b987-3669be7f8a44。身份未修改。

本轮修改 Main、Draw、SeaDraw、Bootstrap、SeaDebug、FishData；新增 FusedScene/SceneState 和测试/报告。原 Config 玩法数值未改；HUD/State、AGENTS.md、.gitignore、.project、.maker-mcp、依赖/包配置和 B 模块均未修改。已有 .gitignore 脏改继续保留。
