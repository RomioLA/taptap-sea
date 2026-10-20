# 读海美术交付批次接入记录（2026-10-20）

交付来源：`C:/codex/taptap-jam/Fishing`（33 个 `读海_*_v1_assets` 合集，176 张图）。
本文只记录**实际入库的素材、落点、接线状态与未接项**，不替代 `docs/ART_PIPELINE.md` 的
冻结规则，也不构成玩法验收。

## 0. 一分钟结论

- 176 张交付图里 **27 张与项目已有素材字节完全相同**（早前批次已入库），28 张是已有素材的
  同源变体（同一生成链的不同导出 / 应用了翻转），**121 张是项目此前没有的图**。
- 本轮入库 **29 张**，全部落在既有 `assets/image/<合集>/`（无新增平行目录），
  由既有生成器统一并入 `scripts/GeneratedData/OceanImageCatalog.lua`（catalog 从 72 → 93 条）。
- 其中 **13 张已接线到运行时绘制**（含回退链），其余为「已入库、待接线」的美术候选，
  详见第 3、4 节。
- 新增测试：`scripts/Tests/V28ContentTests.lua` 增 3 项（catalog 落点、net/kelp 双态回退、
  徽章图集帧集），`run_world_content` 由 353 → **356** 全绿。
- 未入库的 92 张按形态分四类给出处理意见（第 5 节），需要美术/策划拍板后再说。
- **第二批**（同目录更新版）新增 6 张接线图（苹果/鱼饵/沙丁鱼/金枪鱼/货箱/钥匙）+
  2 张图鉴备用，见 0.5 节；catalog 93 → 97 条。

## 0.5 第二批（同目录更新版，2026-10-20 20:40）

美术随后更新了 `读海_船舱物品_v1_assets`（这次直接放在 `C:/codex/taptap-jam/` 下）。
对比结果：**12 张与第一批字节完全相同**，新增 10 张（其中 4 张是重复命名的同图）。

| 新增条目 | 尺寸 | 用途 | 接线 |
|---|---|---|---|
| `apple_01` | 512² | 苹果图标 | **已接线**（HUD 物品行） |
| `bait_01` | 512² | 鱼饵图标 | **已接线** |
| `sardine_01` | 512² | 沙丁鱼图标 | **已接线** |
| `tuna_01` | 512² | 金枪鱼图标 | **已接线** |
| `salvaged_chest_01` | 512² | 海底金属货箱 | **已接线**（此前只在 catalog、HUD 未映射） |
| `rusty_key_01` | 512² | 生锈钥匙 | **已接线**（同上；独立道具栏也走同一帧） |
| `codex_sardine_01` / `codex_tuna_01` | 512² | 图鉴标本式画法 | **仅入 manifest**，`kind=codex_icon` 不进 catalog |
| `sea_note_01(.png/@2x)` | 512²/1024² | 航海残页另一画法 | **不入库**（与已入库 v2 残页是同素材不同画法，保留 v2 为准） |

`item_icons` 图集从 4 帧扩到 **10 帧**（`atlas/item_icons.png` 28 KB）；HUD 的
`ITEM_ICON_FRAMES` 由 5 条扩到 11 条。测试新增「图集里不得有孤儿帧」校验。


## 0.9 自查修复轮（2026-10-20 21:00）

本轮不接新素材，只处理上一轮引入/暴露的问题。

### 已修（有风险 → 已修）

| # | 问题 | 根因 | 修法 |
|---|---|---|---|
| 1 | **包体 104.7MB，超 60MB 红线** | `resources.json` 是 `**` 全量引用，构建不做裁剪，于是「入库但未接线」的候选图全部入包 | ①`.project/resources.json` 增加排除表（未接线候选/参考图/MCP 遗留/零引用 mp3）；②新增 `tests/slim_readhai_art.py` 对**在用**的大图做 256 色量化（带 PSNR 与不透明语义保护）。结果：**104.7 → 59.4MB** |
| 2 | **V28 节点贴图被拉伸** | `v28PlaneTexture` 把 length/width 都传同一个 worldDiameter，一律正方形投放；素材内容比 1.2~2.8，实际被拉伸同样倍数 | 改走 `ImageArt.ContentPlaneSize`（与 `SeaViewComponent`/岛底图同一换算入口），按内容最长边投放 |
| 3 | **`.meta` uuid 非法** | 我用 `uuid.UUID.bytes[:18]`——该属性**恒 16 字节**，编码后是 22 字符，而规范要求 24 | 改用 `sha256(...).digest()[:18]` 重新生成 47 个；`prepush_check.py` 增 `check_asset_meta()` 闸门 |
| 4 | 徽章语义硬编 | A2「单日零空网」映射到 `unconventional_path`、C1「认得鱼群」映射到 `big_fish` 无依据 | 只保留语义确实对得上的 4 条（A1/A4/A5/A6），其余不画徽章走中性状态点 |
| 5 | `HUD` 徽章图集路径写错 | 我写成 `badges.json`，实际产物是 `readhai.json`（`UI.Sprite` 找不到文件时不报错） | 已修；测试有帧集校验兜底 |
| 6 | 量化会破坏逐像素数据 | `water_dudv_flow`（UV 位移向量）、`water_caustic_light*`（A 通道低值细网）被调色板压坏 | `slim_readhai_art.py` 显式 `DO_NOT_QUANTIZE` 白名单 + PSNR 阈值双保险；已从 HEAD 恢复 |
| 7 | 不透明底图被量化出 254 alpha | 调色板给纯不透明图也生成 tRNS | 量化前检测「原本全不透明」，改为 RGB 调色板（无 tRNS） |
| 8 | 纯候选与 LSP 噪声 | — | 修掉 2 条我自己引入的 LSP Error（`io.seek` 缺参、`Items` 重定义），诊断 23 → 21 |

### 新增的两个构建前闸门（`tests/prepush_check.py`）

- `check_image_budget()`：按 `resources.json` 的 groups 规则**实算** image 入包体积，超 40MB 直接拦。
- `check_asset_meta()`：新增资源 `.meta` 的 uuid 必须是 24 字符 base64url(18B)（历史文件只提醒）。

### 已解（2026-10-20 22:15）

- **audio 35.1MB → 18.6MB**：8 个环境声床降采样到 22.05kHz。
  依据是先做的频谱实测——这些素材 >11kHz 的能量占比全部 <0.5%（海洋/风声/人声床
  本质是低频噪声），22.05kHz 已覆盖全部有效内容。
  验收：时长零变化、RMS 电平差 <0.01dB、无削波、loop 首尾差 <20/32768。
  不转 mp3 的原因：`AudioDirector.SPECS` 全走 `.wav`，转码要动 SPECS 与路径自愈逻辑，
  无真机验证时风险高于收益。脚本 `tests/downsample_ambience.py`（幂等，可 `--restore`）。

### 包体最终账（入包口径）

| 项 | HEAD | 本轮后 |
|---|---|---|
| image | 30.5MB | 20.9MB |
| audio | 35.1MB | 18.6MB |
| store | 0.5MB | 0.5MB |
| scripts | 3.0MB | 3.0MB |
| **合计** | **66.8MB（已超线）** | **42.9MB** |

### 仍未解（有意保留）

- **3 张水彩主体图未量化**（`kelp_mirage_01/_b`、`underwater_treasure_01`、`debris_01`）：
  PSNR 23~25dB，压了会糊；它们正是第 2 条修复里恢复正确比例的图，保持原样。
- **7 个历史 `.meta` 的 uuid 仍是 21~23 字符**（多为音频，既有问题）：
  只作 `prepush_check` 的 warning，不阻塞；新建资源已被闸门强制 24 字符。

## 1. 入库清单（29 张，第一批）

| 落点 | 条目 | 尺寸 | 用途/接线状态 |
|---|---|---|---|
| `assets/image/OceanShip/` | `player_boat` | 1024×1024 | 玩家船正式水彩（正俯视，船头 +X）→ **已入库、未接管矢量船** |
| `assets/image/OceanShip/` | `player_boat_scene` / `_sheet` / `_view` | 整幅 RGB | 参考合成图 / 部件表 / 视图，`kind=reference`，**不进 catalog** |
| `assets/image/OceanArtCollection/` | `underwater_treasure_01` | 1024×768 | 03 水下宝藏 → **已接线**（贴图优先，矢量菱形兜底） |
| `assets/image/OceanArtCollection/` | `trapped_net_01` | 768×768 | 06 破渔网 → **已接线**（`V28_TEXTURE.net`） |
| `assets/image/OceanArtCollection/` | `kelp_mirage_01` / `_b` | 1536×1024 ×2 | 12 浮藻假岛 岛影态 / 20m 识破后藻层态 → **已接线**（双态切换） |
| `assets/image/OceanArtCollection/` | `leviathan_bubbles_01` | 512×512 | 03 巨骨海面慢气泡 → **已接线**（Plane 优先，圆点兜底） |
| `assets/image/OceanArtCollection/` | `sea_eye_vortex_01_v1` / `_v1_boost` | 1024×1024 ×2 | 10 海眼 v1（v2 已入库为主用）→ **已入库、A/B 备用** |
| `assets/image/OceanArtCollection/` | `salvaged_chest_01` / `rusty_key_01` | 512×512 | V2.8 物品图标 → **已入库、HUD 图标未接** |
| `assets/image/OceanStoryLayer/` | `island_01_full` / `island_02_full` | 1536×1024 ×2 | 两座主岛完整分层底图 → **已入库、未接管当前底图** |
| `assets/image/SeaSurface/` | `sea_surface_day_v1` / `dusk_v1` / `night_v1` | 1920×1080 ×3 | 海面 v1 三相位候选 → **已入库、不参与相位映射** |
| `assets/image/SeaSurface/` | `sea_surface_day_flat` / `night_flat` | 1920×1080 ×2 | 海面平涂版候选 → **已入库、A/B 备用** |
| `assets/image/Sky/` | `sky_day_v1` / `sky_night_v1` | 1920×1080 ×2 | 天空整幅日/夜候选 → **已入库、未接线** |
| `assets/image/Sky/` | `sky_day_v1_preview` / `sky_dusk_v1_preview` | 1920×1080 ×2 | 天空预览图 → **已入库、留档** |
| `assets/image/WatercolorUI/` | 成就徽章 6 枚 + UI 底板 3 件 | 缩放至 192 / 768 | 徽章 → **已接线**（toast + 成就页）；UI 底板 → **已入库、未接管现有皮肤** |

生成器：`tests/prepare_readhai_batch.py`（`--check` 只读校验）。产物由
`tests/prepare_ocean_eco_art.py` 的 `catalog_text()` 统一重生成，禁止手改 GeneratedData。

## 2. 去重与「同源」判定（避免重复入库）

判定方法：字节 sha256 全等 → 字节级重复；否则对 alpha 包围盒做 premultiplied 归一化
指纹（40×40）求 RMSE，并同时比对水平翻转版本。阈值 0.06 内视为同源变体。

| 判定 | 数量 | 处理 |
|---|---|---|
| 字节级已入库 | 27 | 不入库（含 `读海_风格基准产物合集` 全部 12 张、v2 沉船/漩涡/木桶/鱼鸟等） |
| 同源变体（RMSE ≤ 0.06） | 28 | 不入库（如 `读海_主场景组件_v1` 全部 11 张 ≈ `OceanComponents/sign_*`、生态层 v2 12 张是 `OceanEco` 的翻转源图） |
| 新素材 | 121 | 按用途筛选，本轮入库 29 张 |

`读海_生态层组件_v2_assets` 的 12 张是 `assets/image/OceanEco/*` 的**上游源图**（入库时做过
水平翻转 + 量化），本轮把 `tests/prepare_ocean_eco_art.py` 的 `SOURCE_DIR` 从已失联的
`E:/workbath/...` 改到该目录，恢复了 `--check` 的可校验状态（源图 sha256 全部对得上）。

## 3. 本次实际改动的代码（除资源外）

| 文件 | 改动 | 为什么 |
|---|---|---|
| `scripts/Ocean/SeaDraw.lua` | `V28_TEXTURE` 增加 `net`；新增 `V28_TEXTURE_STATES` 支持 kelp 双态；`drawFixedTreasure` / `drawLeviathanBubbles` 增加贴图优先 | V2.8 节点的正式素材接线，全部保留矢量回退（ART_PIPELINE §2 硬规则） |
| `scripts/Gameplay/HUD.lua` | toast 与成就页改用 `badges.json` 图集（失败回退原宝箱/圆形状态点） | 替换「宝箱暂代徽章」的占位 |
| `tests/prepare_ocean_eco_art.py` | `SOURCE_DIR` 迁移；ship 合集并入 catalog；`ship.kind == reference` 不进 catalog | 恢复 `--check`；船参考图不占运行键位 |
| `tests/prepare_ocean_ready_art.py` | 与 eco 生成器对齐（补 sky/skydecor/art/ship 合集 + repeatTexture 名单） | **修复既有漂移**：该文件的 `catalog_text` 原本只汇总到 SeaSurface，和 eco 生成器输出已不一致 |
| `tests/prepare_ocean_art_collection.py` | 一致性判定改为「负责键逐字段相等 + 允许追加键」 | 该合集现在承载两批素材（append-only），逐字节比对会互相踩写 |
| `tests/prepare_readhai_batch.py` | 新增（本批入库入口） | 与既有生成链同口径，可重跑 + `--check` |

## 4. 需要拍板的接线（美术已就位、代码未接）

以下每一项都已有素材与 catalog 条目，但当前主线另有明确选择，**不在本轮擅自改**：

1. **玩家船**（`player_boat`）。2026-10-16 用户裁决「船贴图替换效果不好，还原矢量船」，
   `OceanImageCatalogTests` 断言 `boat/boat_story` 目录项必须不存在。本轮只把正式水彩船入库为
   `player_boat`（未占用 `boat` 键、未改断言）。要改回贴图船 → 需要用户确认并同步改该测试。
2. **两座主岛完整底图**（`island_01_full` / `island_02_full`）。当前 `island_01←coast_base_v3`、
   `island_02←reef_rocks_v1` 由 `Circle1B5ComponentPlacementTests` 锁定。试改时该套件立即变红，
   已回退——要换底图必须同时更新契约测试。
3. **海面 v1 / 平涂 / 天空整幅候选**。相位映射只认 `sea_surface_day/dusk`，
   夜相走「昼图 + 夜罩」（方案 A，`SeaViewArt.SeaSurfaceFrame` 有明确注释）。
   候选图留在 catalog 里做 A/B，不自动接入。
4. **UI 底板三件**（对话框/气泡/按钮）。现有按钮皮肤走 `UiKit.buttonProps`，
   替换属视觉统一任务，需先给验收口径。
5. ~~物品图标补充~~ → **已接**（第二批）：`ITEM_ICON_FRAMES` 现覆盖 11 个 itemId，
   图集 `item_icons` 10 帧。仍待定：图鉴页（`compendium` 的 marine 页）是否改用
   `codex_sardine_01` / `codex_tuna_01` 的标本式画法——现有页用的是 `marine_life` 图集。

## 5. 未入库的 92 张：按形态分类与建议

| 类别 | 数量 | 说明 | 建议 |
|---|---|---|---|
| 无 alpha 的场景/概念整幅 | ~45 | `读海_主场景昼夜套件` 整幅氛围图（1920×1072/1080、1024²）、`读海_礁石组合/reef_vis_0*`、`日系水彩…概念图_16_*` 4 张、`读海_萌系贴纸风素材表` 3 张、`读海_风格基准_01初遇之岛` | 概念/风格锚图，不是运行时切图素材。建议只把 1~2 张锚图放 `docs/art/` 存档，其余留在美术目录 |
| 旧版/低分辨率变体 | ~25 | `读海_生态层组件_v1`（鱼 tuna/sardine/big/small 各 3 帧 + 中间稿图）、`读海_漂浮物_v1`、`读海_沉船_v1` 的 bones/jewelry（v2 已入库）、`读海_主场景昼夜套件` miora 派生素材 | 已被 v2 取代，不建议再入库；若要做鱼种细分（tuna/sardine 独立帧）需策划确认 |
| 航海残页/漂流瓶旧图标 | ~8 | `读海_物品图标_航海残页`、`sea_note_01.png / @2x`、`读海_漂浮物_v1` 的 `drift_bottle_01` | 已有 1024 母版与 512 图标入库；旧的 512/1024 是同素材不同尺寸 |
| 需要设计口径才能用 | ~14 | `读海_主场景组件_v1` 的 `treasure_island_v1/v2_flat`（与 `island.png` 近似但构图不同）、`读海_破渔网` 的三张 miora 中间稿、`读海_沉船` 的 `jewelry_01`（与 v2 珠宝非同图） | 与现有运行时资产语义冲突（同名不同图），入库会造成「哪张才是正式版」的歧义，先不入 |

## 6. 已知偏差与风险

- **成就徽章语义未绑定**：`scripts/data/achievements.lua` 没有「徽章」字段，交付只有图片语义名。
  HUD 的 `ACHIEVEMENT_BADGE_BY_ID` 只做「每个成就稳定取一枚」，**不声称**徽章画面与成就规则
  一一对应；要正式绑定需策划给映射表。
- **徽章图集分辨率**：交付为 512²/1280×256 原图，按 UI 显示尺寸（26px / ~320px 宽）缩到
  192/768 后再打图集（`readhai.png` 100 KB），避免把整幅 UI 原图塞进包体。
- **`player_boat_scene/sheet/view` 三张整幅 RGB 不透明**，`kind=reference` 所以既不进 catalog
  也不占运行键位；`describe()` 对它们的 alpha 相关字段无意义（全 255）。
- **本轮未做真机/本地窗口验收**（无 GUI）：接线均为「贴图优先 + 矢量回退」，按代码路径
  不应造成黑块；但 `Plane` 的实机缩放观感（尤其 `underwater_treasure_01` 的 `radius*4` 口径、
  `kelp` 的 14m 视觉半径）需要一次本地预览确认。

## 7. 复现与校验

```bash
python tests/prepare_readhai_batch.py --check        # 本批 29 张入库一致性
python tests/prepare_ocean_eco_art.py --check        # catalog 与全部合集同步（含 eco 源图 sha256）
python tests/prepare_ocean_art_collection.py --check  # 老 10 条 + 追加条目
python tests/pack_watercolor_ui.py --sheet readhai    # 徽章图集
python tests/run_world_content.py --lupa-root .tmp/sea-test-deps   # 353 tests
python tests/run_sea_view_regression.py              # 79 套件（基线：SeaMotionEffectsTests 红）
```
