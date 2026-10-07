-- 对白/教程样式令牌（设计方案 v2.0 §7.2，2026-10-07）。
-- 目的：开场剧情、老人对话、S6 教学、捕鱼气泡、结局/强制事件等对白类 UI
-- 的字号、色板、卡片参数统一从本表取值，消除各自为政的硬编码样式。
-- 全局调整只改本表；水彩九宫格底板换肤（批3b）时只替换 card 字段。
-- 纯数据模块：不依赖引擎，测试桩可直接加载。
local Style = {
    -- 字号层级：title=标题级（开场/结局/强制事件主行）；body=正文与反馈；
    -- teaching=教学/引导行（金色小字）。
    fontSize = { title = 17, body = 14, teaching = 12 },
    -- 色板与 HUD 既有用色对齐，不引入新色相：
    -- body=暖米白（剧情/结果正文），teaching=教学金（S6 老人教学沿用色），
    -- dim=辅助弱化文本。
    color = {
        body = { 255, 236, 207, 255 },
        teaching = { 237, 213, 159, 255 },
        dim = { 180, 207, 216, 255 },
    },
    -- 对白卡片参数：批3b 换肤时替换 backgroundColor 为九宫格图，其余不动。
    card = { backgroundColor = { 45, 64, 61, 220 }, borderRadius = 8, padding = 10 },
    -- 教学/引导行统一前缀：一眼可辨"这是教学不是剧情"（圈2 决策 A6 配套）。
    teachMark = "※ ",
}

-- 教学行统一前缀处理；多行文本每行都加前缀。
function Style.teachingText(text)
    if type(text) ~= "string" or text == "" then return text end
    local marked = text:gsub("([^\n]+)", Style.teachMark .. "%1")
    return marked
end

return Style
