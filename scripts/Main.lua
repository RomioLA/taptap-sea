-- Existing ocean artwork and HUD, driven by the modular Sea Runtime.
local FusedScene = require("Ocean.FusedScene")
---@type table?
local sea = nil

function Start()
    sea = FusedScene.Start()
end

function Stop()
    if sea then sea:Stop(); sea = nil end
end
