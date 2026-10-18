# Circle 1 review baseline

- Lua version: Lua 5.4
- Suites: 48/52 passed; 4 remain failing.
- Reported checks: 464.
- The original run is preserved in `baseline-raw.json` (41/52 passed); 8 recorder-dependent suites were rerun with the existing NVGCapture test double, all 8 passed.
- The corrected run does not include native Maker GUI acceptance. The HUD suite was not rerun after production edits.

## Remaining failures at baseline
- `Circle1A2BarrelTests`
  - fixed barrel getter identifies one exact float and returns read-only snapshots: C:/codex/taptap-sea/scripts/Tests\Circle1A2BarrelTests.lua:222: barrel remains a fixed nonblocking float
  - default first-day voyages follow collision-free waypoints to operation range: C:/codex/taptap-sea/scripts/Tests\Circle1A2BarrelTests.lua:92: ship did not reach waypoint
- `Circle1B3SceneUITests`
  - ordinary mouse and touch adapter blocks UI and consumes net-center pointer once: C:/codex/taptap-sea/scripts/Tests\Circle1B3SceneUITests.lua:231: fishing footer must follow flexible content and precede the modal
- `SeaRuntimeTests`
  - predator sees prey before sardine senses danger: C:/codex/taptap-sea/scripts/Tests\SeaRuntimeTests.lua:318: assertion failed!
  - tuna chase tracks moved prey; loss grace >2 sec: C:/codex/taptap-sea/scripts/Tests\SeaRuntimeTests.lua:353: assertion failed!
- `GameLoopUISpec`
  - LuaError: [string "<python>"]:55: missing visible button: 确认抛网

The complete exception text and tracebacks for both the raw and corrected evidence are retained in the JSON files.
