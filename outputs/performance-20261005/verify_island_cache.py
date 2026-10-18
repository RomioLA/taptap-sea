"""Compare warmed island-cache rendering with the pre-optimization snapshot."""

from __future__ import annotations

import copy
import dataclasses
import hashlib
import importlib.util
import json
import math
import sys
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

OUT_DIR = Path(__file__).resolve().parent
ROOT = OUT_DIR.parents[1]
BASELINE_DIR = OUT_DIR / "before-island-fix"
RESULT_PATH = OUT_DIR / "island-cache-checks.json"
TOLERANCE = 1e-6


def load_host():
    source = ROOT / "tests" / "run_circle1_review.py"
    spec = importlib.util.spec_from_file_location("island_cache_review_host", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load Lua host from {source}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(spec.name, None)
        raise
    return module


def prepare_engine(host: Any, LuaRuntime: Any, lua_type: Any,
                   capture_module: Any, baseline: bool) -> dict[str, Any]:
    lua = LuaRuntime(unpack_returned_tuples=True, encoding="utf-8")
    scripts = (ROOT / "scripts").as_posix()
    lua.globals().package.path = (
        f"{scripts}/?.lua;{scripts}/?/init.lua;" + lua.globals().package.path
    )
    lua.globals().print = lambda *_: None

    snapshot_hashes: dict[str, str] = {}
    if baseline:
        files = {}
        for name in ("SeaViewArt", "ProjectedGeometry", "Projection"):
            path = BASELINE_DIR / f"{name}.lua"
            if not path.is_file():
                raise FileNotFoundError(f"baseline snapshot is missing: {path}")
            files[name] = path.as_posix()
            snapshot_hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        lua.globals().islandBaselineFiles = lua.table_from(files)
        lua.execute(
            """
            for name, path in pairs(islandBaselineFiles) do
                local moduleName, modulePath = name, path
                package.preload["Ocean." .. moduleName] = function()
                    local chunk, err = loadfile(modulePath)
                    assert(chunk, err)
                    return chunk()
                end
            end
            """
        )

    recorder = capture_module.NVGCapture()
    recorder_table = recorder.bind(lua)
    host.bind_recorder(lua, recorder, recorder_table, capture_module)
    lua.globals().islandContext = recorder_table
    engine_api = lua.execute(
        """
        local Runtime = require("Ocean.SeaRuntime")
        local Art = require("Ocean.SeaViewArt")
        local Geometry = require("Ocean.ProjectedGeometry")
        local Config = require("Ocean.Config")
        local runtime = Runtime.New({
            daySeed = 271828,
            initializeRegions = false,
            departure = { x = 0, y = 0 },
        })
        local movement = runtime.movement
        local entity = {
            id = "island-cache-regression",
            entityType = "island",
            position = { x = 0, y = 0 },
            radius = 4.9,
        }
        local context = islandContext
        local originalWorldBoundsVisible = Geometry.WorldBoundsVisible
        local guardedPointCalls = 0
        local maximumGuardedAltitude = 0
        local maximumGuardedPointCount = 0
        local raisedBoundsEdgeSpans = 0
        local raisedBoundsEdgePointCount = 0
        local raisedBoundsMinScreenX = math.huge
        local raisedBoundsMaxScreenX = -math.huge

        local function fieldsMatch(point, snapshot)
            local count = 0
            for key, value in pairs(point) do
                count = count + 1
                if snapshot[key] ~= value then return false end
            end
            local expectedCount = 0
            for _ in pairs(snapshot) do expectedCount = expectedCount + 1 end
            return count == expectedCount
        end

        local function guardedWorldBoundsVisible(view, points, altitude, padding)
            local listRef = points
            local pointRefs, snapshots = {}, {}
            local minScreenX, maxScreenX = math.huge, -math.huge
            local maximumAltitude = altitude or 0
            for index, point in ipairs(points) do
                pointRefs[index] = point
                snapshots[index] = {}
                for key, value in pairs(point) do snapshots[index][key] = value end
                maximumAltitude = math.max(maximumAltitude, point.altitude or 0)
                local screenX = movement:WorldToScreen(point, point.altitude or altitude or 0)
                if screenX then
                    minScreenX = math.min(minScreenX, screenX)
                    maxScreenX = math.max(maxScreenX, screenX)
                end
            end
            local result = originalWorldBoundsVisible(view, points, altitude, padding)
            assert(points == listRef, "WorldBoundsVisible replaced the input world-point list")
            assert(#points == #pointRefs, "WorldBoundsVisible changed the input world-point count")
            for index, point in ipairs(points) do
                assert(point == pointRefs[index], "WorldBoundsVisible replaced an input world point")
                assert(fieldsMatch(point, snapshots[index]),
                    "WorldBoundsVisible changed an input world point")
            end
            guardedPointCalls = guardedPointCalls + 1
            maximumGuardedAltitude = math.max(maximumGuardedAltitude, maximumAltitude)
            maximumGuardedPointCount = math.max(maximumGuardedPointCount, #points)
            if #points >= 5 and maximumAltitude > 0 then
                raisedBoundsMinScreenX = math.min(raisedBoundsMinScreenX, minScreenX)
                raisedBoundsMaxScreenX = math.max(raisedBoundsMaxScreenX, maxScreenX)
            end
            if #points >= 5 and maximumAltitude > 0 and minScreenX < view.viewportWidth
                and maxScreenX > view.viewportWidth then
                raisedBoundsEdgeSpans = raisedBoundsEdgeSpans + 1
                raisedBoundsEdgePointCount = math.max(raisedBoundsEdgePointCount, #points)
            end
            return result
        end

        if type(originalWorldBoundsVisible) == "function" then
            Geometry.WorldBoundsVisible = guardedWorldBoundsVisible
        end

        local function probeWorldPoints(state)
            local points = {
                { x = state.x - 1, y = state.y - 1, altitude = 0 },
                { x = state.x + 1, y = state.y - 1, altitude = 0.5 },
                { x = state.x, y = state.y + 1, altitude = 1 },
            }
            local pointRefs = { points[1], points[2], points[3] }
            local values = {}
            for index, point in ipairs(points) do
                values[index] = { point.x, point.y, point.altitude }
            end
            local visible
            if type(Geometry.WorldBoundsVisible) == "function" then
                visible = Geometry.WorldBoundsVisible(movement, points, 0, 0)
            end
            local unchanged = #points == #pointRefs
            for index, point in ipairs(points) do
                unchanged = unchanged and point == pointRefs[index]
                    and point.x == values[index][1]
                    and point.y == values[index][2]
                    and point.altitude == values[index][3]
            end
            return { available = type(originalWorldBoundsVisible) == "function",
                unchanged = unchanged, visible = visible }
        end

        return {
            draw = function(state)
                movement:SetViewport(state.width, state.height)
                movement.camera.x, movement.camera.y = state.cameraX, state.cameraY
                entity.position.x, entity.position.y = state.x, state.y
                entity.radius = state.radius
                Config.visual.projection.circleSegments = state.segments
                local positionRef = entity.position
                local positionX, positionY = entity.position.x, entity.position.y
                local radius, entityType = entity.radius, entity.entityType
                local guardStart = guardedPointCalls
                maximumGuardedAltitude = 0
                maximumGuardedPointCount = 0
                raisedBoundsEdgeSpans = 0
                raisedBoundsEdgePointCount = 0
                raisedBoundsMinScreenX = math.huge
                raisedBoundsMaxScreenX = -math.huge
                local bounds = Art.Island(context, movement, entity, state.time, state.airMix)
                local probeX, probeY = movement:WorldToScreen(entity.position, 0)
                local leftX = movement:WorldToScreen(
                    { x = entity.position.x - entity.radius, y = entity.position.y }, 0)
                local rightX = movement:WorldToScreen(
                    { x = entity.position.x + entity.radius, y = entity.position.y }, 0)
                local horizonY = movement:GetHorizonY(probeX)
                local directProbe = probeWorldPoints(state)
                return {
                    bounds = bounds,
                    entityUnchanged = entity.position == positionRef
                        and entity.position.x == positionX and entity.position.y == positionY
                        and entity.radius == radius and entity.entityType == entityType,
                    probe = {
                        centerX = probeX, centerY = probeY, horizonY = horizonY,
                        leftX = leftX, rightX = rightX,
                        nearDepth = entity.position.y - entity.radius - movement.camera.y,
                        farDepth = entity.position.y + entity.radius - movement.camera.y,
                        farLimit = Config.camera.farDepth,
                    },
                    directWorldPoints = directProbe,
                    guardedPointCalls = guardedPointCalls - guardStart,
                    maximumGuardedAltitude = maximumGuardedAltitude,
                    maximumGuardedPointCount = maximumGuardedPointCount,
                    raisedBoundsEdgeSpans = raisedBoundsEdgeSpans,
                    raisedBoundsEdgePointCount = raisedBoundsEdgePointCount,
                    raisedBoundsMinScreenX = raisedBoundsMinScreenX,
                    raisedBoundsMaxScreenX = raisedBoundsMaxScreenX,
                }
            end,
        }
        """
    )
    return {
        "lua": lua,
        "lua_type": lua_type,
        "recorder": recorder,
        "draw": engine_api["draw"],
        "snapshot_hashes": snapshot_hashes,
    }


def short(value: Any) -> str:
    result = repr(value)
    return result if len(result) <= 180 else result[:177] + "..."


def compare_value(expected: Any, actual: Any, location: str, tolerance: float = TOLERANCE) -> None:
    if expected is None or actual is None:
        if expected is not actual:
            raise AssertionError(f"{location}: expected {short(expected)}, got {short(actual)}")
        return
    if isinstance(expected, bool) or isinstance(actual, bool):
        if expected is not actual:
            raise AssertionError(f"{location}: expected {short(expected)}, got {short(actual)}")
        return
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        if not math.isfinite(float(expected)) or not math.isfinite(float(actual)):
            if expected != actual:
                raise AssertionError(f"{location}: expected {short(expected)}, got {short(actual)}")
            return
        if abs(float(expected) - float(actual)) > tolerance:
            raise AssertionError(f"{location}: expected {short(expected)}, got {short(actual)}")
        return
    if dataclasses.is_dataclass(expected) or dataclasses.is_dataclass(actual):
        if not dataclasses.is_dataclass(expected) or not dataclasses.is_dataclass(actual):
            raise AssertionError(f"{location}: type mismatch {type(expected).__name__}/{type(actual).__name__}")
        if type(expected) is not type(actual):
            raise AssertionError(f"{location}: type mismatch {type(expected).__name__}/{type(actual).__name__}")
        for field in dataclasses.fields(expected):
            compare_value(getattr(expected, field.name), getattr(actual, field.name),
                          f"{location}.{field.name}", tolerance)
        return
    if isinstance(expected, dict) and isinstance(actual, dict):
        if expected.keys() != actual.keys():
            raise AssertionError(f"{location}: keys differ ({sorted(expected)} vs {sorted(actual)})")
        for key in expected:
            compare_value(expected[key], actual[key], f"{location}.{key}", tolerance)
        return
    if isinstance(expected, (list, tuple)) and isinstance(actual, (list, tuple)):
        if len(expected) != len(actual):
            raise AssertionError(f"{location}: length {len(expected)} != {len(actual)}")
        for index, (left, right) in enumerate(zip(expected, actual)):
            compare_value(left, right, f"{location}[{index}]", tolerance)
        return
    if expected != actual:
        raise AssertionError(f"{location}: expected {short(expected)}, got {short(actual)}")


def compare_render_records(expected: list[dict[str, Any]], actual: list[dict[str, Any]]) -> float:
    if len(expected) != len(actual):
        raise AssertionError(f"output element count differs: {len(expected)} != {len(actual)}")
    maximum_coordinate_delta = 0.0
    for element_index, (before, after) in enumerate(zip(expected, actual)):
        if before.keys() != after.keys():
            raise AssertionError(f"element {element_index}: recorder fields differ")
        before_path, after_path = before["path"], after["path"]
        if len(before_path) != len(after_path):
            raise AssertionError(
                f"element {element_index}: path command count {len(before_path)} != {len(after_path)}"
            )
        for command_index, (before_command, after_command) in enumerate(zip(before_path, after_path)):
            if before_command[0] != after_command[0]:
                raise AssertionError(f"element {element_index}, command {command_index}: path command differs")
            before_coords, after_coords = before_command[1], after_command[1]
            if len(before_coords) != len(after_coords):
                raise AssertionError(f"element {element_index}, command {command_index}: coordinate count differs")
            for coordinate_index, (left, right) in enumerate(zip(before_coords, after_coords)):
                delta = abs(float(left) - float(right))
                maximum_coordinate_delta = max(maximum_coordinate_delta, delta)
                if delta > TOLERANCE:
                    raise AssertionError(
                        f"element {element_index}, command {command_index}, coordinate {coordinate_index}: "
                        f"{left} != {right} (delta {delta})"
                    )
        for field in before:
            if field != "path":
                compare_value(before[field], after[field], f"element[{element_index}].{field}")
    return maximum_coordinate_delta


def scenarios() -> list[dict[str, Any]]:
    base = {
        "width": 1280,
        "height": 720,
        "x": 0.0,
        "y": 0.0,
        "cameraX": 0.0,
        "cameraY": 0.0,
        "radius": 4.9,
        "segments": 48,
        "time": 0.25,
        "airMix": 0.15,
    }

    def case(name: str, checks: tuple[str, ...] = (), **changes: Any) -> dict[str, Any]:
        return {"name": name, "state": {**base, **changes}, "checks": list(checks)}

    return [
        case("warm-visible", ("nonempty",), radius=4.9),
        case("radius-below-hill-threshold", ("nonempty",), radius=2.9),
        case("radius-at-hill-threshold", ("nonempty",), radius=3.0),
        case("radius-below-tree-threshold", ("nonempty",), radius=4.9),
        case("radius-at-tree-threshold", ("nonempty",), radius=5.0),
        case("partial-right-edge", ("nonempty", "partial-right"), x=39.0, radius=5.0),
        case("raised-geometry-side-edge", (
            "nonempty", "center-outside-right", "raised-edge-envelope"
        ), x=43.0, radius=5.0),
        case("horizon-crossing", ("nonempty", "horizon-crossing"), y=109.0, radius=5.0),
        case("segment-count-change", ("nonempty",), radius=5.0, segments=64),
        case("portrait-viewport-change", ("nonempty",), radius=5.0, segments=64,
             width=600, height=900),
        case("camera-change", ("nonempty",), x=20.0, y=30.0, cameraX=5.0, cameraY=10.0,
             radius=5.0, segments=64),
        case("animation-reference", ("nonempty",), radius=5.0),
        case("time-change", ("nonempty", "visual-change"), radius=5.0, time=6.25),
        case("air-mix-reference", ("nonempty",), radius=5.0, time=6.25),
        case("air-mix-change", ("nonempty", "visual-change"), radius=5.0,
             time=6.25, airMix=0.9),
    ]


def run_checks() -> dict[str, Any]:
    host = load_host()
    LuaRuntime, lua_type, capture_module = host.prepare_runtime()
    engines = {
        "before": prepare_engine(host, LuaRuntime, lua_type, capture_module, baseline=True),
        "after": prepare_engine(host, LuaRuntime, lua_type, capture_module, baseline=False),
    }
    records: list[dict[str, Any]] = []
    draws_checked = 0
    maximum_coordinate_delta = 0.0
    previous_actual: list[dict[str, Any]] | None = None

    for scenario in scenarios():
        name, state, checks = scenario["name"], scenario["state"], scenario["checks"]
        row: dict[str, Any] = {"name": name, "state": state, "passed": False}
        records.append(row)
        try:
            baseline = engines["before"]
            actual = engines["after"]
            baseline["recorder"].reset()
            baseline_result = baseline["draw"](baseline["lua"].table_from(state))
            baseline_elements = copy.deepcopy(baseline["recorder"].elements)
            baseline_outcome = host.to_json_value(baseline_result, baseline["lua_type"])
            draws = 3 if name == "warm-visible" else 2
            current_draws = []
            current_outputs = []
            for _ in range(draws):
                actual["recorder"].reset()
                actual_result = actual["draw"](actual["lua"].table_from(state))
                current_outputs.append(copy.deepcopy(actual["recorder"].elements))
                current_draws.append(host.to_json_value(actual_result, actual["lua_type"]))
                draws_checked += 1

            row["baselineElements"] = len(baseline_elements)
            row["optimizedElements"] = len(current_outputs[0])
            row["optimizedDraws"] = draws
            row["matchesBaseline"] = True
            row["maximumCoordinateDifferencePx"] = 0.0
            for draw_index, output in enumerate(current_outputs):
                delta = compare_render_records(baseline_elements, output)
                compare_value(baseline_outcome.get("bounds"), current_draws[draw_index].get("bounds"),
                              f"{name}.draw[{draw_index}].bounds")
                row["maximumCoordinateDifferencePx"] = max(
                    row["maximumCoordinateDifferencePx"], delta
                )
            maximum_coordinate_delta = max(maximum_coordinate_delta,
                                            row["maximumCoordinateDifferencePx"])

            first_outcome = current_draws[0]
            if any(outcome.get("entityUnchanged") is not True for outcome in current_draws):
                raise AssertionError("Island changed the input entity or its position table")
            if any(outcome.get("directWorldPoints", {}).get("unchanged") is not True
                   for outcome in current_draws):
                raise AssertionError("WorldBoundsVisible changed caller-owned world points")
            if any(not outcome.get("directWorldPoints", {}).get("available")
                   or outcome.get("guardedPointCalls", 0) < 1 for outcome in current_draws):
                raise AssertionError("optimized WorldBoundsVisible was not exercised by the draw")

            probes = first_outcome.get("probe") or {}
            row["projectionProbe"] = probes
            row["maxWorldBoundsAltitude"] = first_outcome.get("maximumGuardedAltitude", 0)
            row["maxWorldBoundsPointCount"] = first_outcome.get("maximumGuardedPointCount", 0)
            row["raisedBoundsEdgeSpans"] = first_outcome.get("raisedBoundsEdgeSpans", 0)
            row["raisedBoundsEdgePointCount"] = first_outcome.get("raisedBoundsEdgePointCount", 0)
            row["raisedBoundsMinScreenX"] = first_outcome.get("raisedBoundsMinScreenX")
            row["raisedBoundsMaxScreenX"] = first_outcome.get("raisedBoundsMaxScreenX")
            if "nonempty" in checks and row["optimizedElements"] == 0:
                raise AssertionError("fixture produced no recorded draw output")
            if "partial-right" in checks:
                if not (probes.get("centerX", 0) < state["width"]
                        and probes.get("leftX", state["width"]) < state["width"]
                        < probes.get("rightX", 0)):
                    raise AssertionError("island did not partially cross the right viewport edge")
            if "center-outside-right" in checks:
                if not (probes.get("leftX", state["width"]) < state["width"]
                        < probes.get("centerX", 0) < probes.get("rightX", 0)):
                    raise AssertionError(
                        "island center is not outside while its left edge remains in the viewport"
                    )
            if "horizon-crossing" in checks:
                if not (probes.get("nearDepth", math.inf) < probes.get("farLimit", -math.inf)
                        < probes.get("farDepth", -math.inf)):
                    raise AssertionError("fixture did not straddle the far horizon depth")
                if abs(probes.get("centerY", math.inf) - probes.get("horizonY", -math.inf)) > 2:
                    raise AssertionError("island center was not projected near the horizon")
            if "raised-edge-envelope" in checks:
                if first_outcome.get("maximumGuardedAltitude", 0) < 2.0:
                    raise AssertionError("side-edge draw did not pass the complete raised tree envelope")
                if first_outcome.get("maximumGuardedPointCount", 0) < 5:
                    raise AssertionError("side-edge draw did not test the complete tree canopy points")
                if first_outcome.get("raisedBoundsEdgeSpans", 0) < 1:
                    raise AssertionError("raised tree AABB did not span the side viewport edge")
                if first_outcome.get("raisedBoundsEdgePointCount", 0) < 5:
                    raise AssertionError("raised side-edge cull omitted tree canopy points")
            if "visual-change" in checks and previous_actual is not None:
                try:
                    compare_render_records(previous_actual, current_outputs[0])
                    changed = False
                except AssertionError:
                    changed = True
                # Equal paths and paint at these adjacent inputs would indicate that the
                # animated foam or air-perspective tint had been frozen by the cache.
                if not changed:
                    raise AssertionError("time/airMix mutation did not affect recorded rendering")

            row["entityUnchanged"] = True
            row["callerWorldPointsUnchanged"] = True
            row["worldBoundsCallsPerDraw"] = first_outcome.get("guardedPointCalls", 0)
            row["maxWorldBoundsAltitude"] = first_outcome.get("maximumGuardedAltitude", 0)
            row["maxWorldBoundsPointCount"] = first_outcome.get("maximumGuardedPointCount", 0)
            row["raisedBoundsEdgeSpans"] = first_outcome.get("raisedBoundsEdgeSpans", 0)
            row["raisedBoundsEdgePointCount"] = first_outcome.get("raisedBoundsEdgePointCount", 0)
            row["projectionProbe"] = probes
            row["passed"] = True
            previous_actual = current_outputs[0]
        except Exception as error:
            row["error"] = f"{type(error).__name__}: {error}"
            return {
                "passed": False,
                "method": (
                    "Independent Lua 5.4 runtimes load the pre-optimization snapshot and current source. "
                    "A single optimized entity is kept warm across mutations; recorded NanoVG elements "
                    "compare draw order, paint, and every path coordinate within 1e-6 px."
                ),
                "scenarioCount": len(records),
                "optimizedDrawCount": draws_checked,
                "maximumCoordinateDifferencePx": maximum_coordinate_delta,
                "snapshotSha256": engines["before"]["snapshot_hashes"],
                "error": row["error"],
                "scenarios": records,
            }

    return {
        "passed": True,
        "method": (
            "Independent Lua 5.4 runtimes load the pre-optimization snapshot and current source. "
            "A single optimized entity is kept warm across mutations; recorded NanoVG elements "
            "compare draw order, paint, and every path coordinate within 1e-6 px."
        ),
        "scenarioCount": len(records),
        "optimizedDrawCount": draws_checked,
        "maximumCoordinateDifferencePx": maximum_coordinate_delta,
        "snapshotSha256": engines["before"]["snapshot_hashes"],
        "scenarios": records,
    }


def main() -> int:
    result: dict[str, Any] = {
        "passed": False,
        "project": str(ROOT),
        "baseline": str(BASELINE_DIR),
        "resultPath": str(RESULT_PATH),
    }
    try:
        result.update(run_checks())
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
    RESULT_PATH.parent.mkdir(parents=True, exist_ok=True)
    RESULT_PATH.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = {
        "passed": result.get("passed", False),
        "scenarioCount": result.get("scenarioCount", len(result.get("scenarios", []))),
        "optimizedDrawCount": result.get("optimizedDrawCount", 0),
        "maximumCoordinateDifferencePx": result.get("maximumCoordinateDifferencePx"),
        "error": result.get("error"),
        "resultPath": str(RESULT_PATH),
    }
    print(json.dumps(summary, ensure_ascii=False))
    return 0 if result.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
