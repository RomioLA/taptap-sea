# Ocean 主航海画面最小美术闭环测试报告

日期：2026-10-05  
项目：渔夫漂流记  
结论：**核心接入与原生运行验证完成；整体美术验收部分通过，不标记全部完成。**

本报告只覆盖最小主航海画面，不表示商店、背包、捕鱼、剧情、存档、天气、昼夜等全游戏功能验收。本轮没有新增这些系统；截图中已有 UI 和功能均来自原工程。

## 【1】完成内容

- 检查正式入口、场景装配、唯一 World、System 调度、资源根、NanoVG 投影与层级。
- 复用已有海面、天空、云和太阳矢量背景，不合并成背景大图。
- 生成4张透明源图，导入船、岛、海鸥、木桶；程序化生成独立透明波纹，共5张运行 PNG。
- 船使用现有 Movement 位置、世界弧度、转向、起伏与倾侧，未修改船速或碰撞。
- 岛复用已有位置与对象。使用1种岛素材，不增加岛；场景仍保留原来的2座固定岛，未为满足数量示意而删除已有岛。
- 漂浮物复用现有教学木桶；海鸟线索复用现有 SurfaceSignals，由活跃沙丁鱼派生，不另建鸟 AI。
- 木桶波纹读取现有海洋时间；船尾迹复用已有 Wake。没有新动画调度器、粒子寿命表或 Integration 动作状态。
- 最终版本完成8方向、跨帧动态、暂停、105/125米远岸及正常入口原生验证。
- 官方构建成功，显式入口 `Main.lua`、脚本目录 `scripts`。最终 `dist/latest.json` 为版本 `1.0.10`、build `6`。

完成边界：5张运行素材都已经接入并通过加载/绘制运行验证，不属于“素材已生成但未接入”。透明边缘精修、最终比例和全平台验收尚未通过，见第7节。

## 【2】新增素材

运行路径不加 `assets/` 前缀；下列文件实际位于 `assets/image/OceanLoop/`。

| 素材 | 运行路径 | 尺寸 | 导入规则/用途 |
|---|---|---|---|
| 玩家船 | `image/OceanLoop/boat.png` | 1024×512 | RGBA，中心锚点；船头朝世界+X；主体5×2.4米，画布按88%留边换算 |
| 岛面 | `image/OceanLoop/island.png` | 1024×1024 | RGBA，中心锚点；复用原12/20米半径岛，不改变阻挡边界 |
| 海鸥 | `image/OceanLoop/gull.png` | 512×512 | RGBA，鸟喙朝+X；保留源图比例；画布3.2米，实际展翼约2.82米，俯冲会压缩 |
| 木桶 | `image/OceanLoop/barrel.png` | 512×512 | RGBA，中心锚点；主体直径4米，沿用原2米半径，比例仍需优化 |
| 波纹 | `image/OceanLoop/ripple.png` | 512×512 | 程序化透明弧环；Alpha 0–235；读取现有时间做扩散/淡出 |

溯源、主体边界、Alpha 范围、透明率、SHA256：`assets/image/OceanLoop/manifest.json`。5张文件均已检查存在且哈希与 manifest 一致，总计约1.52MiB。

保留的4张生成原图：

- `assets/image/OceanLoop_boat_topdown_20261005103106.png`
- `assets/image/OceanLoop_island_topdown_20261005103049.png`
- `assets/image/OceanLoop_gull_topdown_20261005103040.png`
- `assets/image/OceanLoop_barrel_topdown_20261005103221.png`

既有 `LowPoly_v1` 素材仅作配色/构图参考，未覆盖原图和远端映射。导入脚本处理主体连通域、透明杂点、留边和朝向，但不能据Alpha数值直接宣称运行边缘视觉通过。

## 【3】修改文件

### 新增程序与测试

- `scripts/Ocean/ImageArt.lua`：只读PNG投影、加载/释放、波纹绘制；不持有Entity或推进世界。
- `scripts/tests/OceanArtRuntimeValidate.lua`：正式场景8方向移动、朝向、World/ID、Wake和暂停验证。
- `scripts/tests/OceanArtVisualValidate.lua`：海鸟/波纹跨帧、暂停、105/125米远岸验证。
- `tests/prepare_ocean_art.py`：可重复导入素材、生成波纹和manifest。
- `tests/run_ocean_art_checks.py`：复用原runner，明确扫描小写tests，逐套隔离并记录超时。

### 修改既有代码

- `scripts/Ocean/Bootstrap.lua:43`：初始化加载图片；`:163`停止前释放图片。
- `scripts/Ocean/SeaViewArt.lua:652`：替换岛面；保留原山、树、岸泡沫、几何缓存和高度遮挡。
- `scripts/Ocean/SeaViewArt.lua:788`：替换船体绘制；复用原位置/旋转/起伏/倾侧及阴影。
- `scripts/Ocean/SeaDraw.lua:45`：木桶及波纹接入；`:325`海鸥接入原排序与信号。
- `scripts/Integration/Scene.lua`：显式指定运行包已有MiSans字体，解决默认圆体缺失；未重做UI树。

`Main.lua`、World注册/调度、鱼FSM、移动/碰撞、Gameplay事务、策划data表均未因本轮美术接入修改。构建工具自动刷新 `.project` 和 `dist`；未进行generic Git提交/推送。

## 【4】接入方式

正式链路仍为：

`Main → Integration.Scene → Ocean.FusedScene → Ocean.Bootstrap → Ocean.SeaDraw`

- 不使用新的3D Camera。World +X向右、+Y朝地平线、rotation=0朝+X、弧度制全部保留。
- 逻辑分辨率仍为物理尺寸/DPR；anchor=(0.5,0.72)、viewHeight=45米、farDepth=110米、原弯地平线与深度压缩不变。
- 图片先在世界平面旋转，再分片经过现有 `Projection`/`ProjectedGeometry`。不是将固定斜视图在屏幕平面旋转。
- 世界裁剪后恢复UV，以投影三角形生成纹理仿射；地面片再裁剪到水面侧。原始网格最多8×8格，但裁剪后的扇形三角化可能增加Fill，不是严格128次Fill上限。
- 仍按现有surfaceEntries世界Y稳定远近排序，船不被强制置顶。背景/海面、水下鱼、Wake、海面对象、雾和UI的原链路保留。
- 图片缺失时保留矢量fallback。图片只在初始化加载、停止释放，重复Load/Release探针为5次创建/5次删除。
- 同一World的frame/simulation System继续统一更新。绘制不推进海洋时间、鸟状态、实体或Gameplay时钟。

## 【5】测试结果

### 实际运行证据

使用官方 `/workspace/.cli/UrhoXRuntime`，Linux GLES + llvmpipe真实离屏光栅化，1280×720。不是静态拼贴或纯Lua绘制mock，也不是手机GPU实测。

| 最终运行 | 次数 | 断言 | 结果 |
|---|---:|---:|---|
| 8个方向，150帧/次 | 8 | 112/112 | 全部PASS |
| 鸟/波纹跨帧、暂停，150帧/次 | 2 | 28/28 | 全部PASS |
| 岛中心深度105/125米，150帧/次 | 2 | 22/22 | 全部PASS |
| 无测试注入的Main正常入口，40帧 | 1 | 0（引擎检查） | PASS，显示已有无云存档入口模态 |
| 合计 | **13** | **162/162** | Lua/资源/引擎错误全部0 |

8方向经现有Bridge/Movement注入测试轴输入，船移动超过3米、朝向误差<0.06弧度，World/船/ID不变，Wake生成。不能据此宣称所有实际键鼠/触摸硬件事件都已验收。

逐图检查了最终8方向拼图、两个动态时点、105/125米远岸、正常入口及透明边缘局部放大。动态两图来自两个受控运行的不同帧，并结合实际状态变化断言，不将单张截图当动画证明。

最终证据：

- `outputs/ocean-art-loop-20261005/final/evidence-index.json`：13次报告索引、源码哈希。
- 同目录 `direction-1..8.{json,log,png}`。
- `dynamic-a-verified`、`dynamic-b-verified`、`horizon-105-verified`、`horizon-125-verified`、`entry-normal`对应JSON/日志/图片。
- `directions-sheet.png`、`alpha-detail.png`为内部检查图，不是新游戏素材。

原生引擎报告 `scene_exists=false/scene_stalled=true/update_defined=false` 来自本项目纯NanoVG、没有3D Scene或全局Update；正式事件更新、移动和跨帧断言实际通过，不能用这些3D census字段否定运行。

### 12项验收

| 项 | 检查 | 结论 |
|---:|---|---|
| 1 | 正式场景能启动、资源加载 | 通过 |
| 2 | 原视角、坐标、世界方向 | 通过，未改变 |
| 3 | 青蓝海面、浅天、云、暖黄太阳 | 通过，复用原矢量背景 |
| 4 | 岛提供空间参照、远岸遮挡 | 通过；原2座岛保留，高处不因PNG替换丢失 |
| 5 | 船移动、8方向旋转、起伏 | 通过现有移动链运行验证 |
| 6 | 船主体5×2.4米、比例与投影 | 接入契约通过；与桶/鸟的最终艺术比例待调整 |
| 7 | 木桶可见且保持原身份/玩法距离 | 通过接入；视觉尺寸偏大 |
| 8 | 实际海鸟线索出现并盘旋/俯冲 | 通过；线索可读性仅基础通过，较装饰鸟小 |
| 9 | 波纹/尾迹真实动态、暂停冻结 | 通过 |
| 10 | Alpha无矩形底、无白色整圈/异常发光 | 无矩形底通过；暗点/锯齿精修未通过 |
| 11 | 远近层级、海线裁剪、分片连续 | 已测通过；极限全场景组合不是穷尽验收 |
| 12 | 无新增更新链/注册表/渲染写状态，原生无报错 | 本轮接入通过；全仓回归不是全绿 |

### 回归与LSP

- 53套全量原样隔离测试最初45套通过；12秒上限下8套未通过。
- 未通过项60秒独立复核：Recognition5/5、A3Stability6/6通过，因此原样最终确认 **47/53套通过**。
- Experience、SeaStability仍60秒超时：**未确定**，不判通过。
- SevenDays、HUDReview、GameLoopUISpec存在 `Tests.Circle1BFishingFlowTests` 大小写引用失败。临时runner显式映射到小写tests后分别2/2、12/12、11条通过；未修改源码，不能覆盖原样失败。
- SeaRuntime51/53通过，2项失败为现有blocking木桶预避范围与旧fixture冲突，实际进入Avoid而测试期望Chase/Wander。安装禁止require ImageArt的守卫仍复现，NanoVG调用为空，已确认与本轮图片无关。
- 关键5套架构/岛遮挡/动态/木桶回归45项通过，但这些recorder走矢量fallback，不当作PNG原生证据。
- 修改/新增7个Lua文件分别LSP Error=0。全仓仍有既存27个Error（与开始时数量一致），不能报告全仓LSP全绿。

回归证据：`regression-final.json`、`review/nonpassing-followup.json`、`review/SeaRuntime-failure-steps.json`。最终PNG Loaded专测：`review/image-final-loaded.json`，海线共边差<0.00025纹理像素，24/24朝向冒烟通过。

## 【6】发现的问题

已处理：

1. 既有LowPoly固定斜视船不适合任意方向旋转：生成俯视源图，统一+X，使用世界平面投影。
2. 默认主题圆体在运行包缺失，开场文字不可见：改显式MiSans，最终运行资源错误0。
3. 初次缩略导入不放大，岛/桶主体未达88%：改主体边界resize，重新导入并复验。
4. 全岛图片提前返回会丢原山树高度：只替换岛面，保留高处、泡沫与缓存。
5. 海线附近曲线密采样与三端点仿射UV不兼容，误采透明留白：改裁剪后恢复UV再三角化，原错误点恢复RGBA=(244,218,172,255)，共边连续；原生远岸复验通过。
6. 新远岸测试曾错误要求Project返回nil：按原Visibility接口契约修测试。初失败证据保留，最终以`*-verified`为准；未为让测试通过修改投影。

## 【7】暂未解决的问题

- **透明边缘尚未完成美术验收**：放大图可见船/桶细碎暗点、局部锯齿。源图透明底成立并不等于缩小、投影、采样后的干净边缘成立，不能标记该项完成。
- 海鸟线索仍比天空装饰鸟小；木桶主体4米相对5米船偏大。比例最终定稿未通过，不为此修改碰撞/交互距离。
- 岛面绘本贴图叠加原矢量山树，功能遮挡保持，但风格尚未完全统一。
- 软件离屏运行慢，新增逐片NanoVG提交有性能风险；没有手机GPU/浏览器FPS结论，不给稳定帧率承诺。
- 未做Android/iOS高DPR、触摸硬件或实际浏览器运行验收；这些为“已接入但尚未通过该平台运行验证”。没有生成测试二维码或视频。
- 两套回归超时、三套大小写失败、SeaRuntime两项fixture冲突，以及既存全仓LSP Error未在本美术任务中修复。
- 当前环境无`taptap-maker`与maker://status，无法执行其本地preview status/refresh。未启动dev server或擅自恢复停止会话；使用已暴露的官方build和UrhoXRuntime完成本轮证据。
- 协作Issue已读取，但当前无GitHub写入认证，未能发开工/收工留言，也未形成有效远端冻结声明；不得宣称留言或解除冻结成功。

## 【8】后续建议

1. 首先只修透明边缘：检查Alpha与RGB边缘、纹理过滤和投影采样，做深/浅海底以及8方向原生局部对比。保持当前World、移动和投影不变。
2. 视觉比例独立调整：降低桶视觉直径、提高真实线索辨识度，同时保持现有radius、交互距离、AI与排序契约。
3. 将岛面与原山树统一为同一扁平绘本笔触，仍保留真实高度遮挡，勿用提前return再丢高处。
4. 选一台Android和一台iOS做1280级/高DPR实际移动、旋转、海线、暂停及GPU帧率验收，再决定图片分片优化。
5. 单独处理测试大小写与旧fixture、长跑超时、既存LSP，不混入美术比例任务。

**最终状态：素材生成、导入、正式接线和已列明的原生运行验证完成；严格透明边缘、最终比例/风格和跨平台性能尚未通过，因此整体美术闭环只能交付为部分通过。**
