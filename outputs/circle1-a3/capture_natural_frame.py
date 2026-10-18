"""Replay the normal A3 experience route and record one actual sea-water frame."""
from pathlib import Path
import importlib.util
import json
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('a3_frame_helpers', ROOT/'tests/run_circle1_a2.py')
helpers = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = helpers
spec.loader.exec_module(helpers)
lua = helpers._lua(ROOT/'scripts')
capture = helpers._capture_type()()
capture.bind(lua)
lua.execute('''
local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local Draw = require("Ocean.Draw")
local Config = require("Ocean.Config")
local originalUpdate = Runtime.Update
local originalSplash = Draw.WorldSplash
local splashDrawCalls = 0
Draw.WorldSplash = function(...)
    splashDrawCalls = splashDrawCalls + 1
    return originalSplash(...)
end
Runtime.Update = function(self, ...)
    local result = originalUpdate(self, ...)
    if __naturalFrameEvidence == nil and math.abs(self.world.time - 71.35) < 0.000001
        and math.abs(self.ship.position.x + 0.58646) < 0.0001
        and math.abs(self.ship.position.y - 228.49018) < 0.0001 then
        local target
        for _, splash in ipairs(self.surfaceSignals:GetSplashes()) do
            if splash.sourceId == "sea-92" then target = splash; break end
        end
        assert(target, "the normal route no longer has expected natural splash")
        local x, y = self.movement:WorldToScreen(target.position)
        local margin = 4 * 1080 / self.movement.viewHeight + 3
        local horizon = 1080 * Config.layers.waves
        assert(x - margin >= 0 and x + margin <= 1920
            and y - margin >= horizon and y + margin <= 1080)
        local timeBefore = self.world.time
        local sequenceBefore = self.spawnSequence
        SeaDraw.Scene({}, 1920, 1080, self)
        assert(splashDrawCalls > 0, "no natural water splash was rendered")
        assert(self.world.time == timeBefore and self.spawnSequence == sequenceBefore)
        __naturalFrameEvidence = {seed = self.daySeed, sourceId = target.sourceId,
            worldTime = self.world.time, shipPosition = {x=self.ship.position.x,y=self.ship.position.y},
            splashPosition = {x=target.position.x,y=target.position.y},
            screenPosition = {x=x,y=y}, margin = margin, horizonY = horizon,
            splashDrawCalls = splashDrawCalls, debugUnderwater = self.world.showUnderwater,
            routeModule = "tests.Circle1A3ExperienceTests", nativeScreenshot = false,
            syntheticFishOrSignalUsed = false}
    end
    return result
end
local report = require("tests.Circle1A3ExperienceTests").Run()
for _, check in ipairs(report.results) do assert(check.passed, check.error) end
assert(__naturalFrameEvidence, "expected normal-route frame was not reached")
Runtime.Update = originalUpdate
Draw.WorldSplash = originalSplash
''')
evidence = helpers._lua_value(lua.globals().__naturalFrameEvidence)
evidence['kind'] = 'offline NanoVG capture during normal seeded input replay; not native play'
evidence['png'] = 'natural-water-splash.png'
capture.render_png(1920, 1080, OUT/'natural-water-splash.png')
(OUT/'natural-water-splash.svg').write_text(capture.to_svg(1920,1080,'normal route water splash'),encoding='utf-8')
(OUT/'natural-water-frame.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(evidence,ensure_ascii=False))
