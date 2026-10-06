# ART-W2-01 实施报告

日期：2026-10-06（Asia/Taipei）。工作区：`C:\codex\taptap-sea`。
本轮状态：代码和离线验证已完成；原候选副本移除及实机画面验收待人工执行。所有选择均为 `CURRENT_RUNTIME_CANDIDATE`，不代表 `FINAL_ART_SELECTION`。

## A. PRECHECK

- branch：`main`
- HEAD：`5787f1cbbb40192085fad9bc2f3e20650a8e86e6`
- 开始时已有 dirty：AGENTS.md、TEAM_FILE_BOUNDARIES.md、W1 assets/image/generated、outputs/art-wave1 和前轮测试证据；未覆盖这些修改。完整快照见 precheck.json。
- 已读任务要求的六份项目报告、六份策划、W1-01..06报告、Lua指南和三个NanoVG示例；W1-05以 final report 为当前依据，旧 partial report 仅作历史。
- 只读核对协作 Issue 最新五条留言，没有活动渲染冻结；没有发送外部留言。未执行 clean/reset/checkout/revert/commit/push 或远端构建。
- 本地预览 status 各次均为 stopped/process_alive=false，reload_id=0；未启动、复活或刷新窗口。旧 session errors 不能当作新资源运行错误。

## B. 子代理与源码所有权

- gpt-6-luna / high：93条PNG盘点、SHA/重复、W1-06资料复用、包体快照。
- gpt-6-luna / high：Pillow staging、92个尺寸选项、80个归档副本校验及迁出清单。
- gpt-6-luna / high：基线/最终自动回归、缓存边界复核、七场景离线配对基准。
- 总控：运行选择输入与生成器、Catalog生成、ImageArt元数据、SeaViewArt完整岛分支和船尺寸补偿、SeaDraw信号/夜色顺序、专项测试、正式资源与报告。子代理没有修改 scripts/，没有并行修改共享源码。

## C. 本轮接入与保留候选

接入六图：W1-01船A、沙滩植被完整岛；W1-02功能海鸟平飞/俯冲、接触波纹、大鱼普通水花。现有所有岛实体复用同一代表岛图，岛内植被/岩石随完整PNG接入；没有新增岛、地标或环境实体。
海鸟姿态只读取既有 diveProgress；水花透明度/方向尾迹只读取既有 remaining/lifetime/heading。没有新增粒子状态、计时器、鸟或鱼数量。
暂未正式接入：船B、其他三种岛、独立环境件、追猎水花及其他捕鱼反馈、小鱼跃水、水下鱼与环境、透镜装饰、港口建筑、UI/物品。未接入不等于淘汰，全部候选和旧运行资源保留。港口立面建筑需独立确认Upright锚点，不强行塞入Planar。
维护输入：`docs/art-runtime-selection.json` → `tests/prepare_ocean_ready_art.py --wave2` → `assets/image/OceanWave2/manifest.json` + `scripts/GeneratedData/OceanImageCatalog.lua`。Catalog未手工维护。生成器从outputs归档源导入，检查SHA并采用预乘Alpha Lanczos/PNG optimize，不进行侵蚀或颜色量化。

## D. 正式运行图尺寸与体积

| Catalog名 | 来源 | 原尺寸 / B | 运行尺寸 / B | 节省 |
|---|---|---:|---:|---:|
| boat | ART-W1-01 / `ship_fishing_sloop_A.png` | 768×512 / 395,307 | 640×427 / 235,532 | 40.4% |
| island | ART-W1-01 / `island_sandy_green_cove.png` | 1024×1024 / 1,567,197 | 768×768 / 769,917 | 50.9% |
| gull | ART-W1-02 / `seabird_glide.png` | 512×512 / 158,795 | 384×384 / 73,017 | 54.0% |
| gull_dive | ART-W1-02 / `seabird_dive.png` | 512×512 / 181,304 | 384×384 / 92,628 | 48.9% |
| ripple | ART-W1-02 / `ripple_small.png` | 256×256 / 51,872 | 256×256 / 49,072 | 5.4% |
| splash | ART-W1-02 / `bigfish_splash_roaming.png` | 256×256 / 30,823 | 256×256 / 29,480 | 4.4% |

正式新增六图合计 1,249,646 B；所选源图合计 2,385,298 B。
768岛图为769,917 B，超过500,000 B软目标；保留水彩细节，未为追求数十KB损坏Alpha/降色。其他正式小图及船均在对应软预算内。四岛768与1024候选均留在outputs staging，不把所有选项放入运行树。
已读取正式岛与船图：PNG透明留边保留，轮廓/细节可见；源图细白边仍存在，不据静态图宣称实际青蓝海面无白边。透明像素和bounds经Pillow检查，运行时以Sprite补偿可见主体尺寸；PNG alpha没有成为碰撞数据。

## E. 岛屿视觉替换与游戏几何

- completeIsland=true 且Sprite绘制成功：在旧几何缓存构造之前返回；不再画两层程序岛岸/沙滩填充描边、山体、树木、装饰岸边泡沫和烘进图内的静态装饰。A的旧PNG原本已经关闭底面填充/描边；本轮新增收益主要来自山体/树/泡沫及相关几何构造。
- 保留：原实体、位置/半径、岛屿碰撞、船阻挡、地点/世界规则、broad-phase可见性、稳定世界Y排序、ImageArt.Plane网格、Projection裁剪/地平线。
- 未加载/失败：仍走原静态弱键缓存、保守剔除、流式描边和同步投影参数复用的完整矢量fallback。未删除该路径，未回退此前优化。
- 只在完整图成功时关闭其程序视觉；未修改Projection、ProjectedGeometry、World、Movement、Fish、SurfaceSignals、Config等玩法/投影源码。逐文件HEAD一致哈希见verification.json。岛图不规则轮廓与圆形逻辑碰撞仍需靠岛人工检查，不通过调整碰撞迁就PNG。

## F. A/B性能

A=本轮前快照 + 原PNG加载 + 原山/树/泡沫；B=本轮高规格PNG加载 + 完整岛视觉替换。两边均验证实际PNG路径存在、返回整数句柄（A6/B8张）。
Lua5.4，1920×1080，同种子/相机，预热后交替4×32帧；Python process_time测进程CPU，perf_counter测elapsed；GC暂停期间测临时分配。NanoVG为计数空绑定，不包含图片解码/上传、原生细分、GPU、UI或GC停顿。NVG调用/Fill数量不等于GPU draw call。

| 场景 | CPU A→B ms/帧 | elapsed A→B ms/帧 | 临时分配 A→B KiB | NVG API A→B | Fill A→B | 世界描边 A→B |
|---|---:|---:|---:|---:|---:|---:|
| near_full | 4.39→1.95 | 4.29→1.90 | 744.6→385.7 | 3550.0→1536.0 | 276.0→128.0 | 138.0→0.0 |
| left_edge | 1.95→1.22 | 2.03→1.29 | 394.5→303.7 | 1183.0→732.0 | 112.0→61.0 | 48.0→0.0 |
| horizon_crossing | 4.39→1.95 | 4.28→1.98 | 784.3→445.2 | 2851.0→1433.0 | 184.0→88.0 | 86.0→0.0 |
| small_island | 3.91→1.95 | 3.79→1.79 | 645.1→359.5 | 3217.0→1536.0 | 276.0→128.0 | 138.0→0.0 |
| offscreen | 0.24→0.00 | 0.29→0.01 | 49.8→5.0 | 2.0→0.0 | 0.0→0.0 | 0.0→0.0 |
| port_scene | 18.80→13.92 | 18.71→14.16 | 2448.0→1756.6 | 9930.0→6344.0 | 658.0→370.0 | 276.0→0.0 |
| port_scene_drift | 18.55→13.43 | 18.61→13.57 | 2401.7→1693.4 | 9664.9→6027.0 | 633.2→334.6 | 278.8→0.0 |

完整可见岛的算法CPU约减少55.6%、分配约减少48.2%；近港Scene约减少26.0%/28.2%。Windows进程CPU计时分辨率与负载影响近似百分比；offscreen B=0表示低于计时分辨率，不称无限性能或100%实机收益。离线数据不能当作FPS提升。
`REAL_DEVICE_FPS = NOT_MEASURED`。实际入画流畅度、视觉缺失和GPU尚待手动验收。

## G. 包体Gate与SOURCE_ASSET_RELOCATION

| 范围 | 修改前 B | 修改后 B |
|---|---:|---:|
| assets | 70,510,771 | 71,765,138 |
| assets/image | 41,161,430 | 42,415,797 |
| assets/generated | 14,735,371 | 14,735,371 |
| scripts | 1,541,267 | 1,551,115 |
| assets + scripts | 72,052,038 | 73,316,253 |

当前原始资源树超出十进制60MB：13,316,253 B。
用户明确选择手动移除：80份源候选/sidecar已归档并SHA验证，原副本仍在assets；本轮实际释放0 B。待移除可释放 16,978,913 B，完成后预计资源树 56,337,340 B（距离60MB仍有 3,662,660 B余量）。这是当前资源树估算，后续代码/资源变化需重测。
明确阻塞文件见 MANUAL_SOURCE_RELOCATION.md（80条原路径、归档、字节、SHA及引用检查）和 package-after.json。没有批量删除脚本；本轮没有改asset_ignores或资源扫描根，没有排除未知旧资源。
主要其余占用：旧image候选/正式资源、audio目录约14.61MB（含约6.43MB的sea_exploration_sfx.zip）、未知generated资产；本轮没有删除或重新调查/筛选这些素材。正式归档压缩、转码、去重和实际发布包大小为UNKNOWN，未执行远端构建。
`NEW_RUNTIME_ASSETS_ARE_BUDGETED = YES`（含岛图明确软预算例外）；`SOURCE_CANDIDATES_NOT_ACCIDENTALLY_PACKAGED = NO`（上述80条仍阻塞）。

## H. 回归与画面验收

- 基线53/54套、514报告子检查；最终54/55套、521报告子检查；新增失败0。不是全仓全绿。
- 唯一失败：SeaRuntimeTests:359 predator sees prey before sardine senses danger；:394 tuna chase tracks moved prey/loss grace >2sec；与基线名称和位置一致，未为过测改鱼规则。
- Catalog8、SeaFusionRender10、ArtWave2新增7全通过。后者实际跑Plane UV/裁剪、完整岛跳过描边、warm位置/半径/视口变化、加载失败回退、24朝向船旋转、夜色覆盖世界PNG和可见水下鱼、图片释放平衡。图片采样接口是宿主stub，不是原生PNG像素证明。
- 全量原套件涵盖岛碰撞/移动/捕鱼/信号/鱼群/透镜/港口回港/昼夜/暂停/存档；两项捕食基线失败仍保留。
- 本轮前后fallback缓存专项15场景、31次绘制，坐标差0px。历史before-island-fix快照的旧色板与当前基线不匹配，历史verifier尝试结果保留，不用它宣称新夜色回归；改用本轮准确快照验证，未覆盖旧performance证据。
- 导入--check与归档SHA检查通过；Python源语法解析、git diff --check通过。未运行LSP（现有脚本硬编码其他用户目录）；未安装依赖或重配引擎。
- GUI/截图/真机FPS/远端发布包：NOT_RUN。按预览停止策略与用户UI额度规则，留给人工。

### 人工画面验收（按顺序）

从项目根双击 `本地测试.cmd`；这是用户主动启动本地预览，会加载当前资源。日志应出现 `image/OceanWave2/` 的boat/island/gull/gull_dive/ripple/splash加载记录，而不是只见旧OceanLoop路径。

| 场景 | 预期/关注 | 本轮实机证据 |
|---|---|---|
| 港口附近 | 高规格船/岛进入主画面，港口标记可读 | UNDETERMINED / 待手动 |
| 船出航并转一圈 | 船头连续转向，透明边不裁切，尾迹沿既有运动 | UNDETERMINED / 待手动 |
| 岛从边缘进入 | 无突跳、地平线漏片、明显入画卡顿 | UNDETERMINED / 待手动 |
| 完整岛可见 | 不叠旧山/树/岸泡沫；无矩形底/漂浮感/奇怪投影 | UNDETERMINED / 待手动 |
| 船靠近岛屿 | 仍阻挡船，不从视觉凹口穿入逻辑岛 | UNDETERMINED / 待手动 |
| 白天→黄昏时段→夜晚 | 世界岛/船/水花/水下内容获得夜色；UI和港口导航保持可读；既有时钟仅day/night，无新黄昏状态 | UNDETERMINED / 待手动 |
| 海鸟/水花 | 俯冲与盘旋可辨，水花尾迹指向近期经过方向，背景不吞信号 | UNDETERMINED / 待手动 |
| 开启透镜后暂停 | 原前向揭示与持续开关可用，水下与世界均暂停，显示不改AI | UNDETERMINED / 待手动 |

最近距离重点观察源图细白边/暗边、岛PNG轮廓与圆形碰撞的视觉距离；发现问题请提供场景、时间点、截图及对应加载日志。先确认新路径已加载再改资产。

## I. 最终状态

```text
ART_W2_01_IMPLEMENTATION = PARTIAL
RUNTIME_ART_INTEGRATION = PARTIAL (代码/离线分支PASS，原生画面待验)
ISLAND_VECTOR_VISUAL_REPLACEMENT = PASS (绘制路径与fallback已验证；实机画面UNDETERMINED)
GAMEPLAY_GEOMETRY_PRESERVED = YES
SOURCE_CANDIDATES_OUTSIDE_PACKAGE_ROOT = PARTIAL
PACKAGE_60MB_STATUS = OVER (原始扫描资源树；实际构建包UNKNOWN)
REAL_DEVICE_FPS_MEASURED = NO
```

待人工收口：逐文件移除已校验原副本后重新统计；按8项画面清单验收。未选素材、旧正式素材、候选映射全部保留，不宣布美术定稿。

## 复跑与证据

PowerShell 7使用已有Python（PATH无python，不需要安装）：

```powershell
$artPython = 'C:\Users\Administrator.DESKTOP-NS4I6RF\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
Set-Location 'C:\codex\taptap-sea'
& $artPython tests/prepare_ocean_ready_art.py --wave2
& $artPython tests/prepare_ocean_ready_art.py --check
& $artPython tests/verify_art_wave2.py
& $artPython tests/run_circle1_review.py --phase final --output-dir outputs/art-wave2/ART-W2-01/regression
& $artPython outputs/art-wave2/ART-W2-01/benchmark_islands.py
```

Lua宿主读取旧.tmp/circle1-review-runtime在Codex沙箱内需要已批准的读取权限；本轮经正常审批执行，没有借插件绕过。
证据：asset-map.json/md；runtime-staging/staging-map.json与relocation-plan.json；正式OceanWave2/manifest.json；benchmark.json；regression/{baseline,final}.json；island-cache-w2.json；package-before/after.json；preview-final.json；verification.json；单文件回退点before/。
