# TapTap 制造提交准备清单（2026-10-09）
## 当前验收快照（2026-10-09，最近验证）

- **账号与 Maker：** Maker PAT 与 TapTap auth 已通过官方 CLI 授权。项目绑定、健康状态及云端 build 代理曾由 `maker_status_lite` 确认可用；本对话当前工具列表没有 Maker 工具，因此不能在此直接执行 Maker 运行时验收。
- **Git 配置：** 已获授权，仅为 Maker MCP 进程配置 Git 可执行文件及本仓库 `safe.directory`。从 Codex TOML 加载配置启动的独立 MCP 进程确认 Git 可用、仓库识别正常且 `usable_for_build_submit=yes`。没有修改系统或全局 Git 配置；Codex/MCP 需重新加载配置才能在本会话继承。
- **云存档：** 主场景默认使用 `clientCloud` 适配器，存档键为 `sea_game_loop_v1`。现有 `Circle1B3CloudTests` 使用临时 `uv` 环境运行，10/10 通过、0 失败、0 跳过，覆盖 mock SDK 回调协议。**真实 Maker `clientCloud` 云端写入、重启后读取及账号隔离尚未验收。**
- **Lua 检查：** 2026-10-09 22:50:54 Maker 控制台当前扫描失败，207 个错误；全项目 LSP 尚未通过。当前控制台未提供警告总数，不沿用旧扫描警告数。云存档相关实现文件未列入本次错误摘要，但这不证明真实云端存取成功。
- **预览：** 当前预览 session 已停止（`ready=false`）；本轮未启动。旧日志包含环境错误，本地单机预览也不验证云存档。
- **素材/发布：** 本地素材声明草稿未签署；仍有素材来源与授权凭证待核实。当前版本实机截图/视频缺口、挑战上传表单字段和最终提交检查尚未完成。

目标节点：2026-10-18。工程类型：TapTap 制造（UrhoX Lua），不是 APK 或 H5 工程。赛事提供的 TapTap 登录、云存档、排行榜属于可选能力；本项目将云存档定为本轮必须完成项。
## 已核对

- `.project/project.json` 已有游戏名“渔夫漂流记”、横屏配置和 TapTap 制造发布字段；版本为 `1.0.42`。
- 2026-10-09 Maker CLI `doctor` 首次报告 `.project/project.json` 因 UTF-8 BOM 无法解析；已仅移除 3 字节 BOM，JSON 内容未改。复查首字节为 `{`、JSON 可解析，`doctor` 现报告 `project_initialization=ready`、`project_settings=ready`、开发套件内容齐备。
- 2026-10-09 已按负责人授权安装 Git for Windows 2.56.0.windows.2（签名验证有效）和 Maker 管理的 Python 3.12.15/uv 0.12.24；Maker Lua LSP 0.22.2 已配置就绪。重跑 `doctor` 时在当前命令 PATH 中显式加入 Git 后，Git、Python、Lua LSP、项目初始化和项目设置均报告 ready。Git 已安装，但 Codex 原有进程环境尚未自动刷新 PATH，需重启后让 MCP 客户端也能发现 Git。开发套件更新检查显示有较新版本，但未更新。
- 已补充一版基于现有策划与玩法的简体中文发布简介；`Main.lua` 发布入口已关闭开发调试入口（海上调试面板/StoryArt A-B）。
- 代码中已有基于 `clientCloud:Set/Get` 的云存档适配器，存档键为 `sea_game_loop_v1`；先前默认装配优先写本地文件并将云写入作为后台影子同步，且历史交接记录明确指出真实云端读写未完成真机验收。
- 2026-10-09 起 Maker 主场景默认改用云存档适配器，保留显式注入的 `settings.store` 供受控环境使用。云端回调失败时应继续显示保存失败/重试状态，不报告本地写入成功为云端完成。
- 已新增[素材使用说明草稿](MATERIALS_USAGE_STATEMENT_20261009.md)。项目负责人确认 `WatercolorUI` 为团队原创或 AI 生成且团队留有记录；静态代码请求 3 份图集 JSON（各对应一张图集 PNG）及 3 张不同面板 PNG，但 manifest 声称未接运行时。逐项来源拆分、记录副本和 Maker 实际加载清单尚未归档；工程留有源参考图和切图脚本，仍需整理可核对的提交附件。
- 已读取赛事飞书模板正文；本地草稿已按“作品信息、第三方素材（名称/类型/授权/来源/比例）、AI 素材（类型/说明/比例/工具）”重排。厂商名、队长 TapTap ID、WatercolorUI AI/原创拆分、音效包许可和参考图权属尚待团队核实。模板要求复制到新文档并设置“获得链接的人可阅读”；尚未创建/分享/提交 Feishu 文档。
- 赛事模板注明 AI 生成美术占比达到 50% 的作品不参加“最佳美术”奖项评选；当前视觉 AI 占比无法从目录/工程记录确认，需按来源记录和最终构建重新统计。
- 已生成[素材逐文件清单](MATERIALS_ASSET_INVENTORY_20261009.csv)：82 个 PNG/JPG 图像、30 个 WAV/MP3 音频、1 个 ZIP 音效源包和 10 个 JSON 清单/元数据文件，附文件大小、SHA-256 与可匹配的 manifest 线索；它不能代替生成记录或授权凭证。

## 发布资料缺口

工程发布元数据中，游戏介绍已填写，图标和 16:9 宣传图均已配置；实机截图列表仍为空。2026-10-09 对照 TapTap 当前官方物料要求与审核规范（v4）：仓库当前没有 MP4/MOV/WebM 实机录屏；图标、宣传图尺寸/文件大小通过本地检查。正式下载/试玩发布须提供实机视频和至少 3 张当前版本核心玩法截图；Maker 挑战上传的具体必填字段仍以赛事通知及制造提交页为准。

TapTap 制造 2026 白皮书的“第一次发布前”清单另外列出：完整体验核心玩法、首分钟能理解目标与操作、游戏名/icon/五图/视频/标签一致、启动运行退出更新正常、确认当前平台合规要求；其“资料和素材”章节将五图称为详情页宣传图。当前工程只有 1 张 16:9 宣传图，不能据此视为五图齐备；`.project/project.json` 的实机截图列表为空，仓库未发现实机视频。五图、实机截图和赛事 Maker 上传表单字段应分开核对，白皮书首发清单不自动构成 Game Jam 上传硬性字段。

| 项目 | 当前状态 | 需要完成 |
|---|---|---|
| 云存档真实读写 | 代码路径已改为云优先；服务端读写未验收 | 在 TapTap 制造预览/测试环境完成首次存档、跨会话读档、覆盖更新、云端失败和重试验证；截取成功与失败反馈证据。 |
| 发布描述 | 已填入玩法简介 | 最终由团队按真实提交版本审校，确认流程措辞准确。 |
| 游戏图标 | 已生成 512×512 PNG，并写入发布元数据；Maker 上传/预览尚未验收 | 官方物料规范要求 PNG/JPG、至少 512×512、1:1 直角方图；不能用默认图标、白底、黑底或透明底。 |
| 实机截图 | 截图数组为空；仓库中仅有 10 月 1 日/5 日的历史运行截图，不作为当前版本提交图 | 当前版本实机至少 3 张同方向、同宽高比、不得重复；横图至少 1280×720、单张不超过 4 MB，实机画面至少占 50%，且要展示核心玩法。 |
| 16:9 宣传图 | 已制作 1920×1080 JPG（349 KB）并写入发布元数据；Maker 上传/预览尚未验收 | 官方规范要求至少 1920×1080、PNG/JPG、不超过 4 MB；必须清晰展示游戏名，不得直接使用截图或简单拼贴，且内容须贴近真实玩法。 |
| 实机录屏 | 仓库未发现 MP4/MOV/WebM，工程发布元数据也没有视频路径 | 正式开放下载/试玩须提供；MP4/MOV、H.264/HEVC、短边至少 540 px、15 秒至 30 分钟，前 5 秒展示核心玩法，核心玩法连续超过 10 秒。Maker 挑战是否要求视频以赛事表单为准。 |
| 简介、更新日志、标签 | 简介已填；尚无本次更新日志/标签核对证据 | 简介和更新日志为官方物料规范标注的必填项；标签须准确反映真实玩法。逐项以 TapTap 制造当前提交页为准。 |
| 素材权属 | 已有说明草稿；源记录、证明不完整 | 官方审核规范要求原创素材提供真实有效证明、购买素材提供购买页面与订单证明；完成素材核验清单，逐项补生成记录/购买凭证/授权，并由权利人签署。 |
| 版本与体验验收 | 历史日报显示捕鱼后的经济闭环缺少真机证据 | 18 日前在提交目标端实机走通启动、首分钟目标/操作理解、出航、捕鱼、收网、返港、出售、日结、云保存/恢复、退出重进和版本更新；修复阻断问题并留存证据。 |
| 当前平台表单/构建 | 未通过 Maker 当前提交页面确认 | 临近提交时核对字段、格式/大小限制、审核提示及最终构建结果；此清单不是平台最终审核结论。 |

## 云存档验收步骤

1. 用同一个 TapTap 用户启动游戏，开始新周目并确认首份云存档成功。
2. 完成一天并结算，检查钱、体力、库存、升级、剧情/老人状态等当前快照确实写入。
3. 关闭并重新打开游戏，读取该用户云档，确认恢复的值与结算快照一致。
4. 在另一会话/设备登录同一用户读取同一云档；若设备/端形态不支持，记录平台限制并只申报已验证范围。
5. 触发离线/写入失败，确认界面显示失败并能重试，不把失败显示为“已自动保存”。
6. 确认每周目每日结算保存策略符合预期；未结算当天不应宣称实时逐步云同步。

## 云存档代码核对（静态证据）

- `Persistence.Cloud` 使用项目配置键 `sea_game_loop_v1`，保存完整玩家快照到 `clientCloud:Set`，从 `clientCloud:Get` 的 `values[key]` 读取；接口形态符合工程内 `engine-docs/recipes/client-cloud-score.md`。
- Maker 主场景默认采用纯云存档适配器；不会以本地文件成功冒充云端保存成功。云端错误会进入失败状态，并由入口界面提供重试。
- 存档发生在新周目初始化和每日结算等状态转换节点，不是逐帧写入。工程 API 文档列明 clientCloud 读写各 300 次/分钟、数据量 48 MB/分钟；仍须用 Maker 预览确认线上账号、序列化和回调行为。
- 上述均为代码/本地 API 文档核对，不等于服务端实际读写验收；实机验收步骤仍须完成并留证。

## 建议倒排

| 日期 | 目标 |
|---|---|
| 10 月 10–11 日 | 恢复可用的 Maker 工具会话，完成云存档首次写入、重启读档与跨会话读取。 |
| 10 月 12–14 日 | 走通主要游戏经济闭环和失败重试；修复阻断提交的问题。 |
| 10 月 15–16 日 | 补齐素材来源证明并签署声明；从实际版本准备图标、实机截图、介绍和宣传素材。 |
| 10 月 17 日 | 在 Maker 当前提交页核对字段和审核提示，完成最终版本冒烟验收并留证。 |
| 10 月 18 日 | 按赛事截止时间提交。 |

TapTap 制造工程 API 来源以项目内 `engine-docs/recipes/client-cloud-score.md` 和 `examples/11-client-cloud-score-leaderboard-api.lua` 为准；Maker 当前服务和提交页的规则优先于通用 APK/H5 接入说明。H5 PC 云存档限制仅适用于 H5 路线，不据此推断本 Maker 工程的支持范围。商店通用物料规范见[TapTap 游戏物料要求](https://developer.taptap.cn/docs/store/release/publish/material/)；其中要求截图至少 3 张，而白皮书建议首发素材准备“五图”，二者口径不同，须按当前 Maker 活动/发布表单确认最终数量。

2026-10-09 官方规则复核：白皮书强调首分钟能理解目标与操作、商店素材应真实呈现玩法；TapTap 通用商店物料页/审核规范 v4 另列正式下载/试玩阶段实机视频、至少 3 张核心玩法截图，以及原创/购买素材的权属证明要求。该通用商店规则并不自动等同于 TapTap 制造/Game Jam 当前上传表单；最终逐项按赛事通知和 Maker 提交页核实。中国大陆正式商店分发相关的隐私/资质条件应在确定发布渠道、地区和产品形态后单独复核，不以 APK 条款推断 TapTap 制造项目要求。

[TapTap 游戏审核规范细则（v4）](https://developer.taptap.cn/docs/store/release/publish/agree/)

## 当前阻塞

**2026-10-09 初始化状态更正：**已按负责人给出的 `npx -y @taptap/maker init` 启动初始化。由于当前 Codex 进程 PATH 中没有 `npx`/`npm`，使用本机 npm cache 中已安装的 Maker `0.0.36` 包与 Codex 自带 Node 运行同一 `init` 入口；通过 `TAPTAP_MAKER_GIT_BIN` 显式指向 `C:\Program Files\Git\cmd\git.exe` 后，Maker 确认 Git、Python、Lua LSP 就绪。先前等待 PAT 的 init 进程已退出。只读执行 `apps --json` 报告本机找不到 Maker JWT；没有证据表明 PAT/JWT 已创建或保存。该 CLI 随后提示把网页 JWT 复制到聊天，这涉及认证凭据，不执行此操作。随后已再次按负责人的 init 请求启动新流程（目标仍是当前已绑定的工程目录），Maker 自动打开 PAT 授权页并输出等待“创建 token”；启动进程由命令会话 `36781` 持有。应用选择/克隆尚未继续，须由负责人完成授权并选择现有绑定项目；不要把 PAT/JWT 发到聊天。当前对话工具列表仍未暴露 Maker 工具。

同一时间只读执行 `preview status --target-dir E:\workbath\Fishing\fisherman-drift --json`，当前预览会话 `40afb155-5a3a-4e93-8d75-27844f23bda7`、reload 1 为 `process_alive=true`；不代表本轮启动。此前已记录的 `install_state=missing`、`state=stopped` 结论已过时。运行时日志确认 `Main.lua` 已执行并到达首帧，但 `preview status` 仍显示 `ready=false`，存在 `Cube/Day/DaySpecularHDR.dds` 与 `themis_x64.dll` 两项环境错误，且预览明确声明是单机客户端、不验证云端/服务器能力。故本地运行证据既不能证明云存档，也不能替代 Maker 账号授权后的真实云端读写验收。

**2026-10-09 22:06（北京时间）状态再次复核：**Maker `doctor --target-dir` 显示 Git 2.56.0、Python 3.12.15、Lua LSP 0.22.2、项目绑定、开发套件和工程设置均 ready；`auth.pat=false`、`auth.tap_auth=false`。授权流程命令会话 `36781` 经轮询仍存活并等待 PAT 完成。`console status` 显示本地控制台仍运行；但重新读取 `preview status` 得到 `state=stopped`、`process_alive=false`、`ready=false`。本轮未重启预览；此前“运行到首帧”只作为历史证据，不能代表当前可运行状态。

**Maker Lua LSP 新证据（负责人粘贴，版本 0.22.2）：**输出 `ready=true` 仅说明检查器可用；实际 `status=failed`、`errorCount=207`，因此不能作为通过证据。贴文展示的错误涉及多个既有系统/测试，另有 `tests\PersistenceRegressionSpec.lua:63` 的 PlayerState 联合类型错误；可见错误列表未显示 `Persistence.lua` 或 `Integration/Scene.lua`，但输出只给出有限条目，不能据此断言这两个文件无错误。当前会话没有可调用的 Maker LSP 诊断工具；本机包的 `emmylua_check.exe` 缺失。下一步需获得完整诊断明细，再区分真实类型问题与动态 Lua 类型声明/测试桩问题，修复后重跑 Maker 检查。该 207 项是否属于本次制造提交的硬性阻断，以当前 Maker 提交页/构建器结果为准；不得直接取消预检查来冒充代码通过。

**本地云适配器协议测试准备：**仓库已有 `scripts/tests/Circle1B3CloudTests.lua` 和 `scripts/tests/Circle1B3Run.py`，后者明确是本地 SDK 假体测试、不是实际云端验收。当前 Maker Python 与 Codex workspace Python 都未安装 `lupa`，而该 runner 依赖它；本轮未运行该测试。即使后续通过，也不能替代登录后的 `clientCloud` 真读写。

2026-10-09 复核：负责人提供 `npx -y @taptap/maker install --ide codex,cursor,claude` 后，命令已借助 Codex 自带 Node/Corepack 完成安装，Codex、Cursor 和 Claude 配置均报告更新；Codex 配置使用 Maker `0.0.36` 稳定运行时。按该配置原始命令执行 `mcp verify --json` 成功，阶段为 `tools_list`，包括 `maker_status_lite`、`maker_build_current_directory` 和素材生成工具。Codex 进程已在配置更新时间后重启，但本任务会话的工具列表仍未暴露 Maker 工具/资源；该检查只证明本地启动器及 stdio MCP 能列出工具，不验证此会话的配置刷新、客户端信任或项目 Roots。当前浏览器标签读取状态也连续超时。安装后的官方 CLI 对本项目执行只读 `preview status` 返回 `install_state=missing`、`state=stopped`、`process_alive=false`；未启动或恢复该预览。因此尚未取得可核实的 Maker 项目/运行状态，不能读取 `maker://status` 或验证 `clientCloud` 对真实 TapTap 账号的读写。项目 `.maker-mcp/config.json` 仍只有项目绑定信息，不含启动命令。这里的代码静态核对及本地 launcher 自检不能视为真实云存档接入验收通过；后续须在已连接且能访问此项目的 Maker 工具会话中完成云端步骤并记录结果。

2026-10-09 环境补充：负责人授权安装 Git 和 Python。Git 安装器来自 Git 官方下载页，Authenticode 签名状态为 Valid，安装后版本为 `2.56.0.windows.2`；Maker Python setup 最终报告 Python `3.12.15`、uv `0.12.24`、pip `26.2.1`，Lua LSP `0.22.2` ready。Windows 当前进程未自动刷新系统 PATH，所以 `doctor` 验证时显式加入 `C:\Program Files\Git\cmd`；请重启 Codex 后重新检查 MCP 能否发现 Git。Python setup 首次运行因安装脚本环境失败；按官方 uv 安装器流程安装至用户目录后，Maker setup 成功。重查 preview 仍是 `install_state=missing`、`state=stopped`、`process_alive=false`，未启动预览。Maker 包版本检查暂时不可用；开发套件有更新但未应用。

2026-10-09 当前会话复核：机器级 PATH 已包含 `C:\Program Files\Git\cmd`，但当前 Codex 会话继承的 PATH 仍未更新；用该路径显式执行 Maker `doctor` 报告 Git `2.56.0.windows.2`、Python `3.12.15`、pip `26.2.1`、Lua LSP `0.22.2` 均 ready。`lua-lsp doctor --json` ready；`mcp verify --json` 的 stdio `tools_list` 阶段成功，列出 `maker_status_lite` 与 `maker_build_current_directory` 等 17 个工具。当前对话的工具清单仍不含 Maker 工具，因此这些结果只证明本地 MCP 运行时自检成功，不能替代当前 Codex 会话读取 Maker 项目状态或执行云端构建。须在安装 Git 后重新启动 Codex/打开项目会话，再检查工具可见性与 Git PATH。






**2026-10-09 22:20（北京时间）当前会话复核：**使用已缓存的官方 Maker 0.0.36 CLI（PATH 显式加入 Codex Node 与 Git）运行 `doctor --target-dir`：工程绑定、设置、开发套件、Git 2.56.0、Python 3.12.15、Lua LSP 0.22.2 均 ready；但 `auth.pat=false`、`auth.tap_auth=false`。`mcp verify --json` 成功到达 `tools_list`，列出 17 个 Maker 工具，只能证明本地 MCP launcher 可启动，当前 Codex 会话仍无 Maker 工具可直接调用。

同一复核通过本机 `maker-lua-lsp --mode watch` 的 MCP 分页接口读取完整工作区诊断，而非附件前 50 条：93 个 Lua 文件，216 个错误、848 个警告、230 个提示；216 条错误分 5 页全部取回，临时 JSON 保存在系统 `%TEMP%`（未写入项目）。按文件计 `scripts/Gameplay/HUD.lua` 49 条、`tests/SeaViewUpgradeTests.lua` 36 条、`tests/Circle1HUDReviewTests.lua` 18 条最多；类别为 `undefined-field` 187、`param-type-mismatch` 22、`assign-type-mismatch` 5、`doc-syntax-error` 1、`return-type-mismatch` 1。完整错误文件清单未包含 `scripts/Gameplay/Persistence.lua` 或 `scripts/Integration/Scene.lua`，因此云存档代码没有被此静态诊断报错；这仍不证明它在真实 Maker 运行时完成云读写，也不代表全项目 Lua 检查通过。不要取消构建前检查来绕过。

此次检查还确认云存档真实验收的当前阻塞仍是账号态：Maker 没有 PAT 或 TapTap 登录态，且当前会话没有 Maker proxy 工具。登录授权应在 Maker 官方页面完成，不要把 PAT/JWT 粘贴到聊天；之后需在 Maker 运行环境创建/读取测试存档并保留成功证据。

**2026-10-09 22:21（北京时间）预览状态复核：**官方 CLI 返回已安装预览运行时（`install_state=ready`），但既有 session `40afb155-5a3a-4e93-8d75-27844f23bda7` 为 `state=stopped`、`process_alive=false`、`ready=false`；未启动预览。准备清单仍报增强引用资源 50 项截断、`dependencies_verified=false`，旧日志中的 `Cube/Day/DaySpecularHDR.dds` 与 `themis_x64.dll` 错误仍存在。Maker 本地 console 运行中；该预览是 single-player loopback manifest 模式，明确不验证云存档。后续若要实机/画面验收，需要在用户明确启动预览后重新检查新运行证据。

**2026-10-09 22:23（北京时间）活跃 Maker 配置直连检查：**Codex 的 `config.toml` 已配置 Maker MCP 0.0.36，命令使用 Codex runtime 的绝对 Node 路径，且未写入项目 cwd；以该配置的相同 Node/JS 入口做 stdio initialize + `tools/list`，成功返回 18 个工具。随后显式 `target_dir=E:\workbath\Fishing\fisherman-drift` 调用了只读 `maker_status_lite`：项目 bound、project health ready、Python/LSP ready；但 TapTap auth 与 PAT 都 missing，MCP Roots unsupported。该工具报告 `git=missing_git_repo`；本机 Git 直接检查已证实原因是仓库所有者 SID 与当前 Administrator SID 不同、Git 报 dubious ownership。没有改全局 Git 配置。当前 Codex 对话仍未注入 Maker 工具；本地 active-config 握手成功说明启动器/工具发现可用，需由 Codex 新会话刷新工具注册。真实云存档仍须先由负责人在 Maker 官方登录页完成授权；此后 Git trust 需要遵循 Maker 支持方式处理，不能用更改全局配置来绕过。

**2026-10-09 22:24（北京时间）Maker 登录授权流程：**由 CLI `login --json` 启动官方授权流程，自动打开 Maker PAT 页面并等待负责人登录/创建 token。进程当前仍在等待；登录 URL、一次性授权码和凭据均未输出到对话或项目文件。只有负责人在官方页面完成授权后，CLI 才会把凭据写入本机 Maker 配置并请求 TapTap auth；之后还需重新运行 doctor/status 确认 `pat=true` 与 `tap_auth=true`。

**2026-10-09 22:31（北京时间）账号授权完成、Maker 状态工具验收：**上一轮 CLI 登录进程正常退出；本地 `doctor` 现在显示 `pat=true`、`tap_auth=true`。使用活动 Codex MCP 配置手动直连 `maker_status_lite`（显式指定 target_dir，跳过远程同步）验证：云端代理/build 工具可用、项目绑定且工程健康；目前 Maker 进程因 PATH 未包含 Git 而得到 `spawnSync git ENOENT`，Git 目录检查因此为 `missing_git_repo`。本机对该仓库执行 `git -c safe.directory=E:/workbath/Fishing/fisherman-drift rev-parse --show-toplevel` 可识别仓库；当前 Git 的 owner SID 与执行用户不同，若不设置 safe.directory 会被 Git 拒绝。仅在一次性子进程环境同时设置 Maker 支持的 `TAPTAP_MAKER_GIT_BIN`、Git PATH 和仓库范围的 `GIT_CONFIG_COUNT` 安全目录后，Maker status 将其判定为 `usable_for_build_submit=yes`；这只是作用域验证，未更改持久配置。由于这会改变该 MCP 进程对特定仓库的 Git 信任范围，按项目政策等待负责人确认后再写入活动 Codex 配置。登录由官方 CLI 直接保存至本机；任何用户消息中的 token 字符串均未复制进项目或日志。


**2026-10-09 22:34（北京时间）Maker Git 进程环境配置完成：**负责人授权后，已在 `C:\Users\Administrator\.codex\config.toml` 的 `[mcp_servers."taptap-maker".env]` 中新增 Maker 支持的 Git 可执行文件路径及只包含本项目的 `GIT_CONFIG_COUNT` safe.directory 设置。系统/全局 Git 配置未修改；Python `tomllib` 校验配置有效。使用从该 TOML 加载的原始 Node/JS 命令重新 initialize 并调用 `maker_status_lite`，认证文件可见、`git_installed=yes`、`git_root` 为本工程、`usable_for_build_submit=yes`、代理/build 工具可用。此验证通过独立 MCP 进程完成，桌面当前对话尚未加载新环境；仍需重新启动/刷新 Codex MCP 会话。用 `uv run --no-project --with lupa` 临时环境运行现有 `Circle1B3CloudTests`，10/10 项通过；依赖只进入 uv 缓存，没有安装到项目或 Maker Python。它验证的是 fake-SDK 回调协议，仍不能替代真实服务端保存/读档。

**2026-10-09 22:35（北京时间）云适配器协议回归：**通过 uv 临时运行环境（`--no-project --with lupa`，未改项目依赖）调用仓库现有 `Circle1B3CloudTests`，10/10 通过、0 失败、0 跳过。覆盖 `Get` values 参数/空档/响应校验、`Set` 快照拷贝与重复回调、超时、SDK 错误、同步拒绝、抛错、无 backend、消费者回调异常。该结果证明本地 mock 下适配器协议符合预期；仍不能证明 Maker 真实 `clientCloud` 服务端写入、退出重进后的读取、或玩家账号数据隔离。


**2026-10-09 22:42（北京时间）补充核验：** 从当前 Codex Maker MCP 配置读取启动命令和环境变量，调用稳定 self runtime 的 `mcp verify --json`，结果 exit_code=0、ok=true、stage=tools_list、tool_count=18。此项只证明本机 MCP 启动器可完成 initialize/tools/list；本会话的工具目录仍没有 Maker 工具，因此不代表本会话可调用 Maker 项目工具或真实云存档已经验收。

同日复核 TapTap 制造 2026 白皮书和官方游戏物料规范 v4。白皮书首次发布前检查要求核心玩法完整、首分钟目标/操作易懂、名称/icon/五图/视频/标签一致、启动运行退出更新正常，并核对当前平台合规资料。官方物料规范标注：图标和 16:9 宣传图为必填；游戏截图至少 3 张并需以真实玩法画面为主；开放下载/试玩时需提供实机录屏。它们是平台公开发布规格，赛事 Maker 挑战表单的必填项仍须以挑战页面为准。Feishu 模板链接本次无法由浏览工具直接读取；本地素材稿仍是待核实填写稿，不是已签署或已分享的模板副本。


本轮逐文件检查 `screenshots/`：目录内 5 张 PNG 均为 2026-10-01 20:54:55–57 创建；横屏 1280×720 三张、竖屏 540×960 两张，当前图标 512×512 PNG（138,507 字节），16:9 宣传图 1920×1080 JPG（349,172 字节）。这些截图时间早于当前版本，不能作为当前版本实机截图验收；本机没有新录制的视频，项目元数据中的实机截图数组仍需在 Maker 提交构建后核实。

2026-10-09 22:50 Maker 控制台通过“Lua 检查”触发新一轮完整项目诊断，任务结束时间 22:50:54，Maker Lua LSP 0.22.2 返回 `status=failed`、`errorCount=207`。本轮摘要含 Gameplay/Loop.lua、Gameplay/Circle1B2Barrel.lua、Ocean/PerfProbe.lua、Systems/FishSystem.lua/ClockSystem.lua 及多个测试文件的类型错误。预览显示已安装但已停止，未启动；远端构建状态仍为“尚未构建”。