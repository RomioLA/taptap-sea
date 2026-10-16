# Circle 1 A3：Space/Input 子任务

## 实现

- `Runtime:GetPortPosition()` 返回 `Config.ship.start` 的坐标副本；核实锚点为 `(0, 0)`，独立于 `options.departure`。`Runtime:ResetShipAtPort()` 验证船、有限坐标、边界与水域后复用 `World:isPositionFree`（包括特化谓词），返回 `true` 或 `false, reason`。
- 港口复位调用 `Movement:ResetAtPosition()`，只移动同一艘船、清除目标与推挤残留并重新锚定相机；世界、时间、鱼、信号、区域标记、临时实体寿命、固定木桶引用/代次及暂停状态不被复位改变。
- `Runtime:Init()` 在替换前调用旧 `World:Retire()`，以便退役旧调度和相关引用；World API 由 World owner 提供，本子任务未修改 World 文件。
- Bootstrap 在输入、更新和绘制入口同步物理分辨率/DPR与逻辑视口；使用 `UI.FindWidgetAt` 拦截鼠标/触摸 UI 命中，并对非有限坐标、非法视口、UI 缩放及非水域位置做守卫。只在有限指针输入后运行 `beforePointer`，以同步最新桥接状态，再执行暂停/UI/水域检查；定向测试覆盖桥接 pause/unpause 与 Runtime 短暂不同步的两种情况。
- `onSeaPointer` 严格返回 `true` 时消费指针；返回 `false` 或 `nil` 时设置航行目标。键盘焦点只在 `UI.GetFocus()` 明确返回 `_className == "TextField"` 且 `state.focused == true` 时抑制海上方向键和快捷键；普通按钮焦点不会阻断它们。`Render` 将识别回调作为第 7 个参数传入，保留第 5 个 clock、第 6 个 fishingView。
- 保留 Bootstrap 既有 5 个事件订阅；视口在已有 Update/Render/Pointer 路径同步，避免额外订阅破坏融合场景事件所有权约定。

## 验证

- 新增 `Circle1A3PortTests.lua` 5 项、`Circle1A3InputTests.lua` 6 项；本次类型修正后两组仍全部通过。覆盖港口拷贝与水域谓词、世界状态保留、临时实体年龄、重置后不追旧目标、DPR/屏幕尺寸变化、UI 命中、输入消费、非法水域、普通按钮与 TextField 焦点、陈旧 pause，以及 12 次 Start/Stop、Stop 幂等、每场景单一 5 项事件集和旧回调静默。
- 测试使用 Python 3.12/Lupa 与引擎接口替身，**不是 UrhoX/Maker 原生验证**。类型源头包括区域标记 table 注解、测试输入替身使用合法 `MM_ABSOLUTE`/boolean 初值，以及将消费开关声明为 `boolean?` 以覆盖 `nil` 默认航行语义。
- 之前通过只读 `tests/run_circle1_a2.py` helper 执行的既有回归模块全部通过；本次仅修改两个新增测试的类型声明/替身初值，未运行 LSP（由父任务统一运行）。
- Maker preview status 显示 `state=stopped`、`process_alive=false`；依约未刷新或启动已停止会话。当前没有原生窗口画面/运行验证。状态响应包含旧会话日志中的资源缺失与 `themis_x64.dll` 错误，时间戳为 2026-10-02；它们不是本轮新运行证据。
