# 圈1第二批 · 电脑 A 交付

四项本机独立任务已完成，最终运行器通过。上一批捕获锁定和 5 秒捕食冷却保持原实现，并通过原有回归。未提交、推送或远端构建，没有启动已停止的预览。

## 逐项结果

| 任务 | 结果 | 实现及边界 |
| --- | --- | --- |
| 透镜海洋底层 | 完成 | 船前方 20 米、总角度 90°，边界包含；直接读取当前船位置和朝向，停船保留朝向。`Runtime:SetScopeEnabled(enabled)` / `Runtime:IsScopeEnabled()` 持续开关，仅影响可见性，不暂停、不影响鱼 AI 或捕鱼资格。重置后关闭。既有 `revealWithScope(center, durationSec)` 定时圆和调试观察圆保持独立兼容。 |
| 捕鱼表现与指针 | 完成海洋端契约 | 现有 NanoVG 绘制网心、8 米网圈、约 0.5 秒落水及收网；收缩表现使用已确认的 4 秒总时长。完全读取 B 的 phase/center/elapsedSec，不选鱼、计时、扣费、完成行动或改写快照。Bootstrap 的可选 `getFishingView()` 缺失或返回 nil 时正常运行；`SeaDraw.Scene(ctx, width, height, runtime, clock, fishingView)` 保留第五个时钟参数。指针回调先于航行目标，只有返回 true 消费点击；UI 命中、暂停、鼠标/触摸坐标换算、合法海域检查保留。30 米抛网距离和一次最多一条的原有海洋规则未改变。 |
| 海鸟、水花提示 | 完成 | 小鱼上浮 2 秒、两只鸟、首次约 1.5 秒俯冲、中心偏移 9 米、半径 3 米均保留。海鸟关联真实活跃小鱼，不要求逃跑、不捕食；来源和完整提示圈满足合法水域与 18 米感知约束。大鱼普通 1 秒、追猎 0.5 秒水花，寿命 0.6 秒、短迹 2 米。锁定、捕获/被吃/移除、冻结、重置、非法或失效位置撤销提示；getter 只读，暂停不推进计时。 |
| 性能、稳定性 | 检查完成，收益与代价并存 | 单次更新收集两类鱼，成员不变时复用 ID 顺序，原位压缩水花数组；一批合法性检查只收集一次当前阻挡物；裁掉完全屏外形状，保留部分可见形状。未减少鱼数量、活动范围或添加数量上限。见下方实测。 |

## 最终验证

最终依据是 [validation.json](validation.json) 和 [validation-console.txt](validation-console.txt)，中间定向诊断文件只用于排查过程。

- Lua 5.4 语法：61/61 文件通过。
- 海洋及既有兼容回归：11 个模块，141/141 项通过，包括捕获锁定、5 秒冷却、上浮、海面提示、稳定性与现有 A/B 接口回归。
- 离线绘图：SeaFusionRenderTests 10 项、Circle1A2FishingTests 5 项全部通过；合计 156 项回归/绘图检查。
- 本批新增测试：Circle1A2ScopeTests 9 项、Circle1A2SignalsTests 7 项、Circle1A2FishingTests 5 项。覆盖角度/半径边界、朝向和停船、开关、暂停、重置、非法数值、旧圆兼容、绘图快照只读性、第五时钟参数、指针消费及坐标守卫、提示即时失效。
- Maker EmmyLua：配置过滤后的错误 0；原始错误 41，与上一批 A1 基线 41 相同，新增原始错误 0。项目既有原始诊断仍存在，本次没有将其宣称为全项目原始错误清零。详见 [lsp-summary.json](lsp-summary.json)。
- 文件边界与已有证据保护检查通过，详见 [boundary.json](boundary.json) 和 [delivery-manifest.json](delivery-manifest.json)。

## 性能及输出等价

对比本批修改前保存的 Ocean 源码与当前源码。种子 271828、314159；相同默认场景、8 段航行输入、每次 240 步 × 0.05 世界秒，预热后各 5 次取中位数。鱼/船轨迹摘要、四个检查点的提示快照摘要及提示数量在两种子下全部一致。

| 指标 | 修改前 | 修改后 | 结果 |
| --- | ---: | ---: | --- |
| 初始化 CPU | 7.0 ms | 7.0 ms | 基本相同 |
| 240 步更新 CPU | 102.5 ms | 94.5 ms | 降低约 7.8% |
| 1200 对鸟/水花 getter CPU | 37.0 ms | 63.0 ms | 增加约 70.3%，每对约多 21.7 微秒 |
| 场景 Lua 内存增量 | 416.1 KiB | 470.5 KiB | 增加约 54.4 KiB / 13.1% |
| 横屏 NanoVG 调用 | 1286 | 1198 | 减少 88 |
| 竖屏 NanoVG 调用 | 1286 | 1154 | 减少 132 |

即时来源/水域/圈区检查带来 getter 成本；为确保同帧直接位置修改、冻结、锁定或阻挡物变化能撤销提示，没有跨读取缓存合法性。内存结果也没有改善，不能据此称为所有热路径全面提速。CPU 是微基准测量，内存是 Lua 场景差值，并非原生引擎峰值或分配总量。

性能场景采样到 38–42 只鸟/读取，水花记录为 0；大鱼水花时序和失效由定向回归覆盖，该性能场景不代表水花密集场景。详细结果见 [performance-comparison.json](performance-comparison.json)。

种子 31415 的相同六鱼绘图场景，横屏 1920×1080、竖屏 1200×1150，修改前后 PNG SHA256 完全相同，包含完全屏外及部分跨边界鱼。详见 [draw-equivalence.json](draw-equivalence.json)。离线图片已经目视检查，属于 NanoVG 离线记录，不能当作原生游戏窗口截图。

## 未验证、失败、临时值和跳过项

- **失败：**最终回归、语法、类型增量及边界检查无失败。性能读取与内存的退步如上，不隐藏为优化成功。
- **未验证：**B 的真实捕鱼接线没有验证。当前本机 `scripts/Integration/Scene.lua` 未提供 `getFishingView()`，原有 `onSeaPointer` 也未返回 true；本次只验证海洋端契约和模拟快照，没有越界修改 B 文件。既有 ABIntegrationTests 通过不等于新捕鱼真实接线通过。
- **未验证：**原生预览与真实鼠标/触摸设备效果。各次 CLI status 均为 stopped / process_alive=false，按规则未刷新、未启动。最终证据见 [preview-status-final.json](preview-status-final.json)；其中历史日志不是本批运行证据。
- **临时玩法填值：**无。本批玩法数字来自已确认值或既有配置；线宽、颜色、插值和裁剪包围余量仅是内部表现实现，不新增玩法参数或存档字段。
- **跳过缺项：**鸟群合并、鱼群聚集及新提示触发规则尚未确定，未实现。缺少合并判据、聚集机制和触发时机；当前保留既有逐来源提示，建议后续设计明确这些规则再接入。
- **明确排除：**透镜取得剧情、道具持有、正式玩家按钮、木桶事件、奖励及存档字段，均未编造或实现。

## 文件及复现

改动五个 Ocean 文件：Bootstrap.lua、SeaDraw.lua、SeaRuntime.lua、SurfaceSignals.lua、World.lua；改动既有 SurfaceSignalsTests.lua；新增三个 Circle1A2 测试和 `tests/run_circle1_a2.py`。EntityStateSystem.lua、Fish.lua、Config.lua 和全部禁止区域未修改。全部新证据位于本目录。

使用已配置依赖的本机复现命令：

```powershell
& 'C:/Users/80739/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tests/run_circle1_a2.py --mode all
```

运行器复用已有 Lupa 和 Maker EmmyLua，不安装依赖、不启动预览、不触发构建。绘图样张：[网心](aim.png)、[抛网途中](casting-flight.png)、[落水](landing.png)、[收网](reeling.png)、[透镜关闭](scope-off.png)、[透镜开启](scope-on.png)。
