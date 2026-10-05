# Ocean 主航海画面美术风格替换闭环测试报告

日期：2026-10-05  
项目：渔夫漂流记  
本轮参考：`_uploads/c3fb8b9b0834ca6c098bcb452e23f0c1a899c2747c3b9787e317156cb7abd5b8.png`  
结论：**素材重新生成、替换、正式接入和已列明的原生运行测试完成；参考图风格仅部分统一，未标记美术定稿或全平台验收完成。**

用户明确否定前版效果，本轮依据新参考图改为暖赭细描边、简化色块、青蓝海水与轻水彩纸感。仅处理主航海最小素材集及对应视觉层，不新增角色、老人、灯塔、沉船、商店、背包、任务、完整捕鱼或复杂天气系统。截图中已有 UI 和玩法来自原工程，未因参考图扩大开发范围。

前轮报告与可用回退文件已保留在 `outputs/ocean-story-loop-20261005/before/`。前轮 build 6、162 条断言和全量回归属于历史结果，不作为本轮替换后的验收证据。

## 【1】完成内容

- 直接读取用户上传的本地参考图，批量生成5张源图：船、岛面、海鸥、木桶、水彩海面底纹。未使用手写素材 URL。
- 导入并替换 `assets/image/OceanLoop/` 下船、岛、海鸥、木桶、波纹、水彩底纹，共6张运行 PNG；保留独立对象，不合成一张场景大图。
- 船与海鸥统一为俯视源图，头朝世界 +X，复用原位置、旋转和投影。
- 现有天空、云、太阳、海面笔触、船尾迹、岛山树改用同一暖冷色板。
- 木桶识别态的图片主体直径从4米缩小为2.6米，仅改视觉，不改原2米碰撞半径或80/20/5米玩法距离。
- RGBA 在预乘空间缩放，保存直通 Alpha；扩展透明边 RGB，并清理生成图中的高饱和黄／洋红污染像素。
- 最终清理后重新完成8方向、跨帧动态、暂停、105/125米远岸和正常入口共13次原生运行，174/174条断言通过，运行错误0。
- 官方构建成功：入口显式 `Main.lua`、`scriptsPath="scripts"`。完整13次实跑对应 build `8`；收尾恢复同哈希资源后再次构建，当前 `dist/latest.json` 为版本 `1.0.10`、build `9`，client `ab05c1df`、server `9b9a47fb`、engine `ef9e23e2`。

完成边界：6张运行素材已实际加载和绘制，不属于“仅生成未接入”。技术闭环完成不等于用户已经认可美术效果，也不等于手机真机测试通过。

## 【2】替换素材

运行资源路径不加 `assets/` 前缀；下表文件实际位于 `assets/image/OceanLoop/`。

| 素材 | 运行路径 | 尺寸 | 导入规则／用途 |
|---|---|---|---|
| 玩家船 | `image/OceanLoop/boat.png` | 1024×512 | RGBA、中心锚点、船头 +X；主体5×2.4米，按88%留边换算画布 |
| 岛面 | `image/OceanLoop/island.png` | 1024×1024 | 米黄砂岸、灰绿中心与水彩岩石；复用原12/20米半径两座岛 |
| 海鸥 | `image/OceanLoop/gull.png` | 512×512 | 米白灰青、鸟喙 +X；保留源比例，复用原3.2米画布和俯冲缩放 |
| 木桶 | `image/OceanLoop/barrel.png` | 512×512 | 暖木与灰绿桶箍；识别态图片主体直径2.6米，原阻挡和识别规则不变 |
| 波纹 | `image/OceanLoop/ripple.png` | 512×512 | 超采样生成暖白／浅青透明弧环；Alpha 0–230，读取既有海洋时间 |
| 水彩底纹 | `image/OceanLoop/waterpaper.png` | 1024×1024 | 不透明纹理，实际合成 Alpha 0.5；镜像拼接使左右、上下边周期连续 |

6张运行图合计3,526,890字节，约3.36MiB。最终尺寸、Alpha、SHA256与 manifest 全部一致。污染检查的 `remainingBrightContamination=0` 仅代表导入脚本所定义的高饱和阈值检测通过，不代表所有颜色／边缘问题已穷尽检查。

5张新生成原图：

- `assets/image/OceanStory_boat_20261005114947.png`
- `assets/image/OceanStory_island_20261005114948.png`
- `assets/image/OceanStory_gull_20261005114946.png`
- `assets/image/OceanStory_barrel_20261005115009.png`
- `assets/image/OceanStory_waterpaper_20261005114940.png`

船源图请求768×1152，工具实际返回768×1536；导入按实际主体边界处理，最终运行规格1024×512，未假称生成尺寸与请求相同。

溯源清单：`assets/image/OceanLoop/manifest.json`。旧运行素材及本轮替换前的部分脚本保留在 `before/`；`SeaViewArt.lua`、`Draw.lua` 不在该回退副本中，不声称完整代码回退包齐备。生成源图与远端映射保留，未覆盖其他会话的独立素材包。

## 【3】修改文件

本轮修改7个已有程序／测试文件，没有新建大型 Manager、Service 或 Controller：

- `scripts/Ocean/ImageArt.lua`：增加 `waterpaper` 加载与单次 Fill 材质层；图片使用 Mipmap，底纹增加 RepeatX/RepeatY。
- `scripts/Ocean/SeaViewArt.lua`：青蓝海面与低对比暖白曲线笔触；短斜向尾迹；米黄山面和灰绿树色；保留原格网、裁剪、预算、缓存及高度遮挡。
- `scripts/Ocean/Draw.lua`：浅青天、暖白云、暖黄日及装饰鸟视觉尺寸调整；不修改实际 SurfaceSignals 行为。
- `scripts/Ocean/SeaDraw.lua`：仅缩小识别态木桶图片与其视觉波纹范围。
- `scripts/tests/OceanArtRuntimeValidate.lua`：增加水彩底纹实际加载断言；每方向15条。
- `scripts/tests/OceanArtVisualValidate.lua`：六图实际加载；动态15条、远岸12条。
- `tests/prepare_ocean_art.py`：替换源图、预乘缩放、Alpha主体清理、RGB扩边、高饱和彩点修复、波纹和周期底纹导入。

另替换6张运行 PNG、更新 manifest 和本报告；构建工具自动更新 `.project`／`dist`。没有 generic Git 提交或推送。

本轮未修改 `Main.lua`、World注册与调度、鱼FSM、移动／碰撞、Gameplay事务或策划data表。`Bootstrap.lua` 与 `Integration/Scene.lua` 的SHA对照前轮确认未变；其他受保护文件只记录了当前哈希快照，不能把该快照夸成完整前后比对。

## 【4】接入方式

正式链路保持：

`Main → Integration.Scene → Ocean.FusedScene → Ocean.Bootstrap → Ocean.SeaDraw`

- 继续纯NanoVG 2D世界投影；不新增或改变3D Camera。+X向右、+Y朝地平线、rotation=0朝+X、弧度制不变。
- Mode B仍为物理分辨率／DPR；anchor=(0.5,0.72)、viewHeight=45米、farDepth=110米、原弯地平线与深度压缩不变。
- 船／岛／桶／鸥先在世界平面旋转，再经过原 Projection／ProjectedGeometry 分片投影；保留裁剪后UV恢复，不使用屏幕平面旋转冒充任意方向世界投影。
- **水彩底纹是屏幕固定的画布材质，不是世界透视波浪。** 使用海线遮罩一次Fill，Alpha 0.5；不创建实体、不随移动作为地标漂移。实际海面笔触仍来自固定世界格网，原间距、抖动、远近过渡、1800个mark预算不变。
- 曲线笔触仅在原安全凸包内使用Bezier；边界裁剪片保留折线，避免改变海线边界。
- Wake仍读取原位移采样记录，每记录2次世界线调用；不新建采样、寿命表或调度。木桶波纹读取既有time。
- 原surfaceEntries按世界Y稳定远近排序，船不强制前景；背景、水下鱼、Wake、海面对象、雾、UI原层级保持。
- 图片只初始化加载和停止释放，重复Load／Release探针为6次创建／6次删除；重新加载累计12／12。
- 继续同一World的frame／simulation System统一调度，绘制只读。Integration未新增跨帧玩法或海洋状态。

## 【5】测试结果

### 最终真实引擎运行

使用官方 `/workspace/.cli/UrhoXRuntime`，Linux GLES + llvmpipe离屏光栅化，1280×720；不是静态拼贴，也不是纯Lua mock，更不是Android／iOS GPU实测。

| 最终运行 | 次数 | 断言 | 结果 |
|---|---:|---:|---|
| 8方向移动／旋转／暂停，150帧／次 | 8 | 120/120 | 全部PASS |
| 鸟／波纹跨帧、暂停，150帧／次 | 2 | 30/30 | 全部PASS |
| 岛中心深度105／125米，150帧／次 | 2 | 24/24 | 全部PASS |
| 不注入测试脚本的Main正常入口，40帧 | 1 | 0（引擎检查） | PASS，显示已有无云存档入口模态 |
| 合计 | **13** | **174/174** | **Lua／资源／引擎错误全部0** |

恢复同哈希六图并完成build 9后，额外实跑 `recovery-smoke` 150帧，15/15条加载／鸟与波纹动态／暂停断言通过，Lua／资源／引擎错误0。该补验单独记录，不冒充原13次全部是在build 9后重跑。累计14次运行、189条断言通过。

8方向经现有Bridge／Movement注入受控轴值与1/60秒步长：移动超过3米，朝向误差<0.06弧度，World／船／ID不变，Wake生成，暂停冻结。不是所有真实键鼠／触摸硬件事件验收。

动态报告确认现有SurfaceSignals生成两只海鸟、盘旋／俯冲跨帧变化，波纹相位0.472→0.832；暂停冻结海洋time及鸟位置／朝向／俯冲。两张动态截图取两个受控运行的第70／120帧，并结合状态断言，不将单张图当动画证明。

已读取最终八方向拼图、船／岛放大、动态两图、远岸两图、正常入口。已测画面无矩形底、无整片异常发光，海线裁剪与分片连续基础通过；放大仍有像素阶梯，不能据此宣称所有采样尺度边缘完美。

最终验收文件全部在：`outputs/ocean-story-loop-20261005/final/`。

- `evidence-index.json`：13次结果、断言、源码／资产哈希及构建版本；`media-report-hashes.json`：最终报告／日志／截图的SHA256清单。
- `direction-1..8.{json,log,png}`。
- `dynamic-a`、`dynamic-b`、`horizon-105`、`horizon-125`、`entry-normal`对应JSON／日志／图片。
- `recovery-smoke.{json,log,png}`：恢复及build 9后追加的真实引擎检查，报告和截图均已读取。
- `directions-sheet.png`、`alpha-boat.png`、`alpha-island.png`仅为内部验收图。

`runtime/`、`import.json`、导入中间拼图属于清理前阶段，不替代上述final证据。

原生报告中的 `scene_exists=false`、`scene_stalled=true`、`update_defined=false` 来自纯NanoVG没有3D Scene／全局Update；正式事件更新与运行断言通过，不把3D census字段误报成未更新。

### 回归与专项探针

本轮共尝试9套已有隔离测试，**8套通过、71项检查通过，1套超时未确定**：

- SeaMotionEffects 7、SeaFusionRender 10、SeaViewUpgrade 10。
- SeaHorizonOcclusion 13、SeaAtmosphere 7、SeaFusedScene 9。
- ArchitectureIntegration 12、Circle1A2BarrelRender 3。
- SeaStability：30秒超时，不判通过。

这些原样回归的绘制recorder走矢量fallback，不代替PNG真实引擎证据。未重跑全仓53套；前轮47/53不能写成本轮全量结论。

专项证据：

- `import-final-checks.json`：6张最终PNG尺寸／Alpha／哈希／高饱和彩点检查。
- `visual-layer-checks.json`、`architecture-barrel-checks.json`：本轮回归。
- `visual-clip-budget-probes.json`：9种视口／相机／时间组合271–648个mark≤1800；54种Wake边界组合保持每记录2次世界线调用，未发现海线泄漏。
- `image-loaded-final-probes.json`：清理高饱和彩点前的Loaded分支探针，六图生命周期、单次底纹Fill、7种深度共边UV及24朝向冒烟通过。Lua未变，可沿用几何／生命周期结论；其PNG哈希明确不是最终像素快照，不将其冒充最终素材验收。

### LSP与导入脚本

- 本轮6个修改Lua文件逐个通过 `lua_lsp_client` 诊断，Error=0。
- 全仓83文件仍有27个Error、880个Warning、184个Hint，与前轮数量一致；不是全仓清零。
- Python导入脚本语法通过；最终底纹左右／上下边像素相同，周期检查通过。

## 【6】发现并处理的问题

1. 前版偏写实木纹与新参考不一致：重新生成暖赭描边、简化色块和纸感源图，并调整实际场景色板，不仅改文件名。
2. 木桶相对5米船过大：识别态PNG主体缩为2.6米，保持碰撞、未知轮廓和玩法距离原契约。
3. Alpha连通域清理无法去除与主体相连的不透明黄／洋红杂点：增加颜色污染mask与最近干净主体RGB恢复，最终按定义的阈值剩余0；清理后完整复跑，不沿用旧截图。
4. 缩小透明图容易暗圈：预乘RGBA空间缩放，保存直通Alpha并做透明边RGB扩边；加载使用Mipmap。
5. 水彩纹理平铺易接缝：镜像拼接为周期纹理，四边像素一致。纸纹与波浪职责分离，未创建新的海洋更新链。
6. 前轮已修的字体缺失、岛高处丢失和海线UV错采保持不变，本轮不重新改动投影或装配。
7. 收尾期间正式 `OceanLoop` 派生资源目录一度不可见，生成源PNG与原生证据仍在；另一个会话只读观察到其独立派生目录也不可见。没有审计记录，原因及执行者未确定，不归因于任何会话。使用现有导入脚本恢复本轮六图，SHA256逐项与13次最终实跑素材完全一致，再次官方构建为build 9；没有恢复或覆盖其他会话素材包。

## 【7】尚未完成的美术／平台验收

- **未完全复刻参考图。** 色板与笔触已调整，但原矢量山树仍有明显三角几何感，与PNG水彩岩石不是完全同一造型语言。
- 船保留俯视、收拢帆／简化舱面的表达，便于原世界平面任意方向旋转；没有做成参考图中立起三角帆的侧视小帆船。不能据颜色一致就宣称船型完全一致。
- 水彩底纹较明显，且屏幕固定；它不提供世界透视运动。海面空间感仍依靠原格网、对象投影与动态笔触。
- 尾迹较淡，动态与暂停契约已通过，但可读性及强弱是否符合用户要求仍需美术定稿。
- 放大后的棕色描边仍有像素阶梯，微小杂色／全尺寸采样未穷尽。已测无矩形底，不等于所有透明边缘完全精修。
- 海鸟线索只有基础可读性；未新增鸟数量或AI。原UI未按参考图羊皮纸重做。
- 软件离屏较慢，逐片NanoVG提交仍有性能风险。未进行手机GPU、Android／iOS高DPR、触摸硬件或实际浏览器FPS验收，不承诺手机稳定帧率。
- SeaStability本轮超时；前轮大小写引用、旧fixture冲突和既存全仓LSP问题未在美术替换任务中修复。
- 当前环境无 `taptap-maker` 或 `maker://status`，无法执行CLI本地preview status／refresh；使用已暴露官方build与Runtime。未安装未知客户端、修改服务环境、启动dev server或擅自复活停止窗口。
- 协作Issue已读取，但无GitHub写入认证，开工／收工留言均未发布，也未形成远端冻结或解除记录。
- 其他会话的 `ReadingSeaWatercolor_v1` 是独立未接入资产包，不计入本轮6图和运行成果。

## 【8】后续建议

1. 优先依据实际画面定稿海面纸纹强度和尾迹可读性，不再以测试通过代替视觉认可。
2. 若需要完全贴近参考图，再单独确认船帆与岛山树的造型方案；保持现有视角、世界方向、真实高度和唯一World，不用侧视图直接屏幕旋转。
3. 在真实Android／iOS及浏览器运行后，检查高DPR边缘、触摸移动与GPU帧率，再决定纹理分片优化。
4. 全量回归、测试大小写、旧fixture及既存LSP问题另行处理，不混入本轮美术范围。

**最终状态：6张素材替换与已列明的原生运行技术闭环完成；美术风格定稿和手机／浏览器全平台验收仍未完成。**
