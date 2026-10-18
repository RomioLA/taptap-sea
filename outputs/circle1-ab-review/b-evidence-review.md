# B 交付说明与完成版证据核对

核对范围：D 盘 B 项目及其 `outputs/circle1-b{,2,3}`、三份外部交付说明、当前 C 盘 A3 源码与 `outputs/circle1-a3`。只读完成；未运行 B runner、LSP、预览、云端或构建命令，也未改动生产代码或 D 盘证据。

## 结论

三份外部交付说明与 B 各轮归档说明逐字节相同。B3 `delivery-hashes.json` 列出的 29 个文件当前大小和 SHA256 全部匹配。B3 `protected-before.json` 列出的 285 个既有文件也全部存在；除三项授权玩家测试外，其余哈希匹配基线，三项授权改动匹配 `protected-result.json` 记录的 after-hash。

B3 对模拟与原生验收的界限总体写得准确：Movement 是真实 Lua `Ocean.SeaRuntime`/`Ocean.Movement` 模块在 Lupa 无窗口环境中的运行；云端测试使用本地 SDK 替身；七天路线使用确定性鱼和测试港口适配器；UI 仅有控件树证据。根线程随后用授权的组合检查器读取当前 C 盘 A3 Ocean 和 D 盘 B 玩法模块，取得六项实际模块 smoke 通过；原生窗口、真实云服务、跨设备恢复仍未验证，完整正式流程也未验收。

但 B3 的 A 接口缺失表与当前 C 盘 A3 源码不一致，不能继续作为当前阻塞状态引用。原始 B3 runner 在归档位置执行会覆盖 B3 原证据；当前 C 盘也没有 B3 runner 文件。组合检查已将 A3 的 Ocean 模块与 B 玩法模块实际接起来，但仍有一个 B3 负向夹具失效和透镜关闭真实契约错误。跨轮重复的 `SeaFusedSceneTests` 错误属于 D 盘 B 快照里的旧 HUD 形状，不能直接归为当前 A3 缺陷。

## 逐项发现

1. **交付文本一致。** 外部 `交付说明1/2/3.md` 与 B 归档对应文件的长度和 SHA256 相同：
   - 1：10,320 字节，`7ADCCEA8672422D2A62D3B886E6D71BA4906E518BFBECA212448090A73782083`
   - 2：13,394 字节，`3B811D6EDEA64BF2885AB686BEC2198B04D81029C59291BE7F8F3592EF28D457`
   - 3：14,888 字节，`840D01D468EC518C15B51ECA0B1D0A6A950684A56F8CBCD1C4BA948A1ED077DB`

2. **B3 哈希清单匹配，但不是整目录签名。** 清单中的 29/29 项均通过实际 `Get-FileHash -Algorithm SHA256` 和大小复核。保护基线的 285 项也均匹配，其中三项玩家测试文件按 `protected-result.json` 的 after-hash 比较。清单未包含自身、两个中间预览状态和八个 `.before` 备份，因此不应称为 B3 输出目录全量哈希证明；`protected-result.json` 的范围也仅覆盖其列出的既有文件。

3. **B3 对测试边界的主要表述可信且有限定。** `Circle1B3EconomyTests.lua` 经 `Ocean.SeaRuntime.New()` 创建 Runtime，源码实例化 `Ocean.Movement.New()` 并检查位移，所以“实际 Movement 模块”是合理描述；但这是 Lupa/纯 Lua 运行，不能证明 Maker 原生输入、物理、窗口或当前 C 盘新版 Movement。`Circle1B3CloudTests.lua` 文件头明确使用 local SDK double；`seven-day-evidence.json` 标记 `test-only ocean/port adapter`、确定性模拟鱼，路线运行约 0.03 秒；`regression-result.json` 明示 `guiVerified=false`、`realOceanRuntimeVerified=false`、`realCloudVerified=false`。B3 把这些测试称作模拟/协议验证，没有把它们写成真实海洋、云端或真人七天验收。措辞上“真实 Movement”最好始终与“Lua 模块、无窗口”连在一起，避免读者误解为原生实机。

4. **B3 的 A 接口矩阵是另一份源码快照。** B3 `integration-evidence.json` 记录八个接口缺失且 `Ocean.Bootstrap` 未消费识别/捕鱼视图回调；当前 C 盘 `scripts/Ocean/SeaRuntime.lua` 已定义 `GetPortPosition`、`ResetShipAtPort`、`LockFishingTarget`、`UnlockFishingTarget`、`GetFixedBarrel`、`CanInteractWithBarrel`、`SetScopeEnabled`、`IsScopeEnabled`。当前 `Bootstrap.lua` 会接受 `onSeaPointer(...) == true` 并读取 `getFishingView`/`isLocationRecognized`。因此 B3 缺失列表应标为“B3 所测快照”，不能继续当当前接口清单。根线程的组合结果在当前源码下取得 6/6 实际模块 smoke，并运行了 B3/前轮/玩家测试；这提供了无窗口组合证据，但不等于原生窗口、真实云或正式用户流程验收。B3 报告只写日期、JSON 没有生成时间，且 D 盘 B 树与当前 C 盘树已分化；不能仅凭路径字符串认定它测的就是当前 C 树。

5. **`SeaFusedSceneTests` 的失败在 B 三轮重复，但不是当前 C HUD 的同一调用。** B 的 b、b2、b3 回归都记录 `Ocean.HUD.lua:26` 调用不存在的 `IsPaused()`。B 盘 HUD 确有该调用；当前 C 盘 HUD 使用 `state.paused`，没有 `IsPaused()` 调用。组合回归中的 `SeaFusedSceneTests` 在当前 A3 Ocean 下通过，说明该历史失败不应归为当前 A3 缺陷。B1 的旧 `ShopStockSpec` 空网扣体力断言在 B2 已改正，B2/B3 报告为通过；不应重复列作当前失败。

6. **原始回归有失败；当前组合复跑结果更进一步，但仍未全绿。** B3 归档 `regression-result.json` 有 72 个 Lua 语法文件、62 项本轮专项、63 项前轮协议和五份玩家脚本通过；其旧 A 回归保留 9 个失败、11 个跳过，`allExecutedPassed=false`、`allRequestedVerified=false`、退出码 1。根线程隔离组合复跑中，当前 A3 Ocean + B3 玩法的 B3 专项为 61 通过、1 失败，前两轮 63/63、五份玩家脚本通过；原样旧 A 回归是 45 通过、7 失败、0 跳过；当前 A3 六个专项 26/26。B3 唯一新增专项失败是 `missingPort=true` 负向夹具没有隐藏 `Runtime.__index` 上继承的方法，故没有真正构造缺接口运行时，不应视为当前港口产品回归。组合旧 A 回归中仍有旧断言/夹具不匹配及一个 Runtime façade 兼容失败；详见同目录 `复查说明.md` 与 `b-contract-review.md`。

7. **组合测试暴露透镜关闭的实际契约错误。** B `Loop:ToggleScope()` 把 `SetScopeEnabled(false)` 的 `false` 当作拒绝；当前 A `SeaRuntime:SetScopeEnabled(false)` 成功关闭后返回当前状态 `false`。B 随后误报 `scope_sync_failed` 并恢复本地状态，透镜实际又被打开；场景 Stop 第一次也会因误报拒绝。组合结果的 `scope_contract_reproduction` 已复现。B2 透镜协议替身对成功设置固定返回 `true`，没有覆盖当前 A 的状态返回契约。这是实际产品逻辑问题，与“云未验证”或旧接口表不同；详情及建议见 [b-contract-review.md](b-contract-review.md)。

8. **项目文档的策划版本口径不一致，应按最新用户 AGENTS 执行并同步文档。** B `AGENTS.md` 的项目约定称 2026-10-02 工作簿 Sheet1 为 V1 基线，Sheet5/6 是过程稿；B `docs/ARCHITECTURE_LAYOUT.md` 则称 v2.1 与后续确认是当前依据、旧版 Sheet1/5/6 不能替代新确认条款。当前用户提供的 AGENTS 对策划优先级有明确指示，应以该指示为准，并将架构文档口径同步；这是文档维护项，不是继续实现或验收的阻塞。代码范围方面，B3 本轮清单集中在 `Gameplay/`、`Integration/` 和测试；`Bridge` 仅保存 Loop/Game 引用，跨模块目标由 Gameplay 动作接口提供，未见它自行保存跨帧玩法状态；B3 没有改 `Ocean/`、`Game/World.lua`、`Main.lua` 或 `Systems/`。从清单与静态搜索看，本轮报告所述目录边界与项目架构约定相符。

## runner 风险与复验建议

`Circle1B3Run.py` 用 `Path(__file__).resolve().parents[2]` 决定源码根目录，并把 `.tmp/game-loop-test-runtime` 加入模块搜索路径；第 110 行创建 `outputs/circle1-b3`，第 164–165 行无论选哪个 suite 都写 `regression-result.json`。`Circle1B3Lsp.py` 第 120–121 行也会创建目录并覆盖 `lsp-result.json`。因此不应在 D 盘 B 原件上直接执行交付说明里的命令。`-B` 只避免 Python 字节码缓存，不能避免覆盖 JSON。当前 C 盘 `scripts/Tests` 下不存在 `Circle1B3Run.py` 或 `Circle1B3EconomyTests.lua`，所以交付说明里假定的 C 盘命令在当前 checkout 也不能复现 B3。

本次只做了下面的只读哈希复核，没有运行任何测试：

```powershell
$root = 'D:\sillytavern-data\taptap-sea-B'
$manifest = Get-Content -Raw (Join-Path $root 'outputs\circle1-b3\delivery-hashes.json') | ConvertFrom-Json
$results = foreach ($entry in $manifest) {
    $path = Join-Path $root ($entry.path -replace '/', '\')
    if (Test-Path -LiteralPath $path) {
        $file = Get-Item -LiteralPath $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        [pscustomobject]@{ Path=$entry.path; BytesMatch=($file.Length -eq $entry.bytes); HashMatch=($hash -eq $entry.sha256) }
    } else {
        [pscustomobject]@{ Path=$entry.path; BytesMatch=$false; HashMatch=$false }
    }
}
$results | Where-Object { -not $_.BytesMatch -or -not $_.HashMatch }
```

当前线程已有安全的组合检查入口：[run_review.py](run_review.py)。按用户“看看”的授权运行 `python -B outputs/circle1-ab-review/run_review.py` 会只读加载当前 C 盘 A3 的 Ocean/Systems/FSM/Entities 与 D 盘 B 的其他模块，并把结果写到当前授权的 `outputs/circle1-ab-review/composition-results.json`；它不调用 B runner 的 `main()`，不会覆盖 D 盘 B3 原始报告。当前运行结果见同目录 `summary.json` 和 `复查说明.md`。要复现 B 原样 runner，仍不可直接调用 D 盘脚本；需通过隔离组合器或把其输出重定向到审阅目录。任何上述 Lua/Lupa 结果都不代表原生窗口或云端验收。
