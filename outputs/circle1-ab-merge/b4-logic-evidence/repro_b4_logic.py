from __future__ import annotations

import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, r"D:\sillytavern-data\taptap-sea-B\.tmp\game-loop-test-runtime")
from lupa.lua54 import LuaRuntime

repo = Path(__file__).resolve().parents[3]
scripts = (repo / "scripts").as_posix()
lua = LuaRuntime(unpack_returned_tuples=True)
existing = lua.eval("package.path")
lua.eval("package").path = f"{scripts}/?.lua;{scripts}/?/init.lua;" + existing

lua_source = r'''
local Runtime = require("Ocean.SeaRuntime")
local Loop = require("Gameplay.Loop")
local Game = require("Game.Game")
local Progress = require("Gameplay.Circle1B2Progress")

local function setup()
    local runtime = Runtime.New({ initializeRegions = false })
    local store = {
        Save = function() return true end,
        Load = function() return true end,
    }
    local loop = Loop.New({ store = store })
    loop:EnableWorldActions():BindRuntime(runtime)
    loop:BindRuntime(runtime)
    local barrel = assert(runtime:GetFixedBarrel(), "current C Runtime has no fixed barrel")
    runtime.ship.position = { x = barrel.position.x + 4, y = barrel.position.y }
    loop.inPort = false
    loop.clock:Resume("port")
    return runtime, loop, Game.New(runtime, loop)
end

local function start(runtime, loop)
    local token, reason = loop:BeginBarrelInspection()
    assert(token, tostring(reason))
    return loop.barrel.active
end

local function position(runtime)
    return { x = runtime.ship.position.x, y = runtime.ship.position.y }
end

local results = {}

do
    local runtime, loop, game = setup()
    local record = start(runtime, loop)
    record.elapsed = 3.9
    local before = position(runtime)
    local seaBefore, clockBefore = runtime.time, loop.clock.elapsed
    game:Update(0.1, 1, 0)
    results.final_0_1_frame = {
        dt = 0.1,
        keyboardAxisX = 1,
        actionActiveBefore = true,
        actionActiveAfter = loop.barrel:IsBusy(),
        shipXBefore = before.x,
        shipXAfter = runtime.ship.position.x,
        shipYBefore = before.y,
        shipYAfter = runtime.ship.position.y,
        seaTimeAdvanced = runtime.time - seaBefore,
        clockTimeAdvanced = loop.clock.elapsed - clockBefore,
        stage = Progress.GetBarrelStage(loop.player),
        staminaSpent = 100 - loop.player.stamina,
    }
end

do
    local runtime, loop, game = setup()
    start(runtime, loop)
    local before = position(runtime)
    local seaBefore, clockBefore = runtime.time, loop.clock.elapsed
    game:Update(4, 1, 0)
    results.single_4_second_frame = {
        dt = 4,
        keyboardAxisX = 1,
        actionActiveAfter = loop.barrel:IsBusy(),
        shipXBefore = before.x,
        shipXAfter = runtime.ship.position.x,
        shipYBefore = before.y,
        shipYAfter = runtime.ship.position.y,
        seaTimeAdvanced = runtime.time - seaBefore,
        clockTimeAdvanced = loop.clock.elapsed - clockBefore,
        stage = Progress.GetBarrelStage(loop.player),
        staminaSpent = 100 - loop.player.stamina,
    }
end

do
    local runtime, loop, game = setup()
    local record = start(runtime, loop)
    record.elapsed = 3.9
    loop.clock:Seek("night", loop.clock.nightSec - 0.1)
    local seaBefore, clockBefore = runtime.time, loop.clock.elapsed
    game:Update(0.1, 1, 0)
    results.exact_night_tie = {
        dt = 0.1,
        actionActiveAfter = loop.barrel:IsBusy(),
        nightExhausted = loop.clock.exhausted,
        dayForcedReturn = loop.dayExhausted,
        seaTimeAdvanced = runtime.time - seaBefore,
        clockTimeAdvanced = loop.clock.elapsed - clockBefore,
        stage = Progress.GetBarrelStage(loop.player),
        staminaSpent = 100 - loop.player.stamina,
        runtimePausedAfter = runtime.paused,
        forcedReturnPrepared = loop.forcedAtPort == true,
    }
end

do
    local runtime, loop, game = setup()
    local record = start(runtime, loop)
    record.elapsed = 1
    local opened, openReason = loop:SetInventoryOpen(true)
    local seaBefore, clockBefore = runtime.time, loop.clock.elapsed
    game:Update(0.2, 1, 0)
    results.inventory_pause = {
        opened = opened,
        openReason = openReason,
        barrelActive = loop.barrel:IsBusy(),
        runtimePaused = runtime.paused,
        seaTimeAdvanced = runtime.time - seaBefore,
        clockTimeAdvanced = loop.clock.elapsed - clockBefore,
    }
end

do
    local runtime, loop, game = setup()
    local record = start(runtime, loop)
    record.elapsed = 1
    loop.player.day = 7
    local opened, openReason = loop:OpenDay7PaperBeforeEnding()
    local seaBefore, clockBefore = runtime.time, loop.clock.elapsed
    game:Update(0.2, 1, 0)
    results.dialogue_pause = {
        opened = opened,
        openReason = openReason,
        barrelActive = loop.barrel:IsBusy(),
        runtimePaused = runtime.paused,
        seaTimeAdvanced = runtime.time - seaBefore,
        clockTimeAdvanced = loop.clock.elapsed - clockBefore,
    }
end

do
    local runtime, loop, game = setup()
    local record = start(runtime, loop)
    record.elapsed = 3.9
    local seaBefore, clockBefore = runtime.time, loop.clock.elapsed
    game:Update(0.5, 1, 0)
    results.split_frame_budget = {
        dt = 0.5,
        oceanMaxFrameSec = require("Ocean.Config").world.maxFrameSec,
        actionCompletedAtGameSecond = 0.1,
        seaTimeAdvanced = runtime.time - seaBefore,
        clockTimeAdvanced = loop.clock.elapsed - clockBefore,
        actionActiveAfter = loop.barrel:IsBusy(),
    }
end

do
    local runtime, loop, game = setup()
    local record = start(runtime, loop)
    record.elapsed = 3.9
    loop.clock:Seek("night", loop.clock.nightSec - 0.1)
    local seaBefore, clockBefore = runtime.time, loop.clock.elapsed
    local hookCalls = 0
    debug.sethook(function()
        hookCalls = hookCalls + 1
        if hookCalls >= 20 then error("instruction guard: likely non-progress update loop") end
    end, "", 1000)
    local ok, err = pcall(function() game:Update(0.1000001, 1, 0) end)
    debug.sethook()
    results.night_tie_with_frame_remainder = {
        dt = 0.1000001,
        updateReturned = ok,
        error = ok and nil or tostring(err),
        guardCalls = hookCalls,
        actionActiveAfter = loop.barrel:IsBusy(),
        nightExhausted = loop.clock.exhausted,
        dayForcedReturn = loop.dayExhausted,
        seaTimeAdvanced = runtime.time - seaBefore,
        clockTimeAdvanced = loop.clock.elapsed - clockBefore,
        stage = Progress.GetBarrelStage(loop.player),
        staminaSpent = 100 - loop.player.stamina,
    }
end

return results
'''

results = lua.execute(lua_source)
normalized = {}
for key, row in results.items():
    normalized[key] = {str(k): v for k, v in row.items()}

out = Path(__file__).with_name("results.json")
out.write_text(json.dumps(normalized, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(normalized, ensure_ascii=False, indent=2))
