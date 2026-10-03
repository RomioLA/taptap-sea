-- Standalone preview entry. Shared Main.lua is not permanently wired to this module.
local Bootstrap = require("Ocean.Bootstrap")
---@type table?
local sea = nil
function Start()
    sea = Bootstrap.Start()
    if rawget(_G, "SEA_ENGINE_SMOKE") then
        local update, render = sea.Update, sea.Render
        sea.Update = function(self, dt)
            update(self, dt)
            if not self.smokeRan then
                self.smokeRan = true
                require("tests.SeaEngineSmoke").Run(self)
            end
        end
        sea.Render = function(self)
            render(self)
            if self.smokeDebugPending then
                self.smokeDebugPending = false
                print("[SeaV1][EngineSmoke] underwater + labels + perception frame PASS")
                self.runtime:Reset()
                self.tools.refresh(1)
                print("[SeaV1][EngineSmoke] reset PASS")
            end
        end
    end
end
function Stop()
    if sea then sea:Stop(); sea = nil end
end
