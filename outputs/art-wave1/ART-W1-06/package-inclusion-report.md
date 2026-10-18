# ART-W1-06 发布包 assets 收集机制调查

- 资源树测量时间：`2026-10-06T00:25:52+08:00`（Asia/Taipei）；资产/脚本测量期间稳定：`True`。
- 与图像清单的目录大小/文件数相符：`True`。清单时间 `2026-10-06T00:23:27+08:00`。
- Maker MCP 对显式 `target_dir=C:\codex\taptap-sea` 的本地状态：版本 0.0.36，项目已绑定且 ready。

## 证据

| 来源 | 实际读取 | 支持的结论 |
|---|---|---|
| `.project/settings.json` | `asset_dirs=["../assets", "../scripts"]`；`asset_ignores=[]`；`output_dir=../dist` | assets/ 与 scripts/ 是扫描根；无忽略项。 |
| `.project/resources.json` | `groups.default=["**"]` | `**` 默认匹配扫描根下的资源路径。 |
| `schemas/settings.schema.json` | `asset_dirs` 是构建扫描/运行加载根；`asset_ignores` 是 glob 忽略规则。 | 配置字段语义。 |
| `schemas/resources.schema.json` | 资源 glob 分组；只有组内资源进入构建引用。 | 资源组决定收集范围。 |
| `docs/DATA_MIGRATION_INTERNAL.md` | 记录 Maker 0.0.36 一次历史本地 `preview prepare` manifest，含生成 Lua，记载 49 项项目资源。 | 有历史 CLI/manifest 执行证据；不是当前图片树 manifest。 |
| 当前本地产物 | `dist/`=False；`build/`=False；本轮未远端构建。 | 无当前正式包可逐项枚举。 |

## A–E 结论

| 问题 | 结论 | 等级 |
|---|---|---|
| A. 是否把整个 `assets/` 作为输入？ | 是，构建配置把 `../assets` 设为资源扫描根且忽略列表为空；归档是否包含每种文件仍受格式识别和 prepare manifest 影响。 | STRONGLY_SUPPORTED |
| B. 是否把整个 `assets/image/` 收进资源集？ | 该目录处于 assets 扫描根内，且 `**` 默认组覆盖路径；受支持的 PNG/JPG 大概率进入资源 manifest。 | STRONGLY_SUPPORTED |
| C. 是否仅收代码实际引用资源？ | 配置没看到基于 Lua 引用裁剪的规则；`**` 默认组支持广泛资源收集，不应假设只收代码引用。 | STRONGLY_SUPPORTED（不是只按引用） |
| D. `assets/generated/` 是否自动进入？ | 它位于 assets 扫描根内，无 ignore 规则，里面 PNG/JPG 路径匹配 `**`。 | STRONGLY_SUPPORTED |
| E. 源图/候选/未引用图片是否可能进入？ | 有可能，且按当前组规则很可能；没有按候选/引用状态排除的配置。精确 archive 文件仍待当前 manifest。 | STRONGLY_SUPPORTED |

总体证据等级：**STRONGLY_SUPPORTED**。资源扫描规则有项目配置、schema 和历史 prepare 记录佐证；当前正式包的逐文件清单/压缩字节仍为 **UNKNOWN**。当前 PowerShell PATH 无独立 `taptap-maker` 命令，本轮没有执行远端构建。

## 60 MB 风险

| 范围 | 文件数 | 字节 | MB | MiB |
|---|---:|---:|---:|---:|
| `assets/` | 309 | 70,510,771 | 70.51 | 67.24 |
| `assets/image/` | 192 | 41,161,430 | 41.16 | 39.25 |
| `assets/generated/` | 67 | 14,735,371 | 14.74 | 14.05 |
| `assets/audio/` | 50 | 14,613,970 | 14.61 | 13.94 |
| `scripts/` | 259 | 1,541,267 | 1.54 | 1.47 |

- 配置扫描根 `assets + scripts` 原始体积：**72,052,038 B / 72.05 MB / 68.71 MiB**。
- 高于 60,000,000 B（十进制 MB）**12,052,038 B**；高于 60 MiB（62,914,560 B）**9,137,478 B**。
- `assets/audio/sea_exploration_sfx.zip` 为 6,431,884 B；即使假设不进入包，`assets + scripts` 仍有 **65,620,154 B**。是否过滤 zip、音频转码、压缩或 hash 去重没有当前 manifest 证明。

**结论：当前已有显著的 60 MB 风险，但没有证据断言正式包已经超限。** 源资源树字节已高于十进制 MB 和 60 MiB 两种口径；构建压缩、过滤和音频转码可能改变实际归档大小。

## 第二波图片尺寸预算建议

- 小 HUD/物品图标：单图 128–256 px；显示不超过 64–96 logical px 时避免保留 1024 px 运行版。
- 图标图集和细节 UI：通常 512–1024 px 长边；只有真实图集/屏显细节要求支持时才更大。
- 世界小物件/鱼/海鸟：默认 512 px 长边；近景对象可 768–1024 px。
- 岛屿、建筑、全屏背景：运行图长边 1024–1536 px；2048 px 仅用于通过相机/屏幕占用验证的近景或全屏大图。
- 按最大实际显示像素的约 1.5–2 倍定纹理尺寸；运行源图与候选/归档源图分开，避免候选图落入默认 `assets/**`。
- 512–1024 px 透明 Sprite 留 8–24 px 抗采样边；裁切后同步 anchor/pivot、UV 与碰撞范围。
- 在 60 MB 口径未确认前，将 image+generated 运行资源总量暂控在约 30 MB，为 audio、scripts、manifest 和打包开销留余量。当前 image+generated 栅格合计 {n(inv["imageDirectory"]["rasterBytes"]+inv["generatedDirectory"]["rasterBytes"])} B。

## 范围边界

本轮只读扫描配置/源树，另在指定 `experiments/` 生成变体；没有修改 `assets/`、`scripts/` 或构建配置，没有删除、覆盖、提交或推送。
