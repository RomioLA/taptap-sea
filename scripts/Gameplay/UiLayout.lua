-- scripts/Gameplay/UiLayout.lua — 屏幕适配层（HUD UI 重设计 v3.0 · P0 轮）
--
-- 文档：HUD_UI评审与老人卡重设计方案_v3.0_2026-10-11.md §4.1 / §4.4
--
-- 背景：此前 HUD 内**没有任何视口读取**，全部尺寸是绝对 px（cardHost 锚定
-- 40/92、按钮宽 72~128、对话条数写死 5），屏幕尺寸这个事实根本没进 UI 层。
-- 结果是小屏截断、大屏空白都无解（评审 §二 P1-1 / P1-3）。本模块把「屏幕
-- 多大」变成 UI 层可查询的一等公民。
--
-- 三条硬约束（改这个文件时必须守住）：
--   1. **取不到视口就回退到改动前的行为**：scale=1、mode="compact"、
--      CardMaxWidth()=nil、DockReserve()=92。headless 测试与引擎未就绪时
--      必须与改动前完全一致，否则回归基线会新增红（基线 failureCount=9）。
--   2. **不依赖引擎全局**：graphics / urhox UI 全部用 pcall 探测，缺失时
--      模块照常加载，不抛错。
--   3. **不做每帧计算**：HUD 只在 Create 与 refresh 时读取；视口变化由
--      HUD 侧按需调用 Sync()。
--
-- 坐标系：UI 布局单位是「设计基准像素」= 物理像素 / UI.GetScale()
-- （既有用法见 Integration/Scene.lua:24-36、urhox-libs/FakeAd/init.lua:189-191）。
-- UI.GetWidth()/GetHeight() 已直接返回该坐标系下的宽高，优先使用。

local UiLayout = {}

-- 设计基准短边：现有全部尺寸是按 360 宽手机调出来的，短边 360 => scale 1.0，
-- 即参考机上与改动前**像素级一致**。
local REFERENCE_SHORT = 360
local SCALE_MIN = 0.92
local SCALE_MAX = 1.30

-- 断点按**短边**分档（比按宽分档稳健：手机横屏 780×360 短边仍是 360，
-- 不会被误判成大屏而套用双栏）。
local MODE_EXPANDED_SHORT = 600 -- 平板短边通常 ≥600（820×1180 / 744×1133）
local MODE_REGULAR_SHORT = 420 -- 大屏手机 / 平板竖屏窄边

-- 按钮坞让位常量（与 HUD.lua 原实现对齐）
local DOCK_BASE_RESERVE = 92 -- 原 CARD_HOST_BOTTOM：按按钮坞 1 行预留
local DOCK_ROW_HEIGHT = 44 -- size.buttonMinHeight
local DOCK_ROW_GAP = 6 -- dock 的 gap
local DOCK_SIDE_PADDING = 8 -- actionBar 的 padding

-- 大屏卡片封顶宽度（评审 §4.3：解决平板行长失控 / P1-1）
local CARD_MAX_WIDTH = 720

---@class UiLayoutViewport
---@field width number
---@field height number
---@field short number
---@field scale number
---@field mode "compact"|"regular"|"expanded"
---@field available boolean

---@type UiLayoutViewport
local viewport = {
    width = 0,
    height = 0,
    short = 0,
    scale = 1,
    mode = "compact",
    available = false,
}

local function clamp(value, low, high)
    if type(value) ~= "number" or value ~= value then return low end
    if value < low then return low end
    if value > high then return high end
    return value
end

local function isPositiveNumber(value)
    return type(value) == "number" and value > 0 and value == value
end

---@return number, number 逻辑宽高；取不到返回 0, 0
local function detectViewport()
    local ok, UI = pcall(require, "urhox-libs/UI")
    if not ok or type(UI) ~= "table" then return 0, 0 end

    -- 首选：UI 自带的布局坐标系宽高（已是「物理像素 / UI.GetScale()」）
    if type(UI.GetWidth) == "function" and type(UI.GetHeight) == "function" then
        local okW, w = pcall(UI.GetWidth)
        local okH, h = pcall(UI.GetHeight)
        if okW and okH and isPositiveNumber(w) and isPositiveNumber(h) then return w, h end
    end

    -- 兜底：graphics 物理像素 / UI.GetScale()
    local okScale, uiScale = pcall(function() return UI.GetScale() end)
    if not okScale or not isPositiveNumber(uiScale) then return 0, 0 end
    local graphics = rawget(_G, "graphics")
    if type(graphics) ~= "table" and type(graphics) ~= "userdata" then return 0, 0 end
    local okW, w = pcall(function() return graphics:GetWidth() end)
    local okH, h = pcall(function() return graphics:GetHeight() end)
    if not okW or not okH or not isPositiveNumber(w) or not isPositiveNumber(h) then return 0, 0 end
    return w / uiScale, h / uiScale
end

---重新探测视口并刷新派生值。返回 viewport 表（同一张表，不要长期持有副本）。
---由宽高推导断点与缩放系数（纯函数，测试可直接断言）。
---@param width number
---@param height number
---@return string mode, number scale, number short
function UiLayout.Classify(width, height)
    if not isPositiveNumber(width) or not isPositiveNumber(height) then
        return "compact", 1, 0
    end
    local short = math.min(width, height)
    local mode = "compact"
    if short >= MODE_EXPANDED_SHORT then
        mode = "expanded"
    elseif short >= MODE_REGULAR_SHORT then
        mode = "regular"
    end
    return mode, clamp(short / REFERENCE_SHORT, SCALE_MIN, SCALE_MAX), short
end

---@return UiLayoutViewport
function UiLayout.Sync()
    local width, height = detectViewport()
    if not isPositiveNumber(width) or not isPositiveNumber(height) then
        -- 约束 1：无视口 → 完全回退到改动前行为
        viewport.width, viewport.height, viewport.short = 0, 0, 0
        viewport.scale, viewport.mode, viewport.available = 1, "compact", false
        return viewport
    end

    local mode, scale, short = UiLayout.Classify(width, height)
    viewport.width, viewport.height, viewport.short = width, height, short
    viewport.scale, viewport.mode, viewport.available = scale, mode, true
    return viewport
end

---复位到「无视口」状态。测试套件共用同一个 Lua 运行时，前一个套件若建过
---HUD 就会把视口写进本模块（模块级单例），纯逻辑断言前必须先复位。
---@return UiLayoutViewport
function UiLayout.Reset()
    viewport.width, viewport.height, viewport.short = 0, 0, 0
    viewport.scale, viewport.mode, viewport.available = 1, "compact", false
    return viewport
end

---@return UiLayoutViewport
function UiLayout.Viewport()
    return viewport
end

function UiLayout.Available()
    return viewport.available == true
end

---@return "compact"|"regular"|"expanded"
function UiLayout.Mode()
    return viewport.mode
end

function UiLayout.IsExpanded()
    return viewport.mode == "expanded"
end

---缩放系数。⚠️ P0 轮**不接线到字号**：按钮宽度是固定 px（72~128），
---只放大字号会让 13px×1.3 装进 72px 宽的按钮里截断。字号缩放与按钮宽度
---缩放必须同批做，排在 P1 轮（见方案 §五）。
---@return number
function UiLayout.Scale()
    return viewport.scale
end

function UiLayout.Width()
    return viewport.width
end

function UiLayout.Height()
    return viewport.height
end

---卡片最大宽度：compact 不限制（手机本来就不够宽，限宽反而浪费），
---regular/expanded 封顶 720 并居中（评审 P1-1：平板行长失控）。
---@return number|nil
function UiLayout.CardMaxWidth()
    if viewport.mode == "compact" then return nil end
    return CARD_MAX_WIDTH
end

---按钮坞让位高度（评审 P0-1 的核心修复）。
---原实现固定 92px（按 1 行预留），但常驻 7 键合计 ≈662px、情境键全出峰值
---≈970px，360 宽屏必然折 2~3 行 → 每多一行多 50px，卡片底部操作条被压住。
---改为按「可见按钮总宽 / 可用宽」估算行数，再换算成让位高度。
---@param totalButtonWidth number 可见按钮宽度之和（不含间距）
---@param gapCount number|nil 可见按钮之间的间距个数
---@param screenWidth number|nil 覆盖视口宽度（测试用；缺省用实际视口）
---@return number
function UiLayout.DockReserve(totalButtonWidth, gapCount, screenWidth)
    local width = isPositiveNumber(screenWidth) and screenWidth or viewport.width
    if not viewport.available and not isPositiveNumber(screenWidth) then
        return DOCK_BASE_RESERVE
    end
    if not isPositiveNumber(totalButtonWidth) or not isPositiveNumber(width) then
        return DOCK_BASE_RESERVE
    end

    local usable = width - DOCK_SIDE_PADDING * 2
    if usable <= 0 then return DOCK_BASE_RESERVE end

    local needed = totalButtonWidth + (isPositiveNumber(gapCount) and gapCount or 0) * DOCK_ROW_GAP
    local rows = 1
    if needed > usable then rows = math.ceil(needed / usable) end
    rows = clamp(rows, 1, 4)

    -- rows=1 时正好等于原常量 92，参考机零视觉变化
    return DOCK_BASE_RESERVE + (rows - 1) * (DOCK_ROW_HEIGHT + DOCK_ROW_GAP)
end

---按钮坞行数（与 DockReserve 同一套估算，供诊断/日志用）。
---@param totalButtonWidth number
---@param gapCount number|nil
---@return number
function UiLayout.DockRows(totalButtonWidth, gapCount)
    if not viewport.available or not isPositiveNumber(totalButtonWidth) then return 1 end
    local usable = viewport.width - DOCK_SIDE_PADDING * 2
    if usable <= 0 then return 1 end
    local needed = totalButtonWidth + (isPositiveNumber(gapCount) and gapCount or 0) * DOCK_ROW_GAP
    if needed <= usable then return 1 end
    return clamp(math.ceil(needed / usable), 1, 4)
end

---对话气泡可见条数（评审 P0-3，替代 `ELDER_VISIBLE_LINES = 5` 硬编码）。
---小屏得下限 3~4 条，大屏得上 8 条 —— 同一份代码，两种密度。
---@param availableHeight number 对话区可用高度（px）
---@param bubbleHeight number|nil 单条气泡高度（含间距），缺省 52
---@param minCount number|nil 默认 3
---@param maxCount number|nil 默认 8
---@return number
function UiLayout.BubbleCount(availableHeight, bubbleHeight, minCount, maxCount)
    local low = isPositiveNumber(minCount) and math.floor(minCount) or 3
    local high = isPositiveNumber(maxCount) and math.floor(maxCount) or 8
    if high < low then high = low end
    if not isPositiveNumber(availableHeight) then return low end
    local unit = isPositiveNumber(bubbleHeight) and bubbleHeight or 52
    return clamp(math.floor(availableHeight / unit), low, high)
end

---卡片可用高度估算（给 BubbleCount 用）。
---@param topReserve number 顶部让位（状态栏）
---@param dockReserve number 底部让位（按钮坞）
---@return number 0 表示视口不可用
function UiLayout.CardAvailableHeight(topReserve, dockReserve)
    if not viewport.available then return 0 end
    local top = isPositiveNumber(topReserve) and topReserve or 40
    local bottom = isPositiveNumber(dockReserve) and dockReserve or DOCK_BASE_RESERVE
    local height = viewport.height - top - bottom - 20 -- 20 = cardHost padding 上下各 10
    if height <= 0 then return 0 end
    return height
end

return UiLayout
