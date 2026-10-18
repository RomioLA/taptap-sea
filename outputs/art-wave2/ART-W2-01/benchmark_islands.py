"""Offline A/B benchmark of island and port drawing in isolated Lua 5.4.

This measures Lua-side process CPU, elapsed time, and allocation only. NanoVG
entry points are counted no-ops; no native renderer, GPU, GUI, or FPS is tested.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import statistics
import sys
import time
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BEFORE = OUT / "before"
MODULES = {
    "SeaViewArt": ("Ocean.SeaViewArt", "scripts/Ocean/SeaViewArt.lua", BEFORE / "SeaViewArt.lua"),
    "ImageArt": ("Ocean.ImageArt", "scripts/Ocean/ImageArt.lua", BEFORE / "ImageArt.lua"),
    "SeaDraw": ("Ocean.SeaDraw", "scripts/Ocean/SeaDraw.lua", BEFORE / "SeaDraw.lua"),
    "OceanImageCatalog": (
        "GeneratedData.OceanImageCatalog",
        "scripts/GeneratedData/OceanImageCatalog.lua",
        BEFORE / "OceanImageCatalog.lua",
    ),
}
CASES = [
    {"name": "near_full", "camera": [0, -35], "radius": 20},
    {"name": "left_edge", "camera": [90, -35], "radius": 20},
    {"name": "horizon_crossing", "camera": [0, -108], "radius": 20},
    {"name": "small_island", "camera": [0, -35], "radius": 12},
    {"name": "offscreen", "camera": [2500, -35], "radius": 20},
    {"name": "port_scene", "camera": [0, 0], "radius": 20, "scene": True},
    {"name": "port_scene_drift", "camera": [0, 0], "radius": 20, "scene": True, "drift": True},
]
WIDTH, HEIGHT = 1920, 1080
RUNS, FRAMES = 4, 32


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_host():
    spec = importlib.util.spec_from_file_location(
        "art_w2_circle1_host", ROOT / "tests" / "run_circle1_review.py"
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load tests/run_circle1_review.py")
    host = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(host)
    return host


HOST = load_host()
LuaRuntime, lua_type, capture = HOST.prepare_runtime()
_probe_lua = LuaRuntime(unpack_returned_tuples=True, encoding="utf-8")
_probe_recorder = capture.NVGCapture()
HOST.bind_recorder(_probe_lua, _probe_recorder, _probe_recorder.bind(_probe_lua), capture)
RECORDER_APIS = {
    key for key in _probe_lua.globals().keys()
    if isinstance(key, str) and key.startswith("nvg")
}


def module_sources(version: str) -> dict[str, Path]:
    return {
        key: (row[2] if version == "A_before" else ROOT / row[1])
        for key, row in MODULES.items()
    }


def api_names(version: str) -> list[str]:
    names: set[str] = {"nvgCreateImage", *RECORDER_APIS}
    for path in module_sources(version).values():
        names.update(re.findall(r"\b(nvg[A-Za-z0-9_]+)\s*\(", path.read_text(encoding="utf-8")))
    for relative in ("scripts/Ocean/ProjectedGeometry.lua", "scripts/Ocean/Projection.lua"):
        source = (ROOT / relative).read_text(encoding="utf-8")
        names.update(re.findall(r"\b(nvg[A-Za-z0-9_]+)\s*\(", source))
    return sorted(names)


def configure_lua(version: str, case: dict[str, Any]):
    lua = LuaRuntime(unpack_returned_tuples=True, encoding="utf-8")
    lua.globals().package.path = (
        f"{(ROOT / 'scripts').as_posix()}/?.lua;"
        f"{(ROOT / 'scripts').as_posix()}/?/init.lua;"
        + lua.globals().package.path
    )
    lua.globals().print = lambda *_: None
    lua.globals().width = WIDTH
    lua.globals().height = HEIGHT
    lua.globals().cameraX, lua.globals().cameraY = case["camera"]
    lua.globals().radius = case["radius"]
    lua.globals().scene = case.get("scene", False)
    lua.globals().drift = case.get("drift", False)
    recorder = capture.NVGCapture()
    HOST.bind_recorder(lua, recorder, recorder.bind(lua), capture)

    image_attempts: list[dict[str, Any]] = []
    image_handle = 0

    def create_image(_ctx: Any, image_path: Any, flags: Any) -> int:
        nonlocal image_handle
        raw_path = str(image_path)
        resolved = ROOT / "assets" / Path(raw_path)
        exists = resolved.is_file()
        is_png = exists and resolved.suffix.lower() == ".png" and resolved.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
        image_attempts.append(
            {
                "path": raw_path,
                "resolvedPath": resolved.relative_to(ROOT).as_posix() if resolved.is_relative_to(ROOT) else str(resolved),
                "exists": exists,
                "isPng": bool(is_png),
                "bytes": resolved.stat().st_size if exists else None,
                "flags": int(flags) if isinstance(flags, (int, float)) else str(flags),
            }
        )
        if not is_png:
            return -1
        image_handle += 1
        return image_handle

    lua.globals().imageCreate = create_image
    lua.globals().nvgNames = lua.table_from(api_names(version))

    if version == "A_before":
        for key, (module_name, _current_path, before_path) in MODULES.items():
            lua.execute(
                "package.preload["
                + json.dumps(module_name)
                + "]=function() return assert(loadfile("
                + json.dumps(before_path.as_posix())
                + "))() end"
            )

    setup = lua.execute(
        r"""
        local sharedValue = {}
        local calls, fills, strokeCalls = 0, 0, 0
        local valueNames = {
            nvgRGBA=true, nvgRGB=true, nvgHSLA=true, nvgHSL=true,
            nvgLinearGradient=true, nvgBoxGradient=true, nvgRadialGradient=true,
            nvgImagePattern=true,
        }
        local function install(name)
            return function(...)
                calls = calls + 1
                if name == "nvgFill" then fills = fills + 1 end
                if name == "nvgCreateImage" then
                    return imageCreate(...)
                end
                if valueNames[name] then return sharedValue end
            end
        end
        for _, name in ipairs(nvgNames) do _G[name] = install(name) end
        NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY, NVG_IMAGE_GENERATE_MIPMAPS = 1, 2, 4

        local Runtime = require("Ocean.SeaRuntime")
        local View = require("Ocean.SeaViewArt")
        local Scene = require("Ocean.SeaDraw")
        local ImageArt = require("Ocean.ImageArt")
        local Geometry = require("Ocean.ProjectedGeometry")
        local originalStrokeWorldLine = Geometry.StrokeWorldLine
        Geometry.StrokeWorldLine = function(...)
            strokeCalls = strokeCalls + 1
            return originalStrokeWorldLine(...)
        end

        local ctx = {}
        ImageArt.Load(ctx)
        local runtime = Runtime.New({initializeRegions=scene, daySeed=271828})
        runtime.movement:SetViewport(width, height)
        runtime.movement:ResetAtPosition({x=cameraX, y=cameraY})
        runtime.time = 9
        local island = {position={x=0,y=0},radius=radius,entityType="island",layer="surface"}

        local function draw()
            if drift then
                runtime.time = runtime.time + 1/60
                runtime.movement.camera.x = runtime.movement.camera.x + .02
                runtime.movement.camera.y = runtime.movement.camera.y + .02
                runtime.ship.position.x = runtime.ship.position.x + .02
                runtime.ship.position.y = runtime.ship.position.y + .02
            end
            if scene then Scene.Scene(ctx, width, height, runtime)
            else View.Island(ctx, runtime.movement, island, runtime.time, 0) end
        end
        draw()

        local function measure(frameCount)
            collectgarbage("collect"); collectgarbage("stop")
            calls, fills, strokeCalls = 0, 0, 0
            local cpuStart, elapsedStart = processClock(), elapsedClock()
            for _=1,frameCount do draw() end
            local cpu = (processClock()-cpuStart)*1000/frameCount
            local elapsed = (elapsedClock()-elapsedStart)*1000/frameCount
            local apiCalls, fillCalls, strokeWorldLineCalls = calls/frameCount, fills/frameCount, strokeCalls/frameCount
            collectgarbage("restart"); collectgarbage("collect"); collectgarbage("stop")
            local heap = collectgarbage("count")
            draw()
            local allocated = collectgarbage("count")-heap
            collectgarbage("restart"); collectgarbage("collect")
            return {processCpuMsPerFrame=cpu,elapsedMsPerFrame=elapsed,
                nvgAPICallsPerFrame=apiCalls,nvgFillCallsPerFrame=fillCalls,
                geometryStrokeWorldLineCallsPerFrame=strokeWorldLineCalls,
                allocatedKiBPerFrame=allocated}
        end
        return {measure=measure}
        """
    )
    lua.globals().processClock = time.process_time
    lua.globals().elapsedClock = time.perf_counter
    return lua, setup["measure"], image_attempts


def version_manifest(version: str) -> dict[str, Any]:
    sources = module_sources(version)
    return {
        "modulePaths": {key: path.relative_to(ROOT).as_posix() for key, path in sources.items()},
        "moduleSha256": {key: sha256(path) for key, path in sources.items()},
        "preloadOverrides": version == "A_before",
        "packagePreloadModuleNames": {
            key: row[0] for key, row in MODULES.items()
        } if version == "A_before" else {},
    }


versions = {name: version_manifest(name) for name in ("A_before", "B_current")}
config = {
    "dimensions": [WIDTH, HEIGHT],
    "cases": CASES,
    "runsPerVersion": RUNS,
    "framesPerRun": FRAMES,
    "alternation": ["A_before", "B_current"] if RUNS % 2 == 0 else ["A_before", "B_current", "B_current", "A_before"],
    "versions": versions,
    "otherModules": {
        relative: sha256(ROOT / relative)
        for relative in ("scripts/Ocean/ProjectedGeometry.lua", "scripts/Ocean/Projection.lua")
    },
    "imageStub": "returns positive integer handles only for existing PNG paths beneath assets/",
    "counters": ["nvgAPICalls", "nvgFill", "Geometry.StrokeWorldLine"],
    "countingNoopNvgApiNames": sorted(set(api_names("A_before")) | set(api_names("B_current"))),
}
config_hash = hashlib.sha256(json.dumps(config, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()

records = []
image_paths_by_version: dict[str, list[dict[str, Any]]] = {}
for case in CASES:
    engines = {}
    for version in ("A_before", "B_current"):
        lua, measure, attempts = configure_lua(version, case)
        missing = [entry for entry in attempts if not entry["isPng"]]
        if not attempts or missing:
            raise RuntimeError(f"{version}/{case['name']} PNG image load failed: {missing[:4]}")
        if version not in image_paths_by_version:
            image_paths_by_version[version] = attempts
        engines[version] = (lua, measure)

    samples = {version: [] for version in engines}
    for run in range(RUNS):
        order = ("A_before", "B_current") if run % 2 == 0 else ("B_current", "A_before")
        for version in order:
            _, measure = engines[version]
            samples[version].append(HOST.to_json_value(measure(FRAMES), lua_type))

    row = {
        "scenario": case["name"],
        "dimensions": [WIDTH, HEIGHT],
        "camera": case["camera"],
        "radius": case["radius"],
        "scene": case.get("scene", False),
        "drift": case.get("drift", False),
        "samples": samples,
    }
    for version, values in samples.items():
        row[version] = {
            key: statistics.median(sample[key] for sample in values)
            for key in values[0]
        }
    row["cpuReductionPercent"] = (
        1 - row["B_current"]["processCpuMsPerFrame"] / row["A_before"]["processCpuMsPerFrame"]
    ) * 100
    row["allocationReductionPercent"] = (
        1 - row["B_current"]["allocatedKiBPerFrame"] / row["A_before"]["allocatedKiBPerFrame"]
    ) * 100 if row["A_before"]["allocatedKiBPerFrame"] else None
    records.append(row)
    print(json.dumps({k: v for k, v in row.items() if k != "samples"}, ensure_ascii=False), flush=True)

report = {
    "schemaVersion": 1,
    "method": "Isolated Lua 5.4 A/B, old four presentation modules versus current four modules; process_time and perf_counter; same seed/time/config per scenario; 1 warm-up draw then alternating 4x32 measured frames; GC collected then stopped during each timed batch; one additional GC-stopped draw for allocation delta; Art.Load(ctx) and all draw calls reuse the same ctx.",
    "limitations": [
        "All NanoVG calls are Lua counting no-ops; nvgCreateImage returns a positive integer only when the requested local assets path exists and has a PNG signature.",
        "Reports offline Lua process CPU, elapsed time, allocation, and call counts only; does not measure native NanoVG cost, image decoding/upload, GPU, GUI, or FPS.",
        "Geometry/Projection remain the current optimized files in both versions. Different image specifications are recorded; PNG pixels are not rendered or visually compared.",
    ],
    "nativeFpsVerified": False,
    "config": config,
    "config_hash": config_hash,
    "versions": versions,
    "loadedPngPaths": image_paths_by_version,
    "records": records,
}
(OUT / "benchmark.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
