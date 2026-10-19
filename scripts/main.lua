-- The integrated scene owns the single UI root and the ocean renderer.
local Scene = require("Integration.Scene")
---@type table?
local scene = nil

function Start()
    if scene then scene:Stop() end
    -- 发布默认关闭开发调试入口；需要进行真机调试时由开发者显式打开。
    scene = Scene.Start()
end

function Stop()
    if scene then scene:Stop(); scene = nil end
end
