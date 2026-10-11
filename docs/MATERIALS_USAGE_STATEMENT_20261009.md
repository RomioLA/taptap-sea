# 《渔夫漂流记》素材使用说明（按赛事模板整理的填写稿）

**状态：** 内部待核实稿，尚未签署或提交  
**模板：** [素材使用声明（含 AI 生成资产说明，模板）· 2026 聚光灯 21 天游戏创作挑战](https://xd.feishu.cn/docx/R53mdcCfMouOjPxB5PrcHJ4znOc)

> 模板说明要求复制到新文档填写，勿直接编辑模板；未使用的栏目填“无”，不要留空。此文件是本地整理稿，不会自动创建/分享 Feishu 副本。素材比例是待最终运行包和权属记录复核的估算；未确认项明确标为“待核实”，不能原样签署提交。

## 一、作品信息

| 项目 | 填写内容 |
|---|---|
| 厂商名 | [待负责人填写团队/主体名称] |
| 作品名 | 《渔夫漂流记》 |
| 队长 TapTap ID | [待队长确认；工程内的 author.id、developer_id、MCP user_id 各不相同，暂不猜填] |
| 填写日期 | 2026 年 10 月 9 日（提交前改为实际填写日期） |

## 二、第三方素材使用情况

> 仅凭工程文件不能确定权利人或许可时，按“待核实”保留，不把它写成已获授权。比例为当前代码引用/源包内容的暂估；最终应按提交构建核对。同一素材类别的比例需合计 100%。

| 素材 / 素材包名称 | 素材类型 | 授权类型 | 素材来源 | 使用比例 |
|---|---|---|---|---:|
| `sea_exploration_sfx.zip` 中被 AudioDirector 引用的 12 项非 AI 音效（WAV/MP3 同内容版本） | 音频（音效） | 待核实；源包内未见授权证明，暂按来源未明素材列示，不代表已认定为第三方 | `assets/audio/sea_exploration_sfx.zip`；ZIP 内有 `Original_MP3/` 与 `WAV/` 两套文件 | 待确认；若确属第三方，暂估 66.7%（12/18 个不同音效键） |
| MiSans 常规/粗体 + Microsoft YaHei UI（宣传图标题） | 字体 | MiSans 是否为 Maker 运行环境内置及许可待确认；Microsoft YaHei UI 为 Windows 系统字体，宣传图只含栅格化标题，字体文件未随图分发，仍需核对使用许可 | `Scene.lua` 引用 MiSans；`tools/create_store_promo.ps1` 使用 Microsoft YaHei UI 栅格化宣传图标题；工程资产目录未找到字体文件 | 暂列 100%（本项目已知字体使用合计；来源与最终运行包待确认） |
| TapTap Maker / UrhoX 运行环境及 `urhox-libs` 中实际随项目调用的引擎或插件资源 | 引擎或插件内置资源 | 平台/引擎随附许可；具体资源和署名要求待按当前平台规则核对 | TapTap Maker 工程运行环境、项目 `urhox-libs/` | 暂列 100%（引擎/插件内置资源类别；提交包清点后确认） |
| 航海参考图（仅作为 OceanLoop 美术重制参考；不应直接放入最终游戏或宣传物料） | 视觉（场景参考） | 提供者及原始权利状态待负责人确认 | `_uploads/c3fb8b9b0834ca6c098bcb452e23f0c1a899c2747c3b9787e317156cb7abd5b8.png`；OceanLoop 报告记录以项目参考图为依据制作 | 直接随包使用 0%；衍生素材是否需授权分析待核实 |

## 三、AI（AIGC）生成素材使用情况

| 素材类型 | 使用情况说明 | 使用比例 | 使用工具（选填） |
|---|---|---:|---|
| 音效 | 6 项 AI 生成环境音：`amb_morning_sea_ai`、`amb_overcast_sea_ai`、`amb_storm_premonition_ai`、`amb_rare_fish_ai`、`amb_deep_ruins_ai`、`amb_elder_npc_ai`；AudioDirector 引用这 6 项，另有 12 项非 AI 音效键 | 暂估占当前 18 个不同音效键的 33.3%；最终按构建确认 | TapTap Maker 内置 `batch_sound_effects` / Seed Audio；`.maker/assets/generated-assets.json` 记录生成时间 2026-10-08 |
| 视觉 | `assets/image/WatercolorUI/` 当前有 51 个 PNG。静态引用已确认 HUD 请求 `resource_icons.json`、`marine_life.json`、`button_states.json`，其元数据分别指向 3 张图集 PNG；`UiKit.lua` 直接引用 `ui_panels` 中 3 张不同 PNG。其余切片和 `characters` / `navigation` 图集未发现直接静态引用。manifest 顶层仍写“未接运行时”，与代码不一致，因此最终加载/打包范围仍以 Maker 构建核实。负责人于 2026-10-09 确认该组素材均为团队原创或 AI 生成，且团队留有记录；逐项原创/AI 分类、记录副本尚未提供 | AI 占比待按原始记录和 Maker 最终构建核算；目录文件数不能代替实际使用比例 | 团队有记录，待补充逐项归类及记录出处 |
| 视觉 | OceanLoop 报告记载以参考图重新制作 5 张源图并接入 6 张运行图；目前报告可证实制作流程和派生关系，具体生成工具/方式须回查原始记录。当前可检查的源图 `.meta` 仅包含 Maker UUID，`.maker/assets/generated-assets.json` 只登记 6 项音效、未登记图像生成详情 | 若确认属于 AI 生成，按最终构建使用的视觉资产重新统计；暂不计入已核实 AI 占比 | 待回查 2026-10-05 原始生成记录 |
| 文本、配音、音乐、其他 | 暂无工程证据可确认是否使用 AI 生成；负责人核实后，如未使用请填“无”，如有请逐项说明 | 待负责人确认 | 待负责人确认 |

**AI 美术占比提醒：** 赛事模板说明，AI 生成美术占比达到 50% 及以上的作品不参加“最佳美术”奖项评选。WatercolorUI 和 OceanLoop 的最终归类及比例未完成核算，故本稿不能用于该奖项资格判断。

## 比例口径与证据清单

- 音效比例按 `AudioDirector.lua` 中 18 个不同音效键统计：6 个有 Maker AI 生成记录（占 33.3%），12 个非 AI 键（占 66.7%）。这 12 项的权属未知，66.7% 不能直接当作“第三方素材占比”；WAV/MP3 双格式副本只按一项声音计算，提交前仍须按最终实际加载清单确认。
- WatercolorUI 目录当前有 51 个 PNG；静态代码请求 3 份图集 JSON（元数据各指向 1 张 atlas PNG）和 3 张不同的面板 PNG；未发现对 `characters` / `navigation` 图集的直接静态引用。负责人确认该组为团队原创或 AI 生成且团队留有记录，但逐项分类和记录副本尚未归档到本项目。`manifest.json` 的“未接运行时”标记与 `UiKit.lua` / `HUD.lua` 的资源请求不一致。上述静态引用不能替代 Maker 实际加载/构建证据；51 张目录 PNG 也不等于最终包中的使用量或 AI 数量。
- 图标 `assets/store/icon_512.png` 和宣传图 `assets/store/promotional_16x9_1920x1080.jpg` 是程序排版的展示图，主体复用 OceanLoop 游戏素材；它们没有新增 AI 角色或场景，但其底层素材是否为 AI 生成仍按 OceanLoop 原始记录核实。宣传图标题以 Microsoft YaHei UI 栅格化，相关字体需列入来源核验。
- OceanLoop 的 5 张源图、6 张运行图关系见 `docs/OCEAN_ART_LOOP_REPORT_20261005.md` 和 `assets/image/OceanLoop/manifest.json`。生成提示词、工具及原始记录尚需归档。
- 当前抽查的 OceanStory 源图 `.meta` 文件只含 Maker UUID；`.maker/assets/generated-assets.json` 记录 6 项音效而无图像生成条目。该目录不能证明 OceanLoop 的图像工具、提示词或参考图授权；需回查原始生成会话及参考图提供者。
- AI 环境音的工具/日期线索见 `.maker/assets/generated-assets.json`、`scripts/Gameplay/AudioDirector.lua`。`sea_exploration_sfx.zip` 已只读盘点出 `Original_MP3/` 与 `WAV/` 两套文件；文件名不构成授权证明。
- 当前全部素材路径、大小、SHA-256 和工程内来源线索见[逐文件清单](MATERIALS_ASSET_INVENTORY_20261009.csv)。图标 `assets/store/icon_512.png` 和宣传图 `assets/store/promotional_16x9_1920x1080.jpg` 均由 OceanLoop 运行素材合成；权属随基础素材来源一并核实。
- 签署前需从 Maker 最终构建确认加载素材，逐项核对第三方授权/平台许可、AI 生成记录、字体来源及比例；填写厂商名和队长 TapTap ID，并把此稿复制到新的 Feishu 文档。模板要求新文档设置为“获得链接的人可阅读”后提交链接；分享和提交尚未执行。

## 四、声明与承诺

> 以下为模板原有承诺文本，需由团队在确认全部来源、许可与 AI 使用情况后填写并由队长本人确认。当前仍有第三方音效、OceanLoop 参考图权属等待核实，因此此稿不能签署或提交。

本团队确认：

1. 本团队拥有游戏开发所涉及的第三方软件、工具、素材的合法使用权（免费开源素材符合其许可条款，付费或授权素材可提供授权凭证）；
2. 本声明内容真实、完整，未隐瞒 AI 生成素材的使用情况；
3. 如经核查发现虚假申报或存在侵权，同意主办方取消本团队的参赛与获奖资格，并承担相应责任。

队长真实姓名：[待本人填写]　日期：[实际签署日期]

## 参考

- [TapTap 制造开发者白皮书（2026）](https://taptap-maker-whitepaper.workers.xd.team/)
- [TapTap 官方游戏物料要求](https://developer.taptap.cn/docs/store/release/publish/material/)
- TapTap 游戏审核规范与素材要求：以 TapTap 制造当前提交页面显示规则为准。

