# ART-W1-04 美术资产交付报告

日期：2026-10-06  
项目：C:\codex\taptap-sea  
交付目录：assets/generated/highspec/ART-W1-04/

## 交付概况

- Maker MCP 0.0.36：世界图生成 6/6，UI 图生成 4/4。
- 交付 25 张 PNG：世界资产 6 张，UI 资产 19 张。
- 全部保留透明背景。环境图缩为 384px 级以满足体积预算；按钮图集和 HUD 图集拆成单独图标文件。HUD 图集中的重复日轮格未输出，体力使用独立闪电刻度图标。
- 没有生成本地 `.meta` sidecar；每张 Maker 原图的预览 URL 列在后文，供追溯原始生成结果。
- 总体积：世界 1,251,248 B（1.19 MiB）；UI 1,557,151 B（1.48 MiB）；合计 2,808,399 B（2.68 MiB）。

## 世界资产

| 资产 | 尺寸 | PNG 字节 | Maker 原图 |
|---|---:|---:|---|
| ARTW104_世界_木码头_T形_20261005160008.png | 384×384 | 154,242 | [预览](https://tapcode-sce.spark.xd.com/tapcode-images/0000b505-9fca-4a77-8762-9c2aa10245df.png) |
| ARTW104_世界_小渔舍_20261005160008.png | 384×384 | 214,074 | [预览](https://tapcode-sce.spark.xd.com/tapcode-images/7f3a40cd-51a4-4012-a920-abb720e8305d.png) |
| ARTW104_世界_交易棚_20261005160008.png | 384×256 | 147,717 | [预览](https://tapcode-sce.spark.xd.com/tapcode-images/b99d4765-9454-47cc-ad1e-c90f01f85cb7.png) |
| ARTW104_世界_小仓库_20261005160008.png | 384×384 | 214,216 | [预览](https://tapcode-sce.spark.xd.com/tapcode-images/44f0fc41-4f0f-48ae-8510-2189ecaaef1b.png) |
| ARTW104_世界_修船棚_20261005160008.png | 384×384 | 261,069 | [预览](https://tapcode-sce.spark.xd.com/tapcode-images/c0f47142-a3f8-43ed-88e2-d451dacdaef1.png) |
| ARTW104_世界_港口组合装饰_20261005160008.png | 384×384 | 259,930 | [预览](https://tapcode-sce.spark.xd.com/tapcode-images/3b65bd20-3ce3-461f-8060-7ed96760830b.png) |

港口组合装饰包括木箱、麻绳、折叠渔网、木桶和小型港口方向标。没有生成独立灯塔资产，也没有实现灯塔玩法。建筑图是便于识别的高角度正面 cutout；接入世界前仍需由程序侧确认作为 Upright/Billboard 的朝向与锚点。码头和组合道具为俯视图。

## UI 资产

底部操作栏：

| 资产 | 尺寸 | PNG 字节 |
|---|---:|---:|
| ARTW104_UI_底部操作栏_20261005160639.png | 1024×576 | 162,657 |

栏体本身是窄长海玻璃蓝托盘，留有六个操作位；没有全屏羊皮纸底板。

六类操作按钮均有普通态和按下态，每个 PNG 为 192×192：

| 按钮 | 普通态字节 | 按下态字节 |
|---|---:|---:|
| 捕鱼 | 76,657 | 90,984 |
| 背包 | 83,462 | 93,674 |
| 返港 | 84,566 | 94,989 |
| 透镜 | 75,314 | 90,143 |
| 老人互动 | 85,718 | 94,845 |
| 结束今日 | 80,741 | 90,550 |

单个普通/按下图标最大 94,989 B，均低于 100 KB。普通态与按下态的图形保持一致，按下态加深海蓝底色并强化金色反馈圈。

HUD 数值与昼夜符号：

| 资产 | 尺寸 | PNG 字节 | 用途 |
|---|---:|---:|---|
| ARTW104_UI_金币.png | 192×192 | 61,229 | 金币 |
| ARTW104_UI_体力指示器_20261005160902.png | 256×256 | 67,727 | 闪电与三段刻度 |
| ARTW104_UI_船舱槽位.png | 192×192 | 58,265 | 船舱容量 |
| ARTW104_UI_白昼.png | 192×192 | 53,869 | 白昼标记 |
| ARTW104_UI_夜晚.png | 192×192 | 51,524 | 夜晚标记 |
| ARTW104_UI_时间罗盘.png | 192×192 | 60,237 | 时间显示底图 |

所有单独图标均在 128–256px 范围内、低于 100 KB。底部栏 162,657 B，低于 400 KB 面板软上限。

Maker 原图映射：

- 底部栏：[Maker 预览](https://tapcode-sce.spark.xd.com/tapcode-images/3b1bff2d-dd36-4cc4-9797-fa4556e66480.png)
- 12 个操作态图标由此图集逐格拆出：[Maker 操作图集预览](https://tapcode-sce.spark.xd.com/tapcode-images/0c66e427-603f-436f-9c7e-a6481982e90e.png)
- 金币、船舱、昼夜和时间符号由此图集拆出：[Maker HUD 图集预览](https://tapcode-sce.spark.xd.com/tapcode-images/2cfe5699-cce6-41c7-b388-962b277f8df5.png)
- 独立体力图标：[Maker 预览](https://tapcode-sce.spark.xd.com/tapcode-images/fde10bf5-1136-43f9-94fa-4bc79eaf4175.png)

## 旧资源对照

### 视觉目标已被新候选明显超过

- LP 港口建筑和港口合图：旧建筑为低多边形等距 3D 观感，单栋多为 1024×1024、565,216–919,722 B；LP 港口合图为 1536×1024、1,397,382 B，包含海岸石块、船和灯塔，无法直接拆作独立场景物件。新候选统一到明亮水彩绘本，并按建筑、码头、装饰拆分；世界 PNG 现为 147,717–261,069 B。
- LP_UI03 夜晚面板：旧图为 1025×683、419,929 B 的深色厚重斜切边框。新操作栏是 1024×576、162,657 B 的窄长浅海蓝底，更适合触摸 HUD。
- ReadingSeaWatercolor 面板：clean 版 1152×768、757,549 B，另一版 995,357 B；两者仍是大面积羊皮纸框。新底部栏在主航海画面中更轻，显著减少纸框占屏。
- ReadingSeaWatercolor 导航图集：clean 版 629,695 B，icons 版 834,419 B。新图标把圈1要求的六项操作和普通/按下态补齐，单图低于 100 KB；旧图集在功能范围和按钮态上已被新候选覆盖。

### 仍值得保留的参考

- LP 的木码头 T 形轮廓、建筑功能差异和港口动线仍可作结构/比例参考；不建议沿用其低多边形着色或把合图直接当最终港口背景。
- ReadingSeaWatercolor 导航图标适合继续参考海蓝、暖金、纸感水彩的配色和海事符号识别；其图标造型仍可作备选，不必整体废弃。
- ReadingSeaWatercolor 面板可参考轻微水彩晕染与留白；旧羊皮纸边框不适合作为整屏 HUD 底板。
- LP_UI 其余多数图标/底板目前只有 42 B 的 `.meta` UUID 文件、缺少对应 PNG；本次无法作视觉比较。原文件保留，不作为可用贴图依赖。

## 交付边界与检查

- Maker 项目状态在显式 target_dir=C:\codex\taptap-sea 下为 bound / ready；两次图像批次后及最终检查均正常。
- 临时生成图已逐个迁入本报告指定的素材目录；assets/image/ 当前仍有原来的 43 个候选文件，ARTW104 临时文件数为 0。
- 本任务只产出素材与报告；没有修改 HUD.lua、Draw.lua、SeaDraw.lua、Main.lua、OceanImageCatalog、OceanLoop、.project 或 dist，也没有构建/提交。
- 当前 Maker status-lite 不返回本地预览进程状态，且本机没有 taptap-maker CLI 命令；因此未启动或刷新 GUI 预览。运行时接入与实际屏幕占用仍待接入负责人验收。
