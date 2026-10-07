-- The integrated scene owns the single UI root and the ocean renderer.
local Scene = require("Integration.Scene")
---@type table?
local scene = nil

function Start()
    if scene then scene:Stop() end
    -- 21 天 Jam 测试期：开启调试工具链（「海上调试」按钮 + SeaDebug 面板 + StoryArt A/B）。
    -- 真机反馈 2026-10-07：不传 development 时调试入口在真机完全不存在，无法做性能验收。
    -- ⚠️ 发布对外包前改回 Scene.Start()。
    scene = Scene.Start({ development = true })
end

function Stop()
    if scene then scene:Stop(); scene = nil end
end
