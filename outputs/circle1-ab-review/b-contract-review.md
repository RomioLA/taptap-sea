# Circle1 B 与当前 A3 Ocean Runtime 契约复查

复查范围：只读对照 B 副本 D:\sillytavern-data\taptap-sea-B 的 AGENTS.md、docs/ARCHITECTURE_LAYOUT.md、docs/TEAM_FILE_BOUNDARIES.md、B Integration/Gameplay 调用，与当前 A 工程 C:\codex\taptap-sea 的 Ocean Runtime/Bootstrap。未编辑生产或测试源码，未启动预览、构建或提交。

## 发现

### 1. [B] 透镜关闭把合法的 false 返回值判成失败

- B: [Loop.lua](D:/sillytavern-data/taptap-sea-B/scripts/Gameplay/Loop.lua#L941) 在 SyncScope 调用 runtime:SetScopeEnabled(self.scopeEnabled) 后，把 accepted == false 直接当作同步失败。
- A: [SeaRuntime.lua](C:/codex/taptap-sea/scripts/Ocean/SeaRuntime.lua#L402) 的 setter 将 world.scopeEnabled 设为 enabled == true，并在第 405 行返回这个状态。关闭成功时它按契约返回 false；A 的 IsScopeEnabled 在第 408 行是状态读取接口。
- 触发：透镜已打开时调用 B ToggleScope() 关闭。A 正确关闭后返回 false，B 报 scope_sync_failed，再回滚本地值并重新打开 A 的透镜状态，结果是关闭按钮无法关闭透镜。直接调用 DisableScope() 则第一次已关闭 A，但误报失败；[Scene.lua](D:/sillytavern-data/taptap-sea-B/scripts/Integration/Scene.lua#L261) 据此拒绝本次 Stop，重试时才因读到双方均为 false 而通过。
- 影响：玩家无法从正式开关关闭已打开的透镜；场景第一次 Stop 也会被错误阻止。只读组合证据的 scope_contract_reproduction 记录 toggleOff 后 A 仍为 true、返回 scope_sync_failed；直接 DisableScope 首次虽已关闭 A 仍报错，重试才成功。B 的 [Circle1B2ScopeTests.lua](D:/sillytavern-data/taptap-sea-B/scripts/Tests/Circle1B2ScopeTests.lua#L20) 至第 31 行测试替身对任一合法设置都返回 true，仅用 false 模拟注入拒绝，因此协议测试没有覆盖 A 的状态返回契约。
- 契约依据：B 当前代码要求 setter 返回“是否接受”的布尔值；A 实际返回“当前开关状态”。需统一返回契约，或由调用方在调用后只用 IsScopeEnabled() 回读验证。

### 2. [B] Bridge 的 World 准备收据依赖 façade 未提供的字段，公开接口适配测试失败

- B: [Bridge.lua](D:/sillytavern-data/taptap-sea-B/scripts/Integration/Bridge.lua#L49) 和第 56 行在 refreshDynamicWorld 中将 self.runtime.world 直接传给 Loop:IsWorldPrepared / Loop:MarkWorldPrepared。
- B 项目边界：[AGENTS.md](D:/sillytavern-data/taptap-sea-B/AGENTS.md#L1131) 与 [ARCHITECTURE_LAYOUT.md](D:/sillytavern-data/taptap-sea-B/docs/ARCHITECTURE_LAYOUT.md#L41) 要求 Integration 通过 Ocean 公共接口编排；它们禁止直接改写世界注册表/对象集合，但没有逐字禁止读取 World 引用。更具体的适配约定由 B 的 [ArchitectureIntegrationTests.lua](D:/sillytavern-data/taptap-sea-B/scripts/Tests/ArchitectureIntegrationTests.lua#L234) 至第 240 行表达：只暴露 Runtime 方法的 façade 会在访问 world 时抛错。
- 触发：通过只暴露公开 Runtime 方法的 adapter 调用 Bridge:NewRun()，执行 resetDynamicWorld 时即触发 runtime.world 读取；回调失败，Loop:NewRun() 将其转换为 new_day_preparation_failed，并恢复入口待处理状态。
- 影响：这是公开 Runtime façade 兼容性/架构回归失败，不是已观察到的直接 A Runtime 主流程故障。当前 A Runtime 实例暴露 world，直接组合主流程可正常运行；只暴露公开方法的适配器则无法执行该准备收据路径。
- 可见证据：只读组合结果 [composition-results.json](C:/codex/taptap-sea/outputs/circle1-ab-review/composition-results.json) 记录六条真实 A/B 模块 smoke 通过；原样 B ArchitectureIntegrationTests 的 “Bridge works through public Runtime APIs without sea internals” 在 façade 路径失败，错误为 new_day_preparation_failed。若产品需要该 façade 能力，应使用明确提供的稳定 World identity 公共契约，或重设计准备幂等收据。

## 与当前 A3 接口兼容的项

- 港口：B Loop:CanAccessPort 使用 GetPortPosition/GetShipPosition；PreparePort 调用无参数 ResetShipAtPort 并检查 true。A 当前分别在 SeaRuntime.lua:128–136 和 :168–178 实现，调用参数和返回值匹配。日/读档/新周目通过此处准备海港的 smoke 在 composition-results.json 记录为通过。
- 识别：B Scene.lua:194–196 设置只读 isLocationRecognized(contentId)；当前 A Bootstrap 在 :142–145 将它连同 getClock、getFishingView 交给 SeaDraw.Scene，A SeaDraw.lua:390 定义第七个回调参数。B Bridge 从 GetFixedBarrel() 读取 driftwood_barrel 稳定 ID，并仅在 20 米识别距离内写入 Gameplay 进度；A 的快照字段和 CanInteractWithBarrel(id,generation) 与 B Circle1B2Barrel.lua 使用一致。该识别/往返 smoke 记录为通过。
- 捕鱼：B Actions.lua 调用 canCastNet、GetFishingGeneration、selectFishingTarget、LockFishingTarget/UnlockFishingTarget、GetFishingTarget、SnapshotFishingTarget/RestoreFishingTarget、RemoveFishingTarget、ForgetFishingBehavior、ClearMovementTarget。当前 A SeaRuntime.lua 均有对应方法，B 移除鱼时传递 owner token，匹配 A 对锁定所有权的校验。B getFishingView 的 aim/casting/reeling 映射也匹配 A SeaDraw 接受的 phase 名称。
- 暂停/帧更新：B Game 将 Gameplay Clock 的暂停状态镜像到 runtime.paused，将船级别传给 SetShipLevel；A Runtime Update 读取 paused，A Bootstrap 的 simulationUpdate、beforePointer、onSeaPointer 与 B Scene.lua:188–205 参数签名匹配。暂停输入消费规则及海面点击分流能在 A Bootstrap 当前 hook 上接通。
- 重建/新周目：B 新周目通过 ResetShipAtPort 复位船，再以 refreshOrdinaryFish(seed, departure) 清普通鱼和临时物，不调用 A Runtime:Reset()。这符合当前 A 的重置契约：港口复位保留 World/fixed barrel，刷新接口也不替玩家移动或结算；六条真实模块 smoke 的港口准备、正常返港、重开清识别结果均记录为通过。

## 旧测试夹具，不是当前组合的产品缺陷

B Circle1B3SceneUITests.lua:77–80 在 Runtime.New() 后仅当 missingPort 为 false 时才往实例表添加港口方法。当前 A 的方法继承自 Runtime.__index，因此 missingPort=true 并没有隐藏继承方法；测试第 135–140 行并未真正构造缺少港口接口的 Runtime，预期“拒绝开始新周目”在当前 A 组合中不再成立。A 的实现位于 SeaRuntime.lua:135、:168。因此组合回归里该测试的失败应标为过期/无效夹具，不能据此判成港口接线回归。
