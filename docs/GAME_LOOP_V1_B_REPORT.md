# TAPTAP-JAM-GAME-LOOP-V1-B 本地交接报告

日期：2026-10-02（Asia/Taipei）。RESULT：PARTIAL（B 模块与 mock 验收完成；宿主接入、真实云读写和画面验收待人工/A）。

数值与经济补充已实现：当前值及新增接口以 `GAME_LOOP_V1_B_NUMERIC_UPDATE.md` 为准；以下保留模块初次交接背景。

## 项目身份与边界

- 实际 cwd：`C:\codex\taptap-sea`。
- 正式项目：渔夫漂流记。本地 project_id `m_009f`；Maker App UUID `6fb01c73-66b3-4356-b987-3669be7f8a44`，按用户最终身份修正 PASS。这两个标识不需要相同。
- 未修改任何既有文件。`Main.lua`、`Game/Game.lua`、`Ocean/State.lua`、`Ocean/HUD.lua`、`Ocean/Draw.lua`、`Ocean/Config.lua`、World/Entity/FSM 均保留原样。
- 未修改 AGENTS.md、.gitignore、.project/project.json、.maker-mcp/config.json、项目依赖或其他 Maker 元数据；未改绑定、init/clone、移动或删除项目。
- 没有临时修改共享入口，所以不需要恢复。没有 branch、commit、push、PR/MR、远端 build/submit。
- 预览 status 为 `stopped`、`process_alive=false`；按工作流未启动/刷新。没有 GUI、截图、点击或录制。

## 实际完成步骤

1. 阅读项目规则、实际源码、项目配置、素材目录及 Lua/UI/本地存储/客户端云变量文档。确认原项目只有海洋演示状态和 World 协调层，没有可复用的 PlayerState/Inventory/persistence/UI Store。
2. 完成 Maker status 与显式 target-dir doctor：指向本项目，开发资料完整。CLI doctor 的 Python 缺失与 LSP venv 失效经本机命令证实；没有改系统设置。
3. 新增配置与唯一物品数据源，声明暂定参数，保留四项正式内容和五种分类框架。
4. 新增 PlayerState、不堆叠 Inventory 和当前周目的地点/宝藏/剧情/老人状态。
5. 新增独立 GameClock，提供暂停原因集合、昼夜切换、倍率、指定阶段跳时和夜晚终点钳位。
6. 新增 Loop：动作门槛/成本、食用、赠送、投放交接、返港/再出航、港口交易、主动结束今天、强制返港、结算与云存档。
7. 新增功能原型 HUD、开发工具和显式 Bootstrap；HUD 不接管宿主 UI.Init/SetRoot/Shutdown，不修改旧入口。
8. 完成纯 Lua 5.4 验收、非 GUI UI 结构/回调验收、10 个新增运行模块的实际本地 LSP 诊断，并给出下述接线与手动验收步骤。

## 新增文件 / 修改文件

新增运行代码（10 个）：

```text
scripts/config/gameplay.lua
scripts/data/items.lua
scripts/Gameplay/PlayerState.lua
scripts/Gameplay/Inventory.lua
scripts/Gameplay/GameClock.lua
scripts/Gameplay/Loop.lua
scripts/Gameplay/Persistence.lua
scripts/Gameplay/HUD.lua
scripts/Gameplay/Debug.lua
scripts/Gameplay/Bootstrap.lua
```

新增测试（4 个）：

```text
scripts/Tests/GameLoopSpec.lua
scripts/Tests/GameLoopUISpec.lua
scripts/Tests/run_game_loop.py
scripts/Tests/check_game_loop_lsp.py
```

新增交接文档：本文件。修改既有文件：无。删除文件：无。

测试用 Lupa 2.8 位于已忽略的 `.tmp/game-loop-test-runtime`，仅为纯 Lua 验收，不是游戏依赖；LSP完整结果在 `.tmp/game-loop-lsp-result.json`。没有修改依赖配置。

## gameplay 配置完整值

权威文件：`scripts/config/gameplay.lua`。

```lua
initial = {
  maxStamina = 100, stamina = 100, money = 100, day = 1,
  items = { "apple", "bait" },
}
stamina = { fishingCost = 40, salvageCost = 40, sailingCost = 0, eventOperationCost = 40 }
clock = {
  daySec = 120, nightSec = 60, graceSec = 30,
  penaltyPerSec = 1, forcedStaminaRatio = 0.5,
}
inventory = { capacities = { 5, 10, 15, 20 } }
upgrades = {
  stamina = { maxima = { 100, 160, 200 }, prices = { 400, 600 } },
  inventory = { prices = { 300, 600, 900 } },
  boatSpeed = { metersPerSec = { 6, 8, 10 }, prices = { 350, 750 } },
}
drop = { lifetimeSec = 20 }
location = { recognitionDistance = 20 }
debug = { timeScales = { 1, 5, 20 }, staminaStep = 20, moneyStep = 100 }
persistence = { key = "sea_game_loop_v1", schemaVersion = 1 }
```

`V1_IMPLEMENTATION_VALUE`：本轮补充已确认初始 money、升级序列/价格、物品买价/恢复量和投放生命周期。地点识别距离仅提供语义配置，B 未实现距离检测或像素/世界坐标转换。

## items 配置完整值

唯一权威文件：`scripts/data/items.lua`。商店/HUD/Inventory/Drop 都读取 `Items.GetDefinition(id)`；返回副本。生命周期统一读取 gameplay.drop，没有第二份价格表。

| ID / 名称 | category | 买价 | 卖价 | heal / canEat | canGive | worldEffect | lifetimeSec |
|---|---|---:|---:|---|---|---|---:|
| apple / 苹果 | food | 30 | 0 | 20 / true | true | ATTRACT_SMALL_FISH | 20 |
| bait / 鱼饵 | bait | 20 | 0 | 0 / false | true | ATTRACT_SMALL_FISH | 20 |
| sardine / 沙丁鱼 | fish | 未提供 | 70 | 10 / true | true | ATTRACT_BIG_FISH | 20 |
| tuna / 金枪鱼 | fish | 未提供 | 120 | 20 / true | true | NONE | 20 |

分类表：`fish, food, bait, treasure, misc`。世界效果表：`ATTRACT_SMALL_FISH, ATTRACT_BIG_FISH, NONE`。没有新增具体 treasure/misc、其他食物/鱼类，未来具体宝藏价格由各自定义提供。

业务逻辑没有重新硬编码价格、体力成本、昼夜时长、容量或恢复量。测试中的固定预期值是验收判据；UI 布局尺寸不属于 gameplay 数值。

## 测试结果与验收证据

测试解释器为 Lua 5.4，运行实际模块；云和投放接收方使用 mock，不请求云服务或启动引擎。数值更新后最后验收：20组规则、5组UI mock、84项存档回归、21组数值经济测试、14个Lua文件语法全部通过；LSP 10/10运行模块、0 Error、44 Warning。

执行（PowerShell 7，cwd 为项目根；这里使用本机已存在的 Python）：

```powershell
Set-Location 'C:\codex\taptap-sea'
& 'C:\Users\Administrator.DESKTOP-NS4I6RF\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' scripts/Tests/run_game_loop.py
& 'C:\Users\Administrator.DESKTOP-NS4I6RF\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' scripts/Tests/check_game_loop_lsp.py
```

预期：`GAME_LOOP_SPEC_PASS 20`、`GAME_LOOP_UI_MOCK_PASS 5`、`PERSISTENCE_REGRESSION_PASS 84`、`NUMERIC_ECONOMY_SPEC_PASS 21`，退出0。测试解释器由提升权限下载，因此当前Codex sandbox下仅提升执行可读；普通本机终端可复验。测试脚本不自动下载安装依赖。

LSP：现有 MCP 的单文件缓存返回无 Error，但其默认工作区不能证明 sea 全覆盖。本任务另直接调用已安装 EmmyLua binary，以 sea/scripts 为 root，使用 Maker 文档/实现确认的配置注入（Lua5.4、绝对 .emmylua library、urhox-libs packages），不修改现有 .luarc 或 MCP config。全部 10 个新增运行 Lua 收到诊断，Error=0；仍有非阻塞类型/控制流警告，未宣称零警告。完整信息见 `.tmp/game-loop-lsp-result.json`。

| 原验收项 | 本地证据 / 结果 |
|---|---|
| 1 初始体力100 | configuration、stamina 测试 PASS |
| 2 苹果+20且有上限 | food use 测试：90吃到100 PASS |
| 3 沙丁鱼可吃+10 | food use PASS |
| 4 金枪鱼可吃+20 | food use PASS |
| 5 完整捕鱼/打捞扣40 | stamina 测试+开发按钮接线 PASS |
| 6 不足40不得开始 | CanStartAction 与 CompleteAction 测试 PASS |
| 7 初始5格 | configuration/inventory PASS |
| 8 同类不堆叠 | 五条沙丁鱼占五格 PASS |
| 9 一个物品一格 | Inventory数组和容量拒绝 PASS |
| 10 最大20 | 5→10→15→20并拒绝再升级 PASS |
| 11 昼120夜60 | 边界、阶段转换、耗尽钳位 PASS |
| 12 背包暂停 | 多原因+UI按钮接线 PASS |
| 13 老人暂停 | 多原因+赠送/离开按钮接线 PASS |
| 14 夜前30秒无罚 | 夜0/30/30.9边界 PASS |
| 15 晚归逐秒处罚 | 夜40→90、55→75、59.9→71 PASS |
| 16 夜60强制弹窗结束 | 完整Loop与HUD按钮回调 PASS；像素布局待人工 |
| 17 比例恢复 | 上限120→60，默认100→50 PASS |
| 18 苹果30/鱼饵20 | data与交易余额 PASS |
| 19 沙丁鱼70/金枪鱼120 | data与出售余额 PASS |
| 20 结算自动保存 | 确认后调用Save，成功/失败/重试 PASS；真实云待人工 |
| 21 无事件额外自动保存 | 交易/赠送/消耗/识别后writes=0 PASS |
| 22 海上不手动保存 | Loop无Save方法，海上EndToday/LoadSaved拒绝 PASS |
| 23 新周目全重置 | 玩家/背包/升级/宝藏/剧情/老人+resetDynamicWorld mock PASS |
| 24 地点不跨周目 | 新周目recognizedLocations为空，存档roundtrip PASS |
| 25 数值集中 | config/data回读、业务引用审查 PASS |
| 26 HUD基础信息 | 常驻天/阶段/剩余/体力/钱/背包/内容/暂停mock PASS；真实画面待人工 |

额外验证：特殊事件暂停禁止动作；多暂停原因互不解除；返港保存当天时间可再出航；失败读档不覆写当前状态；读档中拒绝交易/出航；无接收方/拒绝/异常投放保留物品；接收回调重入不重复扣除；只有成功存档后 onNewDay 调用一次；Debug 非开发模式拒绝执行、保存期间拒绝改状态。

## persistence 语义与限制

- 使用文档明确的客户端 `clientCloud:Set(key, table, {ok,error,timeout})` 和 `Get` 返回的 `values[key]`，不假设本地文件刷新后持久化。
- schema v1保存day、maxStamina、stamina、money、boatSpeedLevel、inventory ID数组、inventoryLevel、inventoryCapacity、recognizedLocations、treasures、story、elder；旧快照缺失boatSpeedLevel按1恢复。不保存船位/普通鱼位置/FSM。
- 唯一正式自动写入是确认每日结算：推进下一天并制作快照，保存时冻结普通/Debug变更。失败保留快照与结算状态，按钮重试同一结算，不重复加天数；成功解除结算锁，再调用 onNewDay。
- 失败/超时/重复回调有保护；读档检查版本、有限数值、库存容量/密集数组/物品ID及状态表。剧情/宝藏/老人扩展目前使用字符串键的 JSON 兼容状态表。
- 海上没有手动保存 API；新周目不额外自动存档，下一次每日结算覆盖旧存档。新周目尚未结算即退出再读档时仍会读旧周目最后一个结算存档，这是“仅结算保存”规则的直接结果；未擅自删除云记录或新增存档点。
- clientCloud真实账号、离线/权限/刷新持久化未执行；仅接口与异步语义mock通过。

## SKIPPED_NEEDS_DECISION / 已知问题

| 问题 | 原因与文件 | 推荐方案 | 阻塞范围 |
|---|---|---|---|
| 船舱付费升级价格 | 已确认300/600/900并接入Loop与HUD | 交易及UI mock已验证 | 已解除 |
| 真实云/画面验收 | 用户UI额度规则优先人工；未接入共享Main | A接线后按下一节人工验收 | 不阻塞模块规则测试，不能宣称实机PASS |

已有 Main 仍加载旧 Ocean HUD 与旧 State.time；B 时钟尚未控制实际 World.Update/船只输入。没有建立平行 Sea World，只新增任务要求的玩家玩法域。当前预览直接运行不会自动显示新B HUD。

## 明天 A/B 集成接口和顺序

1. 宿主先 `UI.Init`；若保留已有HUD，由A准备可挂载的容器。只有A调整现有入口/Ocean HUD。
2. `require("Gameplay.Bootstrap")`，调用 `Bootstrap.Init(options)`，返回 `loop, hud, Update, Stop`。有 parent 就插入该父容器；无 parent 时宿主负责 `UI.SetRoot(hud.root)`，Bootstrap不自动接管根。
3. Update 事件转交原始、有限、非负的 dt（不要沿用旧动画0.05秒钳位来计全天时钟）。世界更新依据 `loop.clock:IsPaused()`；已有手动暂停改用 `Pause("manual")/Resume("manual")`，背包/老人/港口/事件重叠由独立reason控制。
4. 完整世界动作开始前 `loop:CanStartAction("fishing"/"salvage")`；成功完成时调用 `loop:CompleteAction(...)`，取消/失败不要扣体力。航行成本0，体力为0仍允许返港。
5. `dropReceiver(payload)`：A负责把payload与真实worldPosition交给 `spawnDroppedItem`/接收队列；只有交接成功同步返回true，B才删除物品。异步spawn先进入可靠队列，再返回true；拒绝/异常返回false，不能在接受后重复调用B删除。世界只消费worldEffect，不按category猜生态，不把pixel当world unit。
6. `elderReceiver(itemId)`（可选）返回 `true, feedback`；未注入时默认文本占位，赠送不恢复体力。
7. `onNewDay(day)`（成功存档后）刷新A普通鱼/动态世界；`resetDynamicWorld()`（新周目）清除A动态状态。两者B不实现世界逻辑，hook异常只反馈不回滚已经成功的存档。
8. 地点侧检测真实距离后 `loop.player:MarkRecognized(locationId)`；读取 `IsRecognized`。配置距离20仅供世界集成，B不测距。
9. 本地开发显式 `development=true`，正式版本默认不启用Debug。退出时 `Stop()`，再由宿主清理自己的UI/事件。

接线示意（供A明天修改宿主，不是已经接入的代码）：

```lua
local Bootstrap = require("Gameplay.Bootstrap")
local loop, hud, updateGameplay, stopGameplay = Bootstrap.Init {
    parent = gameplayContainer, -- 已挂到宿主UI根；或省略后由宿主SetRoot
    development = true,
    dropReceiver = function(payload)
        return dropQueue:Accept(payload, worldRuntime:GetPlayerWorldPosition())
    end,
    onNewDay = function(day) worldRuntime:ResetDailyDynamicWorld(day) end,
    resetDynamicWorld = function() worldRuntime:ResetRun() end,
}
-- 原 Update:
updateGameplay(eventData:GetFloat("TimeStep"))
-- 原 Stop:
stopGameplay()
```

`gameplayContainer/dropQueue/worldRuntime` 是A待提供的集成对象，B没有伪造实现。若只测B规则，注入内存store/mockReceiver，禁止把mock接收成功当作世界已生成。

## 手动实机验收

完成上述接线后，再由用户主动启动本地预览；当前停止会话不能自动复活。

1. 查看HUD：第1天、100/100体力、钱100、2/5格、苹果/鱼饵；港口暂停。
2. 出航观察剩余时间减少；打开背包暂停，关闭恢复；返港暂停，老人对话/背包重叠关闭一个不会误恢复。
3. 开发工具执行捕鱼/打捞各一次体力剩20，第三次拒绝；苹果恢复并封顶，鱼类可食用。
4. 开发跳夜40秒返港并确认结算，下天90；55秒→75；夜60秒应立即出现“夜深了，你必须返港。”，确认后下天50。
5. 买苹果/鱼饵、卖两种鱼，检查data价格和每物品一格；A尚未提供接收方时投放应失败保留物品。
6. 登录真实Maker测试账号确认结算显示保存成功，退出/重新加载后读回钱/库存/天数/地点。断网结算应显示失败，恢复网络重试只推进一天。
7. 实际接收/刷新世界由A负责，核验worldEffect与坐标转换、普通鱼刷新，并确认暂停期间世界行为与B时钟同步。

本地工作区：仅上述新增文件待人工验收/同步；没有正式提交或push。
