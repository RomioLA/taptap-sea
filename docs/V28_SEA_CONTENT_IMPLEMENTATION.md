# V2.8 海上内容扩充实施记录（2026-10-19）

本轮依据：`渔夫漂流记_V2.8_最终合并封板版.xlsx`。
权威顺序：《V2.8最终封板》＞ 当前主正文 Sheet ＞《V2.7审查闭环》＞《V2.8已确认增量》＞ 历史修改记录。
V2.7 已拍板的救人、教学、存档、探海镜、D7 终局规则全部继续有效，本轮未回退。

本文只记录实际落地的代码变更与验收边界；不重复策划原文，不替代策划。

## 一、落地的 V2.8 内容

| 模块 | 内容 | 落点 | 关键边界 |
|---|---|---|---|
| 固定节点 | 11 个新增海上节点（3 礁石 + 木板 + 沉船 + 2 漂流瓶 + 巨骨 + 海眼 + 破渔网 + 浮藻假岛） | `scripts/data/content.lua` | 坐标/半径/layer/blocking 与封板坐标表一致；跨 NewRun 固定 |
| 礁石 | `reef_vis_01~03` 0 体力可重复【观察礁石】 | `Gameplay/V28ContentActions.lua` | 无掉落、无 shown 存档；观察时停船并取消自动返航 |
| 木板 | `debris_01` 0 体力【观察木板】 | 同上 | 05 单点 authored 线索，不做全局洋流 |
| 沉船 | `shipwreck_01` 探海镜 1s 标记 → 40 体力/4s、≥2 空格 → 珠宝+珊瑚枝 | 同上 | 取消/夜尽 0 扣费 0 奖励；每周目一次 |
| 漂流瓶 | `bottle_note_01/02` 0 体力拾取 → 航海残页（一）/（二） | 同上 | 残页进独立道具栏；拾取态由 `treasures.sea_note_0x` 推导，无 `picked` 布尔位 |
| 巨骨 | `leviathan_bones_01` 探海镜 1s 识别 + 海面慢气泡 | 同上 + `Ocean/SeaDraw.lua` | 所在 120×120m 分区 4 小 2 大（总数 6），大鱼优先 15～45m 环带；识别只随检查点持久化 |
| 海眼 | `sea_eye_vortex_01` 0 体力观察；中心 <3m 禁网心；仅正式 WorldDrop 触发 | `Ocean/SeaRuntime.lua`、`Integration/Bridge.lua`、`Gameplay/Loop.lua` | 苹果/鱼饵 60m 吸小鱼、小鱼 90m 吸大鱼，20s，不刷鱼；首次投大鱼原子换深海珍珠 260 |
| 破渔网 | `trapped_net_01` 双分支 | `Gameplay/V28ContentActions.lua`、`Ocean/SeaRuntime.lua` | A：40 体力/4s、≥2 空格 → 2 小鱼且永久放弃钥匙；B：0 体力即时 → 唯一 `rusty_key` + 放出 2 条 Flee 小鱼；不额外生成大鱼 |
| 浮藻假岛 | `kelp_mirage_01` 80m 轮廓 / 20m 识破；探海镜 1s 标记 → 钥匙 + 40 体力/4s + ≥1 空格 | 同上 | 成功完成才消耗钥匙；中断/失败保留；无登岛按钮 |
| 物品 | 珠宝 90 / 珊瑚枝 45 / 深海珍珠 260 / 海底金属货箱 110（普通船舱 1 格）；航海残页、生锈钥匙（独立道具栏） | `data/items.lua` + `scripts/data/items.lua` | 交易品可出售不可投海；残页/钥匙不可出售不可丢弃 |
| W-08 | 三枚记忆正式标题+正文 | `scripts/data/memory_fragments.lua` | 复用既有持有/取得状态，不新增 shown 存档；不确认牵手者/等候者身份 |

## 二、存档契约

- 新增 `Gameplay.V28Progress`：`story.v28.vortexPearlClaimed` + `story.v28.content.<contentId>` 的
  `recognized / marked / completed`，以及 `treasures.sea_note_01/02`、`treasures.rusty_key`。
- 能由物品持有推导的状态一律不落盘：漂流瓶拾取由残页持有推导，无 `picked` 布尔位。
- V2.7 旧档缺 V2.8 字段时由 `Initialize` 补 `false` / 未持有，**不判坏档、不强制 NewRun**。
- 运行态可立即内存置位防同局重复；持久化仍只随 D1 初始化 / 日结 / D7 终局 / NewRun 初始化。
- 首次识别、提示关闭、普通场景观察都不单独写盘。

## 三、输入与门禁

- 动态场景按钮（观察/拾取/打捞/处理破渔网）在正常航行可用。
- 捕鱼选点、投放选点、4 秒动作进行中统一隐藏 0 体力场景按钮（`Loop:GetV28Prompt` 直接返回 nil）。
- 4 秒动作期间原位按钮变为「取消打捞 / 取消…」。
- 点击 0 体力观察/拾取时立即停船并取消自动返航。
- 4 秒事务期间禁止切换探海镜（`Loop:ToggleScope`）。
- 海眼只响应 `SetDropTarget` 显式选定的正式投放；背包【丢弃】与鱼饵船边即时投饵都不触发。

## 四、验收边界

- `tests/run_world_content.py`：16 套件 / 322 tests / 0 skipped，全部通过（含新增 `V28ContentTests` 45 项）。
- `tests/run_sea_view_regression.py`：75 套件 / 70 通过。未通过的 5 项
  （`AutoNavigationTests`、`Circle1HUDReviewTests`、`OceanImageCatalogTests`、`SeaDayNightCycleTests`、`ShipScareTests`）
  在**本轮改动前的 16:23 基线运行**中已同样失败，与本轮无因果关系。
- `tests/check_sea_view_lsp.py`：17 条诊断，与基线集合完全一致（本轮新增 0 条）。
- `git diff --check`：通过。
- Maker 引擎 / GUI 实机验收：**未运行**（本轮无人值守，无法完成 GUI 自动验收）。

## 五、GUI_PENDING

以下需要在有窗口环境时人工/实机确认：

1. 13 个海上节点在 D1/D2 近海的可见密度与辨识度（占位几何）。
2. 探海镜 1 秒标记/识别的可读性（沉船、巨骨、浮藻货箱）。
3. 海眼 60m/90m 聚鱼的实际观感与外缘下网体验。
4. 破渔网双分支模态框在窄屏按钮坞中的排版。
5. 巨骨海面慢气泡与大鱼水花的区分度。
6. 4 秒打捞进度、取消按钮与夜尽中断的实际表现。
7. W-08 三枚记忆标题+正文的实际弹出与排版。

## 六、未做（按策划边界）

- 未制作正式美术：全部 V2.8 节点使用 NanoVG 占位几何（`Ocean/SeaDraw.lua` 的 `drawV28Node`），
  正式资源替换只需替换该函数，不改玩法逻辑。
- 未新增第三批内容、未改 W-05 救活结局正文（保持 V2.7 所选「改变结局｜有人同行」）。
- 未实现全局洋流系统、未新增鱼 AI 状态、未增加每日总鱼数。
