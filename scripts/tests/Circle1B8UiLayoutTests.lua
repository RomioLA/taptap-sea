-- 圈1B8 屏幕适配层回归（2026-10-11，HUD UI v3.0 · P0 轮配套）。
--
-- 守护三条契约，全部写成**纯函数断言**（不依赖引擎、不依赖 HUD 实例），
-- 因此不受其他套件遗留的 graphics / UI 桩污染：
--   ① 参考机零变化 —— 360×780（现有全部尺寸的调校基准）必须得到 scale 1.0
--      与 compact；否则真机上所有字号/间距都会被无故放大。
--   ② 断点是按**短边**分档 —— 手机横屏 780×360 必须仍是 compact，
--      不能被误判成大屏去套双栏（双栏在 360 高上必然截断）。
--   ③ 按钮坞让位随行数增长 —— 单行必须**恰好等于改前的 92**（零视觉变化），
--      多行才递增；对话条数公式必须在上下限内收敛。
--
-- 文档：HUD_UI评审与老人卡重设计方案_v3.0_2026-10-11.md §4.1 / §4.4
local UiLayout = require("Gameplay.UiLayout")

local Tests = {}

local function eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("reference phone 360x780 keeps scale 1.0 and compact mode", function()
        local mode, scale, short = UiLayout.Classify(360, 780)
        eq(mode, "compact", "360-wide reference phone stays compact")
        eq(scale, 1.0, "reference phone must keep scale 1.0 (pixel-identical to before)")
        eq(short, 360, "short side is the classification basis")
    end)

    test("phone landscape 780x360 is not misread as a large screen", function()
        -- 评审 §4.1：按短边分档就是为了挡住这个 case —— 横屏只有 360 高，
        -- 套双栏必然截断。
        local mode, scale = UiLayout.Classify(780, 360)
        eq(mode, "compact", "landscape phone must stay compact")
        assert(scale >= 0.92 and scale <= 1.1, "landscape scale must stay near 1, got " .. tostring(scale))
    end)

    test("tablet 820x1180 expands and clamps the scale to 1.3", function()
        local mode, scale = UiLayout.Classify(820, 1180)
        eq(mode, "expanded", "tablet portrait reaches the expanded breakpoint")
        eq(scale, 1.3, "scale is clamped so 13px text cannot balloon past 17px")
    end)

    test("large phone 390x844 scales slightly up without changing mode", function()
        local mode, scale = UiLayout.Classify(390, 844)
        eq(mode, "compact", "390-wide phone is still compact")
        assert(scale > 1.0 and scale < 1.1, "scale grows gently, got " .. tostring(scale))
    end)

    test("missing viewport classifies as compact with scale 1", function()
        local mode, scale = UiLayout.Classify(0, 0)
        eq(mode, "compact", "no viewport falls back to compact")
        eq(scale, 1, "no viewport falls back to scale 1 (headless parity)")
    end)

    test("single-row dock reserve equals the landscape single-row reserve", function()
        -- v1.5 横板（规格 §3）：单行让位 = padding 8 + 按钮 44 + 缓冲 8 = 60。
        -- 评审 P0-1 的零回归底线仍成立：按钮排得下时不多让位，折行才增长。
        eq(UiLayout.DockReserve(300, 2, 360), 60, "one row keeps the 60px reserve")
        eq(UiLayout.DockReserve(0, 0, 360), 60, "no buttons keeps the 60px reserve")
        eq(UiLayout.DockReserve(nil, nil, 360), 60, "nil input keeps the 60px reserve")
    end)

    test("dock reserve grows by one row height per wrapped row", function()
        -- 常驻 7 键 ≈662px + 9 个间距，360 宽屏放不下 → 必须多让位。
        -- 用「单行基线 + 一行行高(44+6)」的相对断言，改基线数值时不会脆断。
        local base = UiLayout.DockReserve(300, 2, 420)
        local two = UiLayout.DockReserve(662, 9, 420)
        eq(two, base + 50, "two rows add exactly one 44+6 row band")
        local three = UiLayout.DockReserve(662, 9, 360)
        assert(three > two, "narrower screen must reserve more, got " .. tostring(three))
        eq(UiLayout.DockReserve(1034, 9, 360), UiLayout.DockReserve(2000, 9, 360),
            "row count is capped at 4 so a tablet cannot push cards off-screen")
    end)

    test("bubble count stays inside the 3..8 window", function()
        eq(UiLayout.BubbleCount(0, 52, 3, 8), 3, "no height falls back to the lower bound")
        eq(UiLayout.BubbleCount(nil, nil, 3, 8), 3, "nil height falls back to the lower bound")
        eq(UiLayout.BubbleCount(52 * 2, 52, 1, 8), 2, "bounds are respected over defaults")
        eq(UiLayout.BubbleCount(52 * 100, 52, 3, 8), 8, "tall screens cap at 8 bubbles")
        eq(UiLayout.BubbleCount(52 * 5, 52, 3, 8), 5, "mid screens land on the natural count")
    end)

    test("card available height is zero when the viewport is unknown", function()
        -- headless 下 HUD 侧靠这条回退到 ELDER_VISIBLE_LINES_FALLBACK(5)。
        -- 先复位：本模块是单例，前面的套件建过 HUD 就会留下视口。
        UiLayout.Reset()
        eq(UiLayout.Available(), false, "reset clears the viewport")
        eq(UiLayout.CardAvailableHeight(38, 60), 0, "unknown viewport reports zero height")
        eq(UiLayout.DockReserve(662, 9), 60, "unknown viewport keeps the 60px reserve")
    end)

    test("card is capped at 560 only when both sea margins survive", function()
        -- v1.5 横板（规格 §8）：卡宽 560 居中，两侧各留 ≥40 海面露出观察层。
        UiLayout.Reset()
        eq(UiLayout.CardMaxWidth(), nil, "unknown viewport never caps the card")

        local ok = pcall(function() UiLayout.Sync() end)
        if ok and UiLayout.Available() then
            local w = UiLayout.Width()
            local cap = UiLayout.CardMaxWidth()
            if w >= 560 + 40 * 2 then
                eq(cap, 560, "wide screen caps the card at 560")
            else
                eq(cap, nil, "narrow screen keeps the card full width")
            end
        end
    end)

    return { results = results }
end

return Tests
