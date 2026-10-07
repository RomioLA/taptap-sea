-- 对白/教程样式令牌 —— 兼容壳（UI 套件重设计 v2.1 批A，2026-10-07）。
-- 令牌已并入 Gameplay.UiKit 单一令牌源；本模块保留原路径与字段名，
-- 旧引用（HUD/测试桩）不断链。新代码请直接使用 Gameplay.UiKit。
local UiKit = require("Gameplay.UiKit")

return {
    -- 字号层级（title/body/teaching）。
    fontSize = UiKit.fontSize,
    -- 对白文字色板（body/teaching/dim）。
    color = UiKit.color,
    -- 旧对白卡纯色参数（新代码用 UiKit.cardProps 水彩底板）。
    card = UiKit.card,
    -- 教学行前缀与处理函数。
    teachMark = UiKit.teachMark,
    teachingText = UiKit.teachingText,
    -- 批3b 按钮水彩皮肤。
    button = UiKit.button,
    buttonProps = UiKit.buttonProps,
}
