# ART-W1-05 美术生产完成报告

日期：2026-10-06  
Workspace：`C:\codex\taptap-sea`  
范围：仅圈1策划已明确对象。漂流瓶和纸条按剧情视觉候选处理，不代表新增拾取或漂流玩法。

本报告记录后续完成结果，原有部分报告保留未覆盖。

## Maker 新生成候选

以下 11 张 PNG 已移入 `outputs/art-wave1/ART-W1-05/candidates/`。分辨率及大小为文件实测值。

| 文件 | 用途 | 版本 | 分辨率 | PNG 大小 |
|---|---|---|---:|---:|
| `ARTW1_05_Apple_Icon_20261006012957.png` | 背包苹果物品 | UI 图标 | 256×256 | 63,456 B |
| `ARTW1_05_FishBait_Icon_20261006012957.png` | 背包鱼饵物品 | UI 图标 | 256×256 | 47,401 B |
| `ARTW1_05_Tuna_Icon_20261006012957.png` | Tuna 鱼货 | UI 图标 | 256×256 | 49,087 B |
| `ARTW1_05_Lens_Icon_20261006012957.png` | 透镜关键物品 | UI 图标 | 256×256 | 61,414 B |
| `ARTW1_05_DriftingBottle_World_20261006012957.png` | 漂流瓶剧情视觉 | 世界版，正俯视 | 512×512 | 188,999 B |
| `ARTW1_05_Note_Rolled_World_20261006012957.png` | 卷起的空白纸条 | 世界版，正俯视 | 384×384 | 94,500 B |
| `ARTW1_05_Note_Unrolled_Story_20261006013145.png` | 展开纸条，留白供界面叠加正文 | 剧情/UI 版 | 576×384 | 288,383 B |
| `ARTW1_05_FishingNet_World_20261006013145.png` | 捕鱼动作中的网面表现 | 世界版，正俯视 | 512×512 | 449,614 B |
| `ARTW1_05_NetCenter_Target_UI_20261006013145.png` | 选取落网中心 | UI/交互标记 | 256×256 | 44,330 B |
| `ARTW1_05_UnknownLocationMarker_UI_20261006013145.png` | 未识别地点状态 | UI 标记 | 256×256 | 59,438 B |
| `ARTW1_05_IdentifiedLocationMarker_UI_20261006013145.png` | 已识别地点基础状态 | UI 标记 | 256×256 | 59,498 B |

Maker 对展开纸条返回 576×384，宽度略超 512px；渔网为细网目复杂世界物件，文件也超过 250KB。其余图均在对应常用尺寸/大小范围内。生成图已逐张查看。

## 直接复用候选

| 文件 | 用途 | 版本 | 分辨率 | PNG 大小 | 来源 |
|---|---|---|---:|---:|---|
| `assets/generated/highspec/ART-W1-05/barrel_world_candidate.png` | 固定木桶高清候选 | 世界版，正俯视 | 512×512 | 231,191 B | 复用 OceanStory 木桶 |
| `assets/generated/highspec/ART-W1-05/driftwood_world.png` | 漂流木 | 世界版，正俯视 | 512×341 | 134,881 B | OceanReady 漂流木按比例缩小 |
| `assets/generated/highspec/ART-W1-05/sardine_inventory_icon.png` | Sardine 鱼货 | UI 图标 | 256×256 | 22,954 B | OceanReady Sardine 缩放适配 |

苹果、鱼饵和透镜虽有旧素材，但为 LowPoly 风格，本次未复用。没有找到可直接复用的 Tuna、漂流瓶、纸条、渔网或地点/选点标记。

## 文件总量与转移核对

- 本次 Maker 新生成 PNG：11 张，合计 **1,406,120 B**。
- 已整理的 3 张复用 PNG：合计 **389,026 B**；其既有 `.meta` 共 126 B。
- 两组候选合计 **1,795,272 B**（不含本报告）。
- Maker 新生成的 PNG 在 `assets/image/ARTW1_05_*` 下**没有对应 `.meta` 文件**，因此只转移了实际存在的 PNG；没有伪造 UUID sidecar。复用候选原有 `.meta` 留在 highspec 目录。
- 转移后复核：`assets/image/ARTW1_05_*` 残留 **0 个文件**；没有覆盖或删除已有文件。

## 范围与状态

保持暖木色、青蓝海洋色、清晰暖赭描边和轻水彩纸感；没有修改正式代码、数据、玩法规则或 OceanLoop。漂流瓶和纸条不扩展成未确认玩法。
