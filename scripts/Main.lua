-- The integrated scene owns the single UI root and the ocean renderer.
local Scene = require("Integration.Scene")
---@type table?
local scene = nil

function Start()
    if scene then scene:Stop() end
    scene = Scene.Start()
end

function Stop()
    if scene then scene:Stop(); scene = nil end
end
