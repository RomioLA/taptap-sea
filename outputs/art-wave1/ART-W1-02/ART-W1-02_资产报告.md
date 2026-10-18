# ART-W1-02｜海面信息语言资产报告

- 任务：ART-W1-02
- 生成日期：2026-10-06
- 交付目录：`assets/generated/highspec/ART-W1-02/`
- 说明：经用户确认，Maker 原生输出保留在 `assets/image/` 以保留远程映射；本报告中的文件清单指交付目录内的副本。未接入代码。

## 资产清单

KB 按 1 KB = 1024 bytes 计算。所有文件均为透明 RGBA PNG，最长边不超过 512px；抽查角点 alpha 均为 0。

| 交付文件 | 尺寸 | 大小 | 对应游戏含义 | 分类 |
|---|---:|---:|---|---|
| `seabird_glide.png` | 512×512 | 155.1 KB | 功能海鸟平飞／盘旋基础姿态；单鸟素材可重复摆放并组合成两只鸟 | 功能信号 |
| `seabird_dive.png` | 512×512 | 177.1 KB | 功能海鸟首次出现时的俯冲姿态，不表示捕食 | 功能信号 |
| `bigfish_splash_roaming.png` | 256×256 | 30.1 KB | 大鱼普通活动刚经过的轻微水花 | 功能信号 |
| `bigfish_splash_chase.png` | 448×448 | 274.5 KB | 大鱼追猎时更明显的水花，与普通活动区分 | 功能信号 |
| `bigfish_direction_wake.png` | 512×512 | 71.5 KB | 大鱼经过留下的短方向尾迹；不保证鱼仍在原处 | 功能信号 |
| `smallfish_breach.png` | 512×512 | 117.5 KB | 小鱼跃水姿态 | 功能信号 |
| `smallfish_surface_disturbance.png` | 256×256 | 47.4 KB | 小鱼轻微上浮造成的水面扰动 | 功能信号 |
| `ripple_small.png` | 256×256 | 50.7 KB | 小型普通环境圆波纹 | 纯效果，无独立玩法含义 |
| `ripple_medium.png` | 256×256 | 110.6 KB | 中型普通环境圆波纹 | 纯效果，无独立玩法含义 |
| `surface_bubbles.png` | 256×256 | 58.6 KB | 气泡／异常水面细节 | 纯效果，不代表特定新规则 |
| `bait_impact_splash.png` | 256×256 | 22.6 KB | 玩家投饵落水的即时水花，不表示鱼已被吸引 | 动作反馈 |
| `net_impact_splash.png` | 448×448 | 259.5 KB | 捕鱼网落水的即时水花，不表示已捕获 | 动作反馈 |
| `fishing_success_feedback.png` | 384×384 | 220.6 KB | 捕鱼成功的水面结果确认 | 结果反馈 |
| `fishing_empty_feedback.png` | 512×512 | 180.6 KB | 空网结果反馈；不表现为额外惩罚 | 结果反馈 |

功能信号沿用既有玩法语义：海鸟指示附近活跃小鱼；水花与尾迹表示大鱼刚经过；小鱼上浮和鱼跃只表现小鱼状态；投饵不保证成功。水花、涟漪和气泡没有附加新规则。

## 素材复用情况

- `assets/image/OceanStory_gull_20261005114946.png`（512×512，110,885 bytes）：现有俯视水彩海鸟形体清楚，可继续用作平飞／盘旋候选；本批同时提供风格统一的 `seabird_glide.png` 与缺少的俯冲姿态。
- `assets/image/OceanLoop/ripple.png`（512×512，29,856 bytes）：可继续用作简洁线性波纹或占位效果；画风较偏干净描边，复杂水彩表现用本批波纹更合适。
- `assets/image/OceanReady/sardine.png`（768×512，162,712 bytes）：可复用小鱼主体轮廓；不能直接替代跃水姿态。
- `assets/image/OceanLoop/gull.png`（512×512，96,047 bytes）：已检查，主体有明显几何破碎，不建议直接复用。
- `assets/image/reading_sea_watercolor_marine_life_20261005115707.png`（1152×768，611,728 bytes）：作为风格参考图使用，不作为本任务交付资产。
- 未发现可直接复用的大鱼水花、方向尾迹、投饵／网落水水花或捕鱼结果反馈素材。

## 规格整理与新增体积

为保持低体积，4 张复杂图在交付副本中缩至 448×448、384×384 或 256×256；全部交付图小于 300 KB，最大为 `bigfish_splash_chase.png` 的 274.5 KB。`ripple_medium.png` 的中圈黑色不透明填充已清为透明。Maker 原始 PNG 保持不变。

- 交付目录 14 张 PNG：1,818,865 bytes（1,776.2 KB / 1.735 MiB）。
- Maker 原生输出 14 张 PNG（`assets/image/ART-W1-02_*`）：2,248,926 bytes（2,196.2 KB / 2.145 MiB）。
- 本任务新增 PNG 合计：4,067,791 bytes（3,972.5 KB / 3.879 MiB）。以上不含本报告文件。

未修改 `scripts/`、`assets/image/OceanLoop/`、`OceanImageCatalog`、`.project/` 或 `dist/`；未提交或推送。