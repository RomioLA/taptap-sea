# ART-W1-06 资产体积与候选报告

- Workspace：`C:\codex\taptap-sea`
- 图片清单快照：`2026-10-06T00:23:27+08:00`（Asia/Taipei；扫描前后目录签名稳定：`True`）
- 范围：`assets/image/` 与 `assets/generated/` 下 PNG/JPG/JPEG；共 **144 张**，解码错误 **0**。
- `assets/image/` 目录总量 **41,161,430 B / 41.16 MB / 39.25 MiB**，其中栅格图片 **80 张 / 41,150,049 B**。
- `assets/generated/` 目录总量 **14,735,371 B / 14.74 MB / 14.05 MiB**，其中栅格图片 **64 张 / 14,735,245 B**。
- 目录总量包含 `.meta`、manifest 等非栅格文件；分组与 Top 20 只统计图片字节。

## 资产族统计

| 资产族 | 图片数 | 字节 | MB | MiB |
|---|---:|---:|---:|---:|
| LP | 36 | 20,628,470 | 20.63 | 19.67 |
| ReadingSeaWatercolor | 10 | 9,287,280 | 9.29 | 8.86 |
| OceanStory | 5 | 3,533,485 | 3.53 | 3.37 |
| OceanLoop | 6 | 3,526,890 | 3.53 | 3.36 |
| OceanReady | 9 | 1,924,998 | 1.92 | 1.84 |
| 其他 | 78 | 16,984,171 | 16.98 | 16.20 |

“其他”按路径/文件名归类，含 ART-W1 候选、generated 副本等；不代表采用/淘汰结论。

## 最大 20 张图片

| # | 相对路径 | 大小 | 尺寸 | 族群 |
|---:|---|---:|---:|---|
| 1 | `assets/image/reading_sea_watercolor_landmarks_20261005115646.png` | 1,616,891 B | 1536×1024 | ReadingSeaWatercolor |
| 2 | `assets/generated/highspec/ART-W1-01/island_sandy_green_cove.png` | 1,567,197 B | 1024×1024 | 其他 |
| 3 | `assets/image/OceanLoop/waterpaper.png` | 1,532,955 B | 1024×1024 | OceanLoop |
| 4 | `assets/generated/highspec/ART-W1-01/island_exploration_arch.png` | 1,508,648 B | 1024×1024 | 其他 |
| 5 | `assets/generated/highspec/ART-W1-01/island_rocky_reef.png` | 1,484,382 B | 1024×1024 | 其他 |
| 6 | `assets/image/OceanStory_waterpaper_20261005114940.png` | 1,458,080 B | 1024×1024 | OceanStory |
| 7 | `assets/image/reading_sea_watercolor_ocean_tile_20261005115327.png` | 1,430,943 B | 1024×1024 | ReadingSeaWatercolor |
| 8 | `assets/image/LP_港口01_归航港口插画_20261005093244.png` | 1,397,382 B | 1536×1024 | LP |
| 9 | `assets/image/OceanLoop/island.png` | 1,108,621 B | 1024×1024 | OceanLoop |
| 10 | `assets/image/reading_sea_watercolor_ui_panels_20261005115445.png` | 995,357 B | 1152×768 | ReadingSeaWatercolor |
| 11 | `assets/image/reading_sea_watercolor_button_states_20261005115716.png` | 988,248 B | 1152×768 | ReadingSeaWatercolor |
| 12 | `assets/image/LP_岛屿06_天然石拱岛_20261005093245.png` | 956,789 B | 1024×1024 | LP |
| 13 | `assets/image/LP_建筑05_修船棚_20261005093242.png` | 919,722 B | 1024×1024 | LP |
| 14 | `assets/image/OceanStory_island_20261005114948.png` | 897,031 B | 1024×1024 | OceanStory |
| 15 | `assets/image/LP_检查总览_首批.png` | 865,575 B | 1200×1668 | LP |
| 16 | `assets/image/OceanStory_boat_20261005114947.png` | 836,298 B | 768×1536 | OceanStory |
| 17 | `assets/image/reading_sea_watercolor_navigation_icons_20261005115342.png` | 834,419 B | 1152×768 | ReadingSeaWatercolor |
| 18 | `assets/image/LP_建筑03_木质仓库_20261005093236.png` | 813,628 B | 1024×1024 | LP |
| 19 | `assets/generated/highspec/ART-W1-01/island_crescent_sandbar.png` | 807,749 B | 1024×1024 | 其他 |
| 20 | `assets/image/LP_建筑01_海港渔舍_20261005093245.png` | 807,226 B | 1024×1024 | LP |

## 重复与分辨率候选

- SHA256 完全重复：**11 组，重复组内 22 个文件，11 个冗余副本；理论重复载荷 1,164,171 B（1.16 MB）**。没有删除/覆盖任何素材。
- 疑似重复/版本候选：**13 对、25 个文件**；其中 source/runtime manifest 关联 9 对，另有 pHash 候选 4 对。pHash 为白底合成、32×32 灰度缩略图、8×8 低频 DCT，汉明距离阈值 ≤6/63；候选需人工查看。
- `CAN_DOWNSCALE`：**9 张**；`CAN_CROP_TRANSPARENT`：**18 张**；`LIKELY_SOURCE_ONLY`：**9 张**；`POSSIBLE_DUPLICATE`：**25 张**。这些是筛选标签，不是素材取舍决定。

## 非破坏性压缩实验

实验副本仅在 `experiments/`；源文件 SHA 在实验前记录，源素材未覆盖。PNG optimize 两例解码后逐像素相同。相同预览尺寸下，1024→768 与 1024→512 样本轮廓相近；512 在近距离纹理/放大时仍有质量风险。24 px 透明边裁切保留了主体，但需同步 anchor/UV/碰撞边界。

| 实验副本 | 原大小 | 副本大小 | 节省 | 节省比例 | 风险 |
|---|---:|---:|---:|---:|---|
| `OceanLoop_island_png_optimize.png` | 1,108,621 B | 1,104,766 B | 3,855 B | 0.35% | 无像素损失；PNG 解码像素逐点相同；只改实验副本。 |
| `OceanLoop_island_768.png` | 1,108,621 B | 676,995 B | 431,626 B | 38.93% | 中；缩小约25%；细纹理与边缘可能变软，需按游戏中实际占屏大小复核。 |
| `OceanLoop_island_512.png` | 1,108,621 B | 316,359 B | 792,262 B | 71.46% | 高；缩小50%；近看细节损失风险高，仅适合小屏幕显示或远景。 |
| `reading_sea_watercolor_navigation_icons_png_optimize.png` | 834,419 B | 797,116 B | 37,303 B | 4.47% | 无像素损失；PNG 解码像素逐点相同；只改实验副本。 |
| `OceanLoop_gull_crop_pad24.png` | 96,047 B | 87,833 B | 8,214 B | 8.55% | 无重采样损失；接入风险中；按 alpha>0 bounds 裁切后四边留24px；需同步锚点/UV/碰撞与采样边界。 |

- 仅对样本选择：PNG optimize + 裁边约 **49,372 B**；采用 768 版约 **477,143 B**；采用 512 版约 **837,779 B**。
- 若后续打包器可按 SHA 去重（源文件仍保留），另有重复载荷候选 **1,164,171 B**；合并样本变体情景约 **1,213,543–2,001,950 B（1.21–2.00 MB）**。这是已测试样本情景，不是全库最大值。
- 本轮对正式素材的实际节省：**0 B**。当前不能按文件数外推总体压缩率。

逐张 SHA256、Alpha、透明 bounds 与 pHash 在 `asset-inventory.json`；精确重复和疑似版本分别见 `exact-duplicates.json`、`possible-duplicates.json`。
