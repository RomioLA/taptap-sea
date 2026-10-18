# ART-W1-01 美术候选生产报告

- 日期：2026-10-06（Asia/Taipei）
- Workspace：`C:\codex\taptap-sea`
- 资产目录：`assets/generated/highspec/ART-W1-01/`
- 状态：候选资产，待美术负责人审阅；不代表美术定稿。

## Maker MCP 生成记录

使用 TapTap Maker MCP（`@taptap/maker 0.0.36`，项目状态 ready）：

- `batch_generate_images` 生成船 2 张、岛屿首批 4 张、环境件 5 张。
- `generate_image` 追加地标岛 1 张与横向漂流木 1 张。
- 共 13 张成功输出；最终保留 11 张。首版地标岛外围带青蓝水环、未达到本任务平面边界要求；首版方形漂流木被左右裁切。两张中间稿仅逐文件移除，未删除任何既有素材。
- MCP 初始把输出写入 `assets/image/`；最终候选逐张移入本任务指定目录。MCP 预览链接保留在清单中。

## 最终候选清单

以下大小为字节；PNG RGBA 和透明状态已检查（PNG color type 6，四角 alpha 均为 0）。

| 类别 | 文件 | 像素 | 字节 | 透明 | Maker 预览 |
|---|---|---:|---:|---|---|
| 玩家船 A | `assets/generated/highspec/ART-W1-01/ship_fishing_sloop_A.png` | 768×512 | 395,307 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/c9dbb3f4-290d-4164-a8a7-e8ec36aff6d7.png) |
| 玩家船 B | `assets/generated/highspec/ART-W1-01/ship_coastal_cutter_B.png` | 768×512 | 285,411 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/def1e3a2-cda4-452e-a854-7e946a66891b.png) |
| 沙滩植被岛 | `assets/generated/highspec/ART-W1-01/island_sandy_green_cove.png` | 1024×1024 | 1,567,197 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/67817391-952f-4465-8e36-9fcd36720b94.png) |
| 岩礁岛 | `assets/generated/highspec/ART-W1-01/island_rocky_reef.png` | 1024×1024 | 1,484,382 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/bb739b37-379a-4e66-a0f8-d9f933ec88f6.png) |
| 弯月沙洲 | `assets/generated/highspec/ART-W1-01/island_crescent_sandbar.png` | 1024×1024 | 807,749 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/c6e6c763-caf8-418c-8845-c2babb80c876.png) |
| 地标探索岛 | `assets/generated/highspec/ART-W1-01/island_exploration_arch.png` | 1024×1024 | 1,508,648 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/6e0e3605-82f7-43a9-b0e2-373da8fa4c65.png) |
| 海岸岩石 | `assets/generated/highspec/ART-W1-01/env_coastal_rocks.png` | 512×512 | 344,917 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/e4d8e172-3d69-4dea-82e0-997ebf80ad73.png) |
| 灌木组合 | `assets/generated/highspec/ART-W1-01/env_shrub_grove.png` | 512×512 | 405,021 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/84a70abd-0e37-49b8-9d6f-ff20c39f6bf9.png) |
| 小码头 | `assets/generated/highspec/ART-W1-01/env_small_jetty.png` | 512×512 | 251,852 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/9ec24ab3-9379-490a-93a7-ce249a2d57fa.png) |
| 漂流木组合 | `assets/generated/highspec/ART-W1-01/env_driftwood_bundle.png` | 512×341 | 158,167 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/644d995e-b451-44f8-81fd-2434722528be.png) |
| 礁石组合 | `assets/generated/highspec/ART-W1-01/env_reef_cluster.png` | 512×512 | 331,613 | 是 | [打开](https://tapcode-sce.spark.xd.com/tapcode-images/705a368a-37ed-4aaf-b583-e59371f82b02.png) |

## 视觉检查

- **较明显达到高规格目标**：两艘船有完整甲板结构、船板、桅杆/帆布和绳索细节，船头均朝画面右侧（+X）；沙滩植被岛与弯月沙洲的轮廓、沙岸和植被分区清楚；探索岛中央石拱有醒目的识别形状；码头与灌木组合细节丰富。
- **仍偏普通环境件表现**：海岸岩石、礁石组合、漂流木属于细节清楚但形体较简单的组合件；它们不是矢量占位图，不过没有船和主要岛屿那样强的主视觉复杂度。
- 岩礁岛和石拱保留了一些岩体侧面式明暗，存在轻微立体模型感；多数资产轮廓外沿可见细白边。虽然 PNG 边角透明，正式用于青蓝海面前仍应检查白边在实际底色上的表现。此批未接入运行时，不据此宣布旋转或场景适配已验收。

## 可复用旧素材

- `assets/image/OceanReady/driftwood.png`（768×512、透明）与 `assets/image/OceanReady/reef.png`（512×512、透明）可直接满足普通环境件用途，无需为基础可玩版本重做；若要求统一达到本批主视觉规格，再考虑替换。
- `OceanStory_*` 船岛图干净但笔触和细节仍较简；`LP_*` 船岛与码头素材偏低多边形或斜视，不适合作为本批正俯视高规格资产。
- `reading_sea_watercolor_landmarks_*` 是多物件与海水组合图，只用作笔触/配色参考，不作为单件 Planar 资产复用。

## 预算与边界

- 最终新增 PNG：**11 张**；总大小：**7,540,264 字节（约 7.19 MiB）**。
- 两艘船均低于 500 KB。四张主要岛屿为 1024×1024，文件约 808 KB–1.57 MB；超出软预算的原因是大面积水彩纸感、叶片、沙纹与岩层细节。三张普通件（海岸岩石、灌木、礁石）约 332–405 KB，主要来自密集叶片/石纹；码头和漂流木低于 300 KB。未把这些纹理图量化降色以避免明显损伤笔触。
- 漂流木由 Maker 返回 513×342，已轻微缩至 512×341，以满足普通环境件长边上限。
- 本任务只新增到上述资产目录和本报告目录；`assets/image/` 无残留本任务 PNG。保留 `assets/generated/mcp_test_barrel.png` 及开工前所有 dirty changes。
- 未修改 `scripts/`、`scripts/GeneratedData/OceanImageCatalog.lua`、`assets/image/OceanLoop/` 或 `.project/`；未构建、提交或推送。Maker 项目状态检查为 ready。`taptap-maker` CLI 不在 PATH，且未发现本地游戏预览进程；因此没有启动或刷新预览。

- 并行工作区说明：最终状态检查时发现 assets/image/ART-W1-02_*.png 未跟踪文件；它们不属于 ART-W1-01，本任务未修改、移动或计入统计。

