# Circle 1 review baseline baseline

- Lua: Lua 5.4
- Suites: 41/52 passed; reported subtests: 444
- Generated: 2026-10-04T18:18:14.095028+00:00

## Failures
- `Circle1A2BarrelTests` (scripts\Tests\Circle1A2BarrelTests.lua)
  - [{"name": "fixed barrel getter identifies one exact float and returns read-only snapshots", "passed": false, "error": "C:/codex/taptap-sea/scripts/Tests\\Circle1A2BarrelTests.lua:222: barrel remains a fixed nonblocking float"}, {"name": "default first-day voyages follow collision-free waypoints to operation range", "passed": false, "error": "C:/codex/taptap-sea/scripts/Tests\\Circle1A2BarrelTests.lua:92: ship did not reach waypoint"}]
- `Circle1A2FishingTests` (scripts\Tests\Circle1A2FishingTests.lua)
  - [{"name": "fishing_phase_geometry_and_readonly_snapshot", "error": "C:/codex/taptap-sea/scripts/Tests\\Circle1A2FishingTests.lua:68: C:/codex/taptap-sea/scripts/Tests\\Circle1A2FishingTests.lua:37: attempt to index a nil value (upvalue 'recorder')", "passed": false}, {"name": "optional_sixth_argument_keeps_fifth_clock_and_absent_view", "error": "C:/codex/taptap-sea/scripts/Tests\\Circle1A2FishingTests.lua:75: attempt to index a nil value (upvalue 'recorder')", "passed": false}, {"name": "projected_fish_culling_keeps_partial_edge_and_rejects_far_depth", "error": "C:/codex/taptap-sea/scripts/Tests\\Circle1A2FishingTests.lua:97: C:/codex/taptap-sea/scripts/Ocean\\Draw.lua:62: attempt to call a nil value (global 'nvgBeginPath')", "passed": false}]
- `Circle1A3RecognitionTests` (scripts\Tests\Circle1A3RecognitionTests.lua)
  - [{"error": "...x/taptap-sea/scripts/Tests\\Circle1A3RecognitionTests.lua:32: attempt to index a nil value (local 'recorder')", "name": "first_approach_then_depart_and_return_reads_existing_player_progress", "passed": false}, {"error": "...x/taptap-sea/scripts/Tests\\Circle1A3RecognitionTests.lua:32: attempt to index a nil value (local 'recorder')", "name": "restore_and_new_game_are_read_live_without_ocean_progress_copy", "passed": false}, {"error": "...x/taptap-sea/scripts/Tests\\Circle1A3RecognitionTests.lua:32: attempt to index a nil value (local 'recorder')", "name": "missing_false_nil_and_nonboolean_queries_preserve_unknown_behavior", "passed": false}, {"error": "...x/taptap-sea/scripts/Tests\\Circle1A3RecognitionTests.lua:32: attempt to index a nil value (local 'recorder')", "name": "recognized_offscreen_and_content_decoys_do_not_bypass_existing_filters", "passed": false}, {"error": "...x/taptap-sea/scripts/Tests\\Circle1A3RecognitionTests.lua:32: attempt to index a nil value (local 'recorder')", "name": "repeated_draw_is_readonly_for_world_ship_signals_and_player", "passed": false}]
- `Circle1B3SceneUITests` (scripts\Tests\Circle1B3SceneUITests.lua)
  - [{"error": "C:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:231: fishing footer must follow flexible content and precede the modal\nstack traceback:\n\t[C]: in function 'assert'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:231: in upvalue 'action'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:108: in function <C:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:105>\n\t[C]: in function 'xpcall'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:105: in upvalue 'withScene'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:216: in function <C:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:215>\n\t[C]: in function 'xpcall'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:119: in local 'check'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:215: in function 'Tests.Circle1B3SceneUITests.Run'\nstack traceback:\n\t[C]: in function 'error'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:113: in upvalue 'withScene'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:216: in function <C:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:215>\n\t[C]: in function 'xpcall'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:119: in local 'check'\n\tC:/codex/taptap-sea/scripts/Tests\\Circle1B3SceneUITests.lua:215: in function 'Tests.Circle1B3SceneUITests.Run'", "name": "ordinary mouse and touch adapter blocks UI and consumes net-center pointer once", "passed": false}]
- `SeaAtmosphereTests` (scripts\Tests\SeaAtmosphereTests.lua)
  - LuaError: C:/codex/taptap-sea/scripts/Tests\SeaAtmosphereTests.lua:87: NVGCapture recorder is required
stack traceback:
	[C]: in function 'assert'
	C:/codex/taptap-sea/scripts/Tests\SeaAtmosphereTests.lua:87: in function 'Tests.SeaAtmosphereTests.Run'
- `SeaFusionRenderTests` (scripts\Tests\SeaFusionRenderTests.lua)
  - LuaError: C:/codex/taptap-sea/scripts/Tests\SeaFusionRenderTests.lua:258: C:/codex/taptap-sea/scripts/Tests\SeaFusionRenderTests.lua:140: attempt to index a nil value (upvalue 'recorder')
stack traceback:
	[C]: in function 'error'
	C:/codex/taptap-sea/scripts/Tests\SeaFusionRenderTests.lua:258: in function 'Tests.SeaFusionRenderTests.Run'
- `SeaHorizonOcclusionTests` (scripts\Tests\SeaHorizonOcclusionTests.lua)
  - [{"name": "actual scene renders a new float with its center beyond the tangent", "passed": false, "error": "...ex/taptap-sea/scripts/Tests\\SeaHorizonOcclusionTests.lua:144: attempt to index a nil value (upvalue 'recorder')"}]
- `SeaMotionEffectsTests` (scripts\Tests\SeaMotionEffectsTests.lua)
  - [{"name": "water mark budget is enforced even within a single row", "passed": false, "error": "C:/codex/taptap-sea/scripts/Tests\\SeaMotionEffectsTests.lua:129: C:/codex/taptap-sea/scripts/Tests\\SeaMotionEffectsTests.lua:121: attempt to index a nil value (upvalue 'recorder')"}]
- `SeaPresentationTests` (scripts\Tests\SeaPresentationTests.lua)
  - [{"name": "presentation_preserves_world_coordinates_and_restores_drawing_state", "error": "C:/codex/taptap-sea/scripts/Tests\\SeaPresentationTests.lua:67: attempt to index a nil value (upvalue 'recorder')", "passed": false}, {"name": "paused_scene_keeps_hidden_and_beyond_horizon_fish_out_of_the_sky", "error": "C:/codex/taptap-sea/scripts/Tests\\SeaPresentationTests.lua:108: C:/codex/taptap-sea/scripts/Tests\\SeaPresentationTests.lua:93: attempt to index a nil value (upvalue 'recorder')", "passed": false}]
- `SeaRuntimeTests` (scripts\Tests\SeaRuntimeTests.lua)
  - [{"error": "C:/codex/taptap-sea/scripts/Tests\\SeaRuntimeTests.lua:318: assertion failed!", "name": "predator sees prey before sardine senses danger", "passed": false}, {"error": "C:/codex/taptap-sea/scripts/Tests\\SeaRuntimeTests.lua:353: assertion failed!", "name": "tuna chase tracks moved prey; loss grace >2 sec", "passed": false}]
- `GameLoopUISpec` (scripts\Tests\GameLoopUISpec.lua)
  - LuaError: [string "<python>"]:55: missing visible button: 确认抛网
stack traceback:
	[string "<python>"]:174: in main chunk
	[string "<python>"]:6: in local 'test'
	[string "<python>"]:182: in local 'fn'
	[string "<python>"]:55: in upvalue 'button'
	[C]: in function 'assert'
