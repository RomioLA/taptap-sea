-- Standalone test entry; shared Main.lua may require this temporarily for local validation.
local Bootstrap = require("Ocean.Bootstrap")
local Probe = require("tests.SeaNativeVoyage")
---@type table?
local sea = nil
function Start()
    sea = Bootstrap.Start()
    local update, render = sea.Update, sea.Render
    sea.Update = function(self,dt)
        update(self,dt)
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
            self.runtime:Init({daySeed=97,departure={x=400,y=400}})
            self.tools.refresh(1)
            print("[SeaV1][EngineSmoke] reset PASS")
            -- Input subscriptions were exercised above; prevent live user input
            -- from changing the automated voyage's scripted targets/debug state.
            for _, event in ipairs({"MouseButtonDown","TouchBegin","KeyDown"}) do
                self.eventObject:UnsubscribeFromEvent(event)
            end
            self.Update, self.Render = update, render
            Probe.Attach(self)
        end
    end
end
function Stop()
    if sea then sea:Stop(); sea = nil end
end
